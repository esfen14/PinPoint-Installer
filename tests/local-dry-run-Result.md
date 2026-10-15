# Local dry-run: test result

Result of checking the new installer changes on the author's Windows machine before the VM round.
There is no Linux VM, WSL or Docker there, so this is **not** an install test. Nothing here replaces the
VM runners (`restart-sudoers-tests.sh`, `event-handler-tests.sh`, `journald-log-tests.sh`).

## Summary

| Part | Result |
|---|---|
| Syntax (`bash -n`) of every changed script, on `main` and both feature branches | **PASS** |
| `shellcheck` (warnings and above) on the changed and new scripts | **PASS**, 0 findings. One older finding in `check-interval-tests.sh`, not from this work |
| Line endings in the repository (blobs) | **PASS**, all LF (`.gitattributes` enforces it) |
| Sandbox dry-run, `tests/sandbox-dry-run.sh` | **PASS 31, FAIL 0** |
| Extra-rights filter in `check-interval-tests.sh` case 2.3 | **PASS**, clean list gives no extras; `restart sshd`, `stop nagios` and `/bin/bash` are all reported |

## Environment

| Item | Value |
|---|---|
| Date | 2026-10-15 |
| Host | Windows 11, Git Bash, shellcheck from `shellcheck-py` |
| Code tested | `main` (restart rule merged), `feat/event-spool-handler` (`cbfa075`), `feat/journald-log-limits` (`06ecc97` plus the logrotate directory fix) |

## Sandbox dry-run

Each module is run in a temporary folder with stub commands. The stubs record what they were asked
to do, so the arguments (`-m 2770`, `-o nagios -g pinpoint`) are checked, but no real owner, mode or
permission exists.

| ID | Check | Result |
|---|---|---|
| A0 | Restart block found in `configure-pinpoint-privileges.sh` on `main` | PASS |
| A1 | One exact rule, `pinpoint ALL=(root) NOPASSWD: /usr/bin/systemctl restart nagios` | PASS |
| A2 | No wildcard, no comma-joined commands | PASS |
| A3 | Installed with `-m 440 -o root -g root` | PASS |
| A4 | Two units give two separate lines | PASS |
| A5 | Failed validation stops the install and keeps the previous file | PASS |
| A6 | Failure prints "Generated restart sudoers rule is invalid." | PASS |
| B1 | Journald module: fresh run exits 0 | PASS |
| B2 | Drop-in has `SystemMaxUse=200M`, `MaxRetentionSec=30day` | PASS |
| B3 | Drop-in starts with the managed marker | PASS |
| B4 | Logrotate rule: weekly, 8 kept, `copytruncate` | PASS |
| B5 | journald restarted once on first write | PASS |
| B6 | Second run exits 0 and does not restart journald again | PASS |
| B7 | Administrator-edited journald drop-in is kept | PASS |
| B8 | Administrator-edited logrotate rule is kept | PASS |
| B9 | Script says it left edited files unchanged | PASS |
| B10 | Managed drop-in with stale values is restored | PASS |
| B11 | Invalid logrotate rule stops the install and installs nothing | PASS |
| C1 | Event module: exits 0 when the app has no handler | PASS |
| C2 | Warns that the app has no handler | PASS |
| C3 | Spool folder created | PASS |
| C4 | Spool created with `-m 2770 -o nagios -g pinpoint` | PASS |
| C5 | Spool parent created `root:root` `755` | PASS |
| C6 | `pinpoint` added to group `pinpoint` | PASS |
| C7 | No handler installed when the app has none | PASS |
| C8 | Handler copied from the app | PASS |
| C9 | Handler installed with `-m 755 -o root -g root` | PASS |
| C10 | Probe file removed from the spool | PASS |
| C11 | Second run exits 0 | PASS |
| C12 | Handler without an interpreter line is refused | PASS |
| C13 | `enable_event_handlers=0` is warned about and left unchanged | PASS |

## Found and fixed during this run

The first run failed B1, B4, B6, B7 and B8: `/etc/logrotate.d` did not exist in the sandbox. On Ubuntu the
`logrotate` package creates it, but the module should not depend on that, so it now creates the folder
(commit "Create /etc/logrotate.d when it is missing" on `feat/journald-log-limits`). All 31 cases pass
after the fix.

## Not tested here (needs the VM)

- Real owners and modes: spool `nagios:pinpoint 2770`, handler `root:root 755`, sudoers file `root:root 440`.
- `visudo -cf` on the real generated file, and `sudo -n -l` as `pinpoint`: restart nagios allowed,
  `restart sshd`, `restart nagios extra`, `stop` and `start` refused, no wildcard or shell.
- The installer's own verify step ([9/9]) with the new restart checks.
- `nagios` writing to the spool, `pinpoint` reading and deleting entries, the web user unable to modify
  the handler, a real Nagios event firing the handler.
- journald actually applying the limit, `journalctl --disk-usage`, a forced `logrotate -f`.
- `runuser ... test -w` is stubbed to "not writable" in the sandbox, so case E9 / the handler
  write-protection check is only proved on the VM.
- Fresh ISO install and upgrade of an existing appliance. The three feature branches also conflict when
  merged together (`firstboot/pinpoint-firstboot.sh`, `setup/pinpoint-setup.sh`, `docs/Release-Notes.md`);
  the step numbering must be fixed once when they are merged.
- Whether the deployed PinPoint contains `server/scripts/pinpoint_event_handler.py` and
  `RESTARTABLE_UNITS = ["nagios"]`.
