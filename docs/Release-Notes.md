# Release notes

## Unreleased

- PinPoint can now restart `nagios` automatically (proactive resolution, `restart_local_service`).
  The installer adds `/etc/sudoers.d/pinpoint-restart` (`root:root`, `0440`) with one rule:
  `pinpoint ALL=(root) NOPASSWD: /usr/bin/systemctl restart nagios`. No other unit, no wildcards, no
  shell. The existing reload and SMTP helper rules are unchanged. The rule is validated with
  `visudo -cf` before it is moved into place; if validation fails, the previous rule is kept and the
  install stops with an error. The unit list (`RESTARTABLE_UNITS`) must match
  `server/app/remediation_actions.py`.
