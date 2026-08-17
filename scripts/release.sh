#!/bin/bash
#
# Release script for ZWM
# Usage: ./scripts/release.sh <patch|minor|major> [--dry-run]
#
# Creates a GitHub release and updates the Homebrew formula in homebrew-tap.
#
# Examples:
#   ./scripts/release.sh patch      # v0.1.0 -> v0.1.1
#   ./scripts/release.sh minor      # v0.1.0 -> v0.2.0
#   ./scripts/release.sh major      # v0.1.0 -> v1.0.0

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TAP_REPO="$(cd "$REPO_ROOT/../homebrew-tap" && pwd)"

cd "$REPO_ROOT"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Parse arguments
BUMP_TYPE=""
DRY_RUN=false

for arg in "$@"; do
    case $arg in
        --dry-run)
            DRY_RUN=true
            ;;
        patch|minor|major)
            BUMP_TYPE="$arg"
            ;;
        *)
            echo -e "${RED}Unknown argument: $arg${NC}"
            echo "Usage: ./scripts/release.sh <patch|minor|major> [--dry-run]"
            exit 1
            ;;
    esac
done

if [ -z "$BUMP_TYPE" ]; then
    echo -e "${RED}Error: Bump type argument required (patch, minor, or major)${NC}"
    echo "Usage: ./scripts/release.sh <patch|minor|major> [--dry-run]"
    exit 1
fi

# Get the latest version tag
LATEST_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "v0.0.0")

if ! [[ "$LATEST_TAG" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    echo -e "${RED}Error: Latest tag '$LATEST_TAG' is not in format vX.Y.Z${NC}"
    exit 1
fi

MAJOR="${BASH_REMATCH[1]}"
MINOR="${BASH_REMATCH[2]}"
PATCH="${BASH_REMATCH[3]}"

case $BUMP_TYPE in
    patch) PATCH=$((PATCH + 1)) ;;
    minor) MINOR=$((MINOR + 1)); PATCH=0 ;;
    major) MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
esac

VERSION="v${MAJOR}.${MINOR}.${PATCH}"
VERSION_NUM="${MAJOR}.${MINOR}.${PATCH}"

echo -e "Current version: ${YELLOW}${LATEST_TAG}${NC}"
echo -e "New version:     ${GREEN}${VERSION}${NC} (${BUMP_TYPE} bump)"
echo ""

# Check prerequisites
echo "Checking prerequisites..."

if ! command -v gh &> /dev/null; then
    echo -e "${RED}Error: gh CLI is not installed${NC}"
    echo "Install with: brew install gh"
    exit 1
fi
echo "  gh CLI: found"

if ! gh auth status &> /dev/null; then
    echo -e "${RED}Error: Not authenticated with gh CLI${NC}"
    echo "Run: gh auth login"
    exit 1
fi
echo "  gh auth: authenticated"

if [ -n "$(git status --porcelain)" ]; then
    echo -e "${RED}Error: Working directory is not clean${NC}"
    git status --short
    exit 1
fi
echo "  Working directory: clean"

CURRENT_BRANCH=$(git branch --show-current)
if [ "$CURRENT_BRANCH" != "main" ]; then
    echo -e "${RED}Error: Not on main branch (currently on: $CURRENT_BRANCH)${NC}"
    exit 1
fi
echo "  Branch: main"

if git rev-parse "$VERSION" >/dev/null 2>&1; then
    echo -e "${RED}Error: Tag $VERSION already exists${NC}"
    exit 1
fi
echo "  Tag $VERSION: available"

if [ ! -d "$TAP_REPO/Formula" ]; then
    echo -e "${RED}Error: Homebrew tap not found at $TAP_REPO${NC}"
    exit 1
fi
echo "  Homebrew tap: found"

# The release artifact is signed here, on this machine. brew cannot do it at
# install time — its build sandbox denies reads of ~/Library/Keychains, so the
# identity is invisible there. Without a signature the bundle is ad-hoc, its
# designated requirement is a cdhash, and every upgrade invalidates the user's
# Accessibility grant. So refuse to cut a release we can't sign.
# Set via `if` rather than ${VAR:-default}: the apostrophe in the default value
# opens a quote context inside the braces and breaks the parse.
SIGNING_IDENTITY="${ZWM_SIGNING_IDENTITY:-}"
if [ -z "$SIGNING_IDENTITY" ]; then
    SIGNING_IDENTITY="Zack's Window Manager Signing"
fi
if ! security find-identity -v -p codesigning | grep -qF "$SIGNING_IDENTITY"; then
    echo -e "${RED}Error: signing identity '$SIGNING_IDENTITY' not found${NC}"
    echo "Run once: ./scripts/create-signing-cert.sh"
    exit 1
fi
echo "  Signing identity: found"

echo ""
echo -e "${GREEN}Prerequisites check passed${NC}"

if [ "$DRY_RUN" = true ]; then
    echo ""
    echo -e "${YELLOW}Dry run - would perform:${NC}"
    echo "  1. Build and sign the release artifact"
    echo "  2. Create and push tag $VERSION"
    echo "  3. Create GitHub release $VERSION and upload the artifact"
    echo "  4. Update homebrew-tap formula with new version, URL and SHA"
    echo "  5. Commit and push homebrew-tap"
    exit 0
fi

# Step 1: Build and sign the artifact. Done before tagging so a build failure
# doesn't leave a dangling tag behind.
echo ""
echo "Step 1: Building and signing release artifact..."
./build-release.sh > /dev/null
ARCH="$(uname -m)"
ARCHIVE=".release/zwm-macos-${ARCH}.tar.gz"

if [ ! -f "$ARCHIVE" ]; then
    echo -e "${RED}Error: build did not produce $ARCHIVE${NC}"
    exit 1
fi

if codesign -dv .release/ZWM.app 2>&1 | grep -q "Signature=adhoc"; then
    echo -e "${RED}Error: bundle is ad-hoc signed, refusing to release${NC}"
    echo "The Accessibility grant would break on every upgrade."
    exit 1
fi
codesign --verify --strict .release/ZWM.app
echo "  Signed and verified"

ASSET="zwm-${VERSION}-macos-${ARCH}.tar.gz"
ASSET_DIR="$(mktemp -d)"
ASSET_PATH="${ASSET_DIR}/${ASSET}"
cp "$ARCHIVE" "$ASSET_PATH"
SHA256=$(shasum -a 256 "$ASSET_PATH" | awk '{print $1}')
ASSET_URL="https://github.com/zhubert/zwm/releases/download/${VERSION}/${ASSET}"
echo "  Artifact: $ASSET"
echo "  SHA256:   $SHA256"

# Step 2: Tag and push
echo ""
echo "Step 2: Creating and pushing tag ${VERSION}..."
git tag "$VERSION"
git push origin "$VERSION"
echo "  Done"

# Step 3: Create GitHub release with the signed artifact attached
echo ""
echo "Step 3: Creating GitHub release and uploading artifact..."
gh release create "$VERSION" --title "$VERSION" --generate-notes "$ASSET_PATH"
echo "  Done"

# Step 4: Update Homebrew formula
echo ""
echo "Step 4: Updating Homebrew formula..."

FORMULA_PATH="$TAP_REPO/Formula/zwm.rb"

cat > "$FORMULA_PATH" << FORMULA
class Zwm < Formula
  desc "Tiling window manager for macOS"
  homepage "https://github.com/zhubert/zwm"
  url "${ASSET_URL}"
  sha256 "${SHA256}"
  version "${VERSION_NUM}"
  license "MIT"

  depends_on :macos
  depends_on arch: :arm64

  # This ships a prebuilt bundle that was code-signed at release time rather than
  # building from source. brew cannot sign anything itself: its build sandbox
  # denies reads of ~/Library/Keychains, so the signing identity is invisible
  # there. An ad-hoc signature would key the Accessibility grant to a cdhash that
  # changes every version, forcing a re-grant on each upgrade. Signing once,
  # upstream, gives a stable designated requirement so the grant persists.
  #
  # Formula rather than cask on purpose: formulae don't set the quarantine
  # attribute, so a self-signed bundle never faces a Gatekeeper prompt, and
  # \`service\` keeps \`brew services\` working (casks have no launchd support).
  def install
    prefix.install "ZWM.app"
    bin.install "zwm"
  end

  service do
    run [opt_prefix/"ZWM.app/Contents/MacOS/zwm-server"]
    keep_alive true
    log_path var/"log/zwm.log"
    error_log_path var/"log/zwm.log"
  end

  def caveats
    <<~EOS
      ZWM requires Accessibility permissions:
        System Settings → Privacy & Security → Accessibility
        Grant access to: #{opt_prefix}/ZWM.app/Contents/MacOS/zwm-server

      Start the service with:
        brew services start zwm

      The bundle is signed with a stable identity, so this grant survives future
      upgrades. If you are coming from a version installed before ZWM was signed,
      you need to re-grant Accessibility once more.
    EOS
  end

  test do
    assert_match "Usage", shell_output("#{bin}/zwm --help 2>&1", 1)
  end
end
FORMULA

echo "  Formula written to $FORMULA_PATH"

# Step 5: Commit and push homebrew-tap
echo ""
echo "Step 5: Updating homebrew-tap..."
cd "$TAP_REPO"
git add Formula/zwm.rb
git commit -m "zwm ${VERSION}"
git push
echo "  Done"

echo ""
echo -e "${GREEN}Release ${VERSION} completed!${NC}"
echo ""
echo "Users can now run:"
echo "  brew tap zhubert/tap"
echo "  brew install zwm"
echo "  brew services start zwm"
