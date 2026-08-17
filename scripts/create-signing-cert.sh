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
DAYS=3650

# Resolve the user's actual default keychain rather than assuming the
# filename — it's usually login.keychain-db, but security(1) is the source
# of truth and this avoids "keychain could not be found" when it isn't.
KEYCHAIN="$(security default-keychain -d user 2>/dev/null | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//')"
if [ -z "$KEYCHAIN" ] || [ ! -f "$KEYCHAIN" ]; then
    echo "Could not resolve a default keychain for this user." >&2
    echo "Unlock/create your login keychain (Keychain Access.app) and re-run this script." >&2
    exit 1
fi

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

# OpenSSL 3.x defaults to AES-256/SHA-256 for PKCS#12, which macOS's
# `security import` can't parse — it fails with "MAC verification failed
# (wrong password?)" even with the right password. -legacy produces the
# RC2/3DES format macOS expects.
LEGACY_FLAG=()
if openssl pkcs12 -help 2>&1 | grep -q -- -legacy; then
    LEGACY_FLAG=(-legacy)
fi

openssl pkcs12 -export "${LEGACY_FLAG[@]}" \
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
