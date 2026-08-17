#!/bin/bash
# Create a stable self-signed code-signing identity for local ZWM builds.
#
# Why: an ad-hoc signature has no certificate, so TCC keys the Accessibility
# grant to the binary's cdhash — which changes on every build. That is why
# `make install` had to reset the grant and re-prompt every single time.
#
# Signing with a *stable* certificate makes the designated requirement
# ("identifier com.zhubert.zwm and certificate leaf = <this cert>") constant across
# rebuilds, so the Accessibility grant survives them.
#
# Run once. Idempotent — exits early if the identity already exists.
set -euo pipefail

CERT_NAME="${ZWM_SIGNING_IDENTITY:-}"
if [ -z "$CERT_NAME" ]; then
    CERT_NAME="Zack's Window Manager Signing"
fi
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"
DAYS=3650

if security find-identity -v -p codesigning | grep -qF "$CERT_NAME"; then
    echo "Signing identity '$CERT_NAME' already exists — nothing to do."
    exit 0
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "=== Generating self-signed code-signing certificate '$CERT_NAME' ==="
openssl req -x509 -newkey rsa:2048 -nodes -days "$DAYS" \
    -keyout "${WORK_DIR}/key.pem" \
    -out "${WORK_DIR}/cert.pem" \
    -subj "/CN=${CERT_NAME}" \
    -addext "basicConstraints=critical,CA:FALSE" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    2>/dev/null

# LibreSSL rejects an empty-password PKCS#12 on import ("MAC verification
# failed"), so use a throwaway passphrase — the file lives only in $WORK_DIR.
P12_PASS="$(uuidgen)"

openssl pkcs12 -export \
    -inkey "${WORK_DIR}/key.pem" \
    -in "${WORK_DIR}/cert.pem" \
    -out "${WORK_DIR}/identity.p12" \
    -passout "pass:${P12_PASS}"

echo "=== Importing into login keychain ==="
# -T /usr/bin/codesign pre-authorizes codesign to use the private key. macOS may
# still show one "wants to use your confidential information" prompt on first
# use — choose "Always Allow".
security import "${WORK_DIR}/identity.p12" \
    -k "$KEYCHAIN" \
    -P "${P12_PASS}" \
    -T /usr/bin/codesign

echo "=== Marking the certificate as trusted for code signing ==="
echo "(macOS will ask for your login password — this writes user trust settings)"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "${WORK_DIR}/cert.pem"

echo
echo "Done. Identity available to codesign:"
security find-identity -v -p codesigning | grep -F "$CERT_NAME" || true
echo
echo "Next: ./build-release.sh will now sign with '$CERT_NAME' automatically."
echo "The first install after switching still needs one Accessibility re-grant;"
echo "rebuilds after that keep the grant."
