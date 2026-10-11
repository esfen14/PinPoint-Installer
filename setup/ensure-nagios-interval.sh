#!/bin/bash

##################################################
# PinPoint Installer Module
# Module: ensure-nagios-interval.sh
# Purpose: Make sure Nagios interval_length is 60
#
# PinPoint writes check_interval in minutes, which
# Nagios reads as multiples of interval_length. Only
# 60 makes "2" mean two minutes.
#
# Nagios uses the last interval_length it finds; none
# means 60. A different value is replaced by 60 after
# a backup, checked with "nagios -v" and put back if
# the check fails. When the value was changed and
# Nagios is running, it is reloaded so the new value
# takes effect.
#
# Called by configure-nagios.sh (install) and
# deploy-pinpoint-web.sh (install and upgrade).
# LOG may be set by the caller.
##################################################

set -e

LOG="${LOG:-/var/log/pinpoint-configure.log}"

NAGIOS_BIN="/usr/local/nagios/bin/nagios"
NAGIOS_CFG="/usr/local/nagios/etc/nagios.cfg"
REQUIRED_INTERVAL_LENGTH="60"

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: This script must be run as root."
    exit 1
fi

if [ ! -x "$NAGIOS_BIN" ] || [ ! -f "$NAGIOS_CFG" ]; then
    echo "ERROR: Nagios is not installed, cannot check interval_length." | tee -a "$LOG"
    exit 1
fi

CURRENT_INTERVAL_LENGTH="$(
    grep -E '^[[:space:]]*interval_length[[:space:]]*=' "$NAGIOS_CFG" \
        | tail -n 1 | cut -d= -f2 | tr -d '[:space:]' || true
)"

if [ -z "$CURRENT_INTERVAL_LENGTH" ] || \
   [ "$CURRENT_INTERVAL_LENGTH" = "$REQUIRED_INTERVAL_LENGTH" ]; then

    echo "✓ interval_length is ${CURRENT_INTERVAL_LENGTH:-unset (Nagios default $REQUIRED_INTERVAL_LENGTH)}." | tee -a "$LOG"
    exit 0

fi

INTERVAL_BACKUP="$NAGIOS_CFG.interval-length.$(date +%Y%m%d%H%M%S).bak"
cp -p "$NAGIOS_CFG" "$INTERVAL_BACKUP"

echo "interval_length is $CURRENT_INTERVAL_LENGTH, not $REQUIRED_INTERVAL_LENGTH. Setting it to $REQUIRED_INTERVAL_LENGTH (backup: $INTERVAL_BACKUP)." | tee -a "$LOG"

# Drop every active interval_length line and add one, so the
# result does not depend on which line Nagios would have read.
# cat keeps the owner and mode of nagios.cfg.
grep -vE '^[[:space:]]*interval_length[[:space:]]*=' "$NAGIOS_CFG" \
    > "$NAGIOS_CFG.tmp" || true
printf '\n# PinPoint: check_interval is in minutes only if this is 60.\ninterval_length=%s\n' \
    "$REQUIRED_INTERVAL_LENGTH" >> "$NAGIOS_CFG.tmp"
cat "$NAGIOS_CFG.tmp" > "$NAGIOS_CFG"
rm -f "$NAGIOS_CFG.tmp"

if ! "$NAGIOS_BIN" -v "$NAGIOS_CFG" >> "$LOG" 2>&1; then
    cat "$INTERVAL_BACKUP" > "$NAGIOS_CFG"
    echo "ERROR: nagios -v rejected interval_length=$REQUIRED_INTERVAL_LENGTH. nagios.cfg restored from $INTERVAL_BACKUP." | tee -a "$LOG"
    exit 1
fi

echo "✓ interval_length set to $REQUIRED_INTERVAL_LENGTH; nagios -v passes." | tee -a "$LOG"

# The running daemon keeps the old value until it reloads.
if systemctl is-active --quiet nagios; then
    if ! systemctl reload nagios >> "$LOG" 2>&1; then
        echo "ERROR: Could not reload Nagios after changing interval_length." | tee -a "$LOG"
        exit 1
    fi
    echo "✓ Nagios reloaded with interval_length=$REQUIRED_INTERVAL_LENGTH." | tee -a "$LOG"
fi
