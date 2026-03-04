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

### Why suspend crashes (kernel panic on resume)

The crash is a **use-of-stale-MMIO** in the `apple-bce` audio driver:

1. `suspend-wifi-unload.service` calls `rmmod -f apple-bce` while PipeWire has active PCM streams open
2. Force-removal bypasses the driver refcount and taints the kernel `[R]=FORCED_RMMOD`
3. On resume, `modprobe apple-bce` maps BCE audio at a **new MMIO address**
4. PipeWire still holds old `snd_pcm` handles pointing to the **old address**
5. When PipeWire eventually accesses one of those handles → `iowrite32` on an unmapped page → kernel BUG

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

**Fix:** stop PipeWire _before_ removing `apple-bce`, and restart it _after_ the module reloads on resume.

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
7. **Removes `systemd-suspend` override.conf** if present
8. **Installs libnotify** if missing (for desktop notifications on resume failure)

---

## Architecture / Suspend Sequence

### Before suspend (`suspend-wifi-unload.service`)

```text
1. brightnessctl: keyboard backlight off
2. echo deep > /sys/power/mem_sleep  (override Apple EFI cmdline)
3. t2-stop-audio.sh                  (stop PipeWire — prevents stale MMIO crash)
4. nmcli radio wifi off
5. modprobe -r brcmfmac_wcc
6. modprobe -r brcmfmac
7. rmmod -f apple-bce
-> system suspends
```

### After resume (`resume-wifi-reload.service`)

```text
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

- **Some systems do not work** with this fix. Results vary across firmware revisions even on identical hardware. If it doesn't work, uninstall and revert.
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

## Contributing

Yes please!

## License

Use at your own risk.

> Thank you very much [@deqrocks](https://github.com/deqrocks). I built on top of your work to create a more comprehensive fix that targets also my specific firmware/machine. I hope this will be useful to other T2 Linux users as well. If you have any suggestions or improvements, please let me know! 🙌
