# Configures and builds cpp-core with the MSVC toolchain that ships with
# VS 2022 Build Tools. None of cl.exe / cmake.exe / ninja.exe are on PATH by
# default -- they live inside the Build Tools install and need vcvars64.bat's
# environment -- so this script locates them itself rather than assuming a
# developer prompt.
#
#   .\build.ps1              configure + build (Debug)
#   .\build.ps1 -Release     configure + build (RelWithDebInfo)
#   .\build.ps1 -Test        build, then run the fast tests via ctest
#   .\build.ps1 -Slow        build, then run ONLY the "slow" tests
#                            (ZEXALL/ZEXDOC). Use with -Release; these are
#                            billions of emulated instructions and a Debug
#                            build turns minutes into hours.
#   .\build.ps1 -Target zx_server        build just one target -- zx_server is
#                                        what VS Code's launch builds; zx_tests
#                                        is the whole CTest suite, zx_tools the
#                                        benchmarks and diagnostics
#   .\build.ps1 -NoRewind                build without rewind (ZX_REWIND=OFF),
#                                        into build\<config>-norewind
#   .\build.ps1 -NoTests                 configure the server alone, with no
#                                        tests or tools (ZX_BUILD_TESTS=OFF),
#                                        into build\<config>-notests
#   .\build.ps1 -BuildDir <path>         build somewhere else entirely
#
# -BuildDir exists for one specific job: building a change while the user's
# own zx_server.exe is still running. Windows will not let the linker
# overwrite a locked .exe (LNK1168), so an automated check that must not
# disturb a live debug session builds to a throwaway directory instead of
# the default build\<config>. See .claude/skills/zx-live-verify.
param(
    [switch]$Release,
    [switch]$Test,
    [switch]$Slow,
    [string]$Target,
    [string]$BuildDir,
    [switch]$NoRewind,
    [switch]$NoTests
)

$ErrorActionPreference = 'Stop'

if ($NoTests -and ($Test -or $Slow)) {
    throw "-NoTests builds no tests, so there is nothing for -Test or -Slow to run"
}

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) { throw "vswhere.exe not found -- is Visual Studio (or its Build Tools) installed?" }

$vsRoot = & $vswhere -latest -products * -property installationPath
if (-not $vsRoot) { throw "No Visual Studio installation found by vswhere." }

$vcvars = Join-Path $vsRoot 'VC\Auxiliary\Build\vcvars64.bat'
$cmakeDir = Join-Path $vsRoot 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin'
$ninjaDir = Join-Path $vsRoot 'Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja'
foreach ($p in @($vcvars, "$cmakeDir\cmake.exe", "$ninjaDir\ninja.exe")) {
    if (-not (Test-Path $p)) { throw "Missing required tool: $p" }
}

# vcvars64.bat only sets variables in its own cmd session, so run it and import
# the resulting environment back into this PowerShell process.
$envDump = cmd /c "`"$vcvars`" >nul 2>&1 && set"
foreach ($line in $envDump) {
    if ($line -match '^([^=]+)=(.*)$') {
        Set-Item -Path "env:$($matches[1])" -Value $matches[2] -ErrorAction SilentlyContinue
    }
}
$env:PATH = "$cmakeDir;$ninjaDir;$env:PATH"

$buildType = if ($Release) { 'RelWithDebInfo' } else { 'Debug' }
$srcDir = $PSScriptRoot
# Each variant in a directory of its own, so switching between them never
# forces a full rebuild of another.
$defaultDir = "build\$buildType"
if ($NoRewind) { $defaultDir += '-norewind' }
if ($NoTests) { $defaultDir += '-notests' }
$buildDir = if ($BuildDir) { $BuildDir } else { Join-Path $srcDir $defaultDir }
$rewind = if ($NoRewind) { 'OFF' } else { 'ON' }
$tests = if ($NoTests) { 'OFF' } else { 'ON' }

# The -D argument is quoted: unquoted, PowerShell can pass it through with
# $buildType unexpanded, which CMake then takes as a literal config name and
# Ninja chokes on ("expected newline, got lexing error").
cmake -S $srcDir -B $buildDir -G Ninja "-DCMAKE_BUILD_TYPE=$buildType" "-DZX_REWIND=$rewind" "-DZX_BUILD_TESTS=$tests"
if ($LASTEXITCODE -ne 0) { throw "CMake configure failed" }

if ($Target) {
    cmake --build $buildDir --target $Target
} else {
    cmake --build $buildDir
}
if ($LASTEXITCODE -ne 0) { throw "Build failed" }

if ($Test) {
    # -LE slow: exclude the long-running exercisers from the routine run.
    ctest --test-dir $buildDir --output-on-failure -LE slow
    if ($LASTEXITCODE -ne 0) { throw "Tests failed" }
}

if ($Slow) {
    ctest --test-dir $buildDir --output-on-failure -L slow
    if ($LASTEXITCODE -ne 0) { throw "Slow tests failed" }
}

Write-Host "OK: $buildType build in $buildDir"
