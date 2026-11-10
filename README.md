# Azure VM → Windows 365 Migration Workbench

A standalone **PowerShell 7 / WPF desktop application for Windows** that migrates an Azure VM's managed OS disk to Windows 365 using snapshot import. It connects directly to Azure and Microsoft Graph. No hosted service, MCP server or application-registration secret is required.

> **Controlled-pilot tooling, not a Microsoft-supported migration product.** The migration APIs use **Microsoft Graph beta**, which can change and is not supported for production application use. The tool stops the source VM, creates billable staging resources and can assign licenses. Use an approved test scope, a verified backup and an exclusive administration window.

## Status

**2026-11-10:** the operator reported completing a migration with the current migration-engine fixes, running staging cleanup and independently confirming through Graph that the user setting returned to `provisioningSourceType = image`. Earlier pilots also included operator checks of copied custom files and the retained computer name. These are pilot observations, not certification of every environment, application or recovery path.

The current revision includes persistence-fault blocking/recovery, directory-verified Cloud PC lookups, guarded clearing of obsolete pre-license PC observations, source-bound guest assessment, timezone-safe chronology, private local storage, bounded diagnostics and refreshed row-detail display. The known **license-reconciliation creation-time limitation remains**; see [security and recovery](docs/SECURITY-AND-RECOVERY.md#api-and-validation-limitations).

## Documentation

- [Complete operator guide](docs/OPERATOR-GUIDE.md) — every tab, button, phase and recovery action.
- [Simple button reference](docs/OPERATOR-GUIDE.md#simple-button-reference) — use alongside the app.
- [Security and recovery](docs/SECURITY-AND-RECOVERY.md) — storage, identity, persistence faults and API limitations.

## Start

### Requirements

- **Windows and PowerShell 7.2 or newer**, running in STA. The validated runtime is **PowerShell 7.6.9 on Windows ARM64**; the declared 7.2 minimum has not been runtime-tested. Windows PowerShell 5.1, Linux and macOS cannot run this WPF UI.
- PowerShell modules: **Az.Accounts, Az.Resources, Az.Compute, Az.Storage, Microsoft.Graph.Authentication**. Use **Check workstation prerequisites**, then **Install / update dependencies** if needed; installation is for CurrentUser. Restart the idle app after updating loaded modules.
- Organization-approved execution policy/script signing, appropriate administrative permissions and explicit Azure/Graph sign-in. No elevation or execution-policy bypass is requested.

Keep the seven runtime files together, open PowerShell 7 in the repository directory, and run:

```powershell
pwsh -NoProfile -STA -File .\Start-CpcMigration.ps1
```

Optionally lock the app to a tenant at startup (replace this example GUID):

```powershell
pwsh -NoProfile -STA -File .\Start-CpcMigration.ps1 -TenantId "22222222-2222-2222-2222-222222222222"
```

This locks tenant scope, **not authentication**. Detect subscriptions, explicitly select the intended subscription, then connect. It neither grants permissions nor bypasses consent/Conditional Access. Start a new instance to change a locked tenant.

The command-file launcher is intentionally omitted from this upload set. An existing repository launcher can remain alongside the script, but review it for hard-coded organization IDs before public use. The commands above do not depend on it.

## Supported scope and deliberate restrictions

- **Windows 365 Enterprise, Commercial cloud, non-GPU**, with the implemented **CloudPC Lite / CloudPC_AddOn** selection exception (2 vCPU / 4 GB / 128 GB). Lite selection is not certification of migration eligibility; verify service-specific entitlements.
- Source and target users in the **same tenant**; source, staging and snapshot destination in **one explicitly selected Azure subscription per batch**.
- **Gen2 persistent managed Windows client OS disks**. No Windows Server, multi-session, attached data disks, ephemeral OS disks, Confidential VMs, customer-key disk encryption, guest BitLocker/Azure Disk Encryption, or Entra-protected/private-only disk exports. These are this application's restrictions, not a permanent product-support statement.
- Source Entra joined or hybrid joined to the same tenant. Hybrid domain readiness, supported Windows servicing, bootability and complete application/agent compatibility require independent review.
- Existing dedicated Enterprise provisioning policy and an existing group containing **exactly the mapped users as direct members**. Nested, dynamic, synced, license-bearing, unrelated-member and unsupported assignment scopes are blocked. New plans do not change group membership or provisioning-policy assignments.
- Existing **Storage/StorageV2** staging account, **private container**, public network endpoint enabled and default network action **Allow**. Public endpoint access does not mean anonymous blob access. The app does not open firewalls or create the account/container/network/resource group.
- **Trusted Launch** requires the installed `Grant-AzSnapshotAccess` command to expose `-SecureVMGuestStateSAS`; the corresponding VMGS must be exported, copied and imported with the OS disk. Missing capability blocks rather than falling back to OS-only import.
- Source provisioned disk capacity must fit the selected license; used disk space is not the comparison. Available license seats are rechecked, not reserved. Unsupported/unresolved SKUs are excluded.

The source is not generalized with Sysprep, restarted automatically or deleted by this tool. Prefer small reviewed batches and avoid dual-active endpoints with copied identities.

## Permissions and existing infrastructure

### Microsoft Graph / Entra

The app requests these **delegated scopes**, using process-scoped authentication:

| Scope | Purpose |
|---|---|
| `CloudPC.ReadWrite.All` | Cloud PC/policy reads, user-setting changes, snapshot import/purge |
| `User.Read.All` | User identity, license and membership reads |
| `Group.ReadWrite.All` | Group scope reads; write permission retained for legacy app-owned-group recovery |
| `LicenseAssignment.ReadWrite.All` | Assign the selected license after successful import |
| `Organization.Read.All` | Subscribed SKU inventory |

Consent is not an administrator role. Review the signed-in user's Windows 365/Intune, group-management and license-assignment roles with the identity administrator. PIM and Conditional Access remain in force. New existing-group plans do not write group membership/policy assignments; legacy owned-group plans have different recovery behavior.

### Azure

Use reviewed, scoped roles for:

- Subscription/resource enumeration; VM/disk/snapshot reads.
- VM deallocation and **Run Command** for guest assessment. The guest inspection is read-only, but Azure Run Command is a privileged control-plane action executed as SYSTEM.
- Managed snapshot creation, export grant/revoke and optional cleanup deletion in the selected destination resource group.
- Staging container/blob reads, writes and optional cleanup deletion.
- `Microsoft.Storage/storageAccounts/blobServices/generateUserDelegationKey/action` at storage-account scope or above. **Storage Blob Data Contributor at account scope** is one practical option; container-only data rights still need an account-scope delegation-key grant.
- Current-caller permission reads for prerequisite checks.

The app does not grant itself roles. Its RBAC check is not proof that deny assignments, locks, ABAC conditions, immutability or service capacity will allow an operation. Review the provisioning policy, network/ANC, licensing and Windows/Intune/Entra prerequisites before use.

## Normal migration

**Use checkboxes select operation targets; highlighting only inspects a row.** Prepare requires the whole existing-group batch selected. Repair and Use images affect the whole batch regardless of checkboxes.

1. **Connect and discover.** Enter tenant, detect/select subscription, connect Azure + Graph, discover resources. Select policy, license, staging account/container and snapshot resource group.
2. **Map.** Check source VMs, enter unique target UPNs, find/select their existing policy group, then create the draft. Review full resource IDs and hidden checked rows.
3. **Assess guest → Attest prerequisites → Validate prerequisites → Prepare snapshot provisioning.** Resolve failures first. Guest evidence is bound to the VM instance and OS disk. Reassess after pre-capture guest fixes. Prepare creates the snapshot user setting or safely reuses a compatible one under the documented ownership checks; it does not license users.
4. **Validate again → Stop + capture → Refresh until Staged.** Approve backup, sign-out, outage and write-freeze. The source remains stopped. Refresh verifies OS/VMGS copies and revokes Azure snapshot export when complete.
5. **Validate again → Import to W365 → Refresh until Imported.** Requires `succeeded` and `notUsed`. Do not repeat import because it is slow or its outcome is uncertain.
6. **Validate again → Start migration / assign license → Refresh until Provisioned.** Licensing occurs only after fresh successful import checks. No automatic license removal or provisioning retry.
7. **Sign in and verify the actual Cloud PC → Validate cutover (final).** Confirm the intended user, migrated profile/files/apps, enrollment/network and acceptance. A service status or VHD footer checksum does not prove complete restored-data integrity.
8. **Cleanup staging when retention permits.** Deletes owned Azure staging blobs and managed snapshots, not the source VM, Cloud PC or journal. Interrupted cleanup uses CleanupPending and fresh ownership checks.
9. **Use images for future reprovision.** After all rows are Validated/Cleaned/safely Abandoned, switch the dedicated setting back to `image` **before changing group membership**. Read-back must succeed; allow propagation. Existing Cloud PCs remain unchanged and retain their policy membership.

Each Prepare/Capture/Import/License action needs a **stage-specific, single-use, 30-minute validation approval**. Approvals are not saved. Refresh/auto-refresh monitor work; they never start the next migration stage automatically. **Stop after current step** is cooperative, not rollback; current calls and cloud work may continue.

### Verify the image setting

In Graph Explorer, use the saved plan's **UserSettingId** (not a user or group ID):

```http
GET https://graph.microsoft.com/beta/deviceManagement/virtualEndpoint/userSettings/{UserSettingId}?$expand=assignments
```

Confirm `provisioningSourceType` is `image` and the assignment still targets the intended group. The setting's name may still start with `Snapshot-`; this action does not rename it. A later **Reprovision** is a separate destructive rebuild, not restoration of the migrated snapshot.

## Resuming and recovery

Connect in a fresh session → load the **original trusted journal** → check the intended rows → **Refresh status first** → follow **NEXT STEP**. Load clears attestation/approval, not historical ownership. Do not recreate a plan or repeat completed capture/import/license actions. Code updates apply on the next launch; do not interrupt active work to obtain an update.

- **Copying / Importing / Provisioning:** refresh and investigate errors; do not submit the stage again.
- **ImportUnknown / LicenseUnknown / PurgeUnknown:** preserve evidence and establish the actual service outcome. An absent result does not prove that the mutation failed. License reconciliation has the documented creation-time limitation; do not bypass it by editing a journal or reassigning the license.
- **Historical import 404:** only narrowly matching post-license evidence permits a warning. Permission/transient/identity failures stay blocking. Final acceptance still needs independent guest checks.
- **Persistence fault:** fix local storage/access, use **Restore journal writes**, then Refresh/revalidate. This does not replay cloud requests or undo accepted operations.
- **Provisioning failure:** investigate the service error. The script has no Retry provisioning button. Intune Retry and destructive Reprovision are different actions; imported-snapshot reuse is not guaranteed for every retry scenario.

### Safe reset/abandon boundaries

Reset/abandon are guarded **pre-license** recovery, not rollback of a provisioned Cloud PC. They require no live/unknown import, W365 entitlement or Cloud PC, and verified terminal owned artifacts. Purge a known terminal unused import first when applicable. Pending copies, unknown ownership, missing required evidence and inaccessible reads block deletion. Reset never restarts the source. Interrupted reset/abandon must continue the same action with its durable approval.

Keep completed journals and their audit sidecars. Eligible archive is a reversible local move, not cloud cleanup or permanent deletion. Retained all-Cleaned/Abandoned predecessor plans can support an explicitly approved new cycle; unfinished overlap blocks mapping. Deleting evidence is not permission to remigrate.

## Local data and security

- Startup creates a session log and automatic recovery journal in **LocalAppData → CpcMigration → data**. Save/export pickers start there too. No Documents/shared-folder fallback or elevation request.
- New directories restrict access to the executing user, SYSTEM and local Administrators. Existing destinations must already meet privacy/owner rules. Network paths, reparse points and unsafe ACLs are rejected; permissions are not silently repaired.
- Journals retain necessary plan/ownership evidence; **do not commit them to GitHub**. Successful Graph bodies are transient, not diagnostic history. Graph history contains masked request summaries and bounded redacted errors; use a deliberate authorized Graph query when actual response fields are needed.
- Session logs rotate at **5 MiB, current plus three backups**; audit sidecars have one backup. Diagnostic records are bounded to 64 KiB. Journals/reports are separate sensitive evidence, not anonymized or size-bounded logs.
- Locks cover the local workstation/user, not distributed administrators. SAS/token redaction is not encryption or a guarantee against arbitrary sensitive text. Keep backups, exclusive administration and organization retention controls.

See [security and recovery](docs/SECURITY-AND-RECOVERY.md) before operating or sharing diagnostic evidence.

## Files in this upload set

| Files | Purpose |
|---|---|
| [Start-CpcMigration.ps1](Start-CpcMigration.ps1) | WPF launcher, worker dispatch and offline UI smoke tests |
| [CpcMigration.Core.psm1](CpcMigration.Core.psm1) | Migration engine, Graph/Azure operations and persistence |
| [CpcMigration.Workflow.psm1](CpcMigration.Workflow.psm1) | Stage/action gates and resume discovery |
| [CpcMigration.Confirmation.psm1](CpcMigration.Confirmation.psm1) | Scope/risk/confirmation and result dialogs |
| [CpcMigration.Journals.psm1](CpcMigration.Journals.psm1) | Journal inventory and guarded archive |
| [CpcMigration.xaml](CpcMigration.xaml), [CpcMigration.Journals.xaml](CpcMigration.Journals.xaml) | Main and journal-manager layouts |
| [tests](tests/Test-Package.ps1) | Offline application regressions and package validation |
| [package-manifest.json](package-manifest.json) | Explicit upload allowlist; excludes the separately held launcher |
| [.gitignore](.gitignore) | Excludes generated evidence, archives and local workspace files |

Upload the **contents** of this folder to the repository root. Do not add its parent workspace, operational data or internal review history. This set contains no internal handoff/review documents or personal workspace tasks. It does not choose a license for you; retain or select the repository's license through the appropriate owner/approval process.

## Offline validation

Run each command as a **fresh process** from the repository directory. Application tests use synthetic fixtures/cloud mocks; smoke tests do not authenticate. They create isolated temporary files and, for rendered tests, briefly display WPF windows.

```powershell
pwsh -NoProfile -File .\tests\Test-Package.ps1
pwsh -NoProfile -File .\tests\Test-Offline.ps1
pwsh -NoProfile -File .\tests\Test-Recovery.ps1
pwsh -NoProfile -File .\tests\Test-Logging.ps1
pwsh -NoProfile -File .\tests\Test-Workflow.ps1
pwsh -NoProfile -STA -File .\tests\Test-Journals.ps1 -Render
pwsh -NoProfile -STA -File .\Start-CpcMigration.ps1 -SmokeTest
pwsh -NoProfile -STA -File .\Start-CpcMigration.ps1 -SmokeTest -TenantId "22222222-2222-2222-2222-222222222222"
```

The package check validates the allowlisted files, staged hashes and local Markdown file/heading links. `-Strict` additionally rejects extra files in a clean upload folder; omit it in a repository that intentionally also contains the existing launcher/license. It is not a general secret scanner or proof of the contents of a remote repository.

**Upload-set validation, 2026-11-10:** 1,299 application checks passed (197 offline + 319 recovery + 38 logging + 644 workflow + 101 journal/render checks). Both main-window smoke variants passed. The strict package check passed 172 checks across 18 files, including local heading links. Runtime files and the five application test scripts match the tested working copies byte-for-byte; the package validator and publication documentation are specific to this upload set.

Offline tests cover state/identity/approval/persistence/privacy/recovery and UI behavior. They do not certify live service compatibility, bootability, file integrity or every recovery path. PowerShell 7.2 and broader multi-VM/network/join/security configurations still need separate validation.

## Public references

- [Migration to Windows 365](https://learn.microsoft.com/en-us/windows-365/enterprise/migration-to-windows365)
- [Windows 365 requirements](https://learn.microsoft.com/en-us/windows-365/enterprise/requirements)
- [Graph snapshot import contract](https://learn.microsoft.com/en-us/graph/api/cloudpcsnapshot-importsnapshot?view=graph-rest-beta)
- [Cloud PC beta resource](https://learn.microsoft.com/en-us/graph/api/resources/cloudpc?view=graph-rest-beta)
- [Cloud PC user-setting resource](https://learn.microsoft.com/en-us/graph/api/resources/cloudpcusersetting?view=graph-rest-beta)
- [Microsoft Graph beta support policy](https://learn.microsoft.com/en-us/graph/use-the-api#version)