[CmdletBinding()]
param(
    [string]$HostAddress = "127.0.0.1",
    [int]$Port = 8080,
    [switch]$SkipInstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$serverDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$venvDir = Join-Path $serverDir ".venv"
$python = Join-Path $venvDir "Scripts\python.exe"
$requirements = Join-Path $serverDir "requirements.txt"
$stamp = Join-Path $venvDir ".requirements.sha256"

if (-not (Test-Path $python)) {
    $launcher = Get-Command py -ErrorAction SilentlyContinue
    if ($null -eq $launcher) {
        throw "Python Launcher 'py' was not found. Install Python 3.11+ and retry."
    }
    & $launcher.Source -3.11 -m venv $venvDir
    if ($LASTEXITCODE -ne 0) { throw "Python virtual environment creation failed." }
}

if (-not $SkipInstall) {
    $hash = (Get-FileHash $requirements -Algorithm SHA256).Hash
    $installedHash = if (Test-Path $stamp) { (Get-Content $stamp -Raw).Trim() } else { "" }
    if ($hash -ne $installedHash) {
        & $python -m pip install --disable-pip-version-check -r $requirements
        if ($LASTEXITCODE -ne 0) { throw "Python dependency installation failed." }
        Set-Content -Path $stamp -Value $hash -NoNewline
    }
}

$env:HOST = $HostAddress
$env:PORT = [string]$Port
Write-Host "Telemetry server: http://$HostAddress`:$Port"
Write-Host "Press Ctrl+C to stop. Default binding is loopback; use -HostAddress 0.0.0.0 only for LAN testing."
& $python (Join-Path $serverDir "app.py")
exit $LASTEXITCODE
