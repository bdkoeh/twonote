# Builds the app and runs its unattended self-tests against a real server in Docker. Never leaves the app, the
# container or its volume behind.
#
#   pwsh src/TwoNote.App/run-selftest.ps1                    # everything
#   pwsh src/TwoNote.App/run-selftest.ps1 -Only binding      # just the editor-binding assertions (no server)
#   pwsh src/TwoNote.App/run-selftest.ps1 -Only e2e          # first run, restart and the two-instance run
#
#   -Docker      how to reach Docker (default: docker; for Docker inside WSL pass e.g. 'wsl -d Ubuntu -- docker')
#   -Port        host port for the test server (default 18480)
#   -Seeds/-Ops  randomised concurrent-edit runs of the binding test
#   -Shots       where screenshots go (default docs/screenshots)
#   -RealInput   also drive the app with real key presses and mouse clicks (SendInput). This brings the test
#                window to the front and needs it to stay there, so use it only when nobody (and nothing else)
#                is using the PC: keys somebody types meanwhile land in the test window and fail the run.
#
# Phases (each is one run of TwoNote.exe --selftest <mode>; logs in src/TwoNote.App/selftest-out):
#   binding   two editors on two replicas of one page, joined in-process: control = shadow = document after
#             every step, both sides equal, randomised concurrent edits; once in light and once in dark theme
#   first     fresh profile "selftest-a": server address, create account, Emergency Kit, notebooks/sections/
#             pages, every format of PROTOCOL.md 5.2 through the editor, paste filter, search, lock/unlock,
#             auto-lock, settings; screenshots
#   restart   the same profile again: unlock screen, everything still there
#   two       profile "selftest-a" drives a second instance under "selftest-b" through a pipe: enrol with the
#             Secret Key, same tree and page, concurrent edits with caret stability, server stopped and started
#             (offline edits merge), tree changes, password change, revoke, on-disk scan for plaintext, sign out
param(
    [string]$Only = '',
    [string]$Docker = 'docker',
    [string]$Image = 'twonote-server:latest',
    [int]$Port = 18480,
    [string]$Seeds = '1,2,3,4,5',
    [int]$Ops = 300,
    [string]$Shots = '',
    [switch]$RealInput,
    [switch]$NoBuild
)
$ErrorActionPreference = 'Stop'
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    $env:PATH = [Environment]::GetEnvironmentVariable('PATH', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('PATH', 'User')
}
$app = $PSScriptRoot
$repo = Resolve-Path (Join-Path $app '..\..')
$out = Join-Path $app 'selftest-out'
if (-not $Shots) { $Shots = Join-Path $repo 'docs\screenshots' }
New-Item -ItemType Directory -Force $out, $Shots | Out-Null
Get-ChildItem $out -File | Where-Object { $_.Name -notlike 'failed-*' -and $_.Name -notlike 'crash-*' } | Remove-Item -Force   # logs of failed runs and crash dumps are kept
Remove-Item (Join-Path $out 'control') -Recurse -Force -ErrorAction SilentlyContinue
$control = New-Item -ItemType Directory -Force (Join-Path $out 'control')

if (-not $NoBuild) {
    dotnet build (Join-Path $app 'TwoNote.App.csproj') --nologo -v q | Select-String -Pattern ' error | warning |rror\(s\)|arning\(s\)' | ForEach-Object { $_.Line.Trim() }
    if ($LASTEXITCODE -ne 0) { throw 'build failed' }
}
$exe = Join-Path $app 'bin\Debug\net10.0-windows10.0.19041.0\win-x64\TwoNote.exe'
$name = 'twonote-app-selftest'
$server = "http://localhost:$Port"
$results = [ordered]@{}

function Invoke-Docker { param([string[]]$Arguments) $parts = $Docker -split ' '; $rest = @($parts | Select-Object -Skip 1) + $Arguments; & $parts[0] @rest 2>&1 | Out-Null }
function Wait-Server {
    for ($i = 0; $i -lt 60; $i++) {
        try { if ((Invoke-WebRequest "$server/api/v1/status" -UseBasicParsing -TimeoutSec 2).StatusCode -eq 200) { return } } catch { Start-Sleep -Milliseconds 500 }
    }
    throw 'the test server did not come up'
}
function Start-Server {
    Invoke-Docker @('rm', '-f', $name); Invoke-Docker @('volume', 'rm', $name)
    Invoke-Docker @('volume', 'create', $name)
    Invoke-Docker @('run', '-d', '--name', $name, '-p', "${Port}:8080", '-v', "${name}:/data", $Image)
    Wait-Server
}
function Remove-Server { Invoke-Docker @('rm', '-f', $name); Invoke-Docker @('volume', 'rm', $name) }

# Runs one phase. While it runs, serves its requests to stop/start the server (the two-instance phase).
function Invoke-Phase {
    param([string]$Mode, [string]$Log, [string[]]$Extra = @(), [int]$TimeoutSec = 600)
    $logPath = Join-Path $out $Log
    Remove-Item $logPath -ErrorAction SilentlyContinue
    # If the process dies natively, leave a minidump next to the log (analyse with dotnet-dump / WinDbg).
    $env:DOTNET_DbgEnableMiniDump = '1'; $env:DOTNET_DbgMiniDumpType = '2'; $env:DOTNET_DbgMiniDumpName = (Join-Path $out 'crash-%p.dmp')
    $p = Start-Process $exe -ArgumentList (@('--selftest', $Mode, '--log', $logPath, '--out', $out, '--shots', $Shots) + $Extra) -PassThru
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while (-not $p.HasExited) {
        if ((Get-Date) -gt $deadline) { $p.Kill(); Write-Output "  KILLED $Mode after $TimeoutSec s"; break }
        $stop = Join-Path $control 'server-stop.request'; $start = Join-Path $control 'server-start.request'
        if (Test-Path $stop) { Invoke-Docker @('stop', '-t', '1', $name); Remove-Item $stop }
        if (Test-Path $start) { Invoke-Docker @('start', $name); Wait-Server; Remove-Item $start }
        Start-Sleep -Milliseconds 200
    }
    $p.WaitForExit()
    $line = if (Test-Path $logPath) { Select-String -Path $logPath -Pattern 'SELFTEST RESULT' | Select-Object -Last 1 } else { $null }
    $pass = $p.ExitCode -eq 0 -and $line -and $line.Line -match 'SELFTEST RESULT: PASS'
    $results[$Log] = if ($line) { "$($line.Line.Trim()) (exit $($p.ExitCode))" } else { "NO RESULT (exit $($p.ExitCode))" }
    if (-not $pass -and (Test-Path $logPath)) { Copy-Item $logPath (Join-Path $out ("failed-{0:yyyyMMdd-HHmmss}-{1}" -f (Get-Date), $Log)) }
    if (Test-Path $logPath) { Get-Content $logPath | Where-Object { $_ -match '^(PASS|FAIL|SELFTEST|  FAIL|UNHANDLED|  SKIPPED)' } | ForEach-Object { "  $_" } }
}
function Clear-Profiles {
    foreach ($name in 'selftest-a', 'selftest-b') {
        $p = Start-Process $exe -ArgumentList @('--selftest', 'wipe', '--profile', $name) -PassThru
        if (-not $p.WaitForExit(30000)) { $p.Kill() }
    }
}

try {
    if (-not $Only -or $Only -eq 'binding') {
        $extra = @('--seeds', $Seeds, '--ops', "$Ops")
        if ($RealInput) { $extra += '--input' }
        Write-Output 'binding (light theme)'; Invoke-Phase 'binding' 'binding-light.log' ($extra + @('--theme', 'light'))
        Write-Output 'binding (dark theme)'; Invoke-Phase 'binding' 'binding-dark.log' ($extra + @('--theme', 'dark'))
    }
    if (-not $Only -or $Only -eq 'e2e') {
        Clear-Profiles
        Start-Server
        $first = @('--profile', 'selftest-a', '--server', $server)
        if ($RealInput) { $first += '--input' }
        Write-Output 'first run'; Invoke-Phase 'first' 'e2e-first.log' $first 300
        Write-Output 'restart'; Invoke-Phase 'restart' 'e2e-restart.log' @('--profile', 'selftest-a', '--server', $server) 180
        Write-Output 'two instances'; Invoke-Phase 'two' 'e2e-two.log' @('--profile', 'selftest-a', '--server', $server) 600
    }
}
finally {
    Get-Process TwoNote -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe } | ForEach-Object { $_.Kill() }
    if (-not $Only -or $Only -eq 'e2e') { Clear-Profiles; Remove-Server }
    # The test account is gone with its server; its Emergency Kits (which hold its Secret Key) need not linger.
    Get-ChildItem $out -Filter 'Emergency Kit*.html' -ErrorAction SilentlyContinue | Remove-Item -Force
    Remove-Item (Join-Path $out 'e2e-state.json'), $control -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output ''
$failed = 0
foreach ($k in $results.Keys) { Write-Output ("{0,-20} {1}" -f $k, $results[$k]); if ($results[$k] -notmatch 'RESULT: PASS .*\(exit 0\)|RESULT: PASS  .*\(exit 0\)') { $failed++ } }
$dumps = Get-ChildItem $out -Filter 'crash-*.dmp' -ErrorAction SilentlyContinue
if ($dumps) { Write-Output "CRASH DUMPS: $($dumps.FullName -join ', ')"; $failed++ }
Write-Output ("OVERALL: {0}   (logs: {1})" -f $(if ($failed -eq 0) { 'PASS' } else { "FAIL ($failed)" }), $out)
exit $failed
