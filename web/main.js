// The page around the WebAssembly core: loads the ROMs, takes a snapshot from
// a file or a drop, runs the machine a frame at a time against the clock,
// draws each frame and plays what the beeper made of it.
'use strict';

(async function () {
    const canvas = document.getElementById('screen');
    const drop = document.getElementById('drop');
    const fileInput = document.getElementById('file');
    const statusLine = document.getElementById('status');
    const soundButton = document.getElementById('sound');

    /// Where the last snapshot opened is kept, so a visit comes back to it.
    const STORE_KEY = 'zx-web-snapshot';
    /// Frames to catch up at most after the tab was in the background, so
    /// coming back does not run the game fast for minutes.
    const MAX_CATCH_UP = 4;
    /// How far ahead of the audio clock to queue samples: enough that a late
    /// animation frame does not leave a gap, little enough not to be heard as
    /// lag between a key and its sound.
    const AUDIO_LEAD = 0.06;
    /// Beyond this much queued, a frame's samples are dropped rather than
    /// queued, so lag cannot build up when the clocks drift apart.
    const AUDIO_MAX_LEAD = 0.25;
    /// The fewest frames a key is held for, however quickly it is tapped. A
    /// program reads the keyboard once an interrupt, so a tap that goes down
    /// and up between two frames would otherwise never be seen at all.
    const MIN_HOLD_FRAMES = 3;

    function status(text) {
        statusLine.textContent = text;
    }

    status('Loading the emulator…');
    const zx = await createZx();

    function withBytes(bytes, fn) {
        const p = zx._zx_alloc(bytes.length);
        zx.HEAPU8.set(bytes, p);
        try {
            return fn(p, bytes.length);
        } finally {
            zx._zx_free(p);
        }
    }

    function errorOf(ptr) {
        return ptr ? zx.UTF8ToString(ptr) : null;
    }

    async function fetchBytes(url) {
        const response = await fetch(url);
        if (!response.ok) {
            throw new Error(url + ': ' + response.status);
        }
        return new Uint8Array(await response.arrayBuffer());
    }

    try {
        for (const name of ['roms/48.rom', 'roms/128.rom']) {
            const error = withBytes(await fetchBytes(name), (p, n) => errorOf(zx._zx_load_rom(p, n)));
            if (error) {
                throw new Error(name + ': ' + error);
            }
        }
    } catch (e) {
        status('Could not load the ROMs (' + e.message + ').');
        return;
    }
    zx._zx_reset();

    // ---- the screen -------------------------------------------------------

    const width = zx._zx_screen_width();
    const height = zx._zx_screen_height();
    canvas.width = width;
    canvas.height = height;
    const context = canvas.getContext('2d');
    const image = context.createImageData(width, height);

    function draw() {
        const rgb = zx.HEAPU8.subarray(zx._zx_screen(), zx._zx_screen() + width * height * 3);
        const out = image.data;
        for (let i = 0, j = 0; i < rgb.length; i += 3, j += 4) {
            out[j] = rgb[i];
            out[j + 1] = rgb[i + 1];
            out[j + 2] = rgb[i + 2];
            out[j + 3] = 255;
        }
        context.putImageData(image, 0, 0);
    }

    // ---- sound ------------------------------------------------------------

    // Browsers start audio only from a user gesture, so it is off until the
    // button is pressed.
    let audio = null;
    let audioTime = 0;

    function setSound(on) {
        if (on && audio === null) {
            audio = new AudioContext();
            zx._zx_set_sample_rate(audio.sampleRate);
        }
        if (audio !== null) {
            if (on) {
                audio.resume();
            } else {
                audio.suspend();
            }
        }
        soundButton.setAttribute('aria-pressed', on ? 'true' : 'false');
        soundButton.textContent = on ? 'Sound on' : 'Sound off';
    }

    function play() {
        const length = zx._zx_audio_length();
        if (audio === null || audio.state !== 'running' || length === 0) {
            return;
        }
        const now = audio.currentTime;
        if (audioTime < now) {
            audioTime = now + AUDIO_LEAD;
        }
        if (audioTime > now + AUDIO_MAX_LEAD) {
            return;
        }
        const samples = zx.HEAP16.subarray(zx._zx_audio() >> 1, (zx._zx_audio() >> 1) + length);
        const buffer = audio.createBuffer(1, length, audio.sampleRate);
        const channel = buffer.getChannelData(0);
        for (let i = 0; i < length; i++) {
            channel[i] = samples[i] / 32768;
        }
        const source = audio.createBufferSource();
        source.buffer = buffer;
        source.connect(audio.destination);
        source.start(audioTime);
        audioTime += length / audio.sampleRate;
    }

    soundButton.addEventListener('click', () => {
        setSound(soundButton.getAttribute('aria-pressed') !== 'true');
        canvas.focus();
    });

    // ---- the keyboard -----------------------------------------------------

    // The PC key (KeyboardEvent.code) to the Spectrum keys it presses.
    const KEYS = {
        Enter: ['ENTER'], NumpadEnter: ['ENTER'], Space: ['SPACE'],
        ShiftLeft: ['CAPS SHIFT'], ShiftRight: ['CAPS SHIFT'],
        ControlLeft: ['SYM SHIFT'], ControlRight: ['SYM SHIFT'],
        AltLeft: ['SYM SHIFT'], AltRight: ['SYM SHIFT'],
        // The cursor joystick reads the keys under the arrows, unshifted.
        ArrowLeft: ['5'], ArrowDown: ['6'], ArrowUp: ['7'], ArrowRight: ['8'],
        Backspace: ['CAPS SHIFT', '0'],
        Comma: ['SYM SHIFT', 'N'], Period: ['SYM SHIFT', 'M'],
        Quote: ['SYM SHIFT', 'P'], Semicolon: ['SYM SHIFT', 'O'],
        Minus: ['SYM SHIFT', 'J'], Equal: ['SYM SHIFT', 'L'],
        Slash: ['SYM SHIFT', 'V'],
    };
    for (let c = 65; c <= 90; c++) {
        const letter = String.fromCharCode(c);
        KEYS['Key' + letter] = [letter];
    }
    for (let d = 0; d <= 9; d++) {
        KEYS['Digit' + d] = [String(d)];
        KEYS['Numpad' + d] = [String(d)];
    }

    // How many held PC keys are pressing each Spectrum key, so letting go of
    // Backspace does not release a CAPS SHIFT that Shift is still holding.
    const held = new Map();
    const down = new Set();
    /// Each held PC key's frame count when it went down, and the keys let go
    /// of too soon, waiting for MIN_HOLD_FRAMES to pass before they go up.
    const downAt = new Map();
    const lateUp = new Set();
    let frames = 0;

    function press(code, isDown) {
        const keys = KEYS[code];
        if (isDown && lateUp.delete(code)) {
            // Pressed again before its last tap was let go: it stays down.
            return true;
        }
        if (!keys || down.has(code) === isDown) {
            return keys !== undefined;
        }
        if (isDown) {
            down.add(code);
            downAt.set(code, frames);
            lateUp.delete(code);
        } else {
            if (frames - downAt.get(code) < MIN_HOLD_FRAMES) {
                lateUp.add(code);
                return true;
            }
            down.delete(code);
        }
        for (const key of keys) {
            const count = (held.get(key) || 0) + (isDown ? 1 : -1);
            held.set(key, count);
            if ((isDown && count === 1) || (!isDown && count === 0)) {
                const name = zx.stringToNewUTF8(key);
                zx._zx_key(name, isDown ? 1 : 0);
                zx._zx_free(name);
            }
        }
        return true;
    }

    function releaseLate() {
        for (const code of lateUp) {
            if (frames - downAt.get(code) >= MIN_HOLD_FRAMES) {
                lateUp.delete(code);
                press(code, false);
            }
        }
    }

    function releaseAll() {
        down.clear();
        held.clear();
        lateUp.clear();
        zx._zx_keys_clear();
    }

    function typing(event) {
        return event.target instanceof HTMLInputElement || event.metaKey;
    }

    window.addEventListener('keydown', (event) => {
        if (!typing(event) && press(event.code, true)) {
            event.preventDefault();
        }
    });
    window.addEventListener('keyup', (event) => {
        if (down.has(event.code) && press(event.code, false)) {
            event.preventDefault();
        }
    });
    window.addEventListener('blur', releaseAll);

    // ---- snapshots --------------------------------------------------------

    let running = false;

    function load(bytes, name) {
        const error = withBytes(bytes, (p, n) => errorOf(zx._zx_load_snapshot(p, n)));
        if (error) {
            status(name + ': ' + error);
            return false;
        }
        if (audio !== null) {
            zx._zx_set_sample_rate(audio.sampleRate);
        }
        releaseAll();
        running = true;
        drop.hidden = true;
        status(name + (zx._zx_is_128k() ? ' (128K)' : ' (48K)'));
        canvas.focus();
        return true;
    }

    function remember(bytes, name) {
        try {
            let binary = '';
            for (let i = 0; i < bytes.length; i++) {
                binary += String.fromCharCode(bytes[i]);
            }
            localStorage.setItem(STORE_KEY, JSON.stringify({ name, data: btoa(binary) }));
        } catch (e) {
            // Storage full or blocked: the snapshot still runs, it just will
            // not be there next time.
        }
    }

    function recall() {
        try {
            const saved = JSON.parse(localStorage.getItem(STORE_KEY));
            if (!saved) {
                return false;
            }
            const binary = atob(saved.data);
            const bytes = new Uint8Array(binary.length);
            for (let i = 0; i < binary.length; i++) {
                bytes[i] = binary.charCodeAt(i);
            }
            return load(bytes, saved.name);
        } catch (e) {
            return false;
        }
    }

    async function open(file) {
        const bytes = new Uint8Array(await file.arrayBuffer());
        if (load(bytes, file.name)) {
            remember(bytes, file.name);
        }
    }

    fileInput.addEventListener('change', () => {
        if (fileInput.files.length > 0) {
            open(fileInput.files[0]);
        }
        fileInput.value = '';
    });
    document.getElementById('open').addEventListener('click', () => fileInput.click());

    const stage = document.getElementById('stage');
    stage.addEventListener('dragover', (event) => {
        event.preventDefault();
        drop.hidden = false;
        drop.classList.add('over');
    });
    stage.addEventListener('dragleave', () => {
        drop.classList.remove('over');
        drop.hidden = running;
    });
    stage.addEventListener('drop', (event) => {
        event.preventDefault();
        drop.classList.remove('over');
        drop.hidden = running;
        if (event.dataTransfer.files.length > 0) {
            open(event.dataTransfer.files[0]);
        }
    });

    document.getElementById('reset').addEventListener('click', () => {
        // Reset is the BASIC prompt -- worth having running, to show the
        // emulator is alive before there is anything to open.
        zx._zx_reset();
        releaseAll();
        running = true;
        drop.hidden = true;
        status('Reset');
        canvas.focus();
    });

    document.getElementById('full').addEventListener('click', () => {
        if (stage.requestFullscreen) {
            stage.requestFullscreen();
        }
        canvas.focus();
    });

    // ---- the frame loop ---------------------------------------------------

    // Frames are run against the wall clock rather than one per animation
    // frame: a 48K runs at 50.08Hz, and a 60Hz or 144Hz display would
    // otherwise run the game at its own rate.
    let last = performance.now();
    let owed = 0;

    function tick(now) {
        const frameMs = 1e6 / zx._zx_frame_rate_milli();
        owed += now - last;
        last = now;
        if (owed > frameMs * MAX_CATCH_UP) {
            owed = frameMs;
        }
        let ran = false;
        while (running && owed >= frameMs) {
            zx._zx_run_frame();
            frames++;
            releaseLate();
            play();
            owed -= frameMs;
            ran = true;
        }
        if (!running) {
            owed = 0;
        }
        if (ran) {
            draw();
        }
        requestAnimationFrame(tick);
    }

    if (!recall()) {
        status('Open a snapshot to start');
    }
    draw();
    requestAnimationFrame(tick);
})();
