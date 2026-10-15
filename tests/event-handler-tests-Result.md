# Event spool and handler: test result

Not run yet. Run `sudo ./tests/event-handler-tests.sh` on the VM lab after a fresh install and again
after an upgrade, then paste the output and fill in the table.

| Case | Check | Fresh | Upgrade |
|---|---|---|---|
| E1 | Spool is `nagios:pinpoint 2770` | | |
| E2 | Spool parent is `root:root 755` | | |
| E3 | `pinpoint` is in group `pinpoint` | | |
| E4 | `nagios` can write to the spool | | |
| E5 | New entries get group `pinpoint` | | |
| E6 | `pinpoint` can read and delete entries | | |
| E7 | Other accounts cannot list the spool | | |
| E8 | Handler is `root:root 755` (SKIP if the app has no handler) | | |
| E9 | `pinpoint` cannot modify the handler | | |
| E10 | `nagios` can run the handler | | |
| E11 | `enable_event_handlers` not 0 | | |
| E12 | `illegal_macro_output_chars` not overridden | | |
| E13 | Second run keeps owners and modes | | |
