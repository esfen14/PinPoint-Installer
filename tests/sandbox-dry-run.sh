#!/bin/bash
##################################################
# PinPoint Installer Test Runner
# Module : sandbox-dry-run.sh
# Purpose: Run the new installer logic against stubbed
#          system commands (install, visudo, runuser,
#          systemctl ...) inside a temporary folder. It
#          works on any machine with bash and git, as a
#          non-root user, and changes nothing outside
#          that folder.
#
# It reads the scripts from git, not from the working
# tree: the restart rule from main, the journald module
# from feat/journald-log-limits and the event handler
# module from feat/event-spool-handler. After those
# branches are merged, change the three "git show"
# refs below to main.
#
# It cannot check real owners, modes, sudo, visudo or
# systemd. Those need the VM runners in this folder.
#
# Usage: ./sandbox-dry-run.sh
# Output: "PASS|ID|note" or "FAIL|ID|note", then a total.
##################################################

REPO="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
HERE="$(mktemp -d)"
trap 'rm -rf "$HERE"' EXIT
P=0; F=0
ok()  { P=$((P+1)); echo "PASS|$1|$2"; }
bad() { F=$((F+1)); echo "FAIL|$1|$2"; }
chk() { if eval "$2"; then ok "$1" "$3"; else bad "$1" "$3"; fi; }

new_sandbox() {
  SB="$HERE/sb$1"; rm -rf "$SB"; mkdir -p "$SB/bin" "$SB/calls"; : > "$SB/calls/log"
  S="$SB/bin"
  for c in id usermod chown chmod apt-get getent journalctl logrotate systemctl visudo; do
    printf '#!/bin/bash\necho "%s $*" >> "%s/calls/log"\nexit 0\n' "$c" "$SB" > "$S/$c"
  done
  cat > "$S/install" <<EOF
#!/bin/bash
echo "install \$*" >> "$SB/calls/log"
D=0; A=()
while [ \$# -gt 0 ]; do case "\$1" in -d) D=1;; -m|-o|-g) shift;; *) A+=("\$1");; esac; shift; done
if [ \$D = 1 ]; then mkdir -p "\${A[@]}"; else cp "\${A[0]}" "\${A[1]}"; fi
EOF
  cat > "$S/runuser" <<EOF
#!/bin/bash
echo "runuser \$*" >> "$SB/calls/log"
shift 3
if [ "\$1" = test ] && [ "\$2" = -w ]; then exit 1; fi
exec "\$@"
EOF
  chmod +x "$S"/*
  export PATH="$S:$ORIGPATH"
}
ORIGPATH="$PATH"

patch_script() { # src dest: retarget absolute paths into the sandbox, drop the root check
  sed -e "s#\"/var/log/#\"$SB/log/#g" -e "s#=\"/etc/#=\"$SB/etc/#g" \
      -e "s#=\"/usr/local/#=\"$SB/usr/local/#g" -e "s#=\"/opt/#=\"$SB/opt/#g" \
      -e 's#\[ "\$EUID" -ne 0 \]#false#' "$1" > "$2"
}

############ A. restart sudoers block (from the merged main script)
echo "## A. restart sudoers rule generation"
new_sandbox A
SRC="$REPO/setup/configure-pinpoint-privileges.sh"
BLOCK="$SB/block.sh"
awk '/^RESTART_SUDOERS_TMP=/{p=1} p{print} /may restart: /{exit}' "$SRC" > "$BLOCK"
chk A0 '[ -s "$BLOCK" ]' "restart block extracted from setup/configure-pinpoint-privileges.sh on main"
run_block() { ( APP_USER=pinpoint; LOG="$SB/log.txt"; RESTART_SUDOERS_FILE="$SB/pinpoint-restart"
  fail() { echo "FAILED: $1" >> "$LOG"; exit 1; }
  eval "$1"; . "$BLOCK" ) > /dev/null; }
cat > "$SB/bin/visudo" <<'EOF'
#!/bin/bash
f="$2"; [ "$1" = -cf ] || exit 2
grep -vE '^(#|$)' "$f" | grep -qvE '^pinpoint ALL=\(root\) NOPASSWD: /usr/bin/systemctl restart [a-z0-9@._-]+$' && exit 1
exit 0
EOF
run_block 'RESTARTABLE_UNITS=(nagios)'
chk A1 '[ "$(grep -vE "^(#|$)" "$SB/pinpoint-restart")" = "pinpoint ALL=(root) NOPASSWD: /usr/bin/systemctl restart nagios" ]' "one exact rule for nagios"
chk A2 '! grep -vE "^#" "$SB/pinpoint-restart" | grep -qE "\*|, "' "no wildcard, no comma-joined commands"
chk A3 'grep -q "install -m 440 -o root -g root" "$SB/calls/log"' "installed with -m 440 -o root -g root"
run_block 'RESTARTABLE_UNITS=(nagios snmpd)'
chk A4 '[ "$(grep -cvE "^(#|$)" "$SB/pinpoint-restart")" = 2 ]' "two units give two separate lines"
cp "$SB/pinpoint-restart" "$SB/before"
printf '#!/bin/bash\nexit 1\n' > "$SB/bin/visudo"
run_block 'RESTARTABLE_UNITS=(nagios)'; RC=$?
chk A5 '[ "$RC" != 0 ] && cmp -s "$SB/pinpoint-restart" "$SB/before"' "failed validation stops (exit $RC) and keeps the previous file"
chk A6 'grep -q "FAILED: Generated restart sudoers rule is invalid." "$SB/log.txt"' "failure message is the one the installer prints"

############ B. journald and logrotate module
echo "## B. configure-journald-logs.sh"
new_sandbox B
mkdir -p "$SB/log" "$SB/etc"
git -C "$REPO" show feat/journald-log-limits:setup/configure-journald-logs.sh > "$SB/orig.sh"
patch_script "$SB/orig.sh" "$SB/mod.sh"
cat > "$SB/bin/logrotate" <<'EOF'
#!/bin/bash
[ "$1" = -d ] && grep -q '^/var/log/pinpoint-\*\.log {' "$2" && grep -q '^}' "$2"
EOF
bash "$SB/mod.sh" > "$SB/out1.txt" 2>&1; RC=$?
chk B1 '[ $RC = 0 ]' "fresh run exits 0"
D="$SB/etc/systemd/journald.conf.d/pinpoint.conf"; L="$SB/etc/logrotate.d/pinpoint"
chk B2 'grep -qx "SystemMaxUse=200M" "$D" && grep -qx "MaxRetentionSec=30day" "$D"' "drop-in has 200M / 30day"
chk B3 'head -n1 "$D" | grep -qxF "# Managed by PinPoint Installer."' "drop-in starts with the managed marker"
chk B4 'grep -q "weekly" "$L" && grep -q "rotate 8" "$L" && grep -q copytruncate "$L"' "logrotate rule: weekly, 8, copytruncate"
chk B5 '[ "$(grep -c "systemctl restart systemd-journald" "$SB/calls/log")" = 1 ]' "journald restarted once on first write"
bash "$SB/mod.sh" > "$SB/out2.txt" 2>&1; RC=$?
chk B6 '[ $RC = 0 ] && [ "$(grep -c "systemctl restart systemd-journald" "$SB/calls/log")" = 1 ]' "second run exits 0, no second journald restart"
printf '[Journal]\nSystemMaxUse=50M\n' > "$D"; printf '/var/log/pinpoint-*.log {\n    daily\n}\n' > "$L"
bash "$SB/mod.sh" > "$SB/out3.txt" 2>&1; RC=$?
chk B7 '[ $RC = 0 ] && grep -qx "SystemMaxUse=50M" "$D"' "administrator's journald drop-in kept"
chk B8 'grep -qx "    daily" "$L"' "administrator's logrotate rule kept"
chk B9 'grep -q "left unchanged" "$SB/out3.txt"' "script says it left the edited files alone"
rm -f "$D"; bash "$SB/mod.sh" >/dev/null 2>&1; sed -i 's/200M/999M/' "$D"
bash "$SB/mod.sh" >/dev/null 2>&1
chk B10 'grep -qx "SystemMaxUse=200M" "$D"' "managed drop-in with stale values is restored"
printf '#!/bin/bash\nexit 1\n' > "$SB/bin/logrotate"
rm -f "$L"; bash "$SB/mod.sh" >/dev/null 2>&1; RC=$?
chk B11 '[ $RC != 0 ] && [ ! -e "$L" ]' "invalid logrotate rule stops the install and installs nothing (exit $RC)"

############ C. event spool and handler module
echo "## C. configure-event-handler.sh"
new_sandbox C
APPSCRIPTS="$SB/opt/pinpoint/Network-Diagnosis-System/server/scripts"
mkdir -p "$SB/log" "$SB/usr/local/nagios/etc" "$APPSCRIPTS" "$SB/usr/local/sbin"
echo "log_file=x" > "$SB/usr/local/nagios/etc/nagios.cfg"
git -C "$REPO" show feat/event-spool-handler:setup/configure-event-handler.sh > "$SB/orig.sh"
patch_script "$SB/orig.sh" "$SB/mod.sh"
bash "$SB/mod.sh" > "$SB/out1.txt" 2>&1; RC=$?
chk C1 '[ $RC = 0 ]' "run without a handler in the app exits 0"
chk C2 'grep -q "WARNING: .* has no event handler" "$SB/out1.txt"' "warns that the app has no handler"
chk C3 '[ -d "$SB/usr/local/nagios/var/spool/pinpoint-events" ]' "spool folder created"
chk C4 'grep -q "install -d -m 2770 -o nagios -g pinpoint" "$SB/calls/log"' "spool created with mode 2770, nagios:pinpoint"
chk C5 'grep -q "install -d -m 755 -o root -g root" "$SB/calls/log"' "spool parent created root:root 755"
chk C6 'grep -q "usermod -aG pinpoint pinpoint" "$SB/calls/log"' "pinpoint added to group pinpoint"
chk C7 '[ ! -e "$SB/usr/local/sbin/pinpoint-event-handler" ]' "no handler installed when the app has none"
printf '#!/usr/bin/env python3\nprint("hi")\n' > "$APPSCRIPTS/pinpoint_event_handler.py"
bash "$SB/mod.sh" > "$SB/out2.txt" 2>&1; RC=$?
chk C8 '[ $RC = 0 ] && cmp -s "$SB/usr/local/sbin/pinpoint-event-handler" "$APPSCRIPTS/pinpoint_event_handler.py"' "handler copied from the app"
chk C9 'grep -q "install -m 755 -o root -g root" "$SB/calls/log"' "handler installed root:root 755"
chk C10 '[ -z "$(ls -A "$SB/usr/local/nagios/var/spool/pinpoint-events")" ]' "probe file removed from the spool"
bash "$SB/mod.sh" > "$SB/out3.txt" 2>&1; RC=$?
chk C11 '[ $RC = 0 ]' "second run exits 0"
printf 'print("no shebang")\n' > "$APPSCRIPTS/pinpoint_event_handler.py"
bash "$SB/mod.sh" > "$SB/out4.txt" 2>&1; RC=$?
chk C12 '[ $RC != 0 ] && grep -q "interpreter line" "$SB/out4.txt"' "handler without an interpreter line is refused (exit $RC)"
printf '#!/usr/bin/env python3\n' > "$APPSCRIPTS/pinpoint_event_handler.py"
echo "enable_event_handlers=0" >> "$SB/usr/local/nagios/etc/nagios.cfg"
bash "$SB/mod.sh" > "$SB/out5.txt" 2>&1; RC=$?
chk C13 '[ $RC = 0 ] && grep -q "enable_event_handlers=0" "$SB/out5.txt" && grep -qx "enable_event_handlers=0" "$SB/usr/local/nagios/etc/nagios.cfg"' "enable_event_handlers=0 is warned about, not changed"

echo; echo "TOTAL PASS=$P FAIL=$F"
