# Project status and new-session handoff

**Last updated: 2026-09-22, after repeat-migration-cycle support, predecessor-journal verification and the full offline regression run.**

This is the current development checkpoint. Read it with [README](../README.md) and the [operator guide](../docs/OPERATOR-GUIDE.md). Older review documents contain historical test counts and statements that were true at their review date, not necessarily now. This document is not a migration journal or live cloud inventory.

**Documentation layout:** the administrator-only [docs index](../docs/README.md) explains the tool and its operation. This folder contains assistant/developer continuity, engineering reviews and API research; see the [development index](README.md). The four development documents were moved here from docs on 2026-09-17; use the new paths below.

## Start a new assistant session

Open the same workspace and paste:

> Read project-status/PROJECT-STATUS.md, README.md and the relevant source/tests before continuing. This is the standalone PowerShell 7/WPF Azure VM → Windows 365 migration workbench; no MCP server is required. The pilot is completed and its user setting was confirmed as image. Its local logs/journals were deleted at the operator's request for handover, so it cannot be resumed here. Do not repeat migration operations or change cloud resources/journals unless explicitly requested. Summarize the current checkpoint, then work on my next request: [describe the task].

Keep this document updated after meaningful fixes, test runs and live milestones. Do not rely on chat history or assistant memory being available in a new session.

## Where we are now

- **Implemented:** standalone desktop workbench with explicit tenant/subscription selection; source VM → user mapping; existing policy-group selection; guest assessment/manual attestation; stage-specific validation; snapshot capture/export/copy/import; delayed licensing; monitoring; final acceptance; guarded staging cleanup and recovery; durable logs/journals and journal manager.
- **Pilot:** operator reported successful provisioning and working migrated environment. Before disposal, the journal recorded **VMs001 / Cleaned**, **CloudPcStatus / provisioned**, acceptance at **14:44:17 UTC**, and no last error. This is historical evidence summarized here, not a currently available journal or independent certification of every migrated file/app or every supported environment.
- **Use images fix: live verified.** At **15:17:42 UTC**, recorded Graph responses showed the existing setting change from `snapshot` to `image`, with the same setting ID, name and group assignment; local-admin/reset flags stayed false. No further UseImage retry is needed for this pilot. This read-back does not measure assignment propagation to every consumer.
- **Local cleanup:** nine eligible journals (six empty startup, two unused drafts, one completed plan) and audit sidecars were initially archived at **15:19:58 UTC**; nine stale adjacent journal locks were removed. Later, the operator confirmed testing was finished and requested a clean colleague handover. With the app closed and files checked for exclusive access, all nine logs and all archive contents were deleted: **27 files, 603.87 MiB**. The archive folder remains empty. No cloud resources or global per-plan lock files were changed.
- **Same-group setting reuse and Repair idempotency:** a later approved migration can reuse the single compatible tool-created setting assigned directly and exclusively to the selected existing group. Prepare changes `image` back to `snapshot`, or verifies an existing `snapshot` setting without another PATCH. Repair now performs no Graph write when fresh reads show snapshot mode and the exact required assignment are already correct, reports a Pass check, and preserves existing attestation/readiness evidence.
- **Repeat migration cycles:** implemented an explicit, default-No path for intentionally remigrating a source VM when every row of every overlapping retained prior plan is already `Cleaned` or `Abandoned`. Unfinished overlap still hard-stops and directs the operator to resume the original journal. Historical journals are preserved and linked into the new plan as verified predecessors; current cloud safety checks are not bypassed.
- **Current task at handoff:** repeat-cycle implementation and documentation are complete and locally validated. No pending authorized deployment, cloud cleanup, provisioning retry, migration replay or group-membership change.

## Completed pilot and recovery history

**Local pilot journals, audit sidecars and session logs have been deleted, not merely archived.** No backup was created by this cleanup. The historical observations below were recorded before disposal and cannot be independently rechecked against those local files. This cleanup does not delete the migrated Cloud PC or reset tenant configuration.

The identifiers below are internal historical context, not defaults for the next tester. Protect this document appropriately; this handover is not a fully anonymized public-release package.

| Item | Pilot value |
|---|---|
| Tenant | 8bc60b89-006a-432f-92f2-32d9f7317197 |
| Subscription | 1b56c766-df00-46de-b38c-89bd97de67a1 — Microsoft Azure Sponsorship 2 |
| Plan | d1d16c0a-1d87-48f0-bf55-46eaa048d487 |
| Source | VMs001, VMMIGRATION, northeurope |
| Group | VMMigrate — 45194ad9-2c01-4db7-9ce9-0f4f0a0da430 |
| Provisioning policy | Marius_MSHostedNetwork — be55b054-db43-4f50-8183-51f9941bf51c |
| User setting | e3316700-c316-4f2a-bc82-07b30f69692d; name remains Snapshot-d1d16c0a-1d87-48f0-bf55-46eaa048d487 even though source is now image |
| Cloud PC | 7ec6639d-40d1-4ca8-9420-ab9fcb2fd041 |

**Do not try to resume or reconstruct this completed pilot:** its local recovery evidence is no longer available. Deletion also removes this workspace's archived duplicate-plan evidence; it is not permission to remigrate the same source/user. For colleague testing, use a separately approved test scope and review existing cloud state first. A new launch creates a new empty startup journal/log automatically; that is expected.

The existing **Launch CPC Migration UI - specified tenant** VS Code task in [task configuration](../.vscode/tasks.json) uses the tenant above and PowerShell STA. Launch only on request. Loading/resuming the completed plan is not necessary merely to continue editing code.

## Architecture and file map

| File | Responsibility |
|---|---|
| [Start-CpcMigration.ps1](../Start-CpcMigration.ps1) | WPF startup, persistent STA worker runspace, one operation at a time, result processing, timer/modal guards and UI smoke test |
| [CpcMigration.xaml](../CpcMigration.xaml) | Six-tab main window and controls |
| [CpcMigration.Core.psm1](../CpcMigration.Core.psm1) | Azure/Graph operations, state machine, prerequisites, single-use approvals, ownership/recovery checks, journals and logs; entry point `Invoke-CpcOperation` |
| [CpcMigration.Workflow.psm1](../CpcMigration.Workflow.psm1) | Read-only button eligibility, next-step hints, refresh-first resume gate and journal overlap discovery |
| [CpcMigration.Confirmation.psm1](../CpcMigration.Confirmation.psm1) | Confirmations, result dialogs, scope/evidence and remediation text |
| [CpcMigration.Journals.psm1](../CpcMigration.Journals.psm1) / [CpcMigration.Journals.xaml](../CpcMigration.Journals.xaml) | Journal inventory, guarded reversible archive and manager window |
| [Launch-CpcMigration.cmd](../Launch-CpcMigration.cmd) | Desktop launcher |
| [Administrator operator guide](../docs/OPERATOR-GUIDE.md) | Every control/input, simple purpose/when tables, phases and recovery instructions |
| [SOURCES.md](SOURCES.md) | Public API contracts, references and observed discrepancies |
| [WORKFLOW-SAFETY-REVIEW.md](WORKFLOW-SAFETY-REVIEW.md) / [PROJECT-REVIEW.md](PROJECT-REVIEW.md) | Historical engineering reviews; not the latest status |

## Recent fixes that must be preserved

1. **Graph import identity mismatch:** beta sometimes returns an Entra user object GUID in `assignedUserPrincipalName`. `Test-CpcImportUserIdentity` accepts only the exact journal UPN or nonzero GUID equal to journal UserId. It rejects foreign/missing identities. Used consistently in refresh, validation, license, purge and reconcile paths. Never weaken this to matching filename alone.
2. **Graph error evidence:** `Get-CpcGraphFailureDetail` extracts SDK ErrorDetails, ResponseContent or HttpContent. Secrets are redacted before the 12KB bound. Failures reach Dashboard, result error and durable logs. `Write-CpcAudit` already forwards to the session log; avoid duplicate records. PATCH/POST are not automatically retried.
3. **UseImage HTTP 400:** a source-only PATCH returned `requiredFieldsNotProvided`. `New-CpcUserSettingSourceBody` now carries forward live displayName/localAdminEnabled/resetEnabled and supported non-null restore/DR settings, plus the desired source and entity type. Missing required fields block rather than guessing. GET metadata, assignments and deprecated properties are not echoed. Both UseImage and snapshot repair use this helper. UseImage requires fresh GET confirmation of image/ownership/exact assignment; already-image skips PATCH. Corrected UseImage was accepted in the live pilot; repair-path service acceptance was not independently live-tested.
4. **UI/workflow safeguards:** modal/timer reentrancy prevented; loaded rows require successful Refresh before further actions; guest evidence frozen after capture; unknown import/license outcomes use explicit reconciliation, not write replay. Reconciliation inputs clear when their selected scope changes.
5. **Existing group versus legacy plans:** new plans select an existing group and do not change its membership or provisioning-policy assignments. The legacy repair branch for old app-owned groups can restore membership/policy assignments. Do not incorrectly describe or refactor both branches as identical.
6. **Reusable snapshot setting:** preflight accepts only one compatible tool-created `Snapshot-<plan-guid>` setting assigned directly and solely to the exact selected group. It records the ID, name and current source. Prepare rereads and matches that evidence before adoption, does not create a second setting or assignment, changes `image` to `snapshot` using the complete required-field body, and confirms source/assignment by read-back. Already-`snapshot` reuse submits no PATCH. Reuse requires explicit operator confirmation that earlier work is complete/safely abandoned and its journal is intentionally unavailable; multiple, inherited, renamed, multi-target or changed settings remain blocked. This lost-journal exception does not establish repeat-cycle history by itself.
7. **Idempotent snapshot Repair:** for selected existing-group plans, Repair validates live membership/policy/setting scope first. If source is already `snapshot` and the exact direct group assignment is present, it records `Snapshot setting repair / Pass`, writes a no-repair activity entry, submits no Graph mutation and leaves attestation/readiness unchanged. An actual required setting/assignment repair still clears stale evidence and requires renewed attestation and validation. Legacy app-owned-group behavior remains separate.
8. **Intentional repeat-cycle history:** `Find-CpcResumeJournals` classifies an overlapping plan as `NewCycleEligible` only when its entire batch is terminal (`Cleaned`/`Abandoned`) and returns a SHA-256 fingerprint. `Start-CpcMigration.ps1` separates unfinished overlap from eligible history, shows a dedicated default-No confirmation and passes predecessor plan/path/fingerprint evidence into Map. `Set-CpcMappings` independently reopens each predecessor and verifies file availability, size/reparse-point policy, SHA-256, JSON schema, plan ID, tenant, subscription, all-row terminal state and selected-source overlap before saving. Conflicting copies of one plan are rejected. The new journal persists `Predecessors`; load and operation output restore/expose them. Prior journals are never edited or deleted by this flow, and all live Cloud PC/import/license/setting/group/artifact checks remain in force.

### Repeat-cycle files changed on 2026-09-22

| File | Change |
|---|---|
| [CpcMigration.Workflow.psm1](../CpcMigration.Workflow.psm1) | Journal-overlap results now include `NewCycleEligible` and SHA-256 `Fingerprint`; a mixed batch remains ineligible if even one row is unfinished. |
| [Start-CpcMigration.ps1](../Start-CpcMigration.ps1) | Added `Confirm-NewMigrationCycle`; unfinished overlap blocks, eligible terminal overlap prompts with No as the safe default, and confirmed references are sent as `Predecessors`. Operation reviews show prior cycles. |
| [CpcMigration.Core.psm1](../CpcMigration.Core.psm1) | Added predecessor state persistence, authoritative journal revalidation before Map, restoration on Load and inclusion in operation output. |
| [tests/Test-Workflow.ps1](../tests/Test-Workflow.ps1) | Added all-terminal eligibility and mixed-batch fail-closed coverage. |
| [tests/Test-Offline.ps1](../tests/Test-Offline.ps1) | Added healthy Repair no-write/evidence-preservation, image-to-snapshot reuse, already-snapshot no-write reuse, accepted terminal predecessor, unchanged historical journal, changed fingerprint, unfinished plan, wrong scope and missing-source-overlap cases. |
| [README.md](../README.md) / [operator guide](../docs/OPERATOR-GUIDE.md) | Documented the prompt, terminal-only rule, preserved evidence, core revalidation and unchanged cloud gates. |

The deleted 2026-09-17 pilot journal cannot participate in this mechanism. Therefore, this workspace cannot use the new predecessor confirmation to authorize another cycle of that pilot. The feature applies when trustworthy prior journals are retained and discovered; deletion of history is not an approval signal.

## Validation checkpoint

Environment used: Windows ARM64, **PowerShell 7.6.6**, WPF STA; minimum supported PowerShell version is 7.2. Installed test environment included Az.Accounts 5.5.3, Az.Resources 10.2.1, Az.Compute 11.9.0, Az.Storage 9.7.2, Microsoft.Graph.Authentication 2.40.0 and PSScriptAnalyzer 1.25.0. Verify local versions before diagnosing a new environment. No Git repository was initialized during this work.

Run each test script in a fresh PowerShell process with `-NoProfile -File`; do not substitute live cloud operations for offline fixtures.

| Test/check | Last observed result |
|---|---|
| [tests/Test-Workflow.ps1](../tests/Test-Workflow.ps1) | **626 passed**; includes terminal/mixed predecessor classification; no cloud calls |
| [tests/Test-Offline.ps1](../tests/Test-Offline.ps1) | **196 passed**; includes predecessor acceptance, persistence and five fail-closed/evidence checks; no live migration |
| [tests/Test-Recovery.ps1](../tests/Test-Recovery.ps1) | **224 passed**, zero failed/skipped and zero live calls; core SHA-256 unchanged during the suite |
| [tests/Test-Logging.ps1](../tests/Test-Logging.ps1) | **18 passed**, zero failed |
| [tests/Test-Journals.ps1](../tests/Test-Journals.ps1) | **91 passed**; no cloud calls or real journal changes. The earlier manager-render checkpoint remains historical; this run did not use `-Render`. |
| Combined script checks | **1,155 passed** (`626 + 196 + 224 + 18 + 91`) |
| Main launcher with `-STA -SmokeTest` | Constructed/rendered successfully; no cloud calls |
| Main launcher with `-STA -SmokeTest -TenantId 8bc60b89-006a-432f-92f2-32d9f7317197` | Constructed/rendered successfully with locked tenant; no cloud calls |
| All `*.ps1` / `*.psm1` parser check | Passed |
| Touched-file VS Code diagnostics | Zero errors in core, workflow, launcher, repeat-cycle tests and updated administrator docs |
| Operator documentation inventory | All 64 named interactive controls documented; all 38 named buttons also covered by simple purpose/when tables |

These are dated checkpoints, not a claim that tests have run in the next session. The archive manager checked fingerprints under locks before moving journals; do not claim a separate completed post-move hash audit from the prior chat's interrupted verification command.

## Guardrails for future work

- **Standalone/direct Azure + Graph; no MCP server dependency.** All migration Graph APIs are beta; controlled recoverable pilot, not production certification.
- Same tenant, explicit subscription, Commercial cloud; dedicated Enterprise/Lite policy/license restrictions. No unsupported Frontline/shared/Business/GPU shortcut.
- Every major stage needs its own explicit, fingerprint-bound, **single-use 30-minute** preflight approval. Approvals are memory-only. Guest/manual attestation is not automated validation, and final cutover acceptance is a separate user decision.
- Source deallocation, export and staging are disruptive/sensitive. No automatic source restart, reprovision, license removal, group-member change or cloud cleanup on session resume.
- Preserve original journals/audit history during future active tests and according to the operator's retention policy. This completed pilot's disposal was explicitly requested; do not generalize it to unfinished migrations. Never edit phases or IDs to bypass guards. Reports are not resumable journals. Retained archived history participates in duplicate-plan protection; deleted history cannot.
- Path and plan locks protect the same workstation, **not distributed operators**. Exclusive admin coordination remains required. Do not mass-delete locks while an app/session may be running.
- Keep secrets/tokens/SAS out of documentation, persisted UI evidence and test fixtures. Logs still contain sensitive identifiers.
- GET-only bounded retries; no automatic mutation replay after ambiguous outcomes. There is no script Retry provisioning button; Intune Retry is distinct from destructive Reprovision.

## Remaining work / suggested next tasks

1. **UX clarity:** the generic result banner still says “OPERATION RETURNED … not a success declaration … Import/provisioning may still be running” even for verified UseImage. Improve it using action-specific, current-operation evidence; never label asynchronous submission as completed migration or infer success solely from an empty error.
2. Broader approved pilot coverage: other join/network/security configurations, multiple VMs, interruption/recovery paths and actual file/app acceptance. Offline mocks do not establish cloud behavior for every scenario.
3. Consider source control and a sanitized distributable package only when requested; never include pilot logs/journals or sensitive identifiers in a public release.
4. Keep the operator guide, API notes and this checkpoint synchronized with future fixes. Historical reviews should retain their dated context.
5. When testing repeat cycles, retain the original completed/abandoned journal and audit evidence. Verify the prompt identifies the intended plan/VM, then confirm only with separate approval for a genuinely new cycle. Never manufacture, edit or delete history to make a plan eligible.

**No further action on the completed pilot is required merely to resume assistant development work.**