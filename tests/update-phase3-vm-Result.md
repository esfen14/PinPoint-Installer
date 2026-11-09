# update-phase3-vm-Result

Result of testing plan Phase 3 (validation and approval: compatibility gate, approvals, roles, audit
chain, CLI) on a VM. Plan: `docs/University-Maintenance-and-Updates-Plan.md` §16 (exit gate: unit and
security tests pass). The VM runner is `tests/update-approval-tests.sh`. Every case is marked PASS,
FAIL or SKIP with the reason; nothing is marked as passed unless it was run.

## Summary

| Part | Result |
|---|---|
| Portable tests on the VM | **PASS 107, FAIL 0** (`test_pinpoint_update_approval.py` 38; regression: `test_pinpoint_update_exec.py` 23, `test_pinpoint_update.py` 12, `baseline-artifacts-tests.sh` 14, `login-hook-tests.sh` 7, `firstboot-run-once-tests.sh` 13) |
| VM runner, first run | **PASS 28, FAIL 5**, all five caused by the runner (Finding 1) |
| VM runner after fixing the runner | **PASS 33, FAIL 0** |
| Phase 2 regression with the Phase 3 code | Restore drill **PASSED**; FI-10 reboot **PASS 7, FAIL 0** with no workaround |
| Phase 3 exit gate (unit and security tests pass) | **Met** |
| Findings | 1 runner bug (fixed), 1 open item from Phase 2 |

## Environment

| Item | Value |
|---|---|
| Date (UTC) | 2026-11-09 |
| Host | `user-1`, disposable Proxmox VM over Tailscale; snapshot taken by the user after Phase 2 |
| OS | Ubuntu 22.04.5 LTS |
| Starting state | End of the Phase 2 test, plus `setup/fix-firstboot-run-once.sh` applied |
| Code under test | `feat/update-validation-approval`: Phase 3 commit `3192b35` merged with `main` at `d3d92e5` (first-boot fix, Phases 1 and 2), copied to `/root/pinpoint-phase3/` in the `scripts/build.sh` layout; runner run with `PINPOINT_MODULE_DIR=/root/pinpoint-phase3` |
| Tester | Claude Code, over SSH |

## 1. VM runner (after the runner fix)

`sudo PINPOINT_MODULE_DIR=/root/pinpoint-phase3 ./update-approval-tests.sh`

```
A01|PASS|configure-monitoring-updates.sh installed the Update Manager
A02|PASS|Groups pinpoint-update-admins and pinpoint-update-viewers exist
A03|PASS|/etc/sudoers.d/pinpoint-update is root:root 440 and valid
A04|PASS|First sudo member user-1 is an update admin
A05|PASS|Running the module again does not re-add a removed admin
A06|PASS|Viewer may list manifests (exit 0)
A07|PASS|Viewer may run the gate (exit 0)
A08|PASS|Viewer may not approve (exit 3)
A09|PASS|The refused approval is audited with the viewer as actor
A10|PASS|A user in neither group cannot start the program through sudo
A11|PASS|No approval was recorded by the refused calls
A12|PASS|Untested manifest is refused by the program (exit 4)
A13|PASS|Confirmation must match (exit 2)
A14|PASS|Path-like manifest ID is refused (exit 2)
A15|PASS|Admin approves pp-mon-t261109200026-1 (exit 0)
A16|PASS|Approval bound to approver and source state; transaction txn-20261109200029-fe9b5c is approved
A17|PASS|A drill is BUSY while an approved update waits
A18|PASS|Viewer may not cancel (exit 3)
A19|PASS|Admin cancels the approved transaction (exit 0)
A20|PASS|Transaction cancelled and approval revoked
A21|PASS|Admin defers with a reason and review date (exit 0)
A22|PASS|Admin declines with a reason (exit 0)
A23|PASS|Admin approves pp-mon-t261109200026-3 (exit 0)
A24|PASS|Revoking the manifest revokes the approval and cancels its transaction
A25|PASS|A revoked manifest cannot be approved again (exit 4)
A26|PASS|An edited manifest is refused and audited
A27|PASS|A world-writable manifest is refused
A28|PASS|A manifest not owned by root is refused
A29|PASS|Neither refused manifest was recorded
A30|PASS|Audit chain intact
A31|PASS|Newest audit row is copied to /var/log/pinpoint-update.log
A32|PASS|Newest audit row is copied to the journal
A33|PASS|status --json prints one pinpoint-update/v1 object
PASS 33, FAIL 0
```

After the run only `pp-mon-baseline-1.json` is left in the manifest folder and the test users are
removed. Their rows stay in the update database, as the runner header says.

## 2. First run and what was wrong with the runner

The first run gave A09, A20, A24, A25 and A26 as FAIL. Before the runner was changed, each was
checked by hand against the database and by repeating the scenario with fresh manifests:

| Case | First run | Checked by hand |
|---|---|---|
| A09 | FAIL | PASS: audit rows 144 and 149 are `auth.refused` with actor `pp-test-viewer` |
| A11 | PASS (meaningless, see below) | PASS: two `approval.created` rows, both by `pp-test-admin`; none by the viewer. The other approval rows for that manifest are the deferral and the decline, which are stored in the same table |
| A20 | FAIL | PASS: the cancelled transaction is `cancelled`, its approval `revoked` |
| A24 | FAIL | PASS: with a correct `revoked.json`, the approval became `revoked` and its transaction `cancelled` |
| A25 | FAIL | PASS: `BLOCKED: ... was revoked on ...`, exit 4 |
| A26 | FAIL | PASS: `REFUSED ...: changed after it was recorded; a changed manifest needs a new manifest_id`, one `manifest.changed` audit row (not repeated by a second `list`) |
| A29 | PASS (meaningless, see below) | PASS: neither refused manifest is in the `manifest` table, while the same query finds the 3 accepted test manifests |

## 3. Phase 2 regression with the Phase 3 code

Phase 3 changes `pinpoint-update-exec.py`, so the recovery path was run again on the appliance.

| Check | Result |
|---|---|
| `pinpoint-update-exec drill --yes` (no fault) | **PASS**: `DRILL PASSED`, recovery point 0.7 s, downtime 245 s, nagios and pinpoint-gunicorn active |
| FI-10: interrupted change, then a real reboot, **no workaround** | **PASS 7, FAIL 0** (R20 to R26). The first-boot installer was skipped (`ConditionResult=no`, first-boot log still shows 2 runs); files were restored before Nagios started |

## Findings

1. **Runner bugs in `tests/update-approval-tests.sh` (fixed on this branch).**
   - The checks run `sql` inside `bash -c`, which does not see shell functions that are not exported.
     A09, A20, A24 and A26 therefore always failed, and A11 and A29 (which expect empty output) always
     passed. Fix: `export DB` and `export -f sql` after the function.
   - `revoked.json` was written with `printf '...["$T-3"]...'` in single quotes, so it revoked a
     manifest literally called `$T-3`. A24 and A25 tested nothing. Fix: pass the ID as a `printf`
     argument.
2. **Still open from Phase 2:** `pinpoint-update-reconcile-finish.service` shows as failed after a
   successful boot-time rollback (exit 10). Seen again in this FI-10 run. Fix: `SuccessExitStatus=10`.
   The runner lock bug in `tests/update-recovery-tests.sh` (Phase 2 Finding 2) is also still open.

## Not tested

1. Install from an ISO built from this branch.
2. Scheduled windows (`approve --window-start/--window-end`), expiry after 14 days and the missed
   window are covered only by the portable tests (`test_schedule_window_is_checked_and_stored_in_utc`,
   `test_expired_approval_is_voided_and_its_txn_cancelled`, `test_missed_window`), not on the VM.
3. A `conditional` manifest with `--accept-limitations` on the VM (portable test
   `test_conditional_needs_explicit_acceptance` only).
