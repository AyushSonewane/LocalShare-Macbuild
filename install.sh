#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# LocalShare macOS One-Line Installer
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/AyushSonewane/LocalShare-Macbuild/main/install.sh | bash
# ─────────────────────────────────────────────────────────────────────────────

set -e

# Configuration
REPO="AyushSonewane/LocalShare-Releases"
FALLBACK_REPO="AyushSonewane/LocalShare-Macbuild"
DMG_URL="${CUSTOM_DMG_URL:-https://github.com/${REPO}/releases/download/v1.0.1.0/LocalShare.dmg}"
FALLBACK_DMG_URL="https://github.com/${FALLBACK_REPO}/releases/latest/download/LocalShare.dmg"
APP_NAME="LocalShare.app"
DEST_DIR="/Applications"
TMP_DIR="$(mktemp -d /tmp/localshare-install.XXXXXX)"
TMP_DMG="${TMP_DIR}/LocalShare.dmg"
MOUNT_DIR="${TMP_DIR}/mount"

# Color formatting
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

cleanup() {
    if [ -d "${MOUNT_DIR}" ]; then
        hdiutil detach "${MOUNT_DIR}" -quiet 2>/dev/null || true
    fi
    rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

echo ""
echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}            LocalShare — macOS Automated Installer          ${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
echo ""

# 1. Close running instances
if pgrep -x "LocalShare" >/dev/null 2>&1; then
    echo -e "${YELLOW}ℹ Closing running LocalShare instance...${NC}"
    killall "LocalShare" 2>/dev/null || true
    sleep 1
fi

# 2. Download DMG
echo -e "${CYAN}⬇ Downloading LocalShare...${NC}"

if ! curl -fL --progress-bar -o "${TMP_DMG}" "${DMG_URL}"; then
    echo -e "${YELLOW}Retrying from fallback mirror...${NC}"
    if ! curl -fL --progress-bar -o "${TMP_DMG}" "${FALLBACK_DMG_URL}"; then
        echo ""
        echo -e "${RED}❌ Failed to download LocalShare.dmg.${NC}"
        echo "  Please check your connection or download directly from:"
        echo "  https://github.com/AyushSonewane/LocalShare-Releases/releases"
        exit 1
    fi
fi

# 3. Mount DMG
echo ""
echo -e "${CYAN}📦 Mounting disk image...${NC}"
mkdir -p "${MOUNT_DIR}"
hdiutil attach "${TMP_DMG}" -mountpoint "${MOUNT_DIR}" -nobrowse -quiet

# 4. Copy to /Applications
echo -e "${CYAN}🚀 Installing into ${DEST_DIR}/${APP_NAME}...${NC}"
rm -rf "${DEST_DIR}/${APP_NAME}"
cp -R "${MOUNT_DIR}/${APP_NAME}" "${DEST_DIR}/"

# 5. Fix Gatekeeper Quarantine
echo -e "${CYAN}🔓 Removing macOS Gatekeeper quarantine attribute...${NC}"
xattr -cr "${DEST_DIR}/${APP_NAME}"

# 6. Unmount DMG
hdiutil detach "${MOUNT_DIR}" -quiet 2>/dev/null || true

echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}       ✅ LocalShare installed successfully!               ${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo ""
echo "Location: ${DEST_DIR}/${APP_NAME}"
echo ""

# 7. Launch App
read -p "Would you like to open LocalShare now? (Y/n): " -n 1 -r </dev/tty || REPLY="Y"
echo ""
if [[ $REPLY =~ ^[Yy]$ ]] || [[ -z $REPLY ]]; then
    open "${DEST_DIR}/${APP_NAME}"
    echo -e "${GREEN}✨ LocalShare launched!${NC}"
fi
echo ""
