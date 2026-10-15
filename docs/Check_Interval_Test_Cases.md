# Test Cases: Configurable Nagios Check Interval (Installer Issue #4)

Covers the installer side of PinPoint issue #60 (merged as Pinpoint PR #83): the app adds an
admin-only system **Check interval** (1, 2, 5, 10 or 15 minutes). The app owns the setting, the
generated Nagios config and the reload. The installer only guarantees the environment that
feature assumes. App model, migration, UI and config-writer tests are PinPoint's own.

Status of every case: **not run** unless a result is written in the Result column.

## What the installer must guarantee

| Area | Guarantee |
|---|---|
| Nagios timing | `interval_length` is 60, so `check_interval 2` means two minutes. |
| Permissions | `pinpoint` can validate the config and `sudo -n systemctl reload nagios`, and cannot stop or start it (restart is allowed by the proactive resolution rule). |
| Schema | After the app migration `SYSTEM_SETTINGS.Check_Interval` exists and upgraded rows hold 5. |
| Documentation | The four different "intervals" are explained and `localhost.cfg` is stated as unaffected. |

## Conventions

- **VM**: disposable Ubuntu 22.04 (the supported target). Take these snapshots:
  - `os-only`: clean OS, before any install.
  - `fresh`: appliance installed from the branch under test.
  - `pre-60`: appliance whose app is checked out at the commit before PR #83 (`bafcd72^`) and
    whose database is at revision `d3a9e6b2f741`, with a few hosts and users added.
- Restore the matching snapshot before each section so cases do not depend on each other.
- Commands run on the VM as root unless stated. Never paste real passwords into this file.
- Paths: `NAGIOS_CFG=/usr/local/nagios/etc/nagios.cfg`,
  `SERVER_DIR=/opt/pinpoint/Network-Diagnosis-System/server`,
  configure log `/var/log/pinpoint-configure.log`, web log `/var/log/pinpoint-web.log`,
  privileges log `/var/log/pinpoint-privileges.log`.
- Run installer scripts from LF files only (see section L).
- "Helper" means `setup/ensure-nagios-interval.sh`, if the shared-helper design is chosen.
  Until then, read it as the `interval_length` block in `configure-nagios.sh`.

---

## L. Line endings (`fix/enforce-lf-line-endings`)

| ID | Case | Steps | Expected | Result |
|---|---|---|---|---|
| L1 | Attributes file present | `git show main:.gitattributes` after the merge | Lists `*.sh`, `*.service`, `*.conf`, `autoinstall/*`, `firstboot/*.before-*` as `eol=lf`. | PASS (file committed, `4678a5a`) |
| L2 | Scripts are LF on a Windows checkout | On Windows with `core.autocrlf=true`, re-clone and run `git ls-files --eol` | Every `*.sh`, service, conf and autoinstall file shows `w/lf`. | PASS (checked in the existing clone after re-checkout) |
| L3 | Scripts run on Linux unchanged | Copy `setup/` to the VM without `sed`, then `bash -n *.sh` | No `$'\r': command not found`, no syntax errors. | |
| L4 | Docs are not affected | `git ls-files --eol` for `*.md` | Docs may stay CRLF; nothing breaks. | PASS |

---

## 1. `interval_length` (`fix/nagios-interval-length`)

Restore `fresh` for 1.1-1.2 and 1.9, and use the temporary-edit approach described in each case.

| ID | Case | Steps | Expected | Result |
|---|---|---|---|---|
| 1.1 | Fresh install reports 60 | Run the full install. `grep interval_length "$NAGIOS_CFG"` | One active line, `interval_length=60`. Configure log has `✓ interval_length is 60.` | PASS |
| 1.2 | Missing value is accepted | Remove the active `interval_length` line, run the helper | Log says `unset (Nagios default 60)`. `nagios.cfg` is not rewritten (no backup file). | not run |
| 1.3 | Wrong value is normalized | Set `interval_length=30`, run the helper | Log says it was 30 and is now 60. A timestamped `.bak` exists. One active line, `interval_length=60`. | PASS (block run alone; see note 1) |
| 1.4 | Odd values collapse to one line | Append `interval_length = 15` and `interval_length=abc`, run the helper | Exactly one active line, `interval_length=60`. | PASS (block run alone) |
| 1.5 | Commented line is ignored | Replace the active line with `#interval_length=5`, run the helper | Treated as unset (case 1.2). | PASS (parsing checked locally) |
| 1.6 | Validation failure rolls back | Set 30 and append `bogus_directive=1`, run the helper | Exit 1, error says `nagios -v rejected`. `nagios.cfg` is byte-identical to before the run (`cmp`). | PASS (block run alone) |
| 1.7 | Owner and mode kept | `ls -l "$NAGIOS_CFG"` before and after case 1.3 | Still `nagios:nagios`, mode `664`. | PASS |
| 1.8 | Idempotent | Run the helper twice | Second run changes nothing and creates no new backup. | PASS (second `configure-nagios.sh` run: no backup, value 60) |
| 1.9 | Nagios stays healthy | `nagios -v "$NAGIOS_CFG"` and `systemctl is-active nagios` after 1.3 | 0 errors, 0 warnings, `active`. | PASS |
| 1.10 | Re-running `configure-nagios.sh` | Set 30, run the whole script | Ends with 60. Note whether the value was fixed by the helper or by `make install-config`. | PASS, but see note 1 |
| 1.11 | Upgrade path covers it | Restore `pre-60`, set `interval_length=30`, run `deploy-pinpoint-web.sh` | Ends with 60 and a backup. Requires the helper to be called from `deploy-pinpoint-web.sh`. | not run (needs the shared helper) |
| 1.12 | Script syntax | `bash -n` on `configure-nagios.sh`, `deploy-pinpoint-web.sh`, the helper | No errors. | PASS (`configure-nagios.sh`) |

**Note 1.** `make install-config` reinstalls the stock `nagios.cfg` on every run of
`configure-nagios.sh`, so a bad value is reset before the check runs. On that script alone the
check can only confirm the fresh install. Cases 1.3, 1.4 and 1.6 were therefore run against the
extracted block. Case 1.11 is the one that proves the upgrade path.

---

## 2. Permissions (`fix/verify-reload-privileges`)

`configure-pinpoint-privileges.sh` already checks reload and restart allowed and stop and start refused, and that
`pinpoint` can run `nagios -v`. These cases are mostly regression checks; add a script check only
where a case fails or a check is missing.

| ID | Case | Steps | Expected | Result |
|---|---|---|---|---|
| 2.1 | Reload rule exists | `runuser -u pinpoint -- sudo -n -l /usr/bin/systemctl reload nagios` | Exit 0 (the rule is listed). | |
| 2.2 | Stop and start are refused | `runuser -u pinpoint -- sudo -n -l /usr/bin/systemctl stop nagios` (and `start`) | Non-zero for both. | |
| 2.3 | No other sudo rights | `runuser -u pinpoint -- sudo -n -l` | Lists only the reload rule and the SMTP helper rule. | |
| 2.4 | Sudoers valid | `visudo -c` | `parsed OK` for every file under `/etc/sudoers.d`. | |
| 2.5 | Config validation as `pinpoint` | `runuser -u pinpoint -- /usr/local/nagios/bin/nagios -v "$NAGIOS_CFG"` | 0 errors. | |
| 2.6 | Config files writable | `runuser -u pinpoint -- test -w` on `hosts.cfg` and the plugin services cfg | Exit 0 for both. | |
| 2.7 | No reload during the check | Note the Nagios `ActiveEnterTimestamp` and `ExecReload` count before and after running the script | Unchanged. The script must not reload Nagios. | |
| 2.8 | Script is idempotent | Run `configure-pinpoint-privileges.sh` twice | Both exit 0. No duplicate sudoers lines. | |
| 2.9 | A broken rule is detected | Temporarily add `stop nagios` to the reload rule, run the script | Fails with `more sudo rights than reload and restart of nagios`. Restore the file afterwards. | |
| 2.10 | Reload really works | As `pinpoint`, `sudo -n systemctl reload nagios` once, then check `systemctl status nagios` | Reload accepted, service still active. Do this by hand only, never inside the script. | |
| 2.11 | Command matches the app | Compare the app's reload command (Pinpoint `create_host_cfg`) with the sudoers rule path | Same binary path and arguments. If the app calls a different path (`/bin` vs `/usr/bin`), the rule covers both. | |

---

## 3. Schema check (`feat/verify-check-interval-schema`)

The check runs after the app migration in `deploy-pinpoint-web.sh`, is read-only, adds no
migration and logs no credentials. A failure calls `fail`, which triggers the existing upgrade
rollback.

| ID | Case | Steps | Expected | Result |
|---|---|---|---|---|
| 3.1 | Fresh install passes | Restore `fresh` state (or install fresh), then read the log | Log has a `Check_Interval` success line. Column exists, all rows are one of 1, 2, 5, 10, 15. | |
| 3.2 | Column present | `sqlite3 "$SERVER_DIR/system.db" "PRAGMA table_info(SYSTEM_SETTINGS);"` | Shows `Check_Interval`, `INTEGER`, not null, default `'5'`. | |
| 3.3 | Fresh default | `SELECT Check_Interval FROM SYSTEM_SETTINGS;` | `5`. | |
| 3.4 | Upgrade keeps data | Restore `pre-60`, note users and hosts, run `deploy-pinpoint-web.sh` | Same users and hosts afterwards. Migration `a6f4d2c8e190` applied. | |
| 3.5 | Upgraded rows default to 5 | After 3.4, read `Check_Interval` | `5` on every row. | |
| 3.6 | Re-run is harmless | Run `deploy-pinpoint-web.sh` again | Already-latest message, check passes, nothing rewritten. | |
| 3.7 | Missing column fails | Restore `pre-60`, apply the app update but stop the migration (or point the check at an unmigrated copy) | Install stops with a clear `Check_Interval` message. | |
| 3.8 | Failure rolls back | Make the check fail on an upgrade | The upgrade rollback runs: code and databases restored, service restarted, old version responds. | |
| 3.9 | Bad value fails | Set `Check_Interval=3` on a test copy and run the check | Fails and names the value. | |
| 3.10 | Read-only | Compare `system.db` checksum and mtime before and after the check on a fixed database | Unchanged. | |
| 3.11 | No second migration | `ls "$SERVER_DIR/migrations/versions"` after the installer run | No migration file created by the installer. | |
| 3.12 | No secrets in logs | `grep -iE 'password|secret|token' /var/log/pinpoint-web.log` for the new lines | None of the new lines print credentials. | |
| 3.13 | Script syntax | `bash -n deploy-pinpoint-web.sh` | No errors. | |

---

## 4. Documentation (`docs/check-interval-explained`)

| ID | Case | Steps | Expected | Result |
|---|---|---|---|---|
| 4.1 | File exists and is linked | Open `docs/Check-Interval.md` and `README.md` | The doc exists and the README links to it. | |
| 4.2 | Four intervals explained | Read the doc | Discovery scans, Nagios check intervals, Pinpoint's 60-second status poll and per-user dashboard refresh are each defined separately. | |
| 4.3 | Scope is stated | Read the doc | States the setting applies to PinPoint-generated hosts and services and does not change stock `localhost.cfg` checks. | |
| 4.4 | Normalize decision recorded | Read the doc | Says `interval_length` is forced to 60 with a backup and `nagios -v`, and what happens on failure. | |
| 4.5 | Values are accurate | Compare with PR #83 | Allowed list 1, 2, 5, 10, 15 and default 5 match. | |
| 4.6 | Plain wording | Read the doc | No unexplained jargon, no secrets, no real addresses. | |

---

## 5. VM test run: app and installer together (`docs/check-interval-test-result`)

Use an authenticated admin session against the real API through Nginx. These cases mirror the
acceptance list of issue #4 and run once on `fresh` and once on `pre-60` after the upgrade.

| ID | Case | Steps | Expected | Result |
|---|---|---|---|---|
| 5.1 | Setting visible and defaulted | Read system settings (UI or API) | Check interval shown as 5 minutes. | |
| 5.2 | Migration keeps existing data (upgrade) | Compare hosts, users and history counts before and after the upgrade | No rows lost. | |
| 5.3 | Baseline cadence | With 5 minutes set, read `check_interval` in the generated `hosts.cfg` and services cfg | `check_interval 5` on host and service objects. | |
| 5.4 | Change to 2 minutes | Save 2 as admin | HTTP 200. Generated host and service objects now say `check_interval 2`. | |
| 5.5 | Backup kept | List the app's config backup directory | The previous interval-5 config is present. | |
| 5.6 | Nagios reloaded | `journalctl -u nagios` and `systemctl status nagios` | A reload entry appears, the service stays active, no restart. | |
| 5.7 | Cadence really changes | Watch `last_check` for two checks on one service | About 120 seconds apart. | |
| 5.8 | Invalid change keeps old config | Break validation (a bogus directive in a test template) and save a new value | HTTP 422, setting and live `hosts.cfg` unchanged, Nagios still active, old cadence continues. | |
| 5.9 | Failed reload keeps old config | Remove the reload sudoers rule temporarily, save a new value | HTTP 422, old setting and config kept. Restore the rule afterwards and re-run case 2.1. | |
| 5.10 | Non-admin cannot change it | Save as a non-admin user | 403. | |
| 5.11 | Only allowed values | Send 3 through the API | Rejected with 4xx. | |
| 5.12 | `localhost.cfg` untouched | Compare `localhost.cfg` checksum before and after case 5.4 | Identical. | |
| 5.13 | Status poll unchanged | Confirm PinPoint's status poll still runs every 60 seconds after case 5.4 | Unchanged. | |
| 5.14 | Cleanup | Set the value back to 5 and restore snapshots | Back to baseline. | |

---

## R. Whole revision: one pass over the finished installer

Run on a VM restored to `os-only`, using the final merged branch `feat/nagios-check-interval`. This
is the release gate for issue #4.

| ID | Case | Steps | Expected | Result |
|---|---|---|---|---|
| R1 | Branch is clean | `git status`, `git log --oneline main..HEAD` | Only the intended commits: LF fix, `interval_length`, permissions, schema check, docs, tests. No secrets, no `.bak` files. | |
| R2 | Syntax of every script | `bash -n` on all files in `setup/`, `firstboot/`, `tests/` | No errors. | |
| R3 | Fresh install end to end | Run the seven modules in order from LF files | All finish, `ALL DONE`. No `$'\r'` errors. | PASS (seven modules, earlier build of the branch) |
| R4 | `interval_length` | Section 1, cases 1.1 and 1.8 | Pass. | |
| R5 | Permissions | Section 2, cases 2.1-2.8 | Pass. | |
| R6 | Schema | Section 3, cases 3.1-3.3 | Pass. | |
| R7 | App feature works | Section 5, cases 5.1, 5.4, 5.6, 5.7, 5.8 | Pass. | |
| R8 | Upgrade end to end | Restore `pre-60`, run `deploy-pinpoint-web.sh`, then sections 1.11, 3.4-3.6, 5.2 | Pass; data kept, interval normalized, schema check passes. | |
| R9 | Failed upgrade rolls back | Section 3, case 3.8, then confirm cases 1.9 and 2.1 still pass | Old version restored and healthy. | |
| R10 | Existing features still work | Run `tests/smtp-admin-email-tests.sh` | No new failures compared with `tests/smtp-admin-email-tests-Result.md`. | |
| R11 | Health check | Run `setup/pinpoint-healthcheck.sh` | Reports healthy. | |
| R12 | Reboot | Reboot the VM, then check `nagios`, `pinpoint` and `nginx` | All active, `interval_length` still 60, setting still readable. | |
| R13 | Docs match behaviour | Read section 4 against what R4-R9 showed | No contradictions. | |
| R14 | Results recorded | `tests/check-interval-tests-Result.md` is written | Every case is marked PASS, FAIL or SKIPPED with a reason. Nothing marked pass that was not run. | |
| R15 | Issue closing criteria | Walk issue #4's five items and its finish conditions | Each item maps to a passing case above. | |

## Case index by issue #4 item

| Issue item | Cases |
|---|---|
| 1. `interval_length` | 1.1-1.12, R4 |
| 2. Permissions | 2.1-2.11, R5 |
| 3. Schema check | 3.1-3.13, R6 |
| 4. Documentation | 4.1-4.6, R13 |
| 5. VM testing | 5.1-5.14, R3, R7-R12 |
