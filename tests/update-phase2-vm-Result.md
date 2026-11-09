# update-phase2-vm-Result

Result of testing plan Phase 2 (recovery foundation: recovery point, restore, reconcile, health suite,
restore drill) on a VM. Plan: `docs/University-Maintenance-and-Updates-Plan.md` §16 (exit gate:
staging restore drill passes FI-06 to FI-11). The VM runner is `tests/update-recovery-tests.sh`.
Every case is marked PASS, FAIL or SKIP with the reason; nothing is marked as passed unless it was run.

## Summary

| Part | Result |
|---|---|
| Portable tests on the VM | **PASS 55, FAIL 0** (`test_pinpoint_update_exec.py` 22; Phase 1 regression: `baseline-artifacts-tests.sh` 14, `login-hook-tests.sh` 7, `test_pinpoint_update.py` 12) |
| VM runner, main cases (first run) | **PASS 22, FAIL 3** (R18, R18a, R19: caused by the runner, see Finding 2) |
| R18, R18a, R19, R19a rerun with the lock free | **PASS 4, FAIL 0** |
| FI-10 reboot, first attempt | **PASS 4, FAIL 2** (R21, R24: caused by first boot running again, see Finding 1) |
| FI-10 reboot, second attempt (first boot held back) | **PASS 7, FAIL 0** (R20 to R26) |
| Phase 2 exit gate (FI-06 to FI-11 on staging) | **Met for the Phase 2 code.** Finding 1 must be fixed before FI-10 can pass on a real appliance |
| Findings | 1 installer bug (high), 1 runner bug, 1 unit exit-code issue |

## Environment

| Item | Value |
|---|---|
| Date (UTC) | 2026-11-09 |
| Host | `user-1`, disposable Proxmox VM over Tailscale; snapshot taken by the user after Phase 1 |
| OS | Ubuntu 22.04.5 LTS |
| Starting state | End of the Phase 1 test (`tests/update-phase1-vm-Result.md`) |
| Code under test | `feat/update-validation-approval` at `a1064c2`, copied to `/root/pinpoint-phase2/` in the `scripts/build.sh` layout; runner run with `PINPOINT_MODULE_DIR=/root/pinpoint-phase2` |
| Tester | Claude Code, over SSH |

## 1. VM runner, main cases

`sudo PINPOINT_MODULE_DIR=/root/pinpoint-phase2 ./update-recovery-tests.sh`

```
R01|PASS|configure-monitoring-updates.sh installed the executor and health suite
R02|PASS|pinpoint-update-exec is root:root 755
R03|PASS|Recovery point folder is root:root 700 on the Nagios filesystem
R04|PASS|Both reconcile services are enabled
R05|PASS|Reconcile with nothing to do exits 0
R06|PASS|Running the install module again succeeds
R07|PASS|Health suite passes on the installed appliance (SUITE|1|0|0)
R08|PASS|Health suite output never contains the pinpoint-api password
R10|PASS|Restore drill, no fault (Recovery point: 0.6s   Restore and health checks: 122.8s   Downtime: 245s)
R11|PASS|FI-06 invalid Nagios config is rolled back (Recovery point: 0.6s   Restore and health checks: 122.8s   Downtime: 245s)
R12|PASS|FI-07 nagios.service fails to start, rolled back (Recovery point: 0.6s   Restore and health checks: 122.8s   Downtime: 245s)
R13|PASS|FI-08 plugin regression is rolled back (Recovery point: 0.6s   Restore and health checks: 122.8s   Downtime: 245s)
R11a|PASS|Health suite reported: failed: HC-02, HC-03, HC-04, HC-05, HC-06, HC-11
R12a|PASS|Health suite reported: failed: HC-01, HC-02, HC-03, HC-04, HC-05, HC-06, HC-11
R13a|PASS|Health suite reported: failed: HC-07
R14|PASS|FI-09 killed in applying; reconcile rolled back (exit 10)
R15|PASS|FI-13 drill refused while the lock is held (exit 5)
R16|PASS|FI-13 deploy-pinpoint-web.sh refused while the lock is held
R17|PASS|PinPoint web still running after the refused deploy
R18|FAIL|FI-11 damaged recovery copy gives RecoveryFailed (exit 11): exit 5 (want 11), state rolled_back (want recovery_failed)
R18a|FAIL|Recovery copy or CRITICAL message missing
R19|FAIL|verify exit 0
R19a|PASS|Appliance healthy again after the manual repair
R30|PASS|Audit chain intact
R31|PASS|Every completed drill recorded its downtime

PASS 22, FAIL 3
```

The identical timings are real, not copied: every drill runs the health suite twice and each run
waits the fixed settle time (`PINPOINT_HEALTH_SETTLE`, 120 s), so a drill's downtime is about 4 minutes.
The recovery point itself takes 0.6 s.

R18's output was `BUSY: another update, drill or PinPoint web deployment is running.` (Finding 2).

## 2. R18, R18a, R19, R19a rerun with the lock free

Same commands and checks as the runner, run by script after confirming the lock was free.

| Case | Check | Result |
|---|---|---|
| R18 | FI-11: drill with a damaged recovery copy ends RecoveryFailed | **PASS**, exit 11, state `recovery_failed`, failure `RESTORE_FAILED` |
| R18a | Evidence kept and CRITICAL shown | **PASS**, `CRITICAL: recovery failed (RESTORE_FAILED: recovery point rp-20261109185914-821455 does not verify)`; copy kept in `/usr/local/.pinpoint-rp/` |
| R19 | `pinpoint-update-exec verify` reports the damaged copy | **PASS**, exit 11, `rp-20261109185914-821455 DOES NOT VERIFY` |
| R19a | Healthy after the manual repair | **PASS**, nagios and pinpoint-gunicorn active, `nagios -v` 0/0, audit intact |

## 3. FI-10: interrupted change and reboot

**First attempt.** R20 PASS (change interrupted in `applying` with a broken `nagios.cfg`). After the
reboot:

```
R21|FAIL|State after reboot: txn-20261109190142-751f6c|recovery_failed|HEALTH_AFTER_RESTORE|
R22|PASS|Files were restored before nagios.service started.
R23|PASS|nagios.cfg no longer has the injected line
R24|FAIL|Nagios files equal those before the interrupted change
R25|PASS|nagios and pinpoint-gunicorn running
R26|PASS|Audit chain intact
```

The boot-time restore worked (files restored at 6.8 s, Nagios started at 7.4 s). The only failed
health check was HC-03 ("nagios.service stopped or restarted within 120s"). The cause is that
`pinpoint-firstboot.sh` ran the whole installer again on this boot (19:03:42 to 19:05:35), rebuilt
Nagios with the ISO's module scripts and restarted it twice. See Finding 1.

**Second attempt.** A temporary drop-in (`ConditionPathExists=/nonexistent...`) stopped the first-boot
service from running, then the same cases were run again. The drop-in was removed afterwards.

```
R20|PASS|Change interrupted in applying with a broken nagios.cfg (txn-20261109190713-b77828). Reboot now.
R21|PASS|Boot-time reconcile rolled back: txn-20261109190713-b77828|rolled_back|INTERRUPTED|
R22|PASS|Files were restored before nagios.service started.
R23|PASS|nagios.cfg no longer has the injected line
R24|PASS|Nagios files equal those before the interrupted change
R25|PASS|nagios and pinpoint-gunicorn running
R26|PASS|Audit chain intact
reboot-check: PASS 6, FAIL 0
```

## Findings

Status: Finding 1 is fixed in `fix/firstboot-run-once` (merged into `main`), checked on this VM by a
reboot after `setup/fix-firstboot-run-once.sh`. Findings 2 and 3 are still open.

1. **High: the first-boot installer runs again on every reboot (existing bug, also on `main`).**
   `firstboot/getty-tty1.conf` is installed as `/etc/systemd/system/getty@tty1.service.d/pinpoint.conf`
   with `Wants=pinpoint-firstboot.service`. `pinpoint-firstboot.sh` ends with
   `systemctl disable pinpoint-firstboot.service`, but that only removes the `multi-user.target` link;
   `getty@tty1` still pulls the service in on every boot, and the script has no "already done" check.
   On this VM it ran at install (14:34) and again on the first reboot (19:03), rebuilding Nagios,
   redeploying the web app and rewriting `/etc/pinpoint/nagios-api.env` and `pinpoint.env`. Effects:
   every appliance reboot reinstalls PinPoint, and FI-10 (boot-time reconcile) can never pass on a real
   appliance because the reinstall restarts Nagios during the health check. Suggested fix: a done
   marker (for example `ConditionPathExists=!/var/lib/pinpoint/firstboot-done` in the unit, written at
   the end of the script), so both `Wants=` paths are covered.
2. **Test runner: FI-13 leaves the lock held for 60 s.** `flock "$LOCK" sleep 60 &` then
   `kill "$HOLDER"` kills `flock` but not its `sleep` child, which keeps the lock. The next case (R18)
   is then refused with BUSY (exit 5). Fix in `tests/update-recovery-tests.sh`: also kill the child
   (`pkill -P "$HOLDER"`), or wait for the lock (`flock "$LOCK" true`) before R18.
3. **Low: `pinpoint-update-reconcile-finish.service` shows as failed after a successful rollback.**
   `reconcile --finish` exits 10 (ROLLED_BACK, plan §8.5), which systemd treats as a failure, so
   `systemctl --failed` lists the unit after a good recovery. Fix: `SuccessExitStatus=10` in the unit
   written by `configure-monitoring-updates.sh` (exit 11, recovery failed, should stay a failure).

## Not tested

1. Install from an ISO built from this branch (the Phase 2 modules were run on the VM, as in Phase 1).
2. The restore drill on a production-sized Nagios (many hosts). This VM has only the default objects.

## State left on the VM

- `/usr/local/.pinpoint-rp/rp-20261109185914-821455` is the deliberately damaged recovery copy from
  FI-11; `pinpoint-update-exec verify` reports it (exit 11) until it is removed by hand.
- Since the first reboot, Nagios was rebuilt by the ISO's first-boot scripts (Finding 1). The Phase 2
  executor, health suite and reconcile units are still installed and the audit chain is intact.
