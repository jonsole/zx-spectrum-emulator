# Third-party notices

The project's own code is under the MIT licence in [LICENSE](LICENSE). The
parts below are other people's, carried under their own terms. A release
(`zx_server.exe` and the VS Code extension's `.vsix`) contains the first four;
the last is in this repository but in no release.

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

## floooh/chips (repository only)

`vendor/chips/z80.h` and `z80_desc.yml`, zlib-licensed, used only by the
test suite as a reference Z80 to compare against. Not in any release.
