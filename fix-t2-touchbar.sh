#!/bin/bash

# Fix Touch Bar staying dark after boot on T2 MacBooks (kernel 7.x regression).
#
# Root cause: the kernel update to 7.0.x regressed the apple_bce VHCI so the
# SET_CONFIGURATION control transfer that switches the Touch Bar Display
# (USB 05ac:8302) into USB configuration 2 times out (-ETIMEDOUT, logged as
# "Connection timed out"). Config 2 is the configuration that exposes the
# appletbdrm display interface (5-6:2.1). Without it appletbdrm never binds and
# tiny-dfr — the daemon that draws the function keys onto that DRM device —
# never starts, so the bar stays dark. The timeout happens even on an idle,
# unconfigured device with autosuspend disabled, so no udev rule or higher-level
# driver reload can fix it: they all depend on that same control transfer.
#
# The previous kernel (6.18.7-210, still installed) drives the Touch Bar fine.
#
# Fix: fully reload apple_bce, which re-initializes the VHCI from scratch — the
# only userspace lever that lets the config switch succeed on 7.0.x. A boot
# service (t2-touchbar-fix.service) tears down the Touch Bar driver stack,
# reloads apple_bce, switches the device into config 2 (with delays), reloads
# the HID drivers, and restarts tiny-dfr. Reloading apple_bce briefly drops the
# internal keyboard/trackpad/audio and desyncs the keyboard backlight, so the
# service also resyncs the keyboard backlight afterwards. A failsafe always
# reloads apple_bce + the HID modules so input returns even if the Touch Bar
# part fails.
#
# Resume from suspend leaves the Touch Bar in the same broken state as a cold
# boot: the device drops back to no configuration (bConfigurationValue empty),
# appletbdrm unbinds and tiny-dfr stops. So a second service
# (t2-touchbar-resume.service), keyed to suspend.target like the rest of the
# T2 suspend fixes, runs the same helper after every wake.

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [ "$EUID" -eq 0 ]; then
    echo -e "${RED}Error: Do not run as root. Script uses sudo when needed.${NC}"
    exit 1
fi

HELPER=/usr/local/bin/t2-touchbar-fix.sh
SERVICE=/etc/systemd/system/t2-touchbar-fix.service
RESUME_SERVICE=/etc/systemd/system/t2-touchbar-resume.service
POWER_RULE=/etc/udev/rules.d/99-t2-touchbar-power.rules
TINYDFR_CONF=/etc/tiny-dfr/config.toml

# tiny-dfr's adaptive brightness maps the main screen's brightness onto the Touch
# Bar backlight using a value on a 0-255 scale, but the Intel T2 Touch Bar
# (hid-appletb-bl) only has 3 levels (max_brightness=2). With the default
# ActiveBrightness=128 the computed value saturates to 2 at almost any screen
# brightness, so the bar is always at full and never tracks the screen. Scaling
# ActiveBrightness right down brings the output into the usable {1,2} range so it
# actually dims. The dim->bright crossover sits at ~509/ActiveBrightness^2 percent
# of screen brightness; 4 -> ~32%. Raise it to dim later, lower it to dim sooner.
ACTIVE_BRIGHTNESS=4

# Remove stale artifacts from earlier (incorrect) attempts.
for f in /etc/modprobe.d/t2-touchbar.conf \
          /etc/udev/rules.d/99-t2-touchbar.rules \
          /usr/local/bin/t2-touchbar-rebind.sh; do
    if [ -e "$f" ]; then
        echo -e "${YELLOW}⚙${NC} Removing stale file: $f"
        sudo rm -f "$f"
        echo -e "${GREEN}Done.${NC}"
    fi
done

echo -e "${YELLOW}⚙${NC} Installing USB autosuspend rule: $POWER_RULE"
sudo tee "$POWER_RULE" > /dev/null << 'EOF'
# Keep the Touch Bar Display (05ac:8302) powered on. On kernel >= 6.12.31 USB
# autosuspend makes control transfers to the device fail with
# "usb_submit_urb(ctrl) failed: -1".
SUBSYSTEM=="usb", ATTR{idVendor}=="05ac", ATTR{idProduct}=="8302", ATTR{power/control}="on", ATTR{power/autosuspend_delay_ms}="-1"
EOF
echo -e "${GREEN}Done: $POWER_RULE${NC}"

echo -e "${YELLOW}⚙${NC} Configuring tiny-dfr adaptive brightness: $TINYDFR_CONF"
if [ -e "$TINYDFR_CONF" ] && [ ! -e "$TINYDFR_CONF.t2bak" ]; then
    sudo cp "$TINYDFR_CONF" "$TINYDFR_CONF.t2bak"
    echo -e "${YELLOW}  Backed up existing config to $TINYDFR_CONF.t2bak${NC}"
fi
sudo mkdir -p "$(dirname "$TINYDFR_CONF")"
# tiny-dfr merges /etc over /usr/share, so only the overridden keys are needed.
sudo tee "$TINYDFR_CONF" > /dev/null << EOF
# Touch Bar backlight follows the main screen's brightness.
# ActiveBrightness is scaled down because the Intel T2 Touch Bar backlight only
# has 3 levels (max_brightness=2); the default 128 would pin it at full.
# Crossover dim->bright is at ~509/ActiveBrightness^2 % screen brightness.
AdaptiveBrightness = true
ActiveBrightness = $ACTIVE_BRIGHTNESS
EOF
echo -e "${GREEN}Done: $TINYDFR_CONF${NC}"

echo -e "${YELLOW}⚙${NC} Installing helper script: $HELPER"
sudo tee "$HELPER" > /dev/null << 'EOF'
#!/bin/bash
# Reload apple_bce and switch the Touch Bar Display into USB config 2 so
# appletbdrm binds and tiny-dfr can draw the function keys. See
# t2-touchbar-fix.service. Safe to run by hand.
set +e

KBD_BL=/sys/class/leds/:white:kbd_backlight/brightness

# Already working? (appletbdrm bound to the :2.x display interface.) Do nothing.
if ls -d /sys/bus/usb/drivers/appletbdrm/*:2.* >/dev/null 2>&1; then
    echo "t2-touchbar-fix: appletbdrm already bound; nothing to do."
    exit 0
fi

# Remember current keyboard backlight; the apple_bce reload desyncs it.
SAVED_BL=0
[ -r "$KBD_BL" ] && SAVED_BL="$(cat "$KBD_BL" 2>/dev/null)"

# Tear down the Touch Bar driver stack, then fully reset the VHCI.
systemctl stop tiny-dfr 2>/dev/null
rmmod hid_appletb_kbd 2>/dev/null
rmmod hid_appletb_bl 2>/dev/null
rmmod appletbdrm 2>/dev/null
rmmod -f apple_bce 2>/dev/null
sleep 2
modprobe apple_bce
sleep 5

# Wait for the Touch Bar Display (05ac:8302) to re-enumerate.
TB=""
for _ in $(seq 60); do
    for d in /sys/bus/usb/devices/*; do
        case "$(basename "$d")" in *:*) continue ;; esac
        [ -f "$d/idProduct" ] || continue
        if [ "$(cat "$d/idVendor" 2>/dev/null)" = "05ac" ] && \
           [ "$(cat "$d/idProduct" 2>/dev/null)" = "8302" ]; then
            TB="$d"; break 2
        fi
    done
    sleep 0.5
done

modprobe hid_appletb_bl
sleep 2

if [ -n "$TB" ]; then
    echo on > "$TB/power/control" 2>/dev/null
    echo -1 > "$TB/power/autosuspend_delay_ms" 2>/dev/null
    # After a fresh apple_bce reload the device almost always re-enumerates
    # straight into config 2 and appletbdrm binds on its own. Only force the
    # config switch if it did NOT — otherwise the extra 0->2 toggle unbinds and
    # rebinds appletbdrm, which makes the Touch Bar flicker a second time and
    # churns tiny-dfr (it loses and regains its DRM device).
    if ! ls -d /sys/bus/usb/drivers/appletbdrm/*:2.* >/dev/null 2>&1; then
        echo 0 > "$TB/bConfigurationValue" 2>/dev/null
        sleep 1
        echo 2 > "$TB/bConfigurationValue" 2>/dev/null
        sleep 3
    fi
fi

modprobe hid_appletb_kbd
sleep 2

systemctl restart tiny-dfr 2>/dev/null

# Resync the keyboard backlight (reload leaves hardware on while sysfs reads 0).
if [ -w "$KBD_BL" ]; then
    echo 1 > "$KBD_BL"
    sleep 0.3
    echo "$SAVED_BL" > "$KBD_BL"
fi

# Failsafe: guarantee input modules are loaded.
modprobe apple_bce 2>/dev/null
modprobe hid_appletb_bl 2>/dev/null
modprobe hid_appletb_kbd 2>/dev/null

if ls -d /sys/bus/usb/drivers/appletbdrm/*:2.* >/dev/null 2>&1; then
    echo "t2-touchbar-fix: appletbdrm bound; Touch Bar up (tiny-dfr: $(systemctl is-active tiny-dfr))."
    exit 0
else
    echo "t2-touchbar-fix: appletbdrm still not bound after reload." >&2
    exit 1
fi
EOF
sudo chmod +x "$HELPER"
echo -e "${GREEN}Done: $HELPER${NC}"

echo -e "${YELLOW}⚙${NC} Installing systemd service: $SERVICE"
sudo tee "$SERVICE" > /dev/null << 'EOF'
[Unit]
Description=T2 Touch Bar — reload apple_bce and bring up the display (kernel 7.x fix)
After=systemd-udev-settle.service multi-user.target
Wants=systemd-udev-settle.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/t2-touchbar-fix.sh
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
echo -e "${GREEN}Done: $SERVICE${NC}"

echo -e "${YELLOW}⚙${NC} Installing resume service: $RESUME_SERVICE"
sudo tee "$RESUME_SERVICE" > /dev/null << 'EOF'
[Unit]
Description=T2 Touch Bar — bring the display back up after resume (kernel 7.x fix)
After=suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/t2-touchbar-fix.sh
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target
EOF
echo -e "${GREEN}Done: $RESUME_SERVICE${NC}"

echo -e "${YELLOW}⚙${NC} Reloading udev and enabling services..."
sudo udevadm control --reload-rules
sudo systemctl daemon-reload
sudo systemctl enable t2-touchbar-fix.service
sudo systemctl enable t2-touchbar-resume.service
# Apply the new brightness config now if tiny-dfr is already running.
sudo systemctl try-restart tiny-dfr 2>/dev/null
echo -e "${GREEN}Done.${NC}"

echo ""
echo -e "${GREEN}Touch Bar fix installed.${NC}"
echo "It runs automatically at every boot and after every resume from suspend."
echo "Note: reloading apple_bce briefly drops the internal keyboard/trackpad/"
echo "audio while it runs — this is expected. Test it now without rebooting with:"
echo "  sudo $HELPER"
