# Starts zx_server.exe only if nothing is already serving the DAP port.
#
# The attach counterpart to the zxspectrum-cpp.start-server task. That one
# stops every running server and rebuilds before starting its own, which is
# right for a launch and fatal for an attach: it would replace the executable
# of the very process being attached to, and reset the machine being joined.
#
# This one leaves a running server strictly alone, and only fills the gap when
# there is nothing there at all -- so the attach configuration works whether
# the emulator was started by a debug session, by an MCP client (see
# tools/zxserver), or not at all.
#
# Exits as soon as the port answers, so tasks.json can treat it as a plain
# task rather than a background one.

param(
    [int]$DapPort = 4711,
    [int]$McpPort = 8000,
    [int]$ScreenPort = 8500,
    [string]$Exe = "$PSScriptRoot\build\RelWithDebInfo\zx_server.exe",
    [double]$TimeoutSeconds = 20
)

$ErrorActionPreference = 'Stop'

function Test-Listening {
    param([int]$Port)
    # A bare TCP connect, not Test-NetConnection: the cmdlet also pings and
    # resolves names, which costs seconds per call on a task that should be
    # instant when the server is already up.
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $client.Connect('127.0.0.1', $Port)
        return $true
    } catch {
        return $false
    } finally {
        $client.Dispose()
    }
}

if (Test-Listening $DapPort) {
    Write-Host "zx_server is already serving port $DapPort - attaching to it."
    exit 0
}

if (-not (Test-Path $Exe)) {
    Write-Error "$Exe does not exist. Build it first: cd cpp-core; .\build.ps1 -Release -Target zx_server"
    exit 1
}

Write-Host "Nothing on port $DapPort; starting $Exe"
$repoRoot = Split-Path $PSScriptRoot -Parent
$serverArgs = @(
    '--dap-port', $DapPort,
    '--mcp-port', $McpPort,
    '--screen-port', $ScreenPort,
    # Sound out of the host's speakers rather than through the screen panel,
    # matching the server the launch configurations start.
    '--audio-device',
    '--no-audio'
)
Start-Process -FilePath $Exe -ArgumentList $serverArgs -WorkingDirectory $repoRoot

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
while ((Get-Date) -lt $deadline) {
    if (Test-Listening $DapPort) {
        Write-Host "zx_server is up on port $DapPort."
        exit 0
    }
    Start-Sleep -Milliseconds 200
}

Write-Error "zx_server did not open port $DapPort within $TimeoutSeconds seconds."
exit 1
