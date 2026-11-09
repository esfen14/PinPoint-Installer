# Release notes

## Unreleased

- Fix: the first-boot installer no longer runs again at every reboot. `getty-tty1.conf` makes
  `getty@tty1` want `pinpoint-firstboot.service`, so the `systemctl disable` at the end of the first
  boot did not stop it, and every reboot reinstalled packages, rebuilt Nagios, redeployed the web
  app and restarted Nagios. `pinpoint-firstboot.sh` now writes `/var/lib/pinpoint/firstboot-done`
  after the last module succeeds, and the unit has `ConditionPathExists=!/var/lib/pinpoint/firstboot-done`.
  A failed install writes no marker and is still retried at the next boot. **Appliances installed
  before this fix** need it once: `sudo bash /root/pinpoint/fix-firstboot-run-once.sh` (copy it from
  `setup/` first on an older ISO). It writes the marker only if `/var/log/pinpoint-firstboot.log`
  shows a completed install, adds the drop-in
  `/etc/systemd/system/pinpoint-firstboot.service.d/run-once.conf`, and reloads systemd. Safe to run
  again; no reboot needed. Tests: `tests/firstboot-run-once-tests.sh` (any machine); checked on a VM
  by rebooting after the fix (`ConditionResult=no`, no new run in the first-boot log).

- PinPoint can now restart `nagios` automatically (proactive resolution, `restart_local_service`).
  The installer adds `/etc/sudoers.d/pinpoint-restart` (`root:root`, `0440`) with one rule:
  `pinpoint ALL=(root) NOPASSWD: /usr/bin/systemctl restart nagios`. No other unit, no wildcards, no
  shell. The existing reload and SMTP helper rules are unchanged. The rule is validated with
  `visudo -cf` before it is moved into place; if validation fails, the previous rule is kept and the
  install stops with an error. The unit list (`RESTARTABLE_UNITS`) must match
  `server/app/remediation_actions.py`.

- New installer module `configure-event-handler.sh`: creates the event spool folder
  `/usr/local/nagios/var/spool/pinpoint-events` (`nagios:pinpoint`, `2770`) and installs the event
  handler as `/usr/local/sbin/pinpoint-event-handler` (`root:root`, `755`) from the deployed
  PinPoint (`server/scripts/pinpoint_event_handler.py`). Safe to run again on an existing
  appliance. If the deployed PinPoint has no handler, only the spool is created and a warning is logged.

- New installer module `configure-journald-logs.sh`: limits the systemd journal to 200M and 30 days
  (`/etc/systemd/journald.conf.d/pinpoint.conf`) and rotates `/var/log/pinpoint-*.log` weekly, 8 kept
  (`/etc/logrotate.d/pinpoint`). A file an administrator edited (its first line no longer reads
  "Managed by PinPoint Installer.") is never overwritten.
