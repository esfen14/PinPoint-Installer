#!/bin/bash

##################################################
# PinPoint Installer Module
# Module : fix-firstboot-run-once.sh
# Purpose: Stop the first-boot installer from running
#          again on every reboot of an installed
#          appliance.
#
# Why: getty-tty1.conf makes getty@tty1 want
# pinpoint-firstboot.service, so the
# "systemctl disable" at the end of the first boot
# does not stop it, and the whole installer ran
# again at each boot. New installs have the fix in
# the unit itself. This script brings appliances
# installed before the fix in line:
#   - writes the marker /var/lib/pinpoint/firstboot-done,
#     but only if the first install completed
#   - adds a drop-in that skips the unit while the
#     marker exists
#
# Usage: sudo bash /root/pinpoint/fix-firstboot-run-once.sh
# Safe to run again. No reboot needed.
##################################################

set -e

LOG="/var/log/pinpoint-firstboot-fix.log"

MARKER="${PINPOINT_FIRSTBOOT_MARKER:-/var/lib/pinpoint/firstboot-done}"
FIRSTBOOT_LOG="${PINPOINT_FIRSTBOOT_LOG:-/var/log/pinpoint-firstboot.log}"
DROPIN_DIR="${PINPOINT_FIRSTBOOT_DROPIN_DIR:-/etc/systemd/system/pinpoint-firstboot.service.d}"
DROPIN="$DROPIN_DIR/run-once.conf"
DONE_LINE="PinPoint installation completed successfully."

##################################################
# Root Check
##################################################

if [ "$EUID" -ne 0 ] && [ -z "${PINPOINT_FIX_TEST:-}" ]; then
    echo "ERROR: This script must be run as root."
    exit 1
fi

if [ -n "${PINPOINT_FIX_TEST:-}" ]; then
    LOG="${PINPOINT_FIX_TEST}/fix.log"
fi

echo "======================================" | tee -a "$LOG"
echo " PinPoint - First boot runs once" | tee -a "$LOG"
echo " Started: $(date)" | tee -a "$LOG"
echo "======================================" | tee -a "$LOG"

##################################################
# [1/3] Marker
##################################################

echo
echo "[1/3] Checking that the first install completed..." | tee -a "$LOG"

if [ -f "$MARKER" ]; then
    echo "✓ $MARKER already present." | tee -a "$LOG"
elif [ -f "$FIRSTBOOT_LOG" ] && grep -qxF "$DONE_LINE" "$FIRSTBOOT_LOG"; then
    mkdir -p "$(dirname "$MARKER")"
    touch "$MARKER"
    chmod 644 "$MARKER"
    echo "✓ First install completed; $MARKER written." | tee -a "$LOG"
else
    echo "✗ $FIRSTBOOT_LOG does not show a completed first install." | tee -a "$LOG"
    echo "  Nothing was changed: the first-boot installer still runs at the next boot" | tee -a "$LOG"
    echo "  so it can finish. Run this script again once it has completed." | tee -a "$LOG"
    exit 1
fi

##################################################
# [2/3] Drop-in
##################################################

echo
echo "[2/3] Installing the run-once drop-in..." | tee -a "$LOG"

WANT="# Managed by PinPoint Installer.
# Skip the first-boot installer once it has completed.
[Unit]
ConditionPathExists=!$MARKER"

if [ -f "$DROPIN" ] && [ "$(cat "$DROPIN")" = "$WANT" ]; then
    echo "✓ $DROPIN already up to date." | tee -a "$LOG"
else
    mkdir -p "$DROPIN_DIR"
    printf '%s\n' "$WANT" > "$DROPIN.tmp"
    chmod 644 "$DROPIN.tmp"
    mv "$DROPIN.tmp" "$DROPIN"
    echo "✓ $DROPIN written." | tee -a "$LOG"
fi

##################################################
# [3/3] Reload and check
##################################################

echo
echo "[3/3] Reloading systemd..." | tee -a "$LOG"

systemctl daemon-reload

if systemctl cat pinpoint-firstboot.service 2> /dev/null | grep -qxF "ConditionPathExists=!$MARKER"; then
    echo "✓ pinpoint-firstboot.service now runs only while $MARKER is missing." | tee -a "$LOG"
else
    echo "✗ systemd does not show the run-once condition for pinpoint-firstboot.service." | tee -a "$LOG"
    exit 1
fi

echo
echo "======================================" | tee -a "$LOG"
echo " Done. The first-boot installer will not run again." | tee -a "$LOG"
echo " Finished: $(date)" | tee -a "$LOG"
echo "======================================" | tee -a "$LOG"

exit 0
