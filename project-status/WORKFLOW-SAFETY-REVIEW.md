# Workflow safeguards review — 2026-09-17

## Addendum — 2026-09-22 repeat migration cycles

Intentional reuse of a source VM now has an explicit local-history path without weakening cloud validation:

- Journal discovery hashes each overlapping file and marks it eligible only when every row in the whole prior batch is `Cleaned` or `Abandoned`. A mixed or unfinished batch remains blocked even if the matching VM row itself is terminal.
- Mapping separates unfinished overlaps from eligible terminal history. Unfinished plans must be resumed. Eligible plans produce a dedicated default-No confirmation that explains a new cycle will preserve and reference history rather than delete it.
- UI confirmation is not trusted by itself. Core mapping rereads the exact bytes, verifies SHA-256, schema, plan ID, tenant/subscription, terminal state and selected source overlap, and rejects conflicting copies of one prior plan. A changed file, wrong scope or unrelated source fails before the new plan is saved.
- Verified predecessor evidence is persisted in the new journal and restored on load/output. Prior journals are not modified. The bypass applies only to local duplicate-history protection; Cloud PC, import, license, setting, group and artifact checks still run normally.
- The previously deleted pilot history remains unavailable and cannot be used as predecessor evidence. History deletion is never treated as terminal proof or permission to remigrate.

Regression checkpoint: **1,155 script checks passed** (626 workflow, 196 engine/offline, 224 recovery, 18 logging, 91 journals), both main-window smoke modes passed, all PowerShell files parsed, and touched-file diagnostics reported zero errors. Tests made no cloud calls or real journal changes.

The same development sequence also made user-setting reuse and Repair idempotent. Prepare may adopt only one compatible tool-created setting assigned directly and exclusively to the selected group; it switches `image` to `snapshot` or verifies existing `snapshot` mode without a write. Repair also submits no write when fresh live reads already show the required snapshot source and exact assignment, and it preserves valid attestation/readiness evidence in that no-op case. Changed, ambiguous or broader settings still fail closed, and real repairs still invalidate evidence.

Scope: Migration and recovery controls, selected-row/batch scope, confirmation dispatch, journal resume, status reporting and corresponding engine guards. Offline inspection and tests only; no real journals or cloud resources modified.

## Confirmed gaps addressed

| Gap | Fix |
|---|---|
| WPF modal dialogs pump Dispatcher callbacks while review is open. A completed worker could be processed again; auto-refresh could start during a pre-dispatch confirmation. | Nested modal-depth guard, separate completion-in-progress guard, guarded auto-refresh and dispatch. Revalidate action eligibility after confirmation returns. |
| Resume told the admin to refresh but did not enforce it. | Per-row session-only pending-refresh set. Only successful refreshed rows unlock; errors keep them blocked. Never persisted as approval. |
| Reconciliation phase enabled buttons with empty/wrong inputs; inputs could carry over between users. | Validate GUID/audit/time inputs; retain editable evidence fields; clear when plan/selection/phase changes; display recovery scope. |
| Backend LicenseUnknown still had an older inference path using a present SKU and current time. | Block ordinary preflight/license dispatch in LicenseUnknown. Retain explicit reviewed-audit reconciliation with live user/SKU/Cloud PC checks; never retry the write. |
| Guest backend checked only SnapshotId; attestation could partially change a mixed-stage batch. | Precheck all rows for allowed stages and frozen source identity; validate the full attestation selection before changing any row. |
| Copy detail was overwritten by the last artifact, often the small VMGS copy. | Label and retain both artifacts; require IDs and complete bytes before staging; require VMGS for Trusted Launch and successful revocation. |
| Earlier Ready/approval labels could survive advancement. | Clear stage readiness on forward transitions; clear obsolete preflight on status phase changes. |
| Error-only dialog said “0 failed checks”; Load text told users to reassess universally. | Separate operation errors from failed prerequisites; precise stage-specific next steps, no repeat attestation when already recorded, no reassessment of frozen sources. |

## Preserved safeguards

- No new-plan adoption or deletion of unrelated cloud settings.
- No repeated import/license writes after ambiguous outcomes.
- Confirmation and manual cutover acceptance remain mandatory.
- Existing-group membership and provisioning-policy assignments are not automatically changed.
- Recovery is separately confirmed and still checks ownership, pending copy state and absence of provisioning before destructive actions.
- Whole-batch repair/image actions include unchecked rows and are labelled accordingly.
- Journal manager retains exclusive path/plan locks, reversible archive and unfinished-plan protection.

## Validation

Verified after the fixes: **1,119 offline checks passed** (620 workflow, 187 engine/offline, 200 recovery, 14 logging, 98 journal-manager), journal-manager rendering and both main-window smoke modes passed, and PSScriptAnalyzer reported **0 errors**. Previously recorded stale editor diagnostics remain unrelated to current symbols.

- [Workflow matrix](../tests/Test-Workflow.ps1): phase actions, resume gate, selection scope, approval expiry and reconciliation input validation.
- [Offline engine tests](../tests/Test-Offline.ps1): explicit approval, live-check failures, configuration/ownership and unknown-license rejection.
- [Recovery tests](../tests/Test-Recovery.ps1): forbidden guest stages, mixed attestation, copy completion/error cases, successful-refresh output not persisted in rows, plus existing recovery/transaction tests.
- [Journal manager tests](../tests/Test-Journals.ps1) and [logging tests](../tests/Test-Logging.ps1) remain part of regression validation.
- [Rendered smoke tests](../Start-CpcMigration.ps1): real controls, resume-refresh gate, editable reconciliation fields, selection clearing, nested modal/dispatch guards and error heading; with and without locked tenant.

## Remaining operational boundaries

This is not certification of end-to-end migration or every remote API race. Live API behavior, permissions, eventual consistency, bootability and restored-data correctness still require pilot validation. Exclusive administration windows remain necessary: preflight reads cannot prevent a different administrator from changing cloud assignments afterward. Locks are local to the Windows user/workstation, not distributed. Journals are trusted recovery inputs, not tamper-proof evidence. Do not bypass a failed refresh or ambiguous outcome by editing a journal, deleting assignments or creating a new plan.