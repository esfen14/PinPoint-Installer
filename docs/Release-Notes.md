# Release notes

## Unreleased

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
