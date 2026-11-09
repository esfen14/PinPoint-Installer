#!/bin/bash

##################################################
# PinPoint Installer Test Runner
# Module : firstboot-run-once-tests.sh
# Purpose: Check that the first-boot installer runs
#          only once: the unit's run-once condition,
#          the marker written by pinpoint-firstboot.sh,
#          and setup/fix-firstboot-run-once.sh for
#          appliances installed before the fix.
#
# Usage: bash tests/firstboot-run-once-tests.sh
#
# Runs on any machine with bash. systemctl is a stub;
# the fix script writes into a temporary folder.
# The real reboot check (VM) is listed at the end.
# Output: one line per case, "ID|STATUS|note", then a
# summary.
##################################################

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UNIT="$REPO/firstboot/pinpoint-firstboot.service"
FIRSTBOOT="$REPO/firstboot/pinpoint-firstboot.sh"
FIX="$REPO/setup/fix-firstboot-run-once.sh"
MARKER_PATH="/var/lib/pinpoint/firstboot-done"

PASS=0
FAIL=0

SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT
export SB

chk() {
    local ID="$1" NOTE="$2"
    shift 2
    if "$@" >> "$SB/case.log" 2>&1; then
        echo "$ID|PASS|$NOTE"
        PASS=$((PASS + 1))
    else
        echo "$ID|FAIL|$NOTE"
        FAIL=$((FAIL + 1))
    fi
}

# systemctl stub: records calls; "cat" prints the unit
# and the drop-in, as systemd would.
mkdir -p "$SB/bin"
cat > "$SB/bin/systemctl" <<'EOF'
#!/bin/bash
echo "$*" >> "$SB/systemctl.calls"
if [ "$1" = "cat" ]; then
    cat "$SB/unit"
    cat "$SB/dropin/run-once.conf" 2> /dev/null
fi
exit 0
EOF
chmod +x "$SB/bin/systemctl"

# Fresh fake appliance for each fix case.
reset_box() {
    rm -rf "$SB/box" "$SB/dropin" "$SB/systemctl.calls" "$SB/fix.log"
    mkdir -p "$SB/box"
    # An appliance installed before the fix has the old unit.
    grep -v '^ConditionPathExists=' "$UNIT" > "$SB/unit"
}

run_fix() {
    PATH="$SB/bin:$PATH" \
    PINPOINT_FIX_TEST="$SB" \
    PINPOINT_FIRSTBOOT_MARKER="$SB/box/firstboot-done" \
    PINPOINT_FIRSTBOOT_LOG="$SB/box/firstboot.log" \
    PINPOINT_FIRSTBOOT_DROPIN_DIR="$SB/dropin" \
        bash "$FIX" > "$SB/fix.out" 2>&1
}

##################################################
# New installs: unit and first-boot script
##################################################

unit_has_condition() {
    # In the [Unit] section, before [Service].
    awk '/^\[Service\]/{exit} /^ConditionPathExists=!\/var\/lib\/pinpoint\/firstboot-done$/{f=1} END{exit !f}' "$UNIT"
}
chk U1 "unit skips itself once $MARKER_PATH exists ([Unit] section)" unit_has_condition

marker_order() {
    local LAST DONE TOUCH DISABLE
    LAST="$(grep -n 'configure-journald-logs.sh$' "$FIRSTBOOT" | tail -1 | cut -d: -f1)"
    DONE="$(grep -n 'completed successfully' "$FIRSTBOOT" | cut -d: -f1)"
    TOUCH="$(grep -n "touch $MARKER_PATH\$" "$FIRSTBOOT" | cut -d: -f1)"
    DISABLE="$(grep -n 'systemctl disable pinpoint-firstboot.service' "$FIRSTBOOT" | cut -d: -f1)"
    [ -n "$LAST" ] && [ -n "$DONE" ] && [ -n "$TOUCH" ] && [ -n "$DISABLE" ] \
        && [ "$LAST" -lt "$DONE" ] && [ "$DONE" -lt "$TOUCH" ] && [ "$TOUCH" -lt "$DISABLE" ]
}
chk U2 "first boot writes the marker after the last module, before disabling itself" marker_order

marker_once() {
    [ "$(grep -c "touch $MARKER_PATH\$" "$FIRSTBOOT")" -eq 1 ] && grep -q '^set -e$' "$FIRSTBOOT"
}
chk U3 "marker written once, and set -e means a failed module never reaches it" marker_once

chk U4 "fix script and first boot use the same marker path" \
    grep -q "PINPOINT_FIRSTBOOT_MARKER:-$MARKER_PATH}" "$FIX"

chk U5 "all three files are LF only" \
    bash -c "! grep -l \$'\\r' '$UNIT' '$FIRSTBOOT' '$FIX'"

chk U6 "first boot and fix script pass bash -n" \
    bash -c "bash -n '$FIRSTBOOT' && bash -n '$FIX'"

##################################################
# Existing appliances: fix-firstboot-run-once.sh
##################################################

# F1: first install never completed. Nothing may change.
reset_box
printf 'Starting PinPoint installation...\n[2/9] Installing Nagios Core...\n' > "$SB/box/firstboot.log"
run_fix
RC=$?
f1() { [ "$RC" -eq 1 ] && [ ! -e "$SB/box/firstboot-done" ] && [ ! -e "$SB/dropin" ] \
    && [ ! -e "$SB/systemctl.calls" ] && grep -q 'Nothing was changed' "$SB/fix.out"; }
chk F1 "incomplete first install: exit 1, no marker, no drop-in, systemd untouched" f1

# F2: no first-boot log at all.
reset_box
run_fix
RC=$?
f2() { [ "$RC" -eq 1 ] && [ ! -e "$SB/box/firstboot-done" ] && [ ! -e "$SB/dropin" ]; }
chk F2 "missing first-boot log: exit 1, nothing changed" f2

# F3: completed install (the line appears twice, as on an
# appliance that already rebooted once).
reset_box
printf 'PinPoint installation completed successfully.\nDone.\nPinPoint installation completed successfully.\n' > "$SB/box/firstboot.log"
run_fix
RC=$?
f3() { [ "$RC" -eq 0 ] && [ -f "$SB/box/firstboot-done" ] \
    && grep -qxF "ConditionPathExists=!$SB/box/firstboot-done" "$SB/dropin/run-once.conf" \
    && grep -qx 'daemon-reload' "$SB/systemctl.calls"; }
chk F3 "completed install: marker, drop-in with the condition, daemon-reload" f3

f3b() { [ "$(stat -c %a "$SB/box/firstboot-done")" = 644 ] && [ "$(stat -c %a "$SB/dropin/run-once.conf")" = 644 ] \
    && [ ! -e "$SB/dropin/run-once.conf.tmp" ]; }
chk F4 "marker and drop-in are 644; no temporary file left" f3b

# F5: run again: same result, file unchanged.
BEFORE="$(stat -c %Y "$SB/dropin/run-once.conf")$(md5sum < "$SB/dropin/run-once.conf")"
sleep 1
run_fix
RC=$?
f5() { [ "$RC" -eq 0 ] && grep -q 'already present' "$SB/fix.out" && grep -q 'already up to date' "$SB/fix.out" \
    && [ "$BEFORE" = "$(stat -c %Y "$SB/dropin/run-once.conf")$(md5sum < "$SB/dropin/run-once.conf")" ]; }
chk F5 "second run: exit 0, drop-in not rewritten" f5

# F6: marker already there (new install), log gone: drop-in
# is still added and the run succeeds.
reset_box
touch "$SB/box/firstboot-done"
run_fix
RC=$?
f6() { [ "$RC" -eq 0 ] && [ -f "$SB/dropin/run-once.conf" ]; }
chk F6 "marker present without a log: exit 0, drop-in added" f6

# F7: an edited drop-in is put back to the managed text.
printf '[Unit]\nConditionPathExists=/tmp/other\n' > "$SB/dropin/run-once.conf"
run_fix
RC=$?
f7() { [ "$RC" -eq 0 ] && grep -qxF "ConditionPathExists=!$SB/box/firstboot-done" "$SB/dropin/run-once.conf" \
    && ! grep -q '/tmp/other' "$SB/dropin/run-once.conf"; }
chk F7 "a changed drop-in is restored" f7

echo
echo "Summary: $PASS passed, $FAIL failed"
echo
echo "VM check (manual): on an installed appliance run"
echo "  sudo bash /root/pinpoint/fix-firstboot-run-once.sh"
echo "then reboot and confirm: systemctl show -p ConditionResult pinpoint-firstboot.service"
echo "says 'no', and /var/log/pinpoint-firstboot.log has no new 'Starting PinPoint installation'."

[ "$FAIL" -eq 0 ]
