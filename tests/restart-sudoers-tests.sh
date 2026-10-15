#!/bin/bash

##################################################
# PinPoint Installer Test Runner
# Module : restart-sudoers-tests.sh
# Purpose: Check the /etc/sudoers.d/pinpoint-restart
#          rule on a disposable test VM, as root.
#
# Usage: sudo ./restart-sudoers-tests.sh
#
# Output: one line per case, "ID|STATUS|note", then a
# summary. Also written to /root/restart-sudoers-output.txt.
# Nagios is restarted once (case R1). Run it only on a
# VM you can restore from a snapshot.
##################################################

set -u

OUT="/root/restart-sudoers-output.txt"
RULE_FILE="/etc/sudoers.d/pinpoint-restart"

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

as_pinpoint() {
    runuser -u pinpoint -- "$@"
}

# R1: the real command, as PinPoint runs it.
if as_pinpoint sudo -n /usr/bin/systemctl restart nagios > /dev/null 2>&1 \
    && systemctl is-active --quiet nagios; then
    record R1 PASS "restart nagios works and nagios is active"
else
    record R1 FAIL "restart nagios was refused or nagios is not active"
fi

# R2: other units are refused (-l only checks the rule).
if as_pinpoint sudo -n -l /usr/bin/systemctl restart sshd > /dev/null 2>&1; then
    record R2 FAIL "restart sshd is allowed"
else
    record R2 PASS "restart sshd is refused"
fi

# R3: extra arguments are refused.
if as_pinpoint sudo -n -l /usr/bin/systemctl restart nagios extra > /dev/null 2>&1; then
    record R3 FAIL "restart nagios extra is allowed"
else
    record R3 PASS "restart nagios extra is refused"
fi

# R4: stop and start stay refused.
BAD=""
for ACTION in stop start; do
    if as_pinpoint sudo -n -l /usr/bin/systemctl "$ACTION" nagios > /dev/null 2>&1; then
        BAD="$BAD $ACTION"
    fi
done

if [ -z "$BAD" ]; then
    record R4 PASS "stop and start are refused"
else
    record R4 FAIL "allowed:$BAD"
fi

# R5: no wildcard or shell anywhere in pinpoint's rights.
LIST="$(as_pinpoint sudo -n -l 2> /dev/null)"
if printf '%s' "$LIST" | grep -Eq '\*|ALL$|/bin/(ba|da)?sh|/usr/bin/(ba|da)?sh'; then
    record R5 FAIL "wildcard or shell in: $(printf '%s' "$LIST" | grep -E '^\s+\(' | tr '\n' ' ')"
else
    record R5 PASS "no wildcard or shell in sudo -n -l"
fi

# R6: file owner, mode and syntax.
if [ "$(stat -c '%U:%G %a' "$RULE_FILE" 2> /dev/null)" = "root:root 440" ]; then
    record R6 PASS "$RULE_FILE is root:root 440"
else
    record R6 FAIL "$RULE_FILE is $(stat -c '%U:%G %a' "$RULE_FILE" 2>&1)"
fi

if visudo -c > /dev/null 2>&1; then
    record R7 PASS "visudo -c parses every sudoers file"
else
    record R7 FAIL "visudo -c failed"
fi

# R8: the existing rules are still there.
if as_pinpoint sudo -n -l /usr/bin/systemctl reload nagios > /dev/null 2>&1 \
    && as_pinpoint sudo -n -l /usr/local/sbin/pinpoint-apply-smtp > /dev/null 2>&1; then
    record R8 PASS "reload and SMTP helper rules unchanged"
else
    record R8 FAIL "reload or SMTP helper rule missing"
fi

echo
echo "PASS=$PASS FAIL=$FAIL" | tee -a "$OUT"

[ "$FAIL" -eq 0 ]
