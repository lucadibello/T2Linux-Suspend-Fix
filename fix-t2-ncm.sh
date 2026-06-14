#!/bin/bash

# Prevent NetworkManager from trying to DHCP on the T2 NCM interface.
# t2_ncm is an Apple-internal USB Ethernet exposed by the T2 chip;
# it has no DHCP server behind it, so NM's attempts cause the top-bar
# loading spinner after every resume.

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

if [ "$EUID" -eq 0 ]; then
    echo -e "${RED}Error: Do not run as root. Script uses sudo when needed.${NC}"
    exit 1
fi

CONF=/etc/NetworkManager/conf.d/t2-unmanaged.conf

if [ -f "$CONF" ]; then
    echo -e "${GREEN}Already applied: $CONF exists.${NC}"
    exit 0
fi

sudo tee "$CONF" > /dev/null << 'EOF'
[keyfile]
unmanaged-devices=interface-name:t2_ncm
EOF

sudo systemctl reload NetworkManager
echo -e "${GREEN}Done. NetworkManager will no longer manage t2_ncm.${NC}"
