#!/bin/bash

##################################################
# PinPoint Installer Test Runner
# Module : update-approval-tests.sh
# Purpose: Phase 3 of the update plan on a real
#          appliance: roles through real sudo and
#          groups, the compatibility gate, approvals,
#          cancel, revocation, refused manifests and
#          the audit chain with its log and journal
#          copies. Nothing in Nagios is changed.
#
# Usage: sudo ./update-approval-tests.sh
#
# Expects the module scripts in /root/pinpoint/
# (or PINPOINT_MODULE_DIR). Creates the users
# pp-test-admin, pp-test-viewer and pp-test-nobody and
# test manifests pp-mon-t<timestamp>-*, and removes them
# at the end. Their rows stay in the update database, so
# run it only on a VM you can restore from a snapshot.
# Output: one line per case, "ID|STATUS|note", then a
# summary. Also written to /root/update-approval-output.txt
##################################################

set -u

OUT="/root/update-approval-output.txt"
DIR="${PINPOINT_MODULE_DIR:-/root/pinpoint}"
PROGRAM="/usr/local/sbin/pinpoint-update"
EXEC="/usr/local/sbin/pinpoint-update-exec"
DB="/var/lib/pinpoint/updates/updates.db"
MANIFESTS="/etc/pinpoint/updates/manifests"
BASELINE="$MANIFESTS/pp-mon-baseline-1.json"
SUDOERS_FILE="/etc/sudoers.d/pinpoint-update"
ADMINS="pinpoint-update-admins"
VIEWERS="pinpoint-update-viewers"
UPDATE_LOG="/var/log/pinpoint-update.log"
# Unique per run: recorded manifests stay in the database.
T="pp-mon-t$(date +%y%m%d%H%M%S)"

PASS=0
FAIL=0

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Run as root."
    exit 1
fi

record() {
    printf '%s|%s|%s\n' "$1" "$2" "$3" | tee -a "$OUT"

    case "$2" in
        PASS) PASS=$((PASS + 1)) ;;
        FAIL) FAIL=$((FAIL + 1)) ;;
    esac
}

# check ID NOTE COMMAND...: PASS if the command succeeds.
check() {
    local ID="$1" NOTE="$2"
    shift 2
    if "$@" > /dev/null 2>&1; then
        record "$ID" PASS "$NOTE"
    else
        record "$ID" FAIL "$NOTE"
    fi
}

# expect ID NOTE CODE USER ARGS...: PASS if USER running
# "sudo pinpoint-update ARGS" exits with CODE.
expect() {
    local ID="$1" NOTE="$2" WANT="$3" AS="$4" GOT
    shift 4
    sudo -u "$AS" -- sudo -n "$PROGRAM" "$@" > /root/update-approval-last.txt 2>&1
    GOT=$?
    if [ "$GOT" = "$WANT" ]; then
        record "$ID" PASS "$NOTE (exit $GOT)"
    else
        record "$ID" FAIL "$NOTE: exit $GOT, expected $WANT: $(tail -1 /root/update-approval-last.txt)"
    fi
}

# SQL against the update database (no sqlite3 CLI needed).
sql() {
    python3 -I -c 'import sqlite3, sys
con = sqlite3.connect("file:" + sys.argv[1] + "?mode=ro", uri=True)
for row in con.execute(sys.argv[2]):
    print("|".join("" if v is None else str(v) for v in row))' "$DB" "$1"
}

# make_manifest ID STATE: a copy of the baseline that upgrades from it.
make_manifest() {
    python3 -I - "$BASELINE" "$MANIFESTS/$1.json" "$1" "$2" <<'EOF'
import json, sys

source, target, manifest_id, state = sys.argv[1:5]
with open(source, encoding="utf-8") as f:
    body = json.load(f)
body["manifest_id"] = manifest_id
body["upgrade_from"] = ["pp-mon-baseline-1"]
body["compatibility"] = {"state": state, "evidence_ids": ["ev-vm-test"], "known_limitations": []}
body["components"]["nagios-core"]["version"] = "4.5.11-test"
with open(target, "w", encoding="utf-8") as f:
    json.dump(body, f, indent=2)
EOF
    chown root:root "$MANIFESTS/$1.json"
    chmod 644 "$MANIFESTS/$1.json"
}

cleanup() {
    for TXN in $(sql "SELECT txn_id FROM txn WHERE state = 'approved' AND target_manifest_id LIKE 'pp-mon-t%'"); do
        "$PROGRAM" cancel "$TXN" > /dev/null 2>&1
    done
    rm -f "$MANIFESTS"/pp-mon-t[0-9]*.json "$MANIFESTS/revoked.json"
    for U in pp-test-admin pp-test-viewer pp-test-nobody; do
        id "$U" > /dev/null 2>&1 && userdel "$U" > /dev/null 2>&1
    done
}

: > "$OUT"
cleanup

##################################################
# Install, groups and sudoers
##################################################

if ! bash "$DIR/configure-monitoring-updates.sh" > /root/update-approval-install.txt 2>&1; then
    record A01 FAIL "configure-monitoring-updates.sh failed. See /root/update-approval-install.txt"
    echo "PASS $PASS, FAIL $FAIL" | tee -a "$OUT"
    exit 1
fi
record A01 PASS "configure-monitoring-updates.sh installed the Update Manager"

check A02 "Groups $ADMINS and $VIEWERS exist" getent group "$ADMINS" "$VIEWERS"
check A03 "$SUDOERS_FILE is root:root 440 and valid" \
    bash -c "[ \"\$(stat -c '%U:%G %a' $SUDOERS_FILE)\" = 'root:root 440' ] && visudo -cf $SUDOERS_FILE"

SUDO_MEMBER="$(getent group sudo | cut -d: -f4 | cut -d, -f1)"
if [ -n "$SUDO_MEMBER" ]; then
    check A04 "First sudo member $SUDO_MEMBER is an update admin" \
        bash -c "id -nG $SUDO_MEMBER | tr ' ' '\n' | grep -qx $ADMINS"

    # A later run must not re-add someone university IT removed.
    gpasswd -d "$SUDO_MEMBER" "$ADMINS" > /dev/null 2>&1
    bash "$DIR/configure-monitoring-updates.sh" > /dev/null 2>&1
    check A05 "Running the module again does not re-add a removed admin" \
        bash -c "! id -nG $SUDO_MEMBER | tr ' ' '\n' | grep -qx $ADMINS"
    usermod -aG "$ADMINS" "$SUDO_MEMBER"
else
    record A04 SKIP "The sudo group has no members"
    record A05 SKIP "The sudo group has no members"
fi

useradd -M -s /usr/sbin/nologin -G "$ADMINS" pp-test-admin
useradd -M -s /usr/sbin/nologin -G "$VIEWERS" pp-test-viewer
useradd -M -s /usr/sbin/nologin pp-test-nobody

make_manifest $T-1 verified
make_manifest $T-untested untested

##################################################
# Roles
##################################################

expect A06 "Viewer may list manifests" 0 pp-test-viewer list
expect A07 "Viewer may run the gate" 0 pp-test-viewer validate $T-1
expect A08 "Viewer may not approve" 3 pp-test-viewer approve $T-1 --confirm $T-1
check A09 "The refused approval is audited with the viewer as actor" \
    bash -c "[ -n \"\$(sql \"SELECT seq FROM audit WHERE event = 'auth.refused' AND actor = 'pp-test-viewer'\")\" ]"
check A10 "A user in neither group cannot start the program through sudo" \
    bash -c "! sudo -u pp-test-nobody -- sudo -n $PROGRAM list"
check A11 "No approval was recorded by the refused calls" \
    bash -c "[ -z \"\$(sql \"SELECT approval_id FROM approval WHERE manifest_id LIKE '$T-%'\")\" ]"

##################################################
# Gate and approvals
##################################################

expect A12 "Untested manifest is refused by the program" 4 pp-test-admin approve $T-untested --confirm $T-untested
expect A13 "Confirmation must match" 2 pp-test-admin approve $T-1 --confirm $T-2
expect A14 "Path-like manifest ID is refused" 2 pp-test-admin show ../../etc/shadow
expect A15 "Admin approves $T-1" 0 pp-test-admin approve $T-1 --confirm $T-1

APPROVAL="$(sql "SELECT approver, source_manifest_id, status FROM approval WHERE manifest_id = '$T-1'")"
TXN="$(sql "SELECT txn_id FROM txn WHERE target_manifest_id = '$T-1' AND state = 'approved'")"
if [ "$APPROVAL" = "pp-test-admin|pp-mon-baseline-1|active" ] && [ -n "$TXN" ]; then
    record A16 PASS "Approval bound to approver and source state; transaction $TXN is approved"
else
    record A16 FAIL "Approval row: '$APPROVAL', approved transaction: '$TXN'"
fi

if [ -n "$TXN" ]; then
    # The approved transaction holds the only active slot, so a
    # drill is refused before it stops anything.
    "$EXEC" drill --yes > /root/update-approval-drill.txt 2>&1
    RC=$?
    if [ "$RC" -eq 5 ] && grep -q "pinpoint-update cancel $TXN" /root/update-approval-drill.txt; then
        record A17 PASS "A drill is BUSY while an approved update waits"
    else
        record A17 FAIL "Drill exit $RC: $(tail -1 /root/update-approval-drill.txt)"
    fi
    expect A18 "Viewer may not cancel" 3 pp-test-viewer cancel "$TXN"
    expect A19 "Admin cancels the approved transaction" 0 pp-test-admin cancel "$TXN"
    check A20 "Transaction cancelled and approval revoked" \
        bash -c "[ \"\$(sql \"SELECT t.state, a.status FROM txn t JOIN approval a USING (approval_id) WHERE t.txn_id = '$TXN'\")\" = 'cancelled|revoked' ]"
else
    for ID in A17 A18 A19 A20; do record "$ID" SKIP "No approved transaction"; done
fi

expect A21 "Admin defers with a reason and review date" 0 pp-test-admin defer $T-1 --reason "Exam week" --review-date 2099-01-01
expect A22 "Admin declines with a reason" 0 pp-test-admin decline $T-1 --reason "Waiting for the next release"

##################################################
# Revocation (FI-03)
##################################################

make_manifest $T-3 verified
expect A23 "Admin approves $T-3" 0 pp-test-admin approve $T-3 --confirm $T-3
printf '{"schema_version": 1, "manifest_ids": ["$T-3"]}\n' > "$MANIFESTS/revoked.json"
chmod 644 "$MANIFESTS/revoked.json"
"$PROGRAM" status > /dev/null 2>&1
check A24 "Revoking the manifest revokes the approval and cancels its transaction" \
    bash -c "[ \"\$(sql \"SELECT t.state, a.status FROM txn t JOIN approval a USING (approval_id) WHERE a.manifest_id = '$T-3'\")\" = 'cancelled|revoked' ]"
expect A25 "A revoked manifest cannot be approved again" 4 pp-test-admin approve $T-3 --confirm $T-3

##################################################
# Refused manifests
##################################################

python3 -I -c 'import json, sys
path = sys.argv[1]
body = json.load(open(path))
body["components"]["nagios-core"]["artifact"]["sha256"] = "0" * 64
json.dump(body, open(path, "w"))' "$MANIFESTS/$T-1.json"
"$PROGRAM" list > /root/update-approval-list.txt 2>&1
check A26 "An edited manifest is refused and audited" \
    bash -c "grep -q 'REFUSED $T-1.json: changed after it was recorded' /root/update-approval-list.txt && [ -n \"\$(sql \"SELECT seq FROM audit WHERE event = 'manifest.changed' AND manifest_id = '$T-1'\")\" ]"

make_manifest $T-writable verified
chmod 666 "$MANIFESTS/$T-writable.json"
make_manifest $T-owner verified
chown pp-test-viewer "$MANIFESTS/$T-owner.json"
"$PROGRAM" list > /root/update-approval-list.txt 2>&1
check A27 "A world-writable manifest is refused" \
    grep -q "REFUSED $T-writable.json: not owned by root, or writable by others" /root/update-approval-list.txt
check A28 "A manifest not owned by root is refused" \
    grep -q "REFUSED $T-owner.json: not owned by root, or writable by others" /root/update-approval-list.txt
check A29 "Neither refused manifest was recorded" \
    bash -c "[ -z \"\$(sql \"SELECT manifest_id FROM manifest WHERE manifest_id IN ('$T-writable', '$T-owner')\")\" ]"

##################################################
# Audit chain
##################################################

check A30 "Audit chain intact" "$PROGRAM" audit --verify
LAST_HASH="$(sql "SELECT hash FROM audit ORDER BY seq DESC LIMIT 1")"
check A31 "Newest audit row is copied to $UPDATE_LOG" grep -q "hash=$LAST_HASH" "$UPDATE_LOG"
check A32 "Newest audit row is copied to the journal" \
    bash -c "journalctl -t pinpoint-update --no-pager -n 50 | grep -q 'hash=$LAST_HASH'"
check A33 "status --json prints one pinpoint-update/v1 object" \
    bash -c "$PROGRAM status --json | python3 -I -c 'import json, sys; assert json.load(sys.stdin)[\"schema\"] == \"pinpoint-update/v1\"'"

cleanup
echo "PASS $PASS, FAIL $FAIL" | tee -a "$OUT"
exit "$FAIL"
