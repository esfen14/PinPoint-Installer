#!/bin/bash

##################################################
# PinPoint Installer Test Runner
# Module : journald-log-tests.sh
# Purpose: Check the journal limit and installer log
#          rotation set up by configure-journald-logs.sh,
#          on a disposable test VM, as root.
#
# Usage: sudo ./journald-log-tests.sh
#
# Output: one line per case, "ID|STATUS|note", then a
# summary. Also written to /root/journald-log-output.txt.
# The edited-file cases (J7, J8) restore the files.
##################################################

set -u

OUT="/root/journald-log-output.txt"
DROPIN="/etc/systemd/journald.conf.d/pinpoint.conf"
LOGROTATE="/etc/logrotate.d/pinpoint"
SCRIPT="${1:-/root/pinpoint/configure-journald-logs.sh}"

PASS=0
FAIL=0

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Run as root."
    exit 1
fi

: > "$OUT"

record() {
    printf '%s|%s|%s\n' "$1" "$2" "$3" | tee -a "$OUT"

    case "$2" in
        PASS) PASS=$((PASS + 1)) ;;
        FAIL) FAIL=$((FAIL + 1)) ;;
    esac
}

if [ -f "$DROPIN" ] && grep -qx 'SystemMaxUse=200M' "$DROPIN" && grep -qx 'MaxRetentionSec=30day' "$DROPIN"; then
    record J1 PASS "$DROPIN sets SystemMaxUse=200M and MaxRetentionSec=30day"
else
    record J1 FAIL "$DROPIN missing or has other values"
fi

if [ "$(stat -c '%U:%G %a' "$DROPIN" 2> /dev/null)" = "root:root 644" ]; then
    record J2 PASS "drop-in is root:root 644"
else
    record J2 FAIL "drop-in is $(stat -c '%U:%G %a' "$DROPIN" 2>&1)"
fi

if systemctl show systemd-journald -p ActiveState --value | grep -qx active \
    && journalctl --disk-usage > /dev/null 2>&1; then
    record J3 PASS "journald is active and reports disk usage"
else
    record J3 FAIL "journald is not healthy"
fi

if [ -f "$LOGROTATE" ] && logrotate -d "$LOGROTATE" > /dev/null 2>&1; then
    record J4 PASS "$LOGROTATE is valid (logrotate -d)"
else
    record J4 FAIL "$LOGROTATE missing or invalid"
fi

if grep -q '/var/log/pinpoint-\*.log' "$LOGROTATE" 2> /dev/null; then
    record J5 PASS "rule covers /var/log/pinpoint-*.log"
else
    record J5 FAIL "rule does not cover the installer logs"
fi

if bash "$SCRIPT" > /dev/null 2>&1; then
    record J6 PASS "second run succeeds"
else
    record J6 FAIL "second run failed"
fi

# J7: an administrator's own drop-in is kept.
cp -p "$DROPIN" "$DROPIN.test-save"
printf '[Journal]\nSystemMaxUse=50M\n' > "$DROPIN"
bash "$SCRIPT" > /dev/null 2>&1

if grep -qx 'SystemMaxUse=50M' "$DROPIN"; then
    record J7 PASS "edited journald drop-in kept"
else
    record J7 FAIL "edited journald drop-in was overwritten"
fi

mv -f "$DROPIN.test-save" "$DROPIN"

# J8: an administrator's own logrotate rule is kept.
cp -p "$LOGROTATE" "$LOGROTATE.test-save"
printf '/var/log/pinpoint-*.log {\n    daily\n    rotate 3\n}\n' > "$LOGROTATE"
bash "$SCRIPT" > /dev/null 2>&1

if grep -qx '    rotate 3' "$LOGROTATE"; then
    record J8 PASS "edited logrotate rule kept"
else
    record J8 FAIL "edited logrotate rule was overwritten"
fi

mv -f "$LOGROTATE.test-save" "$LOGROTATE"

# J9: a forced rotation keeps the log file in place and writable.
TESTLOG="/var/log/pinpoint-rotation-test.log"
echo test > "$TESTLOG"

if logrotate -f "$LOGROTATE" > /dev/null 2>&1 && [ -f "$TESTLOG" ]; then
    record J9 PASS "forced rotation works and the log file stays in place"
else
    record J9 FAIL "forced rotation failed"
fi

rm -f "$TESTLOG" "$TESTLOG".1 "$TESTLOG".*.gz

echo
echo "PASS=$PASS FAIL=$FAIL" | tee -a "$OUT"

[ "$FAIL" -eq 0 ]
