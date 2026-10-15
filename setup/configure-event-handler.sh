#!/bin/bash

##################################################
# PinPoint Installer Module
# Module : configure-event-handler.sh
# Purpose: Prepare the Nagios event handler used for
#          automatic recovery (proactive resolution):
#            - a spool folder where Nagios (account
#              "nagios") writes events and the web
#              application (group "pinpoint") reads
#              and deletes them
#            - the handler itself, installed as a
#              root-owned file the web user cannot
#              change
#
# Safe to run again on an existing appliance. It does
# not change other Nagios settings, the SMTP helper or
# the sudoers rules.
#
# Must run after deploy-pinpoint-web.sh, which creates
# the pinpoint account and the application checkout.
##################################################

set -e

LOG="/var/log/pinpoint-event-handler.log"

APP_USER="pinpoint"
APP_GROUP="pinpoint"
NAGIOS_USER="nagios"

APP_DIR="/opt/pinpoint/Network-Diagnosis-System"
HANDLER_SOURCE="$APP_DIR/server/scripts/pinpoint_event_handler.py"
HANDLER_BIN="/usr/local/sbin/pinpoint-event-handler"

# The parent stays root-owned: only the spool itself is shared.
SPOOL_PARENT="/usr/local/nagios/var/spool"
SPOOL_DIR="$SPOOL_PARENT/pinpoint-events"

NAGIOS_CFG="/usr/local/nagios/etc/nagios.cfg"

##################################################
# Helpers
##################################################

fail() {
    echo "ERROR: $1" | tee -a "$LOG"
    echo "Check $LOG for details." | tee -a "$LOG"
    exit 1
}

##################################################
# Root Check
##################################################

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: This script must be run as root."
    exit 1
fi

echo "======================================" | tee -a "$LOG"
echo " PinPoint - Configuring Event Handler" | tee -a "$LOG"
echo " Started: $(date)" | tee -a "$LOG"
echo "======================================" | tee -a "$LOG"

##################################################
# [1/4] Check Prerequisites
##################################################

echo
echo "[1/4] Checking prerequisites..." | tee -a "$LOG"

if ! id "$APP_USER" > /dev/null 2>&1; then
    fail "Account $APP_USER not found. Run deploy-pinpoint-web.sh first."
fi

if ! id "$NAGIOS_USER" > /dev/null 2>&1 || [ ! -f "$NAGIOS_CFG" ]; then
    fail "Account $NAGIOS_USER or $NAGIOS_CFG not found. Run install-nagios-core.sh first."
fi

echo "✓ Accounts $APP_USER and $NAGIOS_USER found." | tee -a "$LOG"

##################################################
# [2/4] Create the Spool Folder
##################################################

echo
echo "[2/4] Creating the event spool folder..." | tee -a "$LOG"

# Written by nagios, read and deleted by pinpoint. The setgid
# bit keeps new entries in group pinpoint.
usermod -aG "$APP_GROUP" "$APP_USER"

install -d -m 755 -o root -g root "$SPOOL_PARENT"
install -d -m 2770 -o "$NAGIOS_USER" -g "$APP_GROUP" "$SPOOL_DIR"

# install -d leaves an existing folder's mode alone on some
# versions, so set it explicitly for upgrades.
chown "$NAGIOS_USER:$APP_GROUP" "$SPOOL_DIR"
chmod 2770 "$SPOOL_DIR"

echo "✓ $SPOOL_DIR is $NAGIOS_USER:$APP_GROUP 2770." | tee -a "$LOG"

##################################################
# [3/4] Install the Handler
##################################################

echo
echo "[3/4] Installing the event handler..." | tee -a "$LOG"

if [ -f "$HANDLER_SOURCE" ]; then
    HANDLER_TMP="$(mktemp)"
    cp "$HANDLER_SOURCE" "$HANDLER_TMP"

    if ! head -n 1 "$HANDLER_TMP" | grep -q '^#!'; then
        rm -f "$HANDLER_TMP"
        fail "$HANDLER_SOURCE does not start with an interpreter line."
    fi

    # Root-owned copy: the web user cannot modify what Nagios runs.
    install -m 755 -o root -g root "$HANDLER_TMP" "$HANDLER_BIN"
    rm -f "$HANDLER_TMP"

    echo "✓ $HANDLER_BIN installed (root:root 755)." | tee -a "$LOG"
else
    # Older application versions have no handler. Keep the
    # spool, skip the handler, and say so.
    echo "WARNING: $HANDLER_SOURCE not found; the deployed PinPoint version has no event handler." | tee -a "$LOG"
    echo "         The spool folder is ready. Run this script again after upgrading PinPoint." | tee -a "$LOG"
fi

##################################################
# [4/4] Verify
##################################################

echo
echo "[4/4] Verifying..." | tee -a "$LOG"

# Event handlers are on by default; only an explicit 0 turns them off.
if grep -Eq '^[[:space:]]*enable_event_handlers[[:space:]]*=[[:space:]]*0' "$NAGIOS_CFG"; then
    echo "WARNING: enable_event_handlers=0 in $NAGIOS_CFG; automatic recovery will not run." | tee -a "$LOG"
    echo "         Not changed: it may be an administrator's setting." | tee -a "$LOG"
fi

PROBE="$SPOOL_DIR/.installer-probe-$$"

if ! runuser -u "$NAGIOS_USER" -- sh -c "echo probe > '$PROBE'" >> "$LOG" 2>&1; then
    fail "$NAGIOS_USER cannot write to $SPOOL_DIR."
fi

if ! runuser -u "$APP_USER" -- sh -c "cat '$PROBE' > /dev/null && rm -f '$PROBE'" >> "$LOG" 2>&1; then
    rm -f "$PROBE"
    fail "$APP_USER cannot read and delete entries in $SPOOL_DIR."
fi

if [ -f "$HANDLER_BIN" ]; then
    if runuser -u "$APP_USER" -- test -w "$HANDLER_BIN"; then
        fail "$APP_USER can modify $HANDLER_BIN."
    fi

    if ! runuser -u "$NAGIOS_USER" -- test -x "$HANDLER_BIN"; then
        fail "$NAGIOS_USER cannot run $HANDLER_BIN."
    fi
fi

echo "✓ $NAGIOS_USER can write, $APP_USER can read and delete, and the handler is not writable by $APP_USER." | tee -a "$LOG"

echo
echo "======================================" | tee -a "$LOG"
echo " Event handler setup completed."
echo "======================================" | tee -a "$LOG"
