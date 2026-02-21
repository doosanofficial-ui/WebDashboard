#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${1:-$SCRIPT_DIR/certs}"
LAN_IP="${2:-}"
FORCE_RECREATE="${3:-}"

if ! command -v openssl >/dev/null 2>&1; then
  echo "[ERROR] openssl not found in PATH." >&2
  exit 1
fi

if [[ -z "$LAN_IP" ]]; then
  LAN_IP="$(ipconfig getifaddr en0 2>/dev/null || true)"
fi

mkdir -p "$OUT_DIR"

CA_KEY="$OUT_DIR/dev-local-ca-key.pem"
CA_CERT="$OUT_DIR/dev-local-ca-cert.pem"
CA_CERT_CER="$OUT_DIR/dev-local-ca-cert.cer"
SERVER_KEY="$OUT_DIR/dev-key.pem"
SERVER_CSR="$OUT_DIR/dev.csr"
SERVER_CERT="$OUT_DIR/dev-cert.pem"
SERVER_EXT="$OUT_DIR/dev-ext.cnf"
CA_EXT="$OUT_DIR/ca-ext.cnf"
CA_SRL="$OUT_DIR/dev-local-ca-cert.srl"

if [[ "$FORCE_RECREATE" == "force" ]]; then
  rm -f "$CA_KEY" "$CA_CERT" "$CA_CERT_CER"
fi

if [[ ! -f "$CA_KEY" || ! -f "$CA_CERT" ]]; then
  cat >"$CA_EXT" <<EOF
[req]
distinguished_name=dn
x509_extensions=v3_ca
prompt=no

[dn]
CN=Telemetry Local Dev CA

[v3_ca]
basicConstraints=critical,CA:TRUE,pathlen:0
keyUsage=critical,keyCertSign,cRLSign
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid:always
EOF

  openssl genrsa -out "$CA_KEY" 2048 >/dev/null 2>&1
  openssl req -x509 -new -nodes \
    -key "$CA_KEY" \
    -sha256 \
    -days 3650 \
    -out "$CA_CERT" \
    -config "$CA_EXT" >/dev/null 2>&1
fi

openssl x509 -in "$CA_CERT" -outform der -out "$CA_CERT_CER" >/dev/null 2>&1

SAN_ENTRIES="DNS:localhost,IP:127.0.0.1"
if [[ -n "$LAN_IP" ]]; then
  SAN_ENTRIES="$SAN_ENTRIES,IP:$LAN_IP"
fi

cat >"$SERVER_EXT" <<EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
extendedKeyUsage=serverAuth
subjectAltName=$SAN_ENTRIES
EOF

openssl genrsa -out "$SERVER_KEY" 2048 >/dev/null 2>&1
openssl req -new -key "$SERVER_KEY" -out "$SERVER_CSR" -subj "/CN=localhost" >/dev/null 2>&1
openssl x509 -req \
  -in "$SERVER_CSR" \
  -CA "$CA_CERT" \
  -CAkey "$CA_KEY" \
  -CAcreateserial \
  -out "$SERVER_CERT" \
  -days 825 \
  -sha256 \
  -extfile "$SERVER_EXT" >/dev/null 2>&1

rm -f "$SERVER_CSR" "$SERVER_EXT" "$CA_SRL"
rm -f "$CA_EXT"

echo "[OK] Generated:"
echo "  CA cert   : $CA_CERT"
echo "  CA cert   : $CA_CERT_CER (iOS import friendly)"
echo "  Server cert: $SERVER_CERT"
echo "  Server key : $SERVER_KEY"
echo ""
echo "Run server with:"
echo "  export SSL_CERTFILE=\"$SERVER_CERT\""
echo "  export SSL_KEYFILE=\"$SERVER_KEY\""
echo "  python app.py"
if [[ -n "$LAN_IP" ]]; then
  echo "Use URL:"
  echo "  https://$LAN_IP:18443  (if PORT=18443)"
fi
echo ""
echo "iPhone/iPad trust:"
echo "  1) AirDrop '$CA_CERT_CER' to iPhone/iPad and install profile"
echo "  2) Settings > General > About > Certificate Trust Settings > enable full trust"
if [[ "$FORCE_RECREATE" == "force" ]]; then
  echo "  3) Delete old Telemetry Local Dev CA profile first, then install the new one"
fi
