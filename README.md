# GhostOS — Amnesic RAM-Boot System

A minimal Arch-based OS that lives entirely in RAM.
Pull the USB → it dies clean. No artifacts. No state. No mercy.

## Architecture

```
USB (read-only squashfs)
  └─▶ initramfs
        └─▶ copy rootfs.squashfs → tmpfs
              └─▶ OverlayFS (RAM upper layer)
                    └─▶ switch_root → running system
                          └─▶ All writes → RAM (tmpfs)
                                └─▶ USB removed → kill-switch fires → wipe + reboot
```

## Build Order (do NOT skip steps)

| Step | Component              | Purpose                        |
|------|------------------------|--------------------------------|
| 1    | `archiso-profile/`     | Base Archiso config            |
| 2    | `mkinitcpio` hook      | RAM-copy + OverlayFS mount     |
| 3    | Persistence lockdown   | journald, swap, core dumps     |
| 4    | Kill-switch            | USB removal → instant wipe     |
| 5    | Networking (later)     | WireGuard → Tor → browser      |

## Quick Build

```bash
# On an Arch Linux host:
sudo ./scripts/build.sh

# Flash to USB:
sudo dd if=output/ghostos.iso of=/dev/sdX bs=4M status=progress
```

## Verify Amnesia (critical test)

```bash
# 1. Boot from USB
# 2. Create a file: touch /tmp/testfile && echo "i was here" > /root/secret.txt
# 3. Reboot
# 4. Check: ls /root/secret.txt   → must NOT exist
```

## Directory Layout

```
ghostos/
├── README.md
├── scripts/
│   ├── build.sh              ← Main Archiso build runner
│   ├── flash.sh              ← dd wrapper for USB flashing
│   └── verify-amnesia.sh     ← Post-boot amnesia test suite
├── archiso-profile/
│   ├── profiledef.sh         ← Archiso identity + options
│   ├── packages.x86_64       ← Package list
│   ├── airootfs/
│   │   ├── etc/
│   │   │   ├── mkinitcpio.conf          ← initramfs hook order
│   │   │   ├── systemd/journald.conf    ← volatile logs only
│   │   │   ├── systemd/system/          ← masked/disabled units
│   │   │   ├── sysctl.d/99-ghost.conf   ← kernel hardening
│   │   │   ├── modprobe.d/blacklist.conf← disable risky modules
│   │   │   └── udev/rules.d/            ← USB kill-switch rule
│   │   ├── usr/local/bin/
│   │   │   ├── ghost-init               ← early userspace setup
│   │   │   └── ghost-kill               ← kill-switch executor
│   │   └── root/
│   │       └── .bashrc                  ← root shell hardening
│   └── efiboot/loader/entries/
│       └── ghostos.conf                 ← bootloader entry
└── docs/
    ├── BOOT_FLOW.md          ← Detailed initramfs walkthrough
    └── THREAT_MODEL.md       ← What this protects against
```
