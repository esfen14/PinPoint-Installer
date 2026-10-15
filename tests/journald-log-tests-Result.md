# Journald limit and log rotation: test result

Not run yet. Run `sudo ./tests/journald-log-tests.sh` on the VM lab after a fresh install and after an
upgrade, then paste the output and fill in the table.

| Case | Check | Fresh | Upgrade |
|---|---|---|---|
| J1 | Drop-in has `SystemMaxUse=200M` and `MaxRetentionSec=30day` | | |
| J2 | Drop-in is `root:root 644` | | |
| J3 | journald active, `journalctl --disk-usage` works | | |
| J4 | `/etc/logrotate.d/pinpoint` passes `logrotate -d` | | |
| J5 | Rule covers `/var/log/pinpoint-*.log` | | |
| J6 | Second run succeeds | | |
| J7 | Edited journald drop-in is kept | | |
| J8 | Edited logrotate rule is kept | | |
| J9 | Forced rotation works, log file stays in place | | |

Also check by hand: after heavy logging, `journalctl --disk-usage` stays at or under 200M.
