param(
  [string]$OutDir = "$(Split-Path -Parent $MyInvocation.MyCommand.Path)\\certs",
  [string]$CommonName = "localhost",
  [string]$LanIp = ""
)

$ErrorActionPreference = "Stop"

if (-not (Get-Command openssl -ErrorAction SilentlyContinue)) {
  Write-Host "[ERROR] openssl not found in PATH. Install OpenSSL or use mkcert." -ForegroundColor Red
  exit 1
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$certPath = Join-Path $OutDir "dev-cert.pem"
$keyPath = Join-Path $OutDir "dev-key.pem"

$sanList = @("DNS:localhost", "IP:127.0.0.1")
if ($LanIp -and $LanIp -match "^\d{1,3}(\.\d{1,3}){3}$") {
  $sanList += "IP:$LanIp"
}
$san = "subjectAltName=" + ($sanList -join ",")

openssl req -x509 -newkey rsa:2048 -sha256 -days 365 -nodes `
  -keyout $keyPath `
  -out $certPath `
  -subj "/CN=$CommonName" `
  -addext $san

Write-Host "[OK] Generated:" -ForegroundColor Green
Write-Host "  $certPath"
Write-Host "  $keyPath"
Write-Host ""
Write-Host "Run server with:" -ForegroundColor Cyan
Write-Host "  `$env:SSL_CERTFILE='$certPath'; `$env:SSL_KEYFILE='$keyPath'; python app.py"
if ($LanIp) {
  Write-Host "Use URL: https://$LanIp:8080 (if PORT=8080)" -ForegroundColor Cyan
}
