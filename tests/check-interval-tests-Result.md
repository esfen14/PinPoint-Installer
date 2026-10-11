# check-interval-tests-Result

Result of testing installer issue #4 (configurable Nagios check interval). Case descriptions are in
`docs/Check_Interval_Test_Cases.md`. The automated part is `tests/check-interval-tests.sh`. Cases it
cannot run (upgrade, rollback, fresh install, reboot) were run by hand on the same VM and are listed
separately below. Every case is marked PASS, FAIL, or SKIP with the reason; nothing is marked as
passed unless it was run.

## Summary

| Part | Result |
|---|---|
| Automated runner, final run | **PASS 36, FAIL 0, WARN 0, SKIP 4** |
| Cases run by hand (fresh install, upgrade, rollback, failure cases, reboot, health check, SMTP regression) | **All PASS** (details below) |
| Findings that changed the code | 2 (helper path, literal `\n`), both fixed and re-tested |
| Not tested | 4 items, listed under "Not tested" |

## Environment

| Item | Value |
|---|---|
| Date (UTC) | 2026-10-11 |
| Host | `pinpoint`, disposable VM reached over Tailscale, snapshots `Before-Testing`, `WHelper`, `pre-60` |
| OS | Ubuntu 22.04.5 LTS (the supported target) |
| Installer | `feat/nagios-check-interval`, merge `aa0a8bd` (LF fix, `interval_length` helper, privileges check, schema check, docs) |
| PinPoint | `b11e6dc` (includes PR #83, the check interval feature, and PR #89). The `pre-60` state ran `27ebe46`, the commit before PR #83. |
| Database | revision `a4c8e1f6d392`. The `pre-60` state was `d3a9e6b2f741` with no `Check_Interval` column. |
| Tester | Claude Code, over SSH |

Test data created on the VM (a lab network `192.168.130.0/24`, scanned once): 4 discovered hosts
(`gateway`, `dev-6561af`, `dev-08100e`, `dev-bc9443`), 0 services. Two of them are down on the lab network.

## 1. Automated runner (final run, 08:56 UTC)

Output of `sudo ./check-interval-tests.sh`, one line per case.

| ID | Status | Detail |
|---|---|---|
| 1.1 | PASS | `interval_length` is 60 |
| 1.2 | PASS | Missing value accepted, file untouched, no backup |
| 1.3 | PASS | 30 changed to 60 with a backup |
| 1.9 | PASS | Nagios reloaded (27 to 28 SIGHUP) and is active |
| 1.7 | PASS | `nagios.cfg` still `nagios:nagios` 664 |
| 1.8 | PASS | Second run changes nothing, no new backup |
| 1.4 | PASS | Duplicate and non-numeric lines collapsed to one 60 |
| 1.5 | PASS | Commented line ignored, file untouched |
| 1.6 | PASS | Exit 1, `nagios.cfg` restored byte for byte |
| 1.12, L3 | PASS | `bash -n` clean for every script in `/root/pinpoint`, no carriage returns |
| 2.1, 2.1b | PASS | Reload rule found, also in the unqualified form PinPoint runs |
| 2.2 | PASS | Restart, stop and start are refused |
| 2.3 | PASS | Only the reload rule and the SMTP helper rule |
| 2.4, 2.5, 2.6 | PASS | `visudo -c`, `nagios -v` as `pinpoint`, config files writable |
| 2.10 | PASS | Reload as `pinpoint`: same process, new SIGHUP |
| 2.11 | PASS | The app calls `sudo -n systemctl reload nagios`, which the rule covers |
| 3.2 | PASS | `Check_Interval INTEGER NOT NULL DEFAULT '5'`, values `[5]` |
| 3.3 | PASS | Every row holds an accepted value |
| 3.11 | PASS | 20 migration files, all tracked by git: the installer added none |
| 5.1 | PASS | Check interval is 5 minutes by default |
| 5.11 | PASS | 3 minutes rejected with 400 |
| 5.3 | PASS | 4 `check_interval` lines, all 5 |
| 5.4 | PASS | HTTP 200, the 4 lines are now 2 |
| 5.5 | PASS | Backup of the previous config added (8 to 9 files) |
| 5.6 | PASS | Nagios reloaded (SIGHUP 30 to 31), same process, no restart |
| 5.12 | PASS | `localhost.cfg` unchanged |
| 5.7 | PASS | Host `dev-6561af`: checks 120 s then 120 s apart (at 5 minutes they would be 300 s) |
| 5.8 | PASS | Validation fails: HTTP 422, `hosts.cfg` unchanged, setting still 2, Nagios active |
| 5.9 | PASS | Reload refused: HTTP 422, setting still 2, `hosts.cfg` unchanged |
| 2.1c | PASS | Reload rule restored after 5.9 |
| 5.10 | PASS | Non-admin can read settings (200); changing the interval gets 403 and the value stays 2 |
| 5.14 | PASS | `nagios.cfg`, the sudoers rule and the interval were put back; verified afterwards |
| 1.11, 3.8, 5.2 | SKIP | Need the `pre-60` snapshot, run by hand (section 2) |
| 5.13 | SKIP | The 60-second status poll is fixed in the app; no installer check exists for it |

After the run: `interval_length=60`, no leftover `.bak` files, both sudoers files present, `nagios -v`
0 errors and 0 warnings, all 4 hosts back at `check_interval 5`.

## 2. Cases run by hand

### Fresh install (all modules, merged branch)

| ID | Status | Detail |
|---|---|---|
| R3 | PASS | All seven modules ran from LF files. The first run stopped at `configure-nagios.sh` (finding 1); after the fix the remaining modules ran to `ALL DONE`. Modules 1 to 4 ran once, before the fix, because the fix does not touch them. |
| 1.1 | PASS | One line `interval_length=60`; both logs say `interval_length is 60`. |
| 3.1 | PASS | Log: "Check_Interval is valid on 1 settings row(s)" and "check interval setting is present and valid". |
| 3.2, 3.3 | PASS | `Check_Interval INTEGER NOT NULL DEFAULT '5'`, the settings row holds 5. |
| 2.1, 2.2, 2.4, 2.5 | PASS | Reload allowed; restart, stop and start refused; sudoers parses; `nagios -v` 0 errors, 0 warnings. |
| Services | PASS | `nagios`, `pinpoint-gunicorn`, `nginx` and `apache2` active; web 200; API 401 when not signed in. |

### Upgrade from the `pre-60` state (app `27ebe46`, database `d3a9e6b2f741`)

Run twice: once with the schema-check commit, once with the final merged scripts started the way the
setup wizard starts them (`bash ./deploy-pinpoint-web.sh` from the script folder).

| ID | Status | Detail |
|---|---|---|
| 1.11 | PASS | With `interval_length=30`, the upgrade set it to 60 with a backup, checked `nagios -v`, reloaded Nagios and carried on. |
| 3.4, 3.5 | PASS | Database moved to `a4c8e1f6d392`. `Check_Interval` was added and holds 5. Row counts before and after differ only by the new migrations (one extra permission, one extra role link, the new `SMTP_SETTINGS` table). Users, settings and plugin rows are unchanged. |
| 5.2 | PASS | Same comparison: no data lost. |
| 3.6 | PASS | Re-run says "Already at the latest" and the check passes. |
| 1.11b | PASS | With `interval_length=30` plus a bad directive, the deploy stops at step 1 with "interval_length is not 60 and could not be fixed" and `nagios.cfg` is byte-identical afterwards. (Run on the first version of the helper call; the logic is unchanged.) |

### Failure cases for the schema check

| ID | Status | Detail |
|---|---|---|
| 3.9 | PASS | `Check_Interval=3`: the deploy exits 1 with "setting is missing or invalid". |
| 3.7 | PASS | Column dropped: the same error, exit 1. |
| 3.8 | PASS | A real upgrade from `pre-60` with the check forced to fail (a test copy allowing only the value 99). The log shows "Upgrade failed. Restoring 27ebe46…". Afterwards the app is at `27ebe46`, the database at `d3a9e6b2f741`, the data dump is identical to before, all services are active, web 200, API 401. |
| 3.10 | PASS | `system.db` checksum, mtime and size identical before and after the check; no WAL files. |
| 3.12 | PASS | No password, secret or token in the three test logs. |
| 3.13 | PASS | `bash -n` clean. |

### Permissions (on the Phase 2 version)

| ID | Status | Detail |
|---|---|---|
| 2.7 | PASS | A settled run of the privileges script reloaded Nagios 0 times. |
| 2.8 | PASS | Run three times: exit 0 each time, one sudoers line. |
| 2.9 | PASS | An extra `restart` grant and an extra `stop` grant, each in a separate sudoers file, made the script exit 1 with "more sudo rights than 'systemctl reload nagios'". See "Behaviour to know". |

### Whole revision

| ID | Status | Detail |
|---|---|---|
| R9 | PASS | The rollback after a failed upgrade (3.8) left the old version healthy. |
| R10 | PASS | `tests/smtp-admin-email-tests.sh` on the final VM: PASS 24, FAIL 0, WARN 0, SKIP 19. No regressions. |
| R11 | PASS after a fix to the VM | `pinpoint-healthcheck.sh` first reported 1 failure (finding 3), then 59 passed, 0 failed, 1 warning (2 of the 5 lab hosts are down). |
| R12 | PASS | After a reboot (back in about 65 s): all five services active, `interval_length` 60, web 200, an admin can sign in, the setting reads 5, `nagios -v` 0 errors. |
| 4.1 to 4.6 | PASS | `docs/Check-Interval.md` exists and is linked from the README; every documented command was run on the VM. |
| L1, L2, L4 | PASS | `.gitattributes` forces LF; scripts checked out on Windows are LF on disk. |

## Findings

| # | Finding | Effect | State |
|---|---|---|---|
| 1 | `configure-nagios.sh` changes directory before it calls the helper, so `$(dirname "$0")` was `.` and the helper was not found when the script was started with a relative path (as the setup wizard does). Earlier tests used absolute paths and missed it. The fresh install caught it. | Install stopped at module 5. | Fixed in `639a2b6`: both scripts resolve their own folder first. Re-tested. |
| 2 | The same commit left a literal `\n` instead of a line break in the `deploy-pinpoint-web.sh` call. It happened to work (bash passed `n` to the helper, which ignores arguments). | None in practice. | Fixed in `639a2b6`. |
| 3 | Re-running `configure-nagios.sh` on its own reinstalls the stock `nagios.cfg`, which drops the `plugin-services.cfg` line that `configure-pinpoint-privileges.sh` adds. My own test of case 1.10 did this, and the `pre-60` snapshot was taken afterwards, so the health check failed until the privileges script ran again. | Only when the modules are run out of order. The normal install and upgrade always run the privileges script after. | Not a bug in this change. Recorded as known behaviour. |
| 4 | Two Nagios reloads in the same second are handled as one (the second SIGHUP is not logged separately). My first 2.10 failed because it ran right behind a helper reload. | Test timing only. | Fixed in the runner with a settle pause and a wait for the SIGHUP. |
| 5 | The admin session expired during a long discovery scan (30-minute timeout) and later API calls got 401. | Test only. | Runner now signs in again when needed. |
| 6 | A discovery scan of `192.168.130.0/24` with ports 1 to 10000 and service detection took 81 minutes. | Slow tests. | Runner skips the scan when `hosts.cfg` already has hosts. |
| 7 | One earlier 5.7 run saw the `gateway` host checked 90 s apart at a 2-minute interval. `gateway` was DOWN at the time. Watching an UP host gives exactly 120 s, twice, and `next_check` minus `last_check` is exactly one interval. | The runner now picks an UP host. The 90 s gap on a DOWN host is not explained. | Open, low impact. |

## Behaviour to know

- `configure-pinpoint-privileges.sh` rewrites its own sudoers file on every run, so a hand edit to that
  one file is repaired silently. Extra rights granted in any other file are detected and stop the script.
- Creating or editing an account makes PinPoint rebuild the Nagios contacts and reload Nagios.
- The check interval applies to the hosts and services PinPoint generates, not to `localhost.cfg`
  (confirmed: `localhost.cfg` was unchanged by a change to 2 minutes).

## Not tested

| Item | Why |
|---|---|
| Case 5.13 (the 60-second status poll is unchanged) | Fixed in the app; there is no installer check to run. |
| A scan that creates services | The lab hosts offered no services, so cadence was checked on host checks only. The service path uses the same `check_interval` setting and the same config writer. |
| Reboot and upgrade on Ubuntu 24.04 | Out of scope; 22.04 is the supported target. |
| Cause of the single 90 s host-check gap on a DOWN host (finding 7) | Not investigated further. |

## Left on the test VM

Test-only data that PinPoint cannot delete: three throwaway roles named `CI NonAdmin …` (deactivated)
and two throwaway accounts `ci-nonadmin-…@example.com` (suspended). The admin account was moved out of
its placeholder by the runner (email `pinpoint.tester@example.com`); its login is in
`/root/.check-interval-test-admin` (mode 600) on the VM only. Restore the `WHelper` or `pre-60`
snapshot to remove all of it.
