#!/bin/bash

# T2 MacBook Suspend Debug Helper
# Collects diagnostic information for troubleshooting suspend/resume issues
# André Eikmeyer - 02/02/2026

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

LOGFILE="/tmp/t2-suspend-debug-$(date +%Y%m%d-%H%M%S).log"

echo -e "${GREEN}=== T2 MacBook Suspend Debug Helper ===${NC}\n"
echo "This script will collect diagnostic information."
echo "Log file: ${LOGFILE}"
echo ""

exec > >(tee -a "$LOGFILE") 2>&1

echo "=== System Information ==="
echo "Date: $(date)"
echo "Hostname: $(hostname)"
uname -a
echo ""

echo "=== MacBook Model ==="
sudo dmidecode -s system-product-name 2>/dev/null || echo "Could not detect model"
echo ""

echo "=== Kernel Parameters ==="
cat /proc/cmdline
echo ""

echo "=== Sleep Mode ==="
cat /sys/power/mem_sleep
echo ""

echo "=== ACPI Wakeup Sources ==="
cat /proc/acpi/wakeup
echo ""

echo "=== WiFi Hardware ==="
lspci -nn | grep -i broadcom
echo ""
WIFI_PCI=$(lspci -nn | grep -i "broadcom.*bcm43" | grep -oP '^\S+')
if [ -n "$WIFI_PCI" ]; then
    echo "Detected WiFi PCI: 0000:${WIFI_PCI}"
else
    echo "WARNING: Could not detect WiFi PCI ID"
fi
echo ""

echo "=== Loaded Modules (WiFi & BCE) ==="
lsmod | grep -E "brcmfmac|apple.bce"
echo ""

echo "=== PCI Driver Bindings ==="
if [ -d /sys/bus/pci/drivers/brcmfmac ]; then
    echo "brcmfmac driver directory exists"
    ls -la /sys/bus/pci/drivers/brcmfmac/ 2>/dev/null
else
    echo "WARNING: brcmfmac driver directory not found"
fi
echo ""

echo "=== Keyboard Backlight Status ==="
KBD_PATH="/sys/class/leds/:white:kbd_backlight"
if [ -d "$KBD_PATH" ]; then
    echo "Keyboard backlight path exists: $KBD_PATH"
    echo "Brightness: $(cat ${KBD_PATH}/brightness 2>/dev/null || echo 'Cannot read')"
    echo "Max brightness: $(cat ${KBD_PATH}/max_brightness 2>/dev/null || echo 'Cannot read')"
else
    echo "WARNING: Keyboard backlight path not found"
fi
echo ""

echo "=== Systemd Services Status ==="
for service in suspend-wifi-unload resume-wifi-reload fix-kbd-backlight; do
    echo "--- ${service}.service ---"
    systemctl status ${service}.service --no-pager 2>&1 || echo "Service not found"
    echo ""
done

echo "=== Recent Journal Entries (suspend-wifi-unload) ==="
journalctl -u suspend-wifi-unload.service -n 50 --no-pager
echo ""

echo "=== Recent Journal Entries (resume-wifi-reload) ==="
journalctl -u resume-wifi-reload.service -n 50 --no-pager
echo ""

echo "=== Recent Journal Entries (fix-kbd-backlight) ==="
journalctl -u fix-kbd-backlight.service -n 50 --no-pager
echo ""

echo "=== dmesg: apple-bce (last 50 lines) ==="
sudo dmesg | grep -i "apple.*bce" | tail -50
echo ""

echo "=== dmesg: brcmfmac (last 50 lines) ==="
sudo dmesg | grep -i brcmfmac | tail -50
echo ""

echo "=== NetworkManager WiFi Status ==="
nmcli radio wifi
nmcli device status | grep wifi
echo ""

echo -e "\n${GREEN}=== Debug information collected ===${NC}"
echo "Log saved to: ${LOGFILE}"
echo ""
echo "Please run this script:"
echo "1. BEFORE suspend (to see baseline)"
echo "2. AFTER resume (to see what changed)"
echo ""
echo "Then share both log files when reporting issues."
