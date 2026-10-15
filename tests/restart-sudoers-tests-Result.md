# Restart sudoers rule: test result

Not run yet. Run `sudo ./tests/restart-sudoers-tests.sh` on the VM lab after installing from
`feat/sudoers-restart-nagios`, then paste the output and fill in the table.

| Case | Check | Status |
|---|---|---|
| R1 | `sudo -n /usr/bin/systemctl restart nagios` works as `pinpoint` | |
| R2 | `restart sshd` is refused | |
| R3 | `restart nagios extra` is refused | |
| R4 | `stop` and `start` are refused | |
| R5 | `sudo -n -l` shows no wildcard or shell | |
| R6 | `/etc/sudoers.d/pinpoint-restart` is `root:root 440` | |
| R7 | `visudo -c` parses every file | |
| R8 | Reload and SMTP helper rules unchanged | |

Upgrade check (manual): re-run the installer on a VM that already has the drop-in; the file is
replaced and a deliberately broken generated rule keeps the previous file and stops the install.
