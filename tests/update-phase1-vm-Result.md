# update-phase1-vm-Result

Result of testing plan Phase 1 (version management: verified Nagios downloads and the read-only
PinPoint Update Manager) on a VM. Plan: `docs/University-Maintenance-and-Updates-Plan.md` §16 and §20.
The automated part is the three Phase 1 runners. The real-download, reinstall and Update Manager cases
(V01 to V14) were run by script on the same VM. Every case is marked PASS, FAIL or SKIP with the
reason; nothing is marked as passed unless it was run.

## Summary

| Part | Result |
|---|---|
| Automated runners on the VM | **PASS 33, FAIL 0** (`baseline-artifacts-tests.sh` 14, `login-hook-tests.sh` 7, `test_pinpoint_update.py` 12) |
| Real downloads, wrong digest, reinstall, Update Manager (V01 to V14) | **PASS 14, FAIL 0** |
| Findings that need a code change | None |
| Notes | 3, listed under "Notes" |
| Not tested | 3 items, listed under "Not tested" |

## Environment

| Item | Value |
|---|---|
| Date (UTC) | 2026-11-09 |
| Host | `user-1`, disposable Proxmox VM reached over Tailscale; snapshot taken by the user before testing |
| OS | Ubuntu 22.04.5 LTS |
| Starting state | Fresh install from the earlier ISO (9 first-boot steps, no Update Manager), install credentials still pending |
| Code under test | `feat/update-validation-approval` at `37d28c2` (Phase 1 complete, before Phase 2), copied to `/root/pinpoint-phase1/` in the ISO layout that `scripts/build.sh` produces |
| Tester | Claude Code, over SSH |

## 1. Automated runners

Run from a copy of the repository at `37d28c2` on the VM.

`bash tests/baseline-artifacts-tests.sh`

```
B1|PASS|baseline manifest is valid JSON with schema_version 1
B2|PASS|every component has https URL, file name and 64-hex SHA-256
B3|PASS|baseline_field reads the Nagios Core version (4.5.11)
B4|PASS|baseline_field fails for a missing field
D1|PASS|matching download is accepted and kept
D2|PASS|matching cached archive is reused without downloading
D3|PASS|mismatching cached archive is downloaded again and replaced
D4|PASS|tampered download fails and leaves no archive behind
D5|PASS|failure message names the expected and actual digests
D6|PASS|non-HTTPS manifest URL is refused before downloading
D7|PASS|missing manifest stops the install
M1|PASS|install modules and configure-nagios.sh contain no version literals
M2|PASS|install modules call wget only through fetch_verified_artifact
M3|PASS|build.sh copies the manifest onto the ISO

Summary: 14 passed, 0 failed
```

`bash tests/login-hook-tests.sh`

```
H1|PASS|fresh install: credentials shown, then the menu opens with --first-login
H2|PASS|second login: menu does not open again
H3|PASS|credentials still pending: menu waits
H4|PASS|next login after confirming: menu opens
H5|PASS|existing appliance: nothing shown, menu not opened
H6|PASS|non-interactive shell: menu not opened
H7|PASS|hook leaves no pinpoint_login_ functions behind

Summary: 7 passed, 0 failed
```

`python3 -m unittest -v tests/test_pinpoint_update.py`: 12 tests, all `ok` (audit chain tampering,
baseline recorded once, differing or missing components, first-login menu once, invalid manifest,
menu end of input, menu never claims up to date, non-root refused, version parsers, status JSON,
unreadable version is UNKNOWN, app commit).

## 2. Real downloads and the digest check

| Case | Check | Result |
|---|---|---|
| V01 | The archives the earlier ISO install left in `/usr/local/src` match the manifest SHA-256 (Nagios Core, Plugins, `check_ncpa`) | **PASS**, all 3 match |
| V02 | `fetch_verified_artifact` in an empty folder downloads each archive from its real HTTPS URL and accepts it | **PASS**, all 3 downloaded and verified |
| V03 | Manifest with a wrong Nagios Core digest: the helper refuses, names expected and actual digest, leaves no file or `.part` behind | **PASS**, exit 1 |
| V04 | Same wrong manifest through the full `install-nagios-core.sh` | **PASS**, stops at step 2/8 (download), never reaches extract or build; Nagios binary unchanged and still running |

V04 output:

```
[2/8] Downloading Nagios Core...
  Cached nagios-4.5.11.tar.gz does not match the baseline; downloading again.
✗ nagios-4.5.11.tar.gz does not match the baseline SHA-256.
  Expected: 0000000000000000000000000000000000000000000000000000000000000000
  Got:      1bf85d6704a75e6b89a09844836f68b1cfc61ab1ef005574041e36e73fdb797a
  The download was deleted. Nothing was installed from it.
```

## 3. Reinstall from the verified manifest

| Case | Check | Result |
|---|---|---|
| V05 | First-boot steps 2, 3, 5, 7, 8 with the Phase 1 modules (`install-nagios-core.sh`, `install-nagios-plugins.sh`, `configure-nagios.sh`, `configure-pinpoint-privileges.sh`, `configure-event-handler.sh`) | **PASS**, all exit 0 (27 s, 33 s, 6 s, 3 s, 0 s). Core was downloaded again and verified (`✓ nagios-4.5.11.tar.gz downloaded; SHA-256 matches the baseline.`); Plugins and `check_ncpa` reused verified cached copies |
| V06 | After the reinstall: versions, config, services, web | **PASS**, Nagios Core 4.5.11, Plugins 2.4.12, `nagios -v` 0 warnings 0 errors; nagios, apache2, snmpd, ssh active; `/` and `/nagios/` return 200; `pinpoint-api` can read `statusjson.cgi` (200) |

Steps 6 (web app) and 9 (journald) did not change in Phase 1 and were not rerun.

## 4. PinPoint Update Manager (first-boot step 10)

| Case | Check | Result |
|---|---|---|
| V07 | `configure-monitoring-updates.sh` installs the program and state | **PASS**, exit 0; `/usr/local/sbin/pinpoint-update` `root:root 755` (identical to the source); manifest `root:root 644`; `/var/lib/pinpoint/updates` `700`; `updates.db` `600` |
| V08 | `pinpoint-update inventory --json` | **PASS**, `installed_manifest` is `pp-mon-baseline-1`; Nagios Core 4.5.11, Plugins 2.4.12, `check_ncpa` 1.2.4 all `baseline`; update status `UNKNOWN (no update catalog is configured yet)` |
| V09 | `pinpoint-update status`, `audit --verify` | **PASS**, exit 0; `Audit chain: intact`; first row `installed_state.recorded` (source `installer-baseline`), actor is the sudo user |
| V10 | Run `configure-monitoring-updates.sh` again | **PASS**, exit 0; baseline not recorded twice (one new `inventory.scanned` row only); chain intact |
| V11 | Menu with input 1, 2, 3, 4 | **PASS**, Reload redraws the status; 2 and 3 print "not available in this version" and "Nothing was changed"; 4 exits 0; never says "up to date" |
| V12 | `pinpoint-update status` without sudo | **PASS**, refused with `must be run as root`, exit 3 |
| V13 | Fresh install (credentials pending) sets the first-login marker | **PASS**, `/var/lib/pinpoint/update-menu-pending` created; Phase 1 login hook installed in `/etc/profile.d/` as the autoinstall does |
| V14 | Nagios still healthy after step 10 | **PASS**, `nagios -v` 0/0, nagios active, `/nagios/` 200 |

## Notes

1. Rerunning `configure-nagios.sh` leaves 13 backup files (`*.cfg~`) in `/usr/local/nagios/etc`
   from the Nagios sample-config install. Harmless; only appears on a rerun.
2. In `commands.cfg` the mail command changed from `/bin/mail` to `/usr/bin/mail`. On Ubuntu 22.04
   both are the same file. Harmless.
3. The `pinpoint-api` hash in `htpasswd.users` changed on the rerun, but the password did not:
   `/etc/pinpoint/nagios-api.env` and `/etc/pinpoint/pinpoint.env` still hold the same value and the
   status API accepts it. Only the salt is new.

## Not tested

1. **Install from an ISO built from this branch.** The VM was installed from the earlier ISO and the
   Phase 1 modules were run on it in the first-boot order. That `scripts/build.sh` puts the manifest on
   the ISO is checked only by M3 (static check), not by building and booting an ISO.
2. **The real first console login.** The marker is set and the hook is installed (V13), and the hook
   logic is covered by H1 to H7, but nobody logged in at the console. The marker is left in place so
   this can still be done by hand.
3. **Plan "signing procedure".** Dropped by the decision of 28 October 2026 (manifests are not signed).
