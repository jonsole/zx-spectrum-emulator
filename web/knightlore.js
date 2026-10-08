// web/knightlore.html: takes the visitor's copy of Knight Lore, makes the
// remake with remake.js, and offers it as a download or hands it to the
// emulator page to play.
'use strict';

(async function () {
    const pick = document.getElementById('pick');
    const fileInput = document.getElementById('file');
    const result = document.getElementById('result');
    const done = document.getElementById('done');
    const download = document.getElementById('download');
    const play = document.getElementById('play');

    /// Where the emulator page (main.js) keeps the snapshot it opens on its
    /// next visit, and in what form. Playing is putting the remake there.
    const EMULATOR_SNAPSHOT_KEY = 'zx-web-snapshot';
    const NAME = 'knightlore.z80';

    function say(text, failed) {
        result.textContent = text;
        result.classList.toggle('failed', Boolean(failed));
    }

    let template = null;
    let info = null;
    try {
        const [bin, json] = await Promise.all([fetch('knightlore/template.bin'),
                                               fetch('knightlore/template.json')]);
        if (!bin.ok || !json.ok) {
            throw new Error(bin.ok ? json.status : bin.status);
        }
        template = new Uint8Array(await bin.arrayBuffer());
        info = await json.json();
    } catch (e) {
        say('This site was built without the remake (' + e.message + ').', true);
        pick.hidden = true;
        return;
    }

    let made = null;
    let url = null;

    async function make(file) {
        done.hidden = true;
        say('Reading ' + file.name + '…');
        try {
            made = await KnightLoreRemake.remake(template, info,
                                                 new Uint8Array(await file.arrayBuffer()), file.name);
        } catch (e) {
            made = null;
            say(e instanceof KnightLoreRemake.RemakeError ? e.message
                : file.name + ' could not be read (' + e.message + ').', true);
            return;
        }
        if (url !== null) {
            URL.revokeObjectURL(url);
        }
        url = URL.createObjectURL(new Blob([made], { type: 'application/octet-stream' }));
        download.href = url;
        done.hidden = false;
        say(file.name + ' is Knight Lore: the remake is ready.');
    }

    play.addEventListener('click', () => {
        try {
            let binary = '';
            for (let i = 0; i < made.length; i++) {
                binary += String.fromCharCode(made[i]);
            }
            localStorage.setItem(EMULATOR_SNAPSHOT_KEY, JSON.stringify({ name: NAME, data: btoa(binary) }));
        } catch (e) {
            say('This browser would not hand the remake to the emulator (' + e.message
                + '). Download it, then open it in the emulator.', true);
            return;
        }
        location.href = 'index.html';
    });

    fileInput.addEventListener('change', () => {
        if (fileInput.files.length > 0) {
            make(fileInput.files[0]);
        }
        fileInput.value = '';
    });
    pick.addEventListener('dragover', (event) => {
        event.preventDefault();
        pick.classList.add('over');
    });
    pick.addEventListener('dragleave', () => pick.classList.remove('over'));
    pick.addEventListener('drop', (event) => {
        event.preventDefault();
        pick.classList.remove('over');
        if (event.dataTransfer.files.length > 0) {
            make(event.dataTransfer.files[0]);
        }
    });
})();
