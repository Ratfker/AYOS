# GhostOS — Threat Model

An honest breakdown of what GhostOS protects against, what it doesn't,
and what the residual risks are. Read this before trusting your life to it.

---

## Protected Against ✅

### Disk-based forensics
An attacker who physically seizes the machine after a GhostOS session
and extracts the hard drive will find:
- No modified files (OS runs from RAM, never writes to internal disk)
- No browser history, no cookies, no caches
- No logs (journald is volatile)
- No swap file (swap is disabled)
- No core dumps

**Caveat**: The USB drive itself contains the squashfs (your base OS image).
That's intentional and doesn't leak session data — it's the same read-only
image every boot. Protect the USB separately.

### Accidental persistence
A misconfigured application that tries to write to a "disk" will actually
write to tmpfs (RAM) and the data will vanish on reboot. The OverlayFS
upper layer captures all writes without them ever reaching storage hardware.

### Swap recovery
Swap is disabled at multiple layers:
1. Kernel cmdline (no swap entry)
2. `swapoff -a` in ghost-noswap.service
3. `vm.swappiness=0` in sysctl.d
4. No swap entry in fstab

Even if an attacker knows your encryption keys, there's no swap to decrypt.

### Log analysis
All logs are in RAM. `journald.conf` has `Storage=volatile`. `/var/log` is
a tmpfs. After reboot, there are zero log entries from your session.

---

## Partially Protected ⚠️

### Network traffic (post Phase-2 setup)
With WireGuard + Tor:
- Your ISP sees encrypted WireGuard traffic to your VPN endpoint
- Your VPN sees encrypted Tor traffic (can't read content)
- Tor exit sees traffic but not your identity (if configured correctly)

Residual risks:
- Traffic analysis / timing correlation across Tor hops
- VPN provider logging (jurisdiction dependent)
- Browser fingerprinting (use Tor Browser for best protection)
- JavaScript-based deanonymization

### USB removal detection window
There's a ~2 second window between USB removal and reboot. An attacker
who can capture RAM within this window (e.g. a DMA attack via Thunderbolt)
could potentially read memory. Mitigation: disable Thunderbolt in
modprobe.d (done by default in GhostOS).

---

## NOT Protected Against ❌

### Cold-boot attacks
DRAM retains data for seconds to minutes after power loss, especially
when cooled. An attacker who:
1. Physically removes RAM modules within ~30 seconds of shutdown
2. Cools them with compressed air (extends retention to minutes)
3. Reads them in another machine

...can potentially recover cryptographic keys, session data, etc.

**Mitigation**: `init_on_free=1` in kernel cmdline helps (zeroes freed pages)
but cannot zero pages that are still "in use" at shutdown time.
True protection requires hardware-level RAM encryption (AMD SME/SEV).

### BIOS/UEFI firmware attacks
If the firmware is compromised before GhostOS boots, all bets are off.
A firmware rootkit can:
- Log keystrokes before the OS starts
- Exfiltrate data via network before GhostOS's nftables rules apply
- Modify the kernel as it loads

**Mitigation**: Secure Boot (not yet implemented), TPM attestation.

### Evil maid attacks
If an attacker has physical access to the machine BEFORE you boot,
they can:
- Replace the USB with a backdoored version
- Install a hardware keylogger
- Replace/modify the firmware

**Mitigation**: Verify USB integrity (check squashfs hash before booting).
Tamper-evident seals on the machine.

### Hardware keyloggers
A USB or inline keyboard keylogger captures keystrokes before GhostOS
sees them. No software mitigation possible.

### Malicious USB
If the USB itself is compromised (e.g., a BadUSB attack on the device
you use to flash the USB), the squashfs could be backdoored.
**Mitigation**: Build the squashfs on a trusted machine. Verify hashes.

### Browser fingerprinting
Even through Tor, a unique browser fingerprint can deanonymize you.
- Use Tor Browser (fingerprint-normalized)
- Don't resize the browser window
- Don't install extensions
- Don't enable JavaScript on sensitive sites

### Social engineering / OPSEC failures
GhostOS can't protect against:
- Logging into accounts tied to your real identity
- Using the same username across sessions
- Timing correlation (active at same times as a known identity)
- Writing style analysis

---

## Recommended Additions (Future Phases)

| Addition | Protects Against |
|----------|-----------------|
| Secure Boot + signed kernel | BIOS-level tampering |
| Full-disk encryption on USB | USB seizure |
| AMD SME / Intel TME | Cold-boot attacks |
| Tor Browser integration | Browser fingerprinting |
| TPM-based attestation | Evil maid |
| Physical security (Faraday bag) | Remote exfiltration while stored |

---

## Summary Table

| Threat | Protected? | Notes |
|--------|-----------|-------|
| Disk forensics | ✅ Yes | Nothing written to disk |
| Swap recovery | ✅ Yes | Swap fully disabled |
| Log recovery | ✅ Yes | Volatile journald |
| Browser history | ✅ Yes | Vanishes on reboot |
| Network traffic | ⚠️ Partial | Phase 2 (Tor+WG) needed |
| Cold-boot attack | ❌ No | Hardware limitation |
| Firmware rootkit | ❌ No | Pre-boot attack vector |
| Hardware keylogger | ❌ No | Pre-boot hardware attack |
| Evil maid (USB) | ❌ No | Verify USB hash manually |
| OPSEC failures | ❌ No | Human problem |
