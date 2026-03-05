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

echo ""
echo -e "${GREEN}Prerequisites check passed${NC}"

if [ "$DRY_RUN" = true ]; then
    echo ""
    echo -e "${YELLOW}Dry run - would perform:${NC}"
    echo "  1. Create and push tag $VERSION"
    echo "  2. Create GitHub release $VERSION"
    echo "  3. Update homebrew-tap formula with new version and SHA"
    echo "  4. Commit and push homebrew-tap"
    exit 0
fi

# Step 1: Tag and push
echo ""
echo "Step 1: Creating and pushing tag ${VERSION}..."
git tag "$VERSION"
git push origin "$VERSION"
echo "  Done"

# Step 2: Create GitHub release
echo ""
echo "Step 2: Creating GitHub release..."
gh release create "$VERSION" --title "$VERSION" --generate-notes
echo "  Done"

# Step 3: Get SHA256 of source tarball
echo ""
echo "Step 3: Getting source tarball SHA256..."
TARBALL_URL="https://github.com/zhubert/zwm/archive/refs/tags/${VERSION}.tar.gz"
SHA256=$(curl -sL "$TARBALL_URL" | shasum -a 256 | awk '{print $1}')
echo "  SHA256: $SHA256"

# Step 4: Update Homebrew formula
echo ""
echo "Step 4: Updating Homebrew formula..."

FORMULA_PATH="$TAP_REPO/Formula/zwm.rb"

cat > "$FORMULA_PATH" << FORMULA
class Zwm < Formula
  desc "Tiling window manager for macOS"
  homepage "https://github.com/zhubert/zwm"
  url "https://github.com/zhubert/zwm/archive/refs/tags/${VERSION}.tar.gz"
  sha256 "${SHA256}"
  version "${VERSION_NUM}"

  depends_on :macos

  def install
    system "swift", "build", "-c", "release", "--disable-sandbox"

    # Install server as app bundle (for Accessibility TCC grouping)
    app_bundle = prefix/"ZWM.app"
    mkdir_p app_bundle/"Contents/MacOS"
    mkdir_p app_bundle/"Contents/Resources"
    cp buildpath/".build/release/zwm-server", app_bundle/"Contents/MacOS/zwm-server"
    cp "resources/Info.plist", app_bundle/"Contents/Info.plist"

    # Install CLI
    bin.install ".build/release/zwm"
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
