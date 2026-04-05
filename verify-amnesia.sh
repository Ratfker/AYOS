#!/usr/bin/env bash
# =============================================================================
# GhostOS — scripts/verify-amnesia.sh
#
# The amnesia test suite. Run this INSIDE a booted GhostOS session.
#
# Tests:
#   1. Root is OverlayFS (not a real disk)
#   2. Swap is off
#   3. /tmp, /var/log are tmpfs
#   4. No persistent journal entries
#   5. Core dumps disabled
#   6. Write a test file, reboot, confirm it's gone (manual step)
#   7. Kill-switch armed (boot device recorded)
#
# Exit code: 0 = all tests passed, 1 = one or more tests failed
# =============================================================================

set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

PASS=0
FAIL=0
WARN=0

pass() { echo -e "${GREEN}  [PASS]${RESET} $*"; ((PASS++)); }
fail() { echo -e "${RED}  [FAIL]${RESET} $*"; ((FAIL++)); }
warn() { echo -e "${YELLOW}  [WARN]${RESET} $*"; ((WARN++)); }
info() { echo -e "${CYAN}  [INFO]${RESET} $*"; }
sect() { echo -e "\n${BOLD}$*${RESET}"; }

echo -e "${BOLD}GhostOS Amnesia Verification Suite${RESET}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# =============================================================================
# TEST GROUP 1: Root Filesystem
# =============================================================================
sect "1. Root Filesystem"

ROOT_FSTYPE=$(findmnt -n -o FSTYPE / 2>/dev/null || echo "UNKNOWN")
info "Root FS type: $ROOT_FSTYPE"

if [ "$ROOT_FSTYPE" = "overlay" ]; then
    pass "Root is overlay (OverlayFS) — running from RAM"
elif [ "$ROOT_FSTYPE" = "tmpfs" ]; then
    pass "Root is tmpfs — running from RAM"
else
    fail "Root is '$ROOT_FSTYPE' — NOT running from RAM! This is a fatal failure."
fi

# Check that the upper dir is on tmpfs (i.e., writes go to RAM)
OVERLAY_UPPER=$(findmnt -n -o OPTIONS / 2>/dev/null | tr ',' '\n' | grep '^upperdir=' | cut -d= -f2)
if [ -n "$OVERLAY_UPPER" ]; then
    UPPER_FSTYPE=$(df --output=fstype "$OVERLAY_UPPER" 2>/dev/null | tail -1 || echo "unknown")
    info "OverlayFS upper dir: $OVERLAY_UPPER (type: $UPPER_FSTYPE)"
    if [ "$UPPER_FSTYPE" = "tmpfs" ]; then
        pass "OverlayFS upper dir is tmpfs — writes go to RAM"
    else
        fail "OverlayFS upper dir is '$UPPER_FSTYPE' — writes may persist!"
    fi
fi

# =============================================================================
# TEST GROUP 2: Swap
# =============================================================================
sect "2. Swap"

SWAP_ENTRIES=$(swapon --show 2>/dev/null | tail -n +2 | wc -l)
if [ "$SWAP_ENTRIES" -eq 0 ]; then
    pass "No active swap"
else
    fail "Swap is ACTIVE ($SWAP_ENTRIES entries) — memory may leak to disk!"
    swapon --show 2>/dev/null | while read line; do info "  $line"; done
fi

SWAPPINESS=$(cat /proc/sys/vm/swappiness 2>/dev/null || echo "unknown")
info "vm.swappiness = $SWAPPINESS"
if [ "$SWAPPINESS" = "0" ]; then
    pass "vm.swappiness=0 — kernel won't use swap"
else
    warn "vm.swappiness=$SWAPPINESS — should be 0"
fi

# =============================================================================
# TEST GROUP 3: Volatile Mounts
# =============================================================================
sect "3. Mount Points (must all be tmpfs)"

for mntpoint in /tmp /var/log /run /dev/shm; do
    if mountpoint -q "$mntpoint" 2>/dev/null; then
        FSTYPE=$(findmnt -n -o FSTYPE "$mntpoint" 2>/dev/null || echo "unknown")
        if [ "$FSTYPE" = "tmpfs" ]; then
            pass "$mntpoint is tmpfs"
        else
            fail "$mntpoint is '$FSTYPE' — expected tmpfs"
        fi
    else
        warn "$mntpoint is not a separate mount (relies on root FS)"
    fi
done

# =============================================================================
# TEST GROUP 4: Journal / Logs
# =============================================================================
sect "4. Journal & Logs"

JOURNAL_STORAGE=$(grep -i "^Storage=" /etc/systemd/journald.conf 2>/dev/null | cut -d= -f2 || echo "not set")
info "journald Storage: $JOURNAL_STORAGE"
if echo "$JOURNAL_STORAGE" | grep -qi "volatile"; then
    pass "journald Storage=volatile — no disk writes"
else
    fail "journald Storage='$JOURNAL_STORAGE' — should be 'volatile'"
fi

# Check for any persistent journal on disk
if [ -d /var/log/journal ] && [ "$(ls -A /var/log/journal 2>/dev/null)" ]; then
    fail "/var/log/journal has content — persistent journal may exist!"
    ls -la /var/log/journal/ | while read line; do info "  $line"; done
else
    pass "No persistent journal directory"
fi

# =============================================================================
# TEST GROUP 5: Core Dumps
# =============================================================================
sect "5. Core Dumps"

CORE_PATTERN=$(cat /proc/sys/kernel/core_pattern 2>/dev/null || echo "unknown")
info "core_pattern: $CORE_PATTERN"
if echo "$CORE_PATTERN" | grep -qE "false|/dev/null|^$"; then
    pass "Core dumps disabled (pattern: $CORE_PATTERN)"
else
    warn "Core dumps may be enabled (pattern: $CORE_PATTERN)"
fi

SUID_DUMP=$(cat /proc/sys/fs/suid_dumpable 2>/dev/null || echo "unknown")
if [ "$SUID_DUMP" = "0" ]; then
    pass "fs.suid_dumpable=0 — SUID programs won't dump core"
else
    warn "fs.suid_dumpable=$SUID_DUMP — should be 0"
fi

# =============================================================================
# TEST GROUP 6: Kill-Switch
# =============================================================================
sect "6. Kill-Switch"

BOOT_DEV_FILE="/run/ghost/boot_device"
if [ -f "$BOOT_DEV_FILE" ]; then
    BOOT_DEV=$(cat "$BOOT_DEV_FILE")
    info "Boot device: $BOOT_DEV"
    if [ -b "$BOOT_DEV" ]; then
        pass "Boot device present — kill-switch armed"
    else
        warn "Boot device not found at $BOOT_DEV — kill-switch in fail-safe mode"
    fi
else
    warn "Boot device file not found — kill-switch may not be armed"
fi

# Check kill-switch binary
if [ -x /usr/local/bin/ghost-kill ]; then
    pass "ghost-kill is executable"
else
    fail "ghost-kill not found or not executable"
fi

# Check udev rule
if [ -f /etc/udev/rules.d/99-ghost-killswitch.rules ]; then
    pass "udev kill-switch rule present"
else
    fail "udev kill-switch rule MISSING"
fi

# =============================================================================
# TEST GROUP 7: Sysrq (required for kill-switch)
# =============================================================================
sect "7. Sysrq"

SYSRQ=$(cat /proc/sys/kernel/sysrq 2>/dev/null || echo "0")
if [ "$SYSRQ" = "1" ]; then
    pass "sysrq enabled (value=1) — kill-switch can reboot"
else
    warn "sysrq value=$SYSRQ — kill-switch may not work"
fi

# =============================================================================
# TEST GROUP 8: Write + Reboot Test (manual)
# =============================================================================
sect "8. Reboot Amnesia Test (MANUAL)"

echo ""
info "To verify full amnesia, run this test manually:"
echo ""
echo "  # Step 1: Create a test artifact"
echo "  echo 'ghost-was-here-\$(date)' > /root/amnesia-test.txt"
echo "  echo 'secret data' > /tmp/secret.tmp"
echo ""
echo "  # Step 2: Reboot"
echo "  reboot"
echo ""
echo "  # Step 3: After reboot, check:"
echo "  ls /root/amnesia-test.txt    # must NOT exist"
echo "  ls /tmp/secret.tmp           # must NOT exist"
echo "  cat /var/log/journal         # must be empty/reset"
echo ""
warn "This step requires a real reboot — cannot be automated in-session"

# =============================================================================
# SUMMARY
# =============================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${BOLD}Results:${RESET}"
echo -e "  ${GREEN}PASS: $PASS${RESET}"
echo -e "  ${YELLOW}WARN: $WARN${RESET}"
echo -e "  ${RED}FAIL: $FAIL${RESET}"
echo ""

if [ "$FAIL" -eq 0 ]; then
    echo -e "${GREEN}${BOLD}✓ All critical tests passed.${RESET}"
    echo -e "  GhostOS is running correctly from RAM."
    [ "$WARN" -gt 0 ] && echo -e "  ${YELLOW}Review warnings above — some hardening may be incomplete.${RESET}"
    exit 0
else
    echo -e "${RED}${BOLD}✗ $FAIL critical test(s) FAILED.${RESET}"
    echo -e "  ${RED}This system may NOT be fully amnesic.${RESET}"
    echo "  Review failures above before trusting this session."
    exit 1
fi
