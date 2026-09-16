#include "rewind.h"

#if ZX_REWIND

namespace zx {

History::History(RewindSettings settings) : settings_(settings) {
    if (settings_.checkpoint_frames == 0) {
        settings_.checkpoint_frames = 1;
    }
}

void History::start(Spectrum& m) {
    checkpoints_.clear();
    log_.clear();
    log_base_ = 0;
    bytes_ = 0;
    live_ = true;
    head_hc_ = 0;
    cursor_ = 0;
    last_frame_ = m.ula.frame_count();
    take_checkpoint(m);
}

// ---- recording ------------------------------------------------------------

void History::on_frame(Spectrum& m) {
    const uint64_t frame = m.ula.frame_count();
    last_frame_ = frame;
    if (frame % settings_.checkpoint_frames != 0) {
        return;
    }
    take_checkpoint(m);
    trim(m);
}

void History::take_checkpoint(Spectrum& m) {
    Checkpoint cp;
    m.save_state(cp.state);
    cp.hc = m.global_hc();
    cp.log_index = log_end();
    cp.bytes = Spectrum::state_bytes(cp.state);
    bytes_ += cp.bytes;
    checkpoints_.push_back(std::move(cp));
}

void History::trim(const Spectrum& m) {
    const uint64_t now = m.global_hc();
    const uint64_t window = uint64_t(settings_.max_seconds) * m.ula.timing().hc_per_sec;
    // Drop the oldest while the checkpoint after it still covers the window
    // (or the history is over its size), so what remains always reaches back
    // at least `window` when it can.
    while (checkpoints_.size() > 1) {
        const bool old_enough = now - checkpoints_[1].hc >= window;
        const bool too_big = bytes_ > settings_.max_bytes;
        if (!old_enough && !too_big) {
            break;
        }
        bytes_ -= checkpoints_.front().bytes;
        checkpoints_.pop_front();
    }
    // Inputs before the oldest checkpoint can never be replayed again.
    const uint64_t first_needed = checkpoints_.front().log_index;
    while (!log_.empty() && log_base_ < first_needed) {
        log_.pop_front();
        log_base_++;
    }
}

void History::record(Spectrum& m, RewindInput input) {
    if (!live_) {
        branch(m);
    }
    input.hc = m.global_hc();
    apply(m, input);
    log_.push_back(std::move(input));
}

void History::branch(Spectrum& m) {
    const uint64_t now = m.global_hc();
    // Checkpoints after the present belong to the future being discarded.
    while (checkpoints_.size() > 1 && checkpoints_.back().hc > now) {
        bytes_ -= checkpoints_.back().bytes;
        checkpoints_.pop_back();
    }
    // So do the inputs not yet applied: everything from the cursor on.
    if (!live_) {
        while (log_end() > cursor_ && !log_.empty()) {
            log_.pop_back();
        }
    }
    live_ = true;
    last_frame_ = m.ula.frame_count();
}

// ---- replay -----------------------------------------------------------------

void History::apply(Spectrum& m, const RewindInput& input) {
    switch (input.kind) {
        case RewindInputKind::Keys:
            m.keyboard.set_rows(input.keys);
            break;
        case RewindInputKind::Registers:
            m.set_registers(input.regs);
            break;
        case RewindInputKind::Memory:
            m.write_memory(input.addr, input.bytes.data(), input.bytes.size());
            break;
        case RewindInputKind::TapePlay:
            m.tape.play(m.global_hc());
            break;
        case RewindInputKind::TapeStop:
            m.tape.stop();
            break;
        case RewindInputKind::TapeRewind:
            m.tape.rewind();
            break;
        case RewindInputKind::TapeSeek:
            m.tape.seek(size_t(input.value));
            break;
        case RewindInputKind::TapeFastLoad:
            m.tape.set_fast_load(input.value != 0);
            break;
        case RewindInputKind::RawClocks:
            break; // run by apply_due, not here
    }
}

bool History::apply_due(Spectrum& m, uint64_t limit) {
    while (cursor_ < log_end()) {
        const RewindInput& input = log_at(cursor_);
        const uint64_t now = m.global_hc();
        if (input.hc > now) {
            return false;
        }
        if (input.kind != RewindInputKind::RawClocks) {
            apply(m, input);
            cursor_++;
            continue;
        }
        // A raw span. Nothing is logged inside one -- the Engine clocks it in
        // a single job -- but a replay may have to stop part-way through, to
        // land on a boundary inside it, and carry on from there later. So the
        // cursor stays on the span until the clock has passed its end.
        const uint64_t end = input.hc + input.value;
        if (now >= end) {
            cursor_++;
            continue;
        }
        if (now >= limit) {
            return false;
        }
        for (;;) {
            if (noting_ != nullptr && m.cpu.is_instruction_boundary()) {
                (*noting_)(m);
            }
            m.clock();
            if (m.global_hc() >= end || m.global_hc() >= limit) {
                break;
            }
        }
        if (m.global_hc() >= end) {
            cursor_++;
        }
        return true;
    }
    return false;
}

void History::replay(Spectrum& m, size_t index, uint64_t target_hc,
                     const std::function<void(Spectrum&)>& before_instruction) {
    // Nothing leaves the machine while it replays. The audio especially:
    // generating it costs, and what it would play is the past at many times
    // real speed.
    Profile* profile = m.profile;
    TraceLog* trace = m.trace;
    const bool audio = m.beeper.enabled();
    std::vector<uint8_t> watch = m.watch_flags();
    const WatchHit watch_hit = m.watch_hit;
    m.profile = nullptr;
    m.trace = nullptr;
    m.beeper.set_enabled(false, m.global_hc());
    m.set_watch_flags(replay_watch_);
    m.watch_hit = WatchHit();
    noting_ = before_instruction ? &before_instruction : nullptr;

    const Checkpoint& cp = checkpoints_[index];
    m.restore_state(cp.state);
    cursor_ = cp.log_index;
    for (;;) {
        if (apply_due(m, target_hc)) {
            continue;
        }
        if (m.global_hc() >= target_hc) {
            break;
        }
        if (before_instruction) {
            before_instruction(m);
        }
        m.step_instruction();
    }

    noting_ = nullptr;
    last_replay_hit_ = m.watch_hit.hit;
    m.profile = profile;
    m.trace = trace;
    m.set_watch_flags(std::move(watch));
    m.watch_hit = watch_hit;
    m.beeper.restart_at(m.global_hc());
    m.beeper.set_enabled(audio, m.global_hc());
}

void History::catch_up(Spectrum& m) {
    while (apply_due(m, UINT64_MAX)) {
    }
    if (m.global_hc() >= head_hc_ && cursor_ >= log_end()) {
        live_ = true;
        last_frame_ = m.ula.frame_count();
    }
}

void History::return_to_live(Spectrum& m) {
    if (live_) {
        return;
    }
    const size_t index = checkpoint_before(m.global_hc() + 1);
    replay(m, index < checkpoints_.size() ? index : 0, head_hc_, nullptr);
    live_ = true;
    last_frame_ = m.ula.frame_count();
}

// ---- going back ---------------------------------------------------------------

size_t History::checkpoint_before(uint64_t hc) const {
    size_t found = checkpoints_.size();
    for (size_t i = 0; i < checkpoints_.size(); i++) {
        if (checkpoints_[i].hc < hc) {
            found = i;
        } else {
            break;
        }
    }
    return found;
}

void History::land(Spectrum& m, uint64_t target_hc) {
    // A whole frame before the target when the history reaches that far, so
    // the replay redraws the last completed picture and the one in progress.
    const uint64_t frame = m.ula.timing().hc_per_frame();
    const uint64_t from = target_hc > frame ? target_hc - frame : 0;
    size_t index = checkpoint_before(from + 1);
    if (index >= checkpoints_.size()) {
        index = 0;
    }
    replay(m, index, target_hc, nullptr);
    if (m.global_hc() >= head_hc_ && cursor_ >= log_end()) {
        live_ = true;
        last_frame_ = m.ula.frame_count();
    }
}

History::Result History::go_back(Spectrum& m, RewindOp op, uint16_t address,
                                 const std::function<bool()>& cancelled) {
    Result result;
    const uint64_t present = m.global_hc();
    const uint32_t depth = uint32_t(m.call_stack.size());
    if (live_) {
        head_hc_ = present;
        cursor_ = log_end();
        live_ = false;
    }

    // A search borrows the bus the way a watchpoint does, so it sees exactly
    // what one would -- see spectrum.h's watch flags. Run Back to Last Write
    // installs a watch of its own; Reverse Continue takes the machine's, so
    // that running backwards stops at a watchpoint as running forwards does.
    replay_watch_.clear();
    if (op == RewindOp::RunBackToWrite) {
        replay_watch_.assign(WATCH_ADDRESSES, 0);
        replay_watch_[address] = WATCH_WRITE;
    } else if (op == RewindOp::ReverseContinue) {
        replay_watch_ = m.watch_flags();
    }

    std::vector<RewindMark> marks;
    auto note = [this, &marks](Spectrum& machine) {
        // The hit belongs to the instruction that has just run, which is the
        // boundary before this one.
        if (machine.watch_hit.hit && !marks.empty()
            && (!watch_filter_ || watch_filter_(machine.watch_hit))) {
            marks.back().watched = true;
        }
        machine.watch_hit.hit = false;
        RewindMark mark;
        mark.hc = machine.global_hc();
        mark.pc = machine.registers().pc;
        mark.depth = uint32_t(machine.call_stack.size());
        mark.halted = machine.cpu.halted;
        // A HALT waiting is thousands of identical boundaries a frame; one
        // stands for the run of them, so stepping back crosses it in a step.
        if (mark.halted && !marks.empty() && marks.back().halted && marks.back().pc == mark.pc) {
            return;
        }
        marks.push_back(mark);
    };

    bool found = false;
    uint64_t target = 0;
    uint64_t end = present;
    size_t index = checkpoint_before(present);
    while (index < checkpoints_.size()) {
        marks.clear();
        replay(m, index, end, note);
        // replay() puts the machine's own watch state back as it found it, so
        // a hit on the interval's last instruction is read from what it left
        // behind rather than from the callback, which does not run again.
        if (last_replay_hit_ && !marks.empty()) {
            marks.back().watched = true;
        }

        for (size_t i = marks.size(); i-- > 0;) {
            const RewindMark& b = marks[i];
            if (b.hc >= present) {
                continue;
            }
            bool match = false;
            switch (op) {
                case RewindOp::StepBackInto: match = true; break;
                case RewindOp::StepBackOver: match = b.depth <= depth; break;
                case RewindOp::StepBackOut: match = b.depth < depth; break;
                case RewindOp::ReverseContinue:
                    match = m.breakpoints.count(b.pc) != 0 || b.watched;
                    break;
                case RewindOp::RunBackToAddress: match = b.pc == address; break;
                case RewindOp::RunBackToWrite: match = b.watched; break;
            }
            if (match) {
                found = true;
                target = b.hc;
                break;
            }
        }
        if (found) {
            break;
        }
        if (cancelled && cancelled()) {
            result.cancelled = true;
            break;
        }
        if (index == 0) {
            break;
        }
        end = checkpoints_[index].hc;
        index--;
    }

    replay_watch_.clear();

    if (!found && !result.cancelled && op == RewindOp::ReverseContinue && !checkpoints_.empty()
        && checkpoints_.front().hc < present) {
        found = true;
        target = checkpoints_.front().hc;
    }
    land(m, found ? target : present);
    result.moved = found;
    return result;
}

} // namespace zx

#endif // ZX_REWIND
