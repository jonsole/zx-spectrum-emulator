# Third-party notices

The project's own code is under the MIT licence in [LICENSE](LICENSE). The
parts below are other people's, carried under their own terms. Each section
says which parts of a release carry it: `zx_server.exe` and its zip, the VS
Code extension's `.vsix`, and the example workspaces' zips. The last is in
this repository but in no release.

## ZX Spectrum ROMs

`roms/48.rom` (the 48K ROM) and `roms/128.rom` (the 128K's ROM 0 and ROM 1,
joined) are copyright Amstrad plc. They are not in this repository; a release
bundles them, taken from the [Fuse](https://fuse-emulator.sourceforge.net/)
emulator's source and checked byte for byte against pinned SHA-256 hashes
(see `scripts/fetch_roms.py`).

Amstrad allow distribution of the ROMs but retain the copyright. As Fuse's
`roms/README.copyright` puts it:

> These are copyright Amstrad, who allow distribution of the ROMs but retain
> the copyright. You may not sell the ROMs or embed the ROMs in hardware,
> although it is allowed to sell a product which contains the ROMs, so long as
> the charge is being made for the product, not for the ROMs themselves. See
> <http://groups.google.com/group/comp.sys.amstrad.8bit/msg/c092cc4d4943131e>
> for more details.

## JSON for Modern C++ (nlohmann/json) 3.11.3

`cpp-core/third_party/nlohmann/json.hpp`, compiled into `zx_server`.

> MIT License
>
> Copyright (c) 2013-2023 Niels Lohmann
>
> Permission is hereby granted, free of charge, to any person obtaining a copy
> of this software and associated documentation files (the "Software"), to deal
> in the Software without restriction, including without limitation the rights
> to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
> copies of the Software, and to permit persons to whom the Software is
> furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in
> all copies or substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
> IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
> FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
> AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
> LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
> OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
> SOFTWARE.

## miniz

`cpp-core/third_party/miniz/`, compiled into `zx_server` (inflate only, for
compressed tape and snapshot data).

> Copyright 2013-2014 RAD Game Tools and Valve Software
> Copyright 2010-2014 Rich Geldreich and Tenacious Software LLC
>
> All Rights Reserved.
>
> Permission is hereby granted, free of charge, to any person obtaining a copy
> of this software and associated documentation files (the "Software"), to deal
> in the Software without restriction, including without limitation the rights
> to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
> copies of the Software, and to permit persons to whom the Software is
> furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in
> all copies or substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
> IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
> FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
> AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
> LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
> OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
> THE SOFTWARE.

## stb_image_write 1.16

`cpp-core/third_party/stb_image_write.h`, compiled into `zx_server` (the
screen stream's PNG frames). Public domain, or at your choice:

> MIT License
>
> Copyright (c) 2017 Sean Barrett
>
> Permission is hereby granted, free of charge, to any person obtaining a copy
> of this software and associated documentation files (the "Software"), to deal
> in the Software without restriction, including without limitation the rights
> to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
> copies of the Software, and to permit persons to whom the Software is
> furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in
> all copies or substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
> IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
> FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
> AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
> LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
> OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
> SOFTWARE.

## sjasmplus 1.23.1

Not in any release. The VS Code extension fetches the official Windows build
from sjasmplus's own GitHub release the first time the example workspaces or
the tape designer need an assembler, checked against a pinned SHA-256, and
keeps it in its own storage; `scripts/fetch_sjasmplus.py` fetches the same one
into a checkout, and is what assembles the ROM disassembly and the Filmation
games a release carries. Its licence, for anyone passing a copy on:
<https://github.com/z00m128/sjasmplus>

> Copyright (c) 2016, aprisobal
> All rights reserved.
>
> Redistribution and use in source and binary forms, with or without
> modification, are permitted provided that the following conditions are met:
>
> * Redistributions of source code must retain the above copyright notice, this
>   list of conditions and the following disclaimer.
>
> * Redistributions in binary form must reproduce the above copyright notice,
>   this list of conditions and the following disclaimer in the documentation
>   and/or other materials provided with the distribution.
>
> * Neither the name of sjasmplus nor the names of its
>   contributors may be used to endorse or promote products derived from
>   this software without specific prior written permission.
>
> THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
> AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
> IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
> DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
> FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
> DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
> SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
> CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
> OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
> OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

## zx-tape-loader

`builder/zx-tape-loader/` in the extension's `.vsix`: the fast tape loader the
tape designer builds with -- its Python and its Z80 source. The same author's
own project, <https://github.com/jonsole/zx-tape-loader>, checked out in this
repository as the `examples/zx-tape-loader` submodule.

## The Complete Spectrum ROM Disassembly

`rom_disassembly/rom.asm` and `rom.sld` in the ROM example workspace's zip.
*The Complete Spectrum ROM Disassembly* is by Dr Ian Logan and Dr Frank
O'Hara; the text here is Richard Dymond's SkoolKit edition of it,
<https://github.com/skoolkid/rom>, converted to assembly source by SkoolKit's
`skool2asm.py` and assembled with sjasmplus by `scripts/build_rom_source.py`.
The ROM it describes is copyright Amstrad. The disassembly's text remains its
authors'; it is published with no licence of its own, and is not in this
repository.

## Knight Lore and Pentagram (Ultimate Play the Game)

*Knight Lore* (1984) and *Pentagram* (1986) are copyright Ultimate Play the
Game. The remakes' code and the Filmation engine are this project's own (MIT).
Their art -- the sprites, the font -- and their worlds' data -- the rooms,
what is in them -- come from the original games.

The Knight Lore and Pentagram example workspaces' zips carry **none** of it:
each makes it from the user's own copy of the original
(`examples/filmation/extract.py`), checked against `original.json`, which
holds only hashes. What they carry of the games is `graphics.json` -- which
sprite each graphic number draws and the nudge that places it, the remake's
own table. This repository carries the extracted JSON and `sprites.png` for
`examples/filmation/knightlore/` and `pentagram/`, as the editable source the
builds read.

## floooh/chips (repository only)

`vendor/chips/z80.h` and `z80_desc.yml`, zlib-licensed, used only by the
test suite as a reference Z80 to compare against. Not in any release.
