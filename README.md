# T2Linux MacBook Suspend Fix

Systemd-based suspend/resume fix for Apple T2 MacBooks running Linux. Manages driver unloading and reloading around the sleep cycle to prevent kernel panics and ensure clean wake-up.

Tested and developed on a **MacBookPro16,3 (Late 2019 13" MacBook Pro)** running **Fedora 42** with the [T2 Linux kernel](https://github.com/t2linux/fedora).

---

## Hardware Reference

As we all know, this fix might not work on every T2 MacBook due to firmware differences. Here's the reference hardware configuration for the machine I developed and tested on:

| Component   | Details                                                  |
| ----------- | -------------------------------------------------------- |
| Model       | MacBookPro16,3 (Late 2019 13" MacBook Pro)               |
| BIOS / EFI  | `2075.101.2.0.0` (iBridge: `22.16.14248.0.0,0`)          |
| Board ID    | `Mac-E7203C0F68AA0004`                                   |
| CPU         | Intel Core i5-8257U (Cannon Lake, 8th Gen)               |
| WiFi / BT   | Broadcom BCM4377b (`14e4:4488` / `14e4:5fa0`)            |
| NVMe        | Apple ANS2 (`106b:2005`)                                 |
| T2 chip     | Apple T2 Bridge `106b:1801` + Secure Enclave `106b:1802` |
| Audio       | Apple Audio Device via T2 `106b:1803`                    |
| Thunderbolt | Intel JHL7540 Titan Ridge 4C 2018 (`8086:15ea`)          |
| Bootloader  | GRUB via shim (EFI Boot0000)                             |

### Key PCIe layout

```
01:00.0  BCM4377b WiFi          - brcmfmac + brcmfmac_wcc)
01:00.1  BCM4377 Bluetooth      - btbcm
02:00.0  Apple ANS2 NVMe
02:00.1  T2 Bridge Controller   - apple-bce (BCE driver - keyboard, backlight, Touch ID)
02:00.2  T2 Secure Enclave
02:00.3  Apple Audio Device     - apple-bce / snd_pcm (aaudio)
06:00.0  Thunderbolt 3 xHCI     - fails on every resume with -19 ENODEV (known, non-critical)
```

---

## Root Cause Analysis

### Why the system immediately wakes from S3 (kernel 7.0+)

In kernel 7.0+, PCIe devices left without a driver after `rmmod`/`modprobe -r` are no longer automatically put into D3 before S3 sleep. This means the **T2 BCE devices** (at `02:00.1`/`02:00.3`, rooted at `RP09 00:1d.0`) and the **BCM4377b WiFi hardware** (`01:00.0`, rooted at `RP01 00:1c.0` / `ARPT`) can send **PME (Power Management Events)** almost immediately after the system enters S3, causing a spurious wakeup within seconds. The **Thunderbolt xHCI** (`XHC2 06:00.0` / `RP05 00:1c.4`) already fails on every resume and is a third source.

The fix adds a step to the suspend service that **disables these ACPI wakeup sources** (`RP09`, `RP01`, `ARPT`, `RP05`, `XHC2`, `XHC1`) just before sleep, and re-enables them as the first step on resume. On T2 Macs the keyboard/trackpad wakeup is handled by the T2 chip's firmware through ACPI independently of these PCIe entries, so lid-open and key-press wakeup still work.

PCIe layout relevant to this fix:

```
00:14.0  XHC1  → Intel PCH USB — T2 appears here as a USB device; sends wakeup ~10s after S3
00:1c.0  RP01  → 01:00.0 BCM4377b WiFi (ARPT) + 01:00.1 Bluetooth
00:1c.4  RP05  → Thunderbolt complex → 06:00.0 XHC2 (Thunderbolt xHCI)
00:1d.0  RP09  → 02:00.0 NVMe / 02:00.1 T2 BCE / 02:00.2 Enclave / 02:00.3 Audio
```

---

### Why suspend crashes (kernel panic on resume)

The crash is a **use-of-stale-MMIO** in the `apple-bce` audio driver:

1. `suspend-wifi-unload.service` calls `rmmod -f apple-bce` while PipeWire has active PCM streams open
2. Force-removal bypasses the driver refcount and taints the kernel `[R]=FORCED_RMMOD`
3. On resume, `modprobe apple-bce` maps BCE audio at a **new MMIO address**
4. PipeWire still holds old `snd_pcm` handles pointing to the **old address**
5. When PipeWire eventually accesses one of those handles -> `iowrite32` on an unmapped page -> kernel BUG

```
RIP: iowrite32
__aaudio_send [apple_bce]
__aaudio_send_cmd_sync [apple_bce]
aaudio_cmd_stop_io [apple_bce]
aaudio_pcm_trigger [apple_bce]
snd_pcm_drop / snd_pcm_release [snd_pcm]
Process: pipewire (UID 1000)
Tainted: [R]=FORCED_RMMOD [C]=CRAP (staging driver)
```

To fix the issue, we can simply stop PipeWire *before* removing `apple-bce`, and restart it *after* the module reloads on resume.

### Thunderbolt xHCI (06:00.0) error on resume

Every resume logs:

```
xhci_hcd 0000:06:00.0: Timeout while waiting for setup device command
xhci_hcd 0000:06:00.0: ERROR: ... -19 (ENODEV)
```

This issue is **not the cause of any crash**. Thunderbolt USB devices may need to be re-plugged after resume.

---

## What the Installer Does

Running `t2-suspend-fix.sh` and choosing **Install** performs:

1. **Enables all S3 ACPI wake sources** (backs up current state for uninstall)
2. **Installs systemd services** for suspend/resume driver management
3. **Creates helper scripts** in `/usr/local/bin/`
4. **Sets `mem_sleep_default=deep`** via grubby (Fedora) or GRUB config (Debian/Arch)
5. **Sets `pcie_aspm=off`** kernel parameter
6. **Disables thermald** if present (interferes with suspend)
7. **Configures TLP** to use `deep` sleep instead of `s2idle` (if installed)
8. **Installs `zzz-t2-force-deep.sh`** system-sleep hook as a belt-and-suspenders guarantee that `mem_sleep` is `deep` even if TLP or another tool overrides it
9. **Removes `systemd-suspend` override.conf** if present
10. **Installs libnotify** if missing (for desktop notifications on resume failure)

---

## Architecture / Suspend Sequence

### Before suspend (`suspend-wifi-unload.service`)

```text
1. brightnessctl: keyboard backlight off
2. echo deep > /sys/power/mem_sleep  (override Apple EFI cmdline)
3. t2-stop-audio.sh                  (stop PipeWire to prevent the stale MMIO crash)
4. nmcli radio wifi off
5. modprobe -r brcmfmac_wcc
6. modprobe -r brcmfmac
7. rmmod -f apple-bce
8. disable ACPI S3 wakeup for RP09, RP01, ARPT, RP05, XHC2, XHC1 (prevent spurious PME/USB wakeup)
-> system suspends
```

### After resume (`resume-wifi-reload.service`)

```text
0. re-enable ACPI S3 wakeup for RP09, RP01, ARPT, RP05, XHC2, XHC1
1. modprobe apple-bce
2. t2-wait-apple-bce.sh              (polls up to 15s; aborts with notification if missing)
3. modprobe brcmfmac
4. modprobe brcmfmac_wcc
5. t2-start-audio.sh                 (restart PipeWire after BCE is ready)
6. fix-kbd-backlight.sh              (restore keyboard backlight)
7. (after 5s) check brcmfmac binding; retry modprobe if needed
8. nmcli radio wifi on
```

### Helper scripts

| Script                                | Purpose                                                                       |
| ------------------------------------- | ----------------------------------------------------------------------------- |
| `/usr/local/bin/t2-stop-audio.sh`     | Stops `pipewire`, `pipewire-pulse`, `wireplumber` for the active user session |
| `/usr/local/bin/t2-start-audio.sh`    | Restarts `pipewire.socket` and `pipewire-pulse.socket`                        |
| `/usr/local/bin/t2-wait-apple-bce.sh` | Polls for BCE driver readiness; sends desktop notification on timeout         |
| `/usr/local/bin/fix-kbd-backlight.sh` | Restores keyboard backlight; reloads BCE if the backlight path is missing     |

---

## Additional Fix Scripts

These standalone scripts address issues that are independent of the suspend/resume cycle. Run them once after installing the main fix.

### `fix-t2-ncm.sh` — Stop the top-bar loading spinner after resume

**Problem:** After every resume, GNOME shows a persistent loading animation in the top bar for ~90 seconds. This is caused by NetworkManager repeatedly trying to obtain a DHCP lease on `t2_ncm` — a virtual USB Ethernet interface the T2 chip exposes internally. There is no DHCP server behind it; the interface is an Apple-internal management channel, not a real network connection.

**Fix:** Adds `/etc/NetworkManager/conf.d/t2-unmanaged.conf` to mark `t2_ncm` as unmanaged, preventing NetworkManager from touching it.

```bash
bash fix-t2-ncm.sh
```

---

### `fix-t2-bluetooth.sh` — Fix intermittent Bluetooth not detected at boot

**Problem:** On some boots the Bluetooth adapter is completely invisible. The `hci_bcm4377` driver logs `probe with driver hci_bcm4377 failed with error -110` (`-ETIMEDOUT`). The BCM4377 chip exposes WiFi (`01:00.0`, `brcmfmac`) and Bluetooth (`01:00.1`, `hci_bcm4377`) as two PCIe functions that share the same firmware. If `hci_bcm4377` probes `01:00.1` while `brcmfmac` is still loading the shared firmware, the probe times out and the Bluetooth card is invisible until reboot.

**Fix:** Two-part:
1. `/etc/modprobe.d/t2-bluetooth.conf` — `softdep hci_bcm4377 pre: brcmfmac` ensures the WiFi driver loads first.
2. `/etc/udev/rules.d/99-t2-bluetooth.rules` — re-probes `0000:01:00.1` and unblocks rfkill the moment the WiFi interface (`wlp*`) appears, guaranteeing `brcmfmac` has fully initialized its firmware before `hci_bcm4377` binds.

```bash
bash fix-t2-bluetooth.sh
```

---

## Installation

```bash
wget https://raw.githubusercontent.com/lucadibello/T2Linux-Suspend-Fix/refs/heads/main/t2-suspend-fix.sh
chmod +x t2-suspend-fix.sh
./t2-suspend-fix.sh
```

Choose **Install**, follow the prompts, and reboot.

---

## Uninstallation

Run the script again and choose **Uninstall**. All services, scripts, and system changes (GRUB, ASPM, thermald, ACPI wake sources) are restored from backups stored in `/etc/t2-suspend-fix/`.

---

## Known Issues

- **Some systems still do not work** with this fix. Results vary across firmware revisions even on identical hardware. If it doesn't work, uninstall and revert.
- **Thunderbolt devices** (USB-C peripherals via TB3) may need to be re-plugged after resume due to the JHL7540 -19 ENODEV error.

---

## Debugging

```bash
chmod +x debug-suspend.sh
./debug-suspend.sh          # run BEFORE suspend
# suspend and resume
./debug-suspend.sh          # run AFTER resume
```

Log paths are printed at the end of each run. Include both logs when reporting issues.

---

## License

Use at your own risk.

> Thank you very much [@deqrocks](https://github.com/deqrocks). I built on top of your work to create a more comprehensive fix that targets also my specific firmware/machine. I hope this will be useful to other T2 Linux users as well. If you have any suggestions or improvements, please let me know! 🙌
