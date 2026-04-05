#!/usr/bin/env bash
# =============================================================================
# GhostOS — scripts/build.sh
#
# Main build script. Runs on an Arch Linux host.
# Produces: output/ghostos-<date>.iso
#
# Usage:
#   sudo ./scripts/build.sh              # full build
#   sudo ./scripts/build.sh --clean      # wipe cache and rebuild
#   sudo ./scripts/build.sh --verify     # verify a previous build
# =============================================================================

set -euo pipefail

# --- Colors ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

log()  { echo -e "${CYAN}[build]${RESET} $*"; }
ok()   { echo -e "${GREEN}[  OK  ]${RESET} $*"; }
warn() { echo -e "${YELLOW}[ WARN ]${RESET} $*"; }
fail() { echo -e "${RED}[FATAL ]${RESET} $*"; exit 1; }
step() { echo -e "\n${BOLD}━━━ $* ${RESET}"; }

# --- Paths ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
PROFILE_DIR="$PROJECT_ROOT/archiso-profile"
OUTPUT_DIR="$PROJECT_ROOT/output"
WORK_DIR="$PROJECT_ROOT/work"
ISO_NAME="ghostos-$(date +%Y%m%d).iso"

# =============================================================================
# PRE-FLIGHT CHECKS
# =============================================================================
step "Pre-flight checks"

# Must run as root
[ "$EUID" -eq 0 ] || fail "Must run as root: sudo $0"
ok "Running as root"

# Must be on Arch Linux (or close enough)
[ -f /etc/arch-release ] || warn "Not on Arch Linux — build may fail"

# Check required tools
for tool in mkarchiso mksquashfs pacman git; do
    if command -v "$tool" &>/dev/null; then
        ok "$tool found: $(command -v "$tool")"
    else
        fail "$tool not found. Install: pacman -S archiso squashfs-tools"
    fi
done

# Check archiso version
ARCHISO_VER=$(pacman -Q archiso 2>/dev/null | awk '{print $2}' || echo "unknown")
log "archiso version: $ARCHISO_VER"

# =============================================================================
# HANDLE FLAGS
# =============================================================================
CLEAN_BUILD=false
VERIFY_ONLY=false

for arg in "$@"; do
    case "$arg" in
        --clean)   CLEAN_BUILD=true ;;
        --verify)  VERIFY_ONLY=true ;;
        --help|-h)
            echo "Usage: $0 [--clean] [--verify]"
            echo "  --clean   Wipe work directory and rebuild from scratch"
            echo "  --verify  Verify a previously built ISO (don't rebuild)"
            exit 0
            ;;
    esac
done

if [ "$VERIFY_ONLY" = true ]; then
    ISO_PATH="$OUTPUT_DIR/$ISO_NAME"
    [ -f "$ISO_PATH" ] || fail "ISO not found: $ISO_PATH"
    bash "$SCRIPT_DIR/verify-amnesia.sh" "$ISO_PATH"
    exit $?
fi

if [ "$CLEAN_BUILD" = true ]; then
    step "Cleaning previous build"
    rm -rf "$WORK_DIR"
    ok "Work directory cleaned"
fi

# =============================================================================
# PREPARE DIRECTORIES
# =============================================================================
step "Preparing build directories"

mkdir -p "$OUTPUT_DIR" "$WORK_DIR"
ok "Output dir: $OUTPUT_DIR"
ok "Work dir:   $WORK_DIR"

# =============================================================================
# INSTALL INITRAMFS HOOKS INTO PROFILE
# =============================================================================
step "Staging initramfs hooks"

# These hooks are already in airootfs, but we verify they're in place
HOOKS_DIR="$PROFILE_DIR/airootfs/usr/lib/initcpio"

for f in \
    "$HOOKS_DIR/hooks/ghost_ramboot" \
    "$HOOKS_DIR/install/ghost_ramboot"; do
    if [ -f "$f" ]; then
        ok "Hook present: $f"
        chmod +x "$f"
    else
        fail "Missing hook: $f"
    fi
done

# =============================================================================
# FIX PERMISSIONS
# =============================================================================
step "Setting file permissions"

chmod +x "$PROFILE_DIR/airootfs/usr/local/bin/ghost-kill"
chmod +x "$PROFILE_DIR/airootfs/usr/local/bin/ghost-kill-check"
chmod +x "$PROFILE_DIR/airootfs/usr/local/bin/ghost-init"
chmod 750 "$PROFILE_DIR/airootfs/root"
ok "Permissions set"

# =============================================================================
# VALIDATE PROFILE
# =============================================================================
step "Validating Archiso profile"

required_files=(
    "$PROFILE_DIR/profiledef.sh"
    "$PROFILE_DIR/packages.x86_64"
    "$PROFILE_DIR/airootfs/etc/mkinitcpio.conf"
    "$PROFILE_DIR/airootfs/etc/fstab"
    "$PROFILE_DIR/airootfs/etc/systemd/journald.conf"
    "$PROFILE_DIR/airootfs/etc/sysctl.d/99-ghost.conf"
    "$PROFILE_DIR/airootfs/etc/udev/rules.d/99-ghost-killswitch.rules"
    "$PROFILE_DIR/airootfs/usr/local/bin/ghost-kill"
    "$PROFILE_DIR/airootfs/usr/local/bin/ghost-kill-check"
    "$PROFILE_DIR/airootfs/usr/local/bin/ghost-init"
)

for f in "${required_files[@]}"; do
    if [ -f "$f" ]; then
        ok "Found: $(basename "$f")"
    else
        fail "Missing required file: $f"
    fi
done

# =============================================================================
# BUILD THE ISO
# =============================================================================
step "Building ISO with mkarchiso"
log "This takes 5-15 minutes depending on your internet connection."
log "Packages will be downloaded from Arch mirrors."

mkarchiso \
    -v \
    -w "$WORK_DIR" \
    -o "$OUTPUT_DIR" \
    "$PROFILE_DIR"

# =============================================================================
# FIND AND REPORT OUTPUT
# =============================================================================
step "Build complete"

BUILT_ISO=$(find "$OUTPUT_DIR" -name "ghostos*.iso" -newer "$WORK_DIR" 2>/dev/null | head -1)

if [ -z "$BUILT_ISO" ]; then
    # Fallback: find most recent iso
    BUILT_ISO=$(find "$OUTPUT_DIR" -name "ghostos*.iso" | sort -t- -k2 -r | head -1)
fi

if [ -n "$BUILT_ISO" ]; then
    ISO_SIZE=$(du -h "$BUILT_ISO" | cut -f1)
    ISO_SHA256=$(sha256sum "$BUILT_ISO" | awk '{print $1}')
    
    ok "ISO: $BUILT_ISO"
    ok "Size: $ISO_SIZE"
    ok "SHA256: $ISO_SHA256"
    
    # Write checksum file
    echo "$ISO_SHA256  $(basename "$BUILT_ISO")" > "${BUILT_ISO}.sha256"
    ok "Checksum saved: ${BUILT_ISO}.sha256"
    
    echo ""
    echo -e "${BOLD}Next steps:${RESET}"
    echo -e "  1. Flash to USB:  ${CYAN}sudo ./scripts/flash.sh $BUILT_ISO /dev/sdX${RESET}"
    echo -e "  2. Boot the USB on target hardware"
    echo -e "  3. Verify amnesia: ${CYAN}sudo ./scripts/verify-amnesia.sh${RESET}"
else
    fail "ISO not found in $OUTPUT_DIR — check mkarchiso output above for errors"
fi
