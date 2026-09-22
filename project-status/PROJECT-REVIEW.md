# Whole-project review

## Remediation update — 2026-09-17

The findings below are the **original audit**, retained for traceability; they no longer describe all current behavior. Implemented and covered by offline regressions:

- Membership casts now include the advanced-query header/count on every page.
- Mapping/loading use validated candidates; file and local plan-identity locks protect concurrent copies/Save As. Window shutdown explicitly releases locks. Journal writes flush before atomic replacement; failures preserve the old candidate state.
- Explicit read-only license reconciliation uses reviewed audit evidence, direct assignment, exact user/policy/Cloud PC and timestamps without needing a consumed import. No ambiguous license POST is repeated.
- Ownership-checked reset/abandon and restartable cleanup archive attempts, reject pending/unidentified copies and unknown/live imports, and never restart/delete a source. Purge ambiguity is persisted, not blindly retried.
- Optional startup `-TenantId` locks the UI/engine, Azure/Graph discovery/connection and journal scope to the selected organization.
- Explicit incompatible policy owner/experience values are rejected; durable redacted event sidecars and advisory elapsed-time/expiry warnings are added.
- Local modules updated: Az.Accounts 5.5.3, Az.Resources 10.2.1, Az.Compute 11.9.0, Az.Storage 9.7.2, Graph.Authentication 2.40.0. A fresh process confirmed VMGS export capability. PSScriptAnalyzer 1.25.0 installed for validation. Restart already-open app sessions before use.

Final local validation: **168 original-suite checks + 182 recovery checks passed (350 total)**. Rendered WPF smoke passed with and without startup tenant scope. PSScriptAnalyzer reported **zero errors**; remaining warnings include PowerShell naming/style, Unicode BOM recommendations, test-only unused parameters/output, and the application's custom confirmation rather than ShouldProcess. These results are not a claim of warning-free lint or live migration certification.

See [README recovery instructions](../README.md#recovery-and-security-behavior) and [new regression suite](../tests/Test-Recovery.ps1). Local tests do not establish live API access or migration success. Remaining deliberate boundaries: manual reconciliation for unidentified copies/ambiguous purge or object creation, cross-computer administrator coordination, operator data/boot/entitlement verification and an approved live pilot. No live cloud authentication or migration was performed during remediation.

## Verdict

**Not ready for an unattended or production migration.** The offline suite and WPF smoke test pass, but API-contract, workstation and recovery gaps remain. No application code was changed during this review. No Azure/Graph sign-in, resource reads or cloud mutations were performed; public documentation was fetched and all diagnostic reproductions used in-memory mocks.

## Checks performed

- Full workflow/source review: authentication and inventory, group selection and assignments, guest/preflight checks, capture/export/copy, import, licensing, monitoring, cleanup, journaling and UI orchestration.
- Reran [Test-Offline.ps1](../tests/Test-Offline.ps1): **167 assertions passed**, including PowerShell parsing.
- Reran the rendered WPF smoke test: **passed**.
- Checked editor diagnostics: Core, confirmation module, XAML and tests have no reported errors. Launcher still has three stale diagnostics referring to removed `Apply-Result`, `sender` and `eventArgs` symbols. These do not agree with the current source; parsing and execution pass. PSScriptAnalyzer is not installed, so this is not a clean independent analyzer run.
- Inspected actual installed modules/cmdlet signatures without authenticating: Az.Accounts 5.3.0, Az.Resources 8.1.1, Az.Compute 10.2.0, Microsoft.Graph.Authentication 2.38.1. Az.Storage is absent. Installed Grant-AzSnapshotAccess does not expose SecureVMGuestStateSAS.
- Checked current public Graph policy, assignment, user-setting, import-result and directory-membership documentation.
- Ran isolated probes for membership request construction, consumed-import license recovery, rejected journal loading and invalid replacement mappings.

## Findings requiring attention before a live pilot

### 1. High — Directory membership requests omit required advanced-query options

[Group discovery](../CpcMigration.Core.psm1#L400) and other membership checks use `/memberOf/microsoft.graph.group` or `/transitiveMemberOf/microsoft.graph.group`, with `$select`. [The Graph wrapper](../CpcMigration.Core.psm1#L84) does not send `ConsistencyLevel: eventual`; the requests omit `$count=true`.

The [direct membership](https://learn.microsoft.com/en-us/graph/api/user-list-memberof?view=graph-rest-1.0#request-headers), [user transitive membership](https://learn.microsoft.com/en-us/graph/api/user-list-transitivememberof?view=graph-rest-1.0#request-headers), and [group transitive membership](https://learn.microsoft.com/en-us/graph/api/group-list-transitivememberof?view=graph-rest-1.0#request-headers) references require both for OData casts. This is a documented request-contract gap, not a claimed observed live HTTP failure. It can prevent finding groups and completing prerequisites in a real tenant.

**Probe:** captured the real wrapper's outgoing request through a mocked Invoke-MgGraphRequest: `HasEventualHeader=False`, `HasCountTrue=False`. Current tests stub these boundaries and therefore miss this.

**Action:** either implement the documented advanced-query contract (including headers on pagination) or retrieve uncast membership collections and filter object types locally. Account explicitly for eventual consistency in preflight.

### 2. High — Local dependencies cannot execute the intended capture workflow yet

Az.Storage is missing, which blocks the full connection/import of dependencies. Installed Az.Compute 10.2.0 lacks `Grant-AzSnapshotAccess -SecureVMGuestStateSAS`, blocking Trusted Launch export.

**Action:** use the app's explicit dependency update flow, restart, and rerun workstation checks. Do not infer cloud readiness from mock tests. No packages were installed during this audit.

### 3. High — Ambiguous-license recovery depends on an import that may already be deleted

[Start-CpcLicense](../CpcMigration.Core.psm1#L1204) executes preflight and live import/artifact checks before reaching its read-only already-assigned-license reconciliation. If assignLicense succeeded but its response was lost, the row becomes LicenseUnknown. By the next app session, provisioning may have consumed and removed the imported snapshot. Those earlier checks fail before the license can be reconciled.

**Probe:** LicenseUnknown + mocked missing consumed import leaves `Phase=LicenseUnknown`, with **zero user-license reads reached**. Update-CpcStatus can discover the Cloud PC, but cannot advance the row to Provisioned without LicenseAssignedUtc.

**Action:** add a separate read-only reconciliation path using the exact user/SKU, live Cloud PC identity/policy and available operation/audit evidence. It must not repeat the license POST or require an unused import after provisioning already happened. Keep the stricter import gate for genuinely new assignments.

### 4. High — Mapping and journal loading are not transactional

[Set-CpcMappings](../CpcMigration.Core.psm1#L455) replaces the live Config before Assert-CpcConfig succeeds. On invalid input, the dispatcher catch can save that invalid replacement config alongside the old rows.

[Load](../CpcMigration.Core.psm1#L1423) replaces live plan/config/group fields, then validates/adds rows incrementally. A later invalid row leaves the earlier rows and replacement plan identity active, even though Load reports failure.

**Probe:** a two-row mock journal with an out-of-scope second row produced `PlanChangedDespiteFailure=True`, `RowsRetainedDespiteFailure=1`. No real journal was read/written in the probe. Invalid replacement container input also reaches the error path after live config replacement.

**Action:** fully parse and validate a temporary candidate state, then commit all fields together. On failure preserve the old state and journal unchanged. Add disk-write-failure tests and an exclusive journal lock to prevent two instances overwriting the same journal.

## Additional important gaps / limitations

### Recovery from aborted migrations is incomplete

[CopyFailed has no next-stage transition](../CpcMigration.Core.psm1#L699); [staging cleanup](../CpcMigration.Core.psm1#L1275) requires Validated. Failed/abandoned captures and purged imports therefore lack a supported in-app retry/abort-cleanup path. This is safe against blind overwrites, but may leave billable artifacts and require manual Azure reconciliation. Crashes after snapshot deletion but before the Cleaned journal update also need idempotent recovery handling.

**Action:** define explicit reconcile/retry/abandon states and ownership-checked cleanup for failed attempts, without restarting sources or deleting artifacts potentially in use. Test crash points after every mutation.

### Policy service ownership is not checked

The picker and validation use `provisioningType=dedicated` as the Enterprise criterion. The [current policy resource](https://learn.microsoft.com/en-us/graph/api/resources/cloudpcprovisioningpolicy?view=graph-rest-beta#properties) also defines `managedBy` (windows365, devBox and others). The code does not reject an explicitly non-Windows365 owner. This is a validation gap; this review did not establish whether such policies are returned in the intended tenant.

**Action:** reject explicitly incompatible service owners and validate the expected desktop experience. Add realistic policy fixtures, including incompatible and unknown values.

### Operational evidence needs strengthening

- Logs and Graph request IDs are session-memory data until manual export; [Save-CpcState](../CpcMigration.Core.psm1#L57) does not persist them. A crash loses useful audit evidence. Persist redacted, bounded operation events before/after writes.
- Import/copy/provisioning monitoring lacks elapsed-time/SAS-expiry escalation warnings. A long-running phase should be distinguished from a recently started one without declaring failure or resubmitting automatically.
- The exact-membership requirement is intentionally conservative: a broad production group containing additional users cannot be used for a small migration batch. Use a dedicated existing policy-assigned group; do not remove this guard without an explicit whole-group impact design.
- New existing-group plans do not alter group membership or policy assignments. Legacy owned-group journals still use non-atomic policy assignment replacement and require an exclusive administrator window.
- Windows lifecycle/ESU, Lite entitlement/migration eligibility, full source-data integrity, bootability, network reachability and actual customer sign-in are not established by offline tests.

## Confirmed safeguards retained

- Explicit VM deallocation and verification before snapshot creation.
- Gen2, supported Windows client evidence, no attached data disks and live running-source VM-agent check.
- Trusted Launch VMGS export requirement and matched staged-copy validation.
- Stage-specific, expiring, single-use preflight receipts include configuration and identity scope; live checks rerun before major writes.
- Explicit existing-group choice, exact batch-only membership, Enterprise dedicated-policy assignment and conflict checks.
- Fresh succeeded/unused import checks before a new license assignment; no automatic mutation retries after ambiguous responses.
- Source VMs are never automatically restarted or deleted; cleanup is restricted to journal-owned artifacts.
- Historical import results are retained with a read-error indication so service cleanup does not stop independent Cloud PC monitoring. This alone does not bypass the fresh pre-license gates.

## Recommended order

1. Correct directory-membership request contracts and add request-level tests.
2. Make state loading/mapping transactional; add interrupted-write and shared-journal protection.
3. Implement consumed-import-safe license reconciliation and failed-attempt recovery.
4. Update local dependencies and rerun offline checks.
5. Run an approved, recoverable single-user pilot for standard Gen2 and Trusted Launch, including interruption/restart cases. Graph beta remains a controlled-pilot limitation, not production certification.