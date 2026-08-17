#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="zwm"
BUNDLE_DIR=".release/${APP_NAME}.app"
BUILD_DIR=".build/release"

echo "=== Building release binary ==="
swift build -c release

echo "=== Assembling app bundle ==="
rm -rf "$BUNDLE_DIR"
mkdir -p "${BUNDLE_DIR}/Contents/MacOS"
mkdir -p "${BUNDLE_DIR}/Contents/Resources"

# Copy binary
cp "${BUILD_DIR}/zwm-server" "${BUNDLE_DIR}/Contents/MacOS/zwm-server"

# Copy Info.plist
cp resources/Info.plist "${BUNDLE_DIR}/Contents/Info.plist"

# Copy CLI binary alongside for convenience
cp "${BUILD_DIR}/zwm" ".release/zwm"

# Sign the bundle with a stable identity if one exists. This keeps the app's
# designated requirement constant across rebuilds, so the Accessibility grant
# persists instead of being invalidated by every new cdhash.
# Create the identity with: ./scripts/create-signing-cert.sh
SIGNING_IDENTITY="${ZWM_SIGNING_IDENTITY:-ZWM Signing}"
if security find-identity -v -p codesigning | grep -qF "$SIGNING_IDENTITY"; then
    echo "=== Signing bundle with '$SIGNING_IDENTITY' ==="
    codesign --force --sign "$SIGNING_IDENTITY" --identifier "com.zhubert.zwm" \
        --timestamp=none "${BUNDLE_DIR}"
    codesign --verify --verbose=2 "${BUNDLE_DIR}"
else
    echo "=== No '$SIGNING_IDENTITY' identity — leaving ad-hoc signature ==="
    echo "    Accessibility must be re-granted after every build."
    echo "    Run ./scripts/create-signing-cert.sh once to fix this."
fi

echo "=== Done ==="
echo "App bundle: ${BUNDLE_DIR}"
echo "CLI binary: .release/zwm"
echo ""
echo "To install:"
echo "  cp -r ${BUNDLE_DIR} /Applications/"
echo "  cp .release/zwm /usr/local/bin/"
