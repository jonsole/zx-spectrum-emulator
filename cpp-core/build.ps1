# Configures and builds cpp-core with the MSVC toolchain that ships with
# VS 2022 Build Tools. None of cl.exe / cmake.exe / ninja.exe are on PATH by
# default -- they live inside the Build Tools install and need vcvars64.bat's
# environment -- so this script locates them itself rather than assuming a
# developer prompt.
#
#   .\build.ps1              configure + build (Debug)
#   .\build.ps1 -Release     configure + build (RelWithDebInfo)
#   .\build.ps1 -Test        build, then run the test suite via ctest
param(
    [switch]$Release,
    [switch]$Test
)

$ErrorActionPreference = 'Stop'

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
$buildDir = Join-Path $srcDir "build\$buildType"

# The -D argument is quoted: unquoted, PowerShell can pass it through with
# $buildType unexpanded, which CMake then takes as a literal config name and
# Ninja chokes on ("expected newline, got lexing error").
cmake -S $srcDir -B $buildDir -G Ninja "-DCMAKE_BUILD_TYPE=$buildType"
if ($LASTEXITCODE -ne 0) { throw "CMake configure failed" }

cmake --build $buildDir
if ($LASTEXITCODE -ne 0) { throw "Build failed" }

if ($Test) {
    ctest --test-dir $buildDir --output-on-failure
    if ($LASTEXITCODE -ne 0) { throw "Tests failed" }
}

Write-Host "OK: $buildType build in $buildDir"
