param(
  [string]$OutDir = "$(Split-Path -Parent $MyInvocation.MyCommand.Path)\\certs",
  [string]$CommonName = "localhost"
)

$ErrorActionPreference = "Stop"

if (-not (Get-Command openssl -ErrorAction SilentlyContinue)) {
  Write-Host "[ERROR] openssl not found in PATH. Install OpenSSL or use mkcert." -ForegroundColor Red
  exit 1
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$certPath = Join-Path $OutDir "dev-cert.pem"
$keyPath = Join-Path $OutDir "dev-key.pem"

$san = "subjectAltName=DNS:localhost,IP:127.0.0.1"

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
