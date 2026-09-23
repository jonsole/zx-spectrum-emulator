#!/usr/bin/env python3
"""Build a tape designed in the VS Code tape designer.

    .venv-win\\Scripts\\python.exe scripts\\build_tape.py game.tape.json [output] [--flutter] [--sjasmplus PATH]

A design is a `*.tape.json` -- the loading scheme, the blocks keyed by name in
tape order, the entry address, the stack, and where the loader runs -- and the
`*.screen.json` it names as its loading screen: a picture and the order its
rectangles are sent in. This reads both, turns every file they name into bytes,
and hands the result to the scheme:

  rom             the Spectrum's own LOAD "": tape_rom.py writes the .tap
                  itself, or a .tzx, or renders it to a .wav or .csw
  zx-tape-loader  the fast loader in examples/zx-tape-loader: its loader.py
                  encodes it, to a .tzx whose fast part is one generalized data
                  block, or to a .wav or .csw of the waveform itself

The designer (vscode-extension/tape_view.js) runs this as a task, and makes the
same checks as it edits (tape_model.js's checkTape); this is the last word on
them, and refuses a tape that can't load.
"""
import argparse
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
FAST_LOADER = os.path.join(ROOT, 'examples', 'zx-tape-loader')
sys.path.insert(0, HERE)

import tape_rom  # noqa: E402
import tape_screen  # noqa: E402

SCHEMES = ('zx-tape-loader', 'rom')


def parse_address(value, what):
    """An address as a design writes it: "$7000", "#7000", "0x7000", "28672" or
    a number -- tape_model.js's parseAddress."""
    if value is None:
        return None
    if isinstance(value, bool):
        raise ValueError(f"{what} {value!r} is not an address")
    if isinstance(value, int):
        number = value
    else:
        text = str(value).strip()
        try:
            number = int(text[1:], 16) if text[:1] in ('$', '#') else int(text, 0)
        except ValueError:
            raise ValueError(f"{what} {value!r} is not an address")
    if not 0 <= number <= 0xFFFF:
        raise ValueError(f"{what} {value!r} is outside the 64K")
    return number


def read_json(path):
    with open(path, 'r', encoding='utf-8') as file:
        raw = json.load(file)
    if not isinstance(raw, dict):
        raise ValueError(f"{path}: expected a JSON object")
    return raw


def slice_of(path, offset, length):
    with open(path, 'rb') as file:
        data = file.read()
    end = len(data) if length is None else offset + length
    if not 0 <= offset <= end <= len(data):
        raise ValueError(f"{path}: bytes {offset}..{end} are outside its {len(data)}")
    return data[offset:end]


def read_screen(path):
    """A `*.screen.json`: the picture's 6912 bytes and the order, as
    (x, y, w, h) rectangles."""
    raw = read_json(path)
    here = os.path.dirname(os.path.abspath(path))
    if not isinstance(raw.get('picture'), str) or not raw['picture']:
        raise ValueError(f"{path}: \"picture\" names the file the screen comes from")
    regions = []
    for region in raw.get('order') or []:
        x, y, w, h = (int(region[key]) for key in ('x', 'y', 'w', 'h'))
        if not (0 <= x < 32 and 0 <= y < 24 and 1 <= w <= 32 - x and 1 <= h <= 24 - y):
            raise ValueError(f"{path}: the rectangle {x},{y} {w}x{h} is not on the screen")
        regions.append((x, y, w, h))
    picture = os.path.normpath(os.path.join(here, raw['picture']))
    return {'data': tape_screen.screen_from_file(picture), 'regions': regions, 'picture': picture}


def read_tape(path):
    """A `*.tape.json`, with everything it names read in."""
    raw = read_json(path)
    here = os.path.dirname(os.path.abspath(path))
    scheme = raw.get('scheme', 'zx-tape-loader')
    if scheme not in SCHEMES:
        raise ValueError(f"{path}: \"{scheme}\" is not a loading scheme this knows: {', '.join(SCHEMES)}")
    design = {
        'scheme': scheme,
        # Every file the design reads, so the build can refuse to write over
        # one: a design often takes its blocks straight out of the game's own
        # tape, and "game.tape.json" next to "game.tzx" would otherwise build
        # over the very image it is made of.
        'sources': set(),
        'loader': parse_address(raw.get('loaderAddress'), 'the loader address'),
        'stack': parse_address(raw.get('stack'), 'the stack address'),
        'screen': None,
        'blocks': [],
        'entry': parse_address(raw.get('entry'), 'the entry address'),
        'output': os.path.normpath(os.path.join(here, raw['output'])) if raw.get('output') else None,
    }
    if raw.get('loadingScreen'):
        screen_path = os.path.normpath(os.path.join(here, raw['loadingScreen']))
        design['screen'] = read_screen(screen_path)
        design['sources'].add(os.path.abspath(screen_path))
        design['sources'].add(os.path.abspath(design['screen']['picture']))
    blocks = raw.get('blocks') or {}
    if not isinstance(blocks, dict):
        raise ValueError(f"{path}: \"blocks\" is an object of blocks keyed by name")
    for name, block in blocks.items():
        if not isinstance(block, dict) or not isinstance(block.get('file'), str):
            raise ValueError(f"{path}: block \"{name}\" needs a \"file\"")
        source = os.path.normpath(os.path.join(here, block['file']))
        design['sources'].add(os.path.abspath(source))
        design['blocks'].append({
            'name': name,
            'address': parse_address(block.get('address'), f'block "{name}"\'s address'),
            'data': slice_of(source, int(block.get('offset') or 0), block.get('length')),
        })
        if design['blocks'][-1]['address'] is None:
            raise ValueError(f"{path}: block \"{name}\" has no address to load at")
    return design


def fast_loader():
    """The zx-tape-loader submodule's loader.py, or why not."""
    if not os.path.isfile(os.path.join(FAST_LOADER, 'loader.py')):
        raise ValueError("the zx-tape-loader scheme needs examples/zx-tape-loader: "
                         "git submodule update --init")
    sys.path.insert(0, FAST_LOADER)
    import loader
    return loader


def default_output(design, base):
    """What to build when the design names nothing: the design's own name with
    the scheme's extension -- unless that is a file the design is made from,
    which it well may be, since a design is often the blocks of the game's own
    tape. tape_view.js's outputOf picks the same name."""
    kind = '.tap' if design['scheme'] == 'rom' else '.tzx'
    if os.path.abspath(base + kind) not in design['sources']:
        return base + kind
    return base + ('-rom' if design['scheme'] == 'rom' else '-fast') + kind


def main():
    parser = argparse.ArgumentParser(description="Build a tape from a *.tape.json design.")
    parser.add_argument('tape', help='the *.tape.json')
    parser.add_argument('output', nargs='?', default=None,
                        help='what to write: .tap (rom only), .tzx, .wav or .csw (default: the '
                             'design\'s "output", else its name as a .tap for rom or a .tzx)')
    parser.add_argument('--flutter', action='store_true',
                        help='give a .wav the wow and flutter of a real cassette')
    parser.add_argument('--sjasmplus', default=None,
                        help='sjasmplus, needed only when a zx-tape-loader design moves its loader or its stack')
    args = parser.parse_args()

    try:
        design = read_tape(args.tape)
        base = args.tape[:-len('.tape.json')] if args.tape.lower().endswith('.tape.json') \
            else os.path.splitext(args.tape)[0]
        output = args.output or design['output'] or default_output(design, base)
        kind = os.path.splitext(output)[1].lower()
        if os.path.abspath(output) in design['sources']:
            raise ValueError(f"{output} is one of the files this tape is made from: name the output "
                             "something else, or give the design an \"output\"")

        if design['scheme'] == 'rom':
            errors, warnings = tape_rom.check(design)
            if errors:
                raise ValueError('this tape would not load:\n  ' + '\n  '.join(errors))
            tap = tape_rom.tap(design, os.path.basename(base))
            seconds = tape_rom.seconds(tap)
            if kind == '.tap':
                with open(output, 'wb') as file:
                    file.write(tap)
            elif kind == '.tzx':
                with open(output, 'wb') as file:
                    file.write(tape_rom.tzx(tap))
            else:
                loader = fast_loader()
                gen = loader.TapeGenerator()
                loader.encode_tap_bytes(gen, tap)
                # A few pulses after the last block, so its last bit's edges are
                # never the last edges on the tape: whether the edge into the
                # silence survives depends on the level the tape stops at, and
                # when it doesn't the ROM fails the block's final bit -- "R Tape
                # loading error" on the last LOAD ""CODE. The ROM has finished
                # with the block by the time these play.
                for _ in range(8):
                    gen.pulse(855)
                gen.pulse(1000000)
                write_audio(loader, gen, output, kind, args.flutter)
        else:
            if kind == '.tap':
                raise ValueError("the fast loader's own encoding is not a .tap: build a .tzx, whose "
                                 "generalized data block can say it, or a .wav or .csw of the waveform")
            loader = fast_loader()
            gen, warnings = loader.build_designed_tape(
                {'loader': design['loader'], 'stack': design['stack'], 'screen': design['screen'],
                 'blocks': design['blocks'], 'entry': design['entry']},
                sjasmplus=args.sjasmplus)
            seconds = sum(gen.pulses) / 3500000
            if kind == '.tzx':
                if args.flutter:
                    raise ValueError("wow and flutter is something a recording has: build a .wav for it")
                loader.write_tzx(gen, output)
            else:
                write_audio(loader, gen, output, kind, args.flutter)
    except (OSError, ValueError, KeyError, TypeError) as err:
        print(f"{args.tape}: {err}", file=sys.stderr)
        sys.exit(1)

    for warning in warnings:
        print(f"warning: {warning}")
    print(f"Wrote {output} ({design['scheme']}, {seconds:.1f}s of tape)")


def write_audio(loader, gen, output, kind, flutter):
    if kind == '.csw':
        loader.write_csw(gen, output)
    elif kind == '.wav':
        loader.write_wav(loader.wow_flutter_samples(gen) if flutter else gen.samples, output)
    else:
        raise ValueError(f"can't write a {kind}: a .tap, .tzx, .wav or .csw")


if __name__ == '__main__':
    main()
