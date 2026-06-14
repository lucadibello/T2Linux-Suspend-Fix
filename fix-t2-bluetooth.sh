#!/bin/bash

# Fix intermittent Bluetooth failure on T2 MacBooks (BCM4377).
#
# Root cause: BCM4377 exposes WiFi (01:00.0, brcmfmac) and Bluetooth (01:00.1,
# hci_bcm4377) as two PCIe functions sharing the same firmware. If hci_bcm4377
# probes 01:00.1 while brcmfmac is still loading the shared firmware, the BT
# probe times out with -ETIMEDOUT and the Bluetooth card is invisible until reboot.
#
# Fix 1: modprobe softdep — tells the kernel to load brcmfmac before hci_bcm4377.
# Fix 2: udev rule — re-probes the BT device the moment the WiFi interface (wlp*)
#         appears, guaranteeing brcmfmac is fully initialized before BT binds.

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [ "$EUID" -eq 0 ]; then
    echo -e "${RED}Error: Do not run as root. Script uses sudo when needed.${NC}"
    exit 1
fi

MODPROBE_CONF=/etc/modprobe.d/t2-bluetooth.conf
UDEV_RULE=/etc/udev/rules.d/99-t2-bluetooth.rules

echo -e "${YELLOW}⚙${NC} Installing modprobe soft dependency..."
sudo tee "$MODPROBE_CONF" > /dev/null << 'EOF'
# Load brcmfmac (WiFi) before hci_bcm4377 (Bluetooth).
# Both share firmware on the BCM4377 PCIe device; loading in order avoids
# the -ETIMEDOUT race that makes Bluetooth invisible at boot.
softdep hci_bcm4377 pre: brcmfmac
EOF
echo -e "${GREEN}Done: $MODPROBE_CONF${NC}"

echo -e "${YELLOW}⚙${NC} Installing udev rebind rule..."
sudo tee "$UDEV_RULE" > /dev/null << 'EOF'
# When the WiFi interface (wlp*) appears, brcmfmac is fully ready.
# Re-probe the BT PCIe function in case it timed out during boot,
# then unblock rfkill so bluetoothd can power the controller on.
ACTION=="add", SUBSYSTEM=="net", KERNEL=="wlp*", \
    RUN+="/bin/sh -c 'echo 0000:01:00.1 > /sys/bus/pci/drivers/hci_bcm4377/bind 2>/dev/null || true'", \
    RUN+="/usr/sbin/rfkill unblock bluetooth"
EOF
echo -e "${GREEN}Done: $UDEV_RULE${NC}"

echo -e "${YELLOW}⚙${NC} Reloading udev rules..."
sudo udevadm control --reload-rules
echo -e "${GREEN}Done.${NC}"

echo ""
echo -e "${GREEN}Bluetooth fix applied.${NC}"
echo "The fix takes effect on next boot (modprobe softdep changes load order)."
echo "To unblock Bluetooth now (controller already bound):"
echo "  rfkill unblock bluetooth"
