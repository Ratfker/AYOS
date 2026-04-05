# GhostOS — Boot Flow (Detailed)

This document traces the exact execution path from power-on to running OS.
Understanding this is essential before modifying anything.

---

## Stage 0: BIOS/UEFI

```
Power on
  → BIOS/UEFI POST
  → Reads USB boot sector
  → Loads systemd-boot (UEFI) or SYSLINUX (BIOS)
  → Reads efiboot/loader/entries/ghostos.conf
  → Loads vmlinuz-linux + initramfs-linux.img into RAM
  → Jumps to kernel
```

**Key parameters in ghostos.conf:**
- `init_on_free=1` — zeroes RAM pages when freed (cold-boot mitigation)
- `nohibernate` — blocks hibernation (persistence prevention)
- `init_on_alloc=1` — zeroes RAM on allocation

---

## Stage 1: Kernel init

```
Kernel decompresses itself into RAM
  → Mounts initramfs (in-memory tmpfs, ~50MB)
  → Runs /init from initramfs (mkinitcpio-generated script)
```

The initramfs is a tiny standalone Linux environment. It has just
enough binaries to set up the real root filesystem.

---

## Stage 2: initramfs hooks (left to right from mkinitcpio.conf)

### `base`
Sets up minimal environment: `/dev`, `/proc`, `/sys`, busybox tools.

### `udev`
Starts a minimal udev daemon. This triggers module loading for:
- USB host controllers (xhci_hcd, ehci_hcd)
- USB storage (usb-storage, uas)
- Filesystem modules (vfat, ext4, squashfs, overlay)

Without this, the USB drive wouldn't be detected.

### `modconf`
Applies `/etc/modprobe.d` rules inside the initramfs environment.
Our blacklist (firewire, thunderbolt, etc.) takes effect here.

### `block`
Polls until block devices appear. Gives udev time to finish
initializing the USB controller and presenting /dev/sdX devices.

### `filesystems`
Loads filesystem-specific modules. Ensures squashfs and overlay
are loaded before our hook runs.

### `ghost_ramboot` ← THE CRITICAL HOOK
See: `airootfs/usr/lib/initcpio/hooks/ghost_ramboot`

Execution sequence:
```
1. mount -t tmpfs tmpfs /ghost_ram          (4GB RAM canvas)
2. mkdir /ghost_ram/{rootfs_img,rootfs_ro,rw_upper,rw_work,merged}
3. Scan /dev/sd?1, /dev/vd?1, /dev/mmcblk?p1 for rootfs.squashfs
4. mount -o ro <usb_device> /ghost_mnt_probe
5. cp /ghost_mnt_probe/rootfs.squashfs /ghost_ram/rootfs_img/  ← USB→RAM
6. Verify copy: stat -c%s src == stat -c%s dest
7. umount /ghost_mnt_probe                  ← USB no longer needed
8. mount -t squashfs -o loop,ro rootfs.squashfs /ghost_ram/rootfs_ro
9. mount -t overlay overlay \
       -o lowerdir=/ghost_ram/rootfs_ro,upperdir=/ghost_ram/rw_upper,workdir=/ghost_ram/rw_work \
       /ghost_ram/merged
10. echo $usb_dev > /ghost_ram/merged/run/ghost/boot_device
11. exec switch_root /ghost_ram/merged /sbin/init
```

After step 7, the USB is read-only mounted for the copy, then fully
unmounted. Removing the USB at any point after step 5 completes has
no effect on the running OS.

---

## Stage 3: switch_root

`switch_root /ghost_ram/merged /sbin/init`:
- PID 1 (the initramfs /init) replaces itself with systemd
- The initramfs tmpfs is DELETED (freed from RAM)
- Systemd starts in /ghost_ram/merged (our overlay)

At this point:
- **Root**: OverlayFS on tmpfs — all writes go to RAM
- **USB**: logically disconnected from the OS
- **Persistence**: physically impossible (no disk path exists)

---

## Stage 4: systemd (userspace)

Systemd processes units in dependency order. Key early units:

| Unit | What it does |
|------|-------------|
| `ghost-noswap.service` | `swapoff -a`, sets `vm.swappiness=0` |
| `ghost-init.service` | Verifies RAM state, wipes /var/log, locks sysctl |
| `systemd-sysctl.service` | Applies `/etc/sysctl.d/99-ghost.conf` |
| `systemd-udevd.service` | Starts udev — loads kill-switch rules |
| `systemd-journald.service` | Starts with `Storage=volatile` — RAM logs only |

### udev loads `99-ghost-killswitch.rules`

From this point, any USB block device removal triggers:
```
ghost-kill-check → checks /run/ghost/boot_device → ghost-kill
```

---

## Stage 5: Kill-switch (USB removal)

```
USB removed
  → kernel generates udev event (ACTION=remove, SUBSYSTEM=block)
  → udev matches rule: ACTION=="remove", ENV{ID_BUS}=="usb"
  → spawns: ghost-kill-check
  → ghost-kill-check: is /dev/sdX (boot device) gone? YES
  → exec ghost-kill
  → ghost-kill:
      sync
      echo 3 > /proc/sys/vm/drop_caches
      swapoff -a
      (dd zeros to tmpfs for 1 second)
      echo b > /proc/sysrq-trigger   ← INSTANT REBOOT
```

Time from USB removal to reboot: **< 2 seconds** in typical conditions.

On reboot:
- RAM is cleared by hardware reset
- No write ever touched any persistent storage
- Zero artifacts remain

---

## Memory Map (what lives where during operation)

```
Physical RAM
├── Kernel + initramfs remnants (~100MB)
├── /ghost_ram/rootfs_img/rootfs.squashfs (~800MB compressed OS)
├── /ghost_ram/rootfs_ro (squashfs mount, read-only view)
├── /ghost_ram/rw_upper (OverlayFS upper — all writes land here)
├── /ghost_ram/rw_work (OverlayFS internals)
├── /ghost_ram/merged (unified view — what systemd sees as /)
├── tmpfs mounts (/tmp, /var/log, /run, /dev/shm)
└── Process memory (running programs)
```

None of this touches a disk. All of it vanishes on reboot/power-off.

---

## What This Does NOT Protect Against

See `THREAT_MODEL.md` for the full analysis. Short version:

- ❌ Cold-boot attack (RAM contents readable ~seconds after power-off)
- ❌ Hardware keylogger
- ❌ Malicious firmware (BIOS/UEFI rootkit)
- ❌ Compromised squashfs on the USB
- ❌ Network-based deanonymization (Phase 2 addresses this partially)
- ✅ Disk forensics after normal reboot/shutdown
- ✅ Swap-based recovery
- ✅ Log-based recovery
- ✅ Browser history (if browser is configured correctly)
