#!/bin/bash

##################################################
# PinPoint Installer Test Runner
# Module : event-handler-tests.sh
# Purpose: Check the event spool folder and handler
#          set up by configure-event-handler.sh, on a
#          disposable test VM, as root.
#
# Usage: sudo ./event-handler-tests.sh
#
# Output: one line per case, "ID|STATUS|note", then a
# summary. Also written to /root/event-handler-output.txt.
##################################################

set -u

OUT="/root/event-handler-output.txt"
SPOOL="/usr/local/nagios/var/spool/pinpoint-events"
PARENT="/usr/local/nagios/var/spool"
HANDLER="/usr/local/sbin/pinpoint-event-handler"
NAGIOS_CFG="/usr/local/nagios/etc/nagios.cfg"

PASS=0
FAIL=0
SKIP=0

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
        SKIP) SKIP=$((SKIP + 1)) ;;
    esac
}

expect_stat() {
    # expect_stat ID path "owner:group mode"
    local actual
    actual="$(stat -c '%U:%G %a' "$2" 2> /dev/null)"

    if [ "$actual" = "$3" ]; then
        record "$1" PASS "$2 is $actual"
    else
        record "$1" FAIL "$2 is '$actual', expected '$3'"
    fi
}

expect_stat E1 "$SPOOL" "nagios:pinpoint 2770"
expect_stat E2 "$PARENT" "root:root 755"

if id -nG pinpoint | tr ' ' '\n' | grep -qx pinpoint; then
    record E3 PASS "pinpoint is in group pinpoint"
else
    record E3 FAIL "pinpoint is not in group pinpoint"
fi

PROBE="$SPOOL/.test-probe-$$"

if runuser -u nagios -- sh -c "echo probe > '$PROBE'" 2> /dev/null; then
    record E4 PASS "nagios can write to the spool"
else
    record E4 FAIL "nagios cannot write to the spool"
fi

if [ "$(stat -c '%G' "$PROBE" 2> /dev/null)" = "pinpoint" ]; then
    record E5 PASS "new entries get group pinpoint (setgid)"
else
    record E5 FAIL "new entry group is '$(stat -c '%G' "$PROBE" 2>&1)'"
fi

if runuser -u pinpoint -- sh -c "cat '$PROBE' > /dev/null && rm -f '$PROBE'" 2> /dev/null && [ ! -e "$PROBE" ]; then
    record E6 PASS "pinpoint can read and delete entries"
else
    rm -f "$PROBE"
    record E6 FAIL "pinpoint cannot read and delete entries"
fi

if runuser -u nobody -- ls "$SPOOL" > /dev/null 2>&1; then
    record E7 FAIL "other accounts can list the spool"
else
    record E7 PASS "other accounts cannot list the spool"
fi

if [ -f "$HANDLER" ]; then
    expect_stat E8 "$HANDLER" "root:root 755"

    if runuser -u pinpoint -- test -w "$HANDLER"; then
        record E9 FAIL "pinpoint can modify the handler"
    else
        record E9 PASS "pinpoint cannot modify the handler"
    fi

    if runuser -u nagios -- test -x "$HANDLER"; then
        record E10 PASS "nagios can run the handler"
    else
        record E10 FAIL "nagios cannot run the handler"
    fi
else
    record E8 SKIP "handler not installed (the deployed PinPoint has no server/scripts/pinpoint_event_handler.py)"
fi

if grep -Eq '^[[:space:]]*enable_event_handlers[[:space:]]*=[[:space:]]*0' "$NAGIOS_CFG"; then
    record E11 FAIL "enable_event_handlers=0"
else
    record E11 PASS "event handlers are not disabled"
fi

# Stock Nagios sets this to `~$&|'"<>. It is "left at the default" when the
# line is absent or still has that value.
MACRO_LINE="$(grep -E '^[[:space:]]*illegal_macro_output_chars' "$NAGIOS_CFG" | head -n 1)"
MACRO_DEFAULT="illegal_macro_output_chars=\`~\$&|'\"<>"

if [ -z "$MACRO_LINE" ] || [ "$MACRO_LINE" = "$MACRO_DEFAULT" ]; then
    record E12 PASS "illegal_macro_output_chars left at the default"
else
    record E12 FAIL "illegal_macro_output_chars is overridden: $MACRO_LINE"
fi

# Running the module again must keep owners and modes.
if bash /root/pinpoint/configure-event-handler.sh > /dev/null 2>&1; then
    expect_stat E13 "$SPOOL" "nagios:pinpoint 2770"
else
    record E13 FAIL "configure-event-handler.sh failed on a second run (expects /root/pinpoint/)"
fi

echo
echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP" | tee -a "$OUT"

[ "$FAIL" -eq 0 ]
