# Azure VM → Windows 365 Migration Workbench

A standalone **PowerShell 7 / WPF** desktop application. Connects directly to Azure and Microsoft Graph. **No MCP server, web server, Azure Function, app-registration secret, or hosted component is required.**

> **Controlled-pilot implementation, not a Microsoft-supported migration product.** The migration APIs are documented under **Microsoft Graph beta**. Microsoft states that beta APIs can change and are not supported for production application use. Validate tenant access and run an approved, recoverable pilot before considering broader use. Offline regression/UI tests have passed; on **2026-09-17**, the operator reported successful pilot provisioning and that everything was OK, with the UI showing **Cleaned** (recorded acceptance and staging cleanup). **This operator-reported pilot result is not independent certification of all data, environments or failure-recovery paths.**

## Operator documentation

**[Start with the simple button reference: what each button does and when to click it](OPERATOR-GUIDE.md#simple-button-reference).** It covers every tab and dialog without requiring the technical implementation details.

**[Complete operator guide — every tab, button, input and dialog](OPERATOR-GUIDE.md)** is the UI reference. It includes required values/examples, read-only displays, action effects, stage/selection restrictions, confirmations, journal management, recovery inputs and a resume playbook.

- [Connect/configure and destination inputs](OPERATOR-GUIDE.md#tab-1--connect--configure)
- [VM/user mapping and group selection](OPERATOR-GUIDE.md#tab-2--select--map)
- [Migration buttons, polling, journal/report toolbar and evidence](OPERATOR-GUIDE.md#tab-3--migration)
- [Prerequisite results](OPERATOR-GUIDE.md#tab-4--prerequisite-results)
- [Dashboard, Graph and every recovery control](OPERATOR-GUIDE.md#tab-5--dashboard--graph)
- [Activity log](OPERATOR-GUIDE.md#tab-6--activity-log), [saved journals](OPERATOR-GUIDE.md#saved-migration-journals-dialog) and [confirmation/file dialogs](OPERATOR-GUIDE.md#confirmation-result-and-file-dialogs)
- [Phase dictionary](OPERATOR-GUIDE.md#phase-dictionary-and-allowed-next-steps) and [resume playbook](OPERATOR-GUIDE.md#resume-playbook)

Use this README for installation, prerequisites, technical boundaries and tests; use the guide while operating the UI. **Use-checkbox selection is distinct from highlighting; Repair and Use images affect the whole batch.**

### Normal migration in plain language

1. **Connect and discover:** choose the tenant/subscription, policy, license and staging destination.
2. **Map:** check source VMs, enter target user UPNs, find/select their existing policy group, create the draft.
3. **Assess → Attest → Validate → Prepare:** read the guest, confirm manual requirements, check readiness and enable snapshot provisioning for the group.
4. **Validate again → Stop + capture → Refresh until Staged:** stops the source and copies its snapshot to Azure staging.
5. **Validate again → Import to W365 → Refresh until Imported:** imports the staged snapshot; no license yet.
6. **Validate again → Start migration / assign license → Refresh until Provisioned:** triggers creation of the Cloud PC.
7. **Test the actual Cloud PC → Validate cutover:** verify user sign-in, migrated files/apps and acceptance. Service success alone is not enough.
8. **Cleanup staging when retention permits:** deletes owned Azure staging/snapshots, not the source VM or Cloud PC.
9. **Use images before changing group membership:** once the entire batch is validated/cleaned/safely abandoned, switch the setting to normal image provisioning and confirm success/allow propagation before adding users. Existing PCs are untouched; keep their policy membership. [Detailed explanation](OPERATOR-GUIDE.md#return-the-group-to-normal-image-provisioning-before-changing-membership).

**Resuming?** Connect → load the **original** journal → Refresh first → follow NEXT STEP. Do not repeat completed actions. Renew Attest when indicated (for example after load/repair/reassessment); every major stage needs its own Validate approval.

**Waiting?** Copying / Importing / Provisioning need Refresh, not another capture/import/license. **Failed provisioning?** There is no script provisioning-retry button; investigate/fix the cause and use Intune's Retry where appropriate. Snapshot reuse for every retry is not guaranteed by the public documentation. Keep the script monitoring and preserve artifacts. Other recovery buttons are for their named pre-license/unknown-outcome problems, not a general retry.

## Start

Keep the application files together. **Double-click [Launch-CpcMigration.cmd](Launch-CpcMigration.cmd)** to start in PowerShell 7 STA, or open PowerShell 7 and run:

```powershell
pwsh -NoProfile -STA -File .\Start-CpcMigration.ps1
```

To force a particular organization even when the administrator has cached sign-ins elsewhere, supply the optional tenant GUID:

```powershell
pwsh -NoProfile -STA -File .\Start-CpcMigration.ps1 -TenantId "22222222-2222-2222-2222-222222222222"
# The command launcher forwards the same option:
.\Launch-CpcMigration.cmd -TenantId "22222222-2222-2222-2222-222222222222"
```

Replace the example GUID with the intended tenant. `-TenantId` validates before UI startup, prepopulates and locks the tenant field, and enforces that tenant in the engine for subscription detection, Azure/Graph connection and journal loading. Cached sessions in another organization cannot override it. It does **not** sign in automatically, switch subscriptions implicitly, grant access, or bypass consent/Conditional Access. Without the parameter, enter the tenant in the UI as before. Open a new instance to change a startup-locked tenant.

Use your organization's normal script-signing/execution-policy process. The launcher does **not** bypass execution policy, request elevation, or automatically sign in. Windows PowerShell 5.1, Linux and macOS are not supported by this UI.

### Automatic log and recovery journal

At startup, the app creates a unique timestamp/GUID-named **session log and JSON recovery journal in the script folder**. It checks access as the executing user by actually creating, writing and flushing files; no administrator elevation or ACL changes are attempted.

If that folder cannot be used, it resolves the executing user's Windows **Documents** location (including redirected Documents), creates **MigrateLog** there if needed, and uses it instead. A popup explicitly announces the changed log/journal paths. If neither location is writable, startup stops before sign-in or migration.

Activity messages are flushed to the `.log` as they occur. Graph responses and the results listed in the UI—resource catalogs, rows, prerequisites, status, configuration and errors—are also recorded automatically with timestamps and secret redaction. The recovery journal remains separate from the readable log and is updated automatically; **Save is no longer required to enable journaling**. Approval receipts and credentials are never persisted. This is application logging, not a PowerShell transcript or a recording of identity-provider sign-in prompts.

Both paths are shown in the footer (hover for full text), startup activity, and a copyable field in **Activity log**. **Save journal as...** optionally changes the active recovery-journal path; loading an existing journal switches to that journal. The session log stays at its startup location so the current run's history remains together. Logs can grow throughout a run; archive them according to your retention policy. Protect all generated files as sensitive tenant/user/resource data. Runtime logging failures are surfaced and do not silently redirect an in-progress migration.

- [Start-CpcMigration.ps1](Start-CpcMigration.ps1): WPF launcher, dedicated background runspace and event handlers.
- [CpcMigration.xaml](CpcMigration.xaml): desktop interface.
- [CpcMigration.Core.psm1](CpcMigration.Core.psm1): migration engine and safety checks.
- [CpcMigration.Confirmation.psm1](CpcMigration.Confirmation.psm1): scrollable resource/action review and confirmation dialogs.
- [CpcMigration.Workflow.psm1](CpcMigration.Workflow.psm1): read-only stage/button policy, next-step guidance and local resume-journal discovery.
- [CpcMigration.Journals.psm1](CpcMigration.Journals.psm1) and [CpcMigration.Journals.xaml](CpcMigration.Journals.xaml): saved-plan manager and guarded local archive.

## Included functionality

| Area | Functionality |
|---|---|
| Workstation | Prerequisite button; install/update Az.Accounts, Az.Resources, Az.Compute, Az.Storage, Microsoft.Graph.Authentication for CurrentUser |
| Sign-in | Tenant-scoped discovery of enabled accessible subscriptions, name/ID dropdown, explicit connection to the selected subscription + Graph; Commercial-cloud restriction |
| Inventory | Source resource-group dropdown + VM text search, full VM resource IDs, editable VM → user UPN mappings, selectable existing snapshot destination group, provisioning policy, subscribed SKU and staging account |
| Assessment | Azure metadata, delegated permissions, staging network/container checks, license headroom, existing Cloud PCs/licenses, assignment conflicts, guest OS/join/BitLocker/agent evidence |
| Identity | Admin explicitly selects an existing user group already assigned to the Enterprise policy; creates a plan-owned snapshot user setting and assigns it to that group without changing existing membership or policy assignments |
| Capture | Explicit shutdown/deallocation, managed OS snapshot, Trusted Launch VMGS, asynchronous server-side copy into customer-owned storage |
| Import | Fixed VHD footer/checksum check; documented Graph snapshot import; separate import and provisioning status |
| Cutover | License assignment only after import success; operator validation after the Cloud PC is provisioned |
| Monitoring | Refresh/30-second auto-refresh, actual copy byte counts, phase charts, Graph request IDs, advisory elapsed-time and recorded SAS-expiry warnings |
| Recovery | Transactional journal/load/map, exclusive file + local plan-identity locks, redacted durable event sidecars, explicit ambiguous-license/import reconciliation, reset/abandon terminal owned attempts |
| Completion | Restartable validated cleanup; restore image setting when all rows are validated/cleaned or safely abandoned |
| Reporting | HTML phase charts, CSV migration results, JSON prerequisite/Graph results and redacted activity log |

No progress percentage is fabricated for Graph import/provisioning: those stages expose states, not reliable percentage-complete values.

## Supported scope and deliberate restrictions

- **Windows 365 Enterprise, Commercial cloud, non-GPU** targets, with the requested **CloudPC Lite** license-selection exception described below.
- Azure **Gen2**, persistent **managed Windows OS disks**. Windows client, not Windows Server or multi-session.
- Same tenant; this version also requires source and staging resources in **one selected subscription per batch**. Use another app instance/plan for another subscription.
- Source Entra joined or hybrid joined to the same tenant. The guest assessment validates Entra tenant; hybrid domain readiness still needs operator review.
- No data disks. No ephemeral OS disks, Confidential VMs, customer-key disk encryption, guest BitLocker/Azure Disk Encryption, or Entra-protected/private-only disk exports. These are **application restrictions**, not a claim that every such scenario is prohibited by the product forever.
- Staging: existing **Storage/StorageV2** account, private container, public network endpoint enabled and default network action **Allow**. Public endpoint does **not** mean anonymous container access. The app deliberately rejects restricted networks rather than trying to determine W365 private connectivity or relaxing rules.
- Trusted Launch requires an Az.Compute version exposing `Grant-AzSnapshotAccess -SecureVMGuestStateSAS`. The app checks the actual command capability instead of guessing a minimum version. If updating an already-loaded module, **close and reopen the app**.
- Target selection uses the license-discovery logic adapted from [example get licenses.txt](example%20get%20licenses.txt): Enterprise SKU/child-plan configuration matching, service-plan lookup and the explicit **CloudPC Lite / CloudPC_AddOn** mapping (2 vCPU / 4 GB / 128 GB). Only Enterprise and this Lite exception are retained. Flex, Frontline, shared, GPU, Business, Reserve, DR add-ons, unrelated and unresolved/contradictory SKUs are excluded. Exclusion applies to the entire SKU, including child plans, before the Lite exception.
- Each license option displays **Available / Assigned / Enabled** counts. Available is `max(0, prepaidUnits.enabled - consumedUnits)` for an enabled SKU with known counts; suspended/disabled/unknown-count SKUs have zero assignable seats. Zero-seat options are visible but disabled. **Refresh available licenses** updates counts without reloading VM mappings. Counts are re-read when creating a plan, checking prerequisites and assigning licenses; they are not a reservation.
- Disk capacity is populated automatically from the selected license and is read-only. Saved-plan capacity is validated against current discovery. The comparison uses provisioned OS-disk size, not used space. Lite is a requested selection exception based on the supplied example, not independent certification of its migration eligibility; verify any Lite-specific entitlements with the service.
- Existing source-user apps/profiles are preserved by snapshot import, not by Sysprep/generalized-image creation. The app never generalizes the source.
- Small, reviewed batches are recommended. Mutation requests are sequenced; server-side copies and imports can run concurrently after submission. Tenant inventories are re-read for safety rather than optimized for thousands of devices.
- Dedicated policies explicitly owned by services other than `windows365`, or using an experience other than `cloudPc`, are rejected. Missing optional owner/experience fields are accepted for legacy beta responses; explicit null/unknown values fail engine validation.
- Membership OData casts use `ConsistencyLevel: eventual` and `$count=true`, including paginated requests. This index can lag recent membership changes. Wait and revalidate rather than treating a transient mismatch as permission to bypass scope checks.

## Permissions and existing infrastructure

### Microsoft Graph / Entra

Interactive delegated scopes requested:

- `CloudPC.ReadWrite.All`: policy/user-setting operations, snapshot import/purge and Cloud PC reads.
- `User.Read.All`: user identity, license assignments and group membership reads.
- `Group.ReadWrite.All`: read group eligibility/membership; retained write permission for resuming legacy journals that create their own group. New selected-group plans do not write group membership or policy assignments.
- `LicenseAssignment.ReadWrite.All`: trigger provisioning through user licensing.
- `Organization.Read.All`: subscribed SKU inventory.

Admin consent and appropriate **signed-in administrator roles** are required; consent alone does not grant the user an administrative role. Review Windows 365 Administrator/Intune Administrator requirements, group-management authorization and License Administrator capabilities with your identity team. PIM and Conditional Access remain in force. The app does not assign itself roles or grant consent.

The current public import/purge reference unusually lists `CloudPC.Read.All` as least privilege. This app intentionally requests `CloudPC.ReadWrite.All` because it also writes policies and user settings; it does not rely on the surprising read-only grant for mutation.

### Azure

Use a scoped/custom role where possible. Expected operations include:

- Subscription/resource enumeration and VM/disk reads.
- `Microsoft.Compute/virtualMachines/deallocate/action` on source VMs.
- `Microsoft.Compute/virtualMachines/runCommand/action` for the explicitly approved guest assessment. Azure runs the inspection as SYSTEM; it is read-only in the guest, but **not** a control-plane read operation.
- Snapshot read/write/beginGetAccess/endGetAccess on the selected snapshot resource group; delete for optional cleanup.
- Staging account/container reads and blob data read/write; blob delete for optional cleanup.
- `Microsoft.Storage/storageAccounts/blobServices/generateUserDelegationKey/action` at storage-account scope or above. **Storage Blob Data Contributor** at account scope is a practical option. Container-scoped data rights additionally need an account-scope delegation-key grant.
- Read current-caller permissions at these scopes for the prerequisite report.

RBAC assessment handles wildcard grants and `NotActions` **per role entry**. It is not proof that deny assignments, resource locks, ABAC conditions, storage immutability, access policies or service capacity will permit the operation. Cleanup rights are exercised only when cleanup is selected.

Create/review the target provisioning policy, network/ANC, private staging container and snapshot resource group **before** using the tool. It does not create networks, configure Intune enrollment restrictions, alter firewall rules or acquire licenses.

## Recommended end-to-end sequence

1. **Check workstation prerequisites.** Install/update dependencies if necessary, then restart the app. No cloud changes occur here.
2. Enter the intended **tenant GUID**, then **Sign in to Azure / detect subscriptions**. Complete authentication directly in the identity prompts. Choose an enabled accessible subscription by **name and ID**, then **Connect selected subscription + Graph**. The app disables Az's console subscription-selection prompt at **Process** scope because the WPF worker cannot answer console prompts; browser authentication remains enabled and saved user-wide Az settings are unchanged. No subscription is selected automatically for migration. Subscription/tenant changes are locked once a plan exists; use a fresh app for another scope. Reconnect to the same scope when resuming a saved plan. Sign-in failures are shown with their recorded error text; an empty worker error stream does not produce a blank dialog.
3. **Discover VMs / resource groups.** Choose an existing Enterprise dedicated policy, an Enterprise or CloudPC Lite license with enough available seats, storage account/private container and **destination resource group for temporary managed snapshots**. The selected license supplies the target disk capacity automatically. Subscription changes clear old VM/configuration selections; reconnect and discover again.
4. **Select & map.** Choose the **source VM resource group** (or **All resource groups**), then optionally search by VM/group/region. Check the desired VM(s) and enter one unique user UPN per VM. Full VM resource IDs are shown to distinguish similarly named VMs. The source group filter is independent of the snapshot destination group. Filtering preserves UPN edits and **does not clear hidden selections**; all checked VMs are included in the mapping confirmation. Review the complete batch before creating the plan. Explicit inventory rediscovery resets these unsubmitted VM selections/UPNs.
   - Click **Find groups for selected users + policy**, then explicitly choose the intended **user group by name and ID**. Even a single result is not selected automatically. Candidates are common direct memberships of all checked target users, already directly assigned to the selected **Enterprise dedicated** policy. Change the policy or split batches if users do not share an eligible group.
   - **A user setting is assigned to a group, not directly to an individual user.** Every member receives that setting. Therefore the selected group must contain **exactly the mapped batch users as direct members**. Extra users, nested groups, dynamic/synced groups, filtered/unknown assignment targets, and groups or ancestors with license assignments are blocked. Use an existing dedicated migration group assigned to the Enterprise policy if a broader group contains unrelated users. The app does not add/remove users or alter policy assignments to make an existing group eligible.
   - Membership, policy type/assignment and group scope are read again during mapping, preflight and immediately before group-wide changes. Existing conflicting policies/settings still block; choosing one group does not override other effective assignments. Use an exclusive administration window to prevent concurrent changes.
5. **Review the automatic log/journal paths** in Activity log. Journaling is already enabled from startup. Optionally use **Save journal as...** to select another protected recovery-journal location. Restrict access to the folder; never edit the journal or load one from an untrusted party.
6. **Assess guest** while each source is running. This uses Azure Run Command to collect Windows edition/build, Entra tenant/join, BitLocker status and a limited list of known VDI agent candidates. It does not use `Win32_Product`, uninstall software or alter guest configuration.
   **After fixing Windows join, BitLocker or agents, repeat Assess guest → Attest prerequisites → Validate prerequisites before capture.** Validation reuses saved guest evidence; neither restarting the VM nor validating again refreshes it. The migration grid shows the guest assessment time, and guest check details show the collection timestamp, recorded values and refresh instructions. The results grid's Checked UTC is the validation time, not the guest collection time. Reassessment clears prior attestation and approval. BitLocker must be **FullyDecrypted**, not merely suspended or still decrypting. After capture, source evidence is frozen: use recovery review instead of restarting or reassessing the captured source.
7. Review evidence by selecting a row. Remove incompatible third-party agents yourself, reboot and assess again. Independently verify bootability, a supported Windows release, backup, user/profile ownership, entitlement prerequisites, CSE/network readiness and the target policy. **Attest prerequisites**, then **Validate prerequisites**. All selected rows must pass for **Prepare**.
8. **Prepare snapshot provisioning.** Select and validate **all batch rows**. This creates a separate `provisioningSourceType = snapshot` user setting and assigns it to the explicitly selected existing group. Users receive it through existing group membership. The group must already be assigned to the selected Enterprise policy; no group is created and existing membership/policy assignments are not changed. There is **no license assignment** in this step.
   - Use an **exclusive administration window**. Group membership and assignment reads cannot guarantee atomicity against concurrent administrator changes.
   - Wait for membership/policy propagation, then **Validate prerequisites** again for **Capture**. A temporary failure during propagation is not automatically remediated.
9. Confirm backup, user sign-out, outage and a write-freeze, then **Stop + capture**. The source is deallocated, an OS snapshot is created, and OS/VMGS copies start in storage. Billable resources are created. The source stays stopped.
10. **Refresh status** until **Staged**. All applicable copies must succeed, and copy IDs must match the journal. Snapshot export access is then revoked. Copy failure or ambiguous copy submission requires reconciliation, not overwriting a blob.
11. Click **Validate prerequisites** for **Import** and review PASS results for snapshot ownership/Gen2/capacity, completed VHD/VMGS copy IDs and byte counts, PageBlob and fixed-VHD footer checksum, storage/network, policy/group/snapshot setting, user and licenses. Then **Import to W365**. Confirm the full resource scope and acknowledge that validation passed. The app rechecks before submission and creates read-only 48-hour user-delegation SAS URLs in memory. Import is asynchronous.
12. **Refresh status** until **Imported**, with `importStatus = succeeded` and `usageStatus = notUsed`. If unsuccessful, inspect redacted Graph results and service error details. Do not repeatedly submit imports for the same user.
13. Click **Validate prerequisites** again for **License**, including a live check of imported snapshot identity/completion and retained staging. Then **Start migration / assign license** and confirm the full scope. Fresh batch and per-user checks run before the provisioning trigger. Existing licenses are not removed. The script never assigns a new W365 license before the imported snapshot is ready.
14. **Refresh** until the target Cloud PC is **provisioned**. This is a service state, not proof of restored-data correctness.
15. Have the user sign in. Verify source/snapshot/profile/data/apps, Intune enrollment, network and acceptance. **Validate cutover** records this explicit operator decision. It checks the Cloud PC policy and the recorded successful import followed by licensing.
   - A current `inUse` snapshot status is useful evidence. The service may delete imported artifacts after provisioning, so import-read failure does not prevent independent Cloud PC monitoring. In that case, the UI retains historical import status and reports the read error; **Graph alone does not prove snapshot provenance**. The operator must verify the actual restored data before validating.
16. Retain resources according to your recovery/retention policy. Optionally **Cleanup staging** after validation. Only journal-owned Azure blobs and managed snapshots are removed. The source VM is **never** deleted.
17. When **all** batch rows are validated/cleaned or safely abandoned, optionally select **Use images for future reprovision**. Abandoned users are rechecked for absence of Cloud PCs/W365 licenses. This patches only the dedicated setting to `image`; it does not reprovision existing PCs. Keep provisioning-policy membership intact.

### Stage-aware controls and resuming an existing migration

- **NEXT STEP · checked rows** describes the next action for the rows selected with **Use**, not just the highlighted row. Invalid-stage buttons are disabled; hover over a disabled button for its reason. The same policy is checked before and after confirmation (a long review can outlive approval). Prepare/Capture/Import/License require unexpired, stage-specific explicit validation; backend live safety checks and confirmations remain authoritative. Mixed-stage selections are explained explicitly.
- **Copying:** use **Refresh status** or auto-refresh until **Staged**. Import, recapture, licensing and other normal forward actions stay disabled. **Importing** waits for **Imported**, and **Provisioning** waits for **Provisioned**. Status polling never automatically starts the next migration step.
- Copy progress labels **OS VHD** and **VMGS** separately. A small successful VMGS copy is not proof that the OS VHD finished. Staged requires the recorded copy IDs, complete byte counts and successful export revocation. Old readiness/approval is invalidated on advancement; revalidate for the next stage.
- All review dialogs, message boxes, file pickers and journal-manager dialogs pause application polling/dispatch. Server-side work continues. The worker completion handler cannot reenter while displaying its result. Only Refresh may use the automatic path; migration writes cannot bypass confirmation through that flag.
- Recovery shows its checked-row scope. Import reconciliation requires a known nonzero GUID; license reconciliation requires reviewed audit evidence and an explicit-zone, nonfuture assignment timestamp. Evidence fields remain editable while submission is disabled and clear when the selection/phase changes. The backend still verifies identities and timing. **LicenseUnknown** must use explicit audit-based reconciliation; a present SKU alone never establishes this migration's assignment time.
- Recovery controls are separate, deliberate actions. For example, revoking export access can interrupt an ongoing copy and still requires confirmation. Reset/abandon remain subject to live artifact checks that reject pending copies; an enabled recovery button does not mean the operation is safe without review.
- **Create / update draft mappings** edits only an unprepared local draft. Prepared mappings/configuration are locked. It does not replace cloud settings, adopt another plan's resources or undo a migration.
- After connecting a fresh session, the app shows a reminder if it finds saved journals for that tenant/subscription. Choose **Resume / load journal** before creating mappings. Select the trusted **original** journal that owns the setting/snapshot/import, not simply the newest file. Creating mappings for VMs found in another prepared local journal is blocked, with that journal's path and an explanation. Even a completed prepared journal is treated conservatively; remigrating its source requires separate ownership/retention review, not deleting the journal to bypass the guard.
- Discovery is advisory and local: top-level JSON files in the script directory, Documents/MigrateLog and current journal directory, up to 32 MiB each. Other locations must be browsed manually. No journal is automatically loaded or modified, and discovery does not replace the core's journal scope, ownership and lock checks.
- If a draft is already open, restart and reconnect before loading the original journal. Loading restores recorded ownership and clears attestations/approval receipts. **Refresh status is required first**: other row actions stay blocked until each affected row returns a successful refresh; a failed/unselected refresh cannot unlock it. For **IdentityPrepared**, step 4 is already complete: review saved guest evidence, **Attest → Validate prerequisites → Stop + capture**; do not repeat Prepare. Reassess the guest only when pre-capture evidence needs refreshing. Missing frozen evidence routes to recovery, not a restart/reassessment or new plan.
- Code updates apply on the next launch; they do not alter an already-running window. Do not interrupt an active worker merely to obtain UI changes. Resume the existing journal when restarting at a safe point.

### Managing saved journals

Open **Manage saved journals / archive** on Connect & configure. **Resume / load journal** and **Load journal** also open this manager instead of a filename-only picker.

- The list shows category, VM, phase, user, last-saved UTC, plan ID and whether the plan is open here. Select a row to see its full path and tenant/subscription. Unfinished **KEEP — migration / recovery** plans sort ahead of old drafts; nothing is selected automatically. Multiple copies remain distinct—verify phase/path, not just age.
- **Resume selected** requires a fresh connected session and matching scope. **Browse another journal** handles other save locations. Normal trusted-journal confirmation, scope checks and locks still apply. Refresh server status after loading.
- **Archive selected** is available only for empty startup journals, genuinely unprepared drafts without artifact evidence, or batches where every row is **Cleaned/Abandoned**. **Validated** alone is not sufficient. No cloud resources, user settings, licenses or group assignments are modified. Archive is not a substitute for migration cleanup.
- Archive rechecks file contents and holds both the engine's journal-path and plan-identity locks. The current plan, another open instance/copy, changed files, inaccessible paths and linked/network paths are refused. These locks have the same local-user/workstation boundary as the engine; coordinate other administrators and do not manage copies concurrently on other machines.
- Each archive gets a unique subfolder beneath **JournalArchive**, adjacent to the original journal. The JSON and its adjacent audit sidecars move together, with best-effort rollback on failure. Nothing is overwritten or permanently deleted. Review the reported archive path after an interrupted/failed archive. Session logs stay in place because they can span multiple journal paths; lock files also remain to avoid races.
- Archived journals are hidden by default. **Show archived** makes them selectable for resume, preserving terminal history and any future image-setting operation. Archived prepared plans still participate in the new-mapping overlap guard. Archiving is organization, **not disk-space reclamation**; permanent retention disposal remains an administrator decision outside this UI.
- Housekeeping works without cloud sign-in and includes unconnected startup journals. Discovery is limited to the script directory, Documents/MigrateLog, the current journal directory and their managed archive folders, with a 32 MiB per-journal limit. Malformed/unrecognized files are left untouched. Protect archive folders with the same permissions and retention rules as active journals.

### Admin buttons for Graph prerequisites

- **4 Prepare snapshot provisioning** creates a plan-owned snapshot setting and assigns it to the selected existing user group. It requires successful preflight and selection of the entire batch. It never creates or modifies the selected existing group.
- **Repair snapshot setting + assignments (batch)** explicitly PATCHes `provisioningSourceType` to `snapshot` and restores this plan-owned setting's assignment to the selected group. Existing-group plans require valid membership and Enterprise policy assignment first; correct these in Entra/Intune manually. No automatic membership/policy repair is performed on an existing group.
- **Legacy journals** without an existing-group selection retain their original plan-owned-group workflow: create `CPCMigration-{PlanId}`, add users and append the group to the selected policy preserving existing targets. Repair may restore memberships/policy assignment only for those owned groups. Existing saved plans are not silently rebound to a different group.
- Repair is confirmed for the **entire batch** and requires a saved journal and an exclusive administration window. It rejects unrelated members/settings/assignments, synced/dynamic or license-bearing groups, conflicting policies/settings, existing Cloud PCs/licenses, and in-flight or provisioning phases. It does not create arbitrary objects, change region/network configuration, grant permissions, remove unrelated assignments, import snapshots or assign licenses.
- Repair deliberately does **not** require a passing migration preflight: its purpose is to fix the failed assignment prerequisites. Instead it performs separate scope/ownership/user safety checks. It clears all preflight approvals and customer attestations. After propagation, the customer/admin must **Attest prerequisites → Validate prerequisites → confirm the major step**. Successful repair alone never authorizes provisioning.

## What checks are—and are not—automatic

### Required validation and confirmations

- **Validate prerequisites** is the preflight button; **Validate cutover (final)** is only for post-provisioning user acceptance. They are not interchangeable.
- Prepare, Capture, Import and Start migration require a **successful explicit validation for that stage and selection**. Approval is held only in memory, expires after **30 minutes**, is consumed once, and is invalidated by phase/configuration/evidence changes or reload/reconnect. Running automatic checks cannot grant approval. A failed stage requires another explicit validation before retry.
- Major operations still re-read live prerequisites immediately before changes; validation is not a license reservation or a guarantee against concurrent administrator changes. Missing prepared group/user-setting IDs and missing or conflicting policy assignment block post-preparation stages.
- Important operations show a scrollable, copyable confirmation with action/risk details, tenant/subscription, policy/SKU/storage configuration, group/user-setting names and IDs, and every selected VM/user/snapshot/blob/copy/import/Cloud PC identifier known at that point. **Cancel is the default**. Major stages require a separate acknowledgement of successful preflight. IDs not yet issued by Azure/Graph are explicitly marked unresolved, then shown in the result dialog after the operation returns.
- Result dialogs include current phases, validation evidence and any operation error; returning from a call does not mean import/provisioning succeeded. Auto-refresh is explicitly confirmed because completed copies cause owned snapshot export access to be revoked.
- Failed checks and operation errors appear **in red at the top of the popup**, with a specific **NEXT** action (including the repair button where applicable). Failed rows are also red in the prerequisite grid. Manual responsibilities are amber and remain customer/admin attestations, not automatic proof. The provisioning confirmation explicitly requires acknowledgement that customer prerequisites are completed.

**Automatic:** accessible metadata, Gen2/Windows/no-data-disk checks, persistent disk, disk-size comparison, source identity continuity, Commercial/same-tenant context, staging configuration, current-caller permission grants, enabled target user/usage location, existing Cloud PCs/licenses, license headroom, detectable group-based policy/setting conflicts, region/join configuration, ANC health, guest-agent evidence and guest encryption/join/OS checks.

**Capture-specific gates:** checks run for the batch and again for each VM before deallocation/snapshot creation. The managed OS disk must be **Gen2 (V2)**, with **no attached data disks**. Guest evidence must show a **Windows client build >= 10240 (Windows 10+)**, not Server or multi-session, and healthy Azure VM agent evidence. For running sources, current Azure agent status must also be `ProvisioningState/succeeded`; for an already-deallocated source the agent cannot be checked live, so the recent pre-capture guest assessment is required. Windows lifecycle/ESU support remains an admin check. **Trusted Launch** requires the VMGS export capability, requests `SecureVMGuestStateSAS`, rejects a missing `SecurityDataAccessSAS`, and copies both OS VHD and VMGS. Import validation requires the matching completed VMGS copy; it cannot silently fall back to OS-only import.

**Operator evidence:** correct source-user/profile mapping; full third-party-agent removal; complete disk/content integrity; bootability; current supported Windows servicing/ESU status; exact license edition/capacity and Windows E3/Intune/Entra ID P1 entitlement; exhaustive policy exclusion/filter/assignment precedence; existing external import state; network reachability from the Cloud PC/CSE; source write-freeze across app downtime; tested recovery; and user acceptance after provisioning.

The VHD footer checksum is **not a full disk hash or proof that every file is uncorrupted**. Copy success plus footer validation is a structural check. VMGS is copied from the same snapshot and its source blob type is preserved; it is not treated as an ordinary fixed VHD for footer validation.

## Recovery and security behavior

| Situation | Handling |
|---|---|
| Cancel/close during work | Stop is cooperative between steps. Current API calls and server-side work may continue. Closing is blocked while a worker is active. No automatic rollback. |
| App closes during normal copy/import/provisioning | Open a fresh app, connect/discover, load the matching journal and refresh. A `Copying` row is monitored rather than recaptured. |
| Import request times out / no snapshot ID returned | `ImportUnknown`; no automatic POST retry. Obtain the real import ID from tenant/service diagnostics, then reconcile the unique filename, user and start time. Do not invent an ID or assume failure. |
| License response is uncertain | `LicenseUnknown`; no new assignLicense POST or ordinary validation/license shortcut is allowed. Use **Reconcile license (no write)** with reviewed audit evidence and the actual assignment time as described below. A present SKU alone does not prove this migration's assignment timing; an absent SKU is NOT proof the original write failed. |
| Group/user-setting creation accepted but response/journal lost | Same-name detection refuses duplicate creation. Review actual objects and repair the journal through a controlled, knowledgeable recovery process; no automatic adoption. |
| Copy request accepted but copy ID not saved | Refuses overwrite AND deletion of the unjournaled blob. Manual source/target copy-ID reconciliation is required; never assume an unknown request failed. |
| Capture/copy fails after export grant | Export SAS remains bounded to 24 hours; **Revoke Azure export** explicitly invalidates it, potentially interrupting unfinished copies. No credentials are persisted. |
| Import is failed/succeeded and unused | Optional **Purge unused W365 import**, with user identity and live no-license/no-PC checks. Ambiguous response becomes `PurgeUnknown` and is not retried; manual service reconciliation is required. |
| Source was restarted / replaced | Later checks block detectable running/replaced sources or disk/VM ID changes. The app cannot prove the VM stayed stopped while it was closed; operator write-freeze controls remain required. |
| Provisioning fails after licensing | Investigate Windows 365 error. No automatic license removal, reprovision, data discard or source restart. Preserve the journal/backup and avoid dual-active endpoints with copied identities. |
| Cleanup partially fails | `CleanupPending` persists approved ownership evidence before deletion. Repeat Cleanup to reconcile absence and continue remaining verified deletions; permission/network errors are never treated as absence. |
| Capture fails before Stop/snapshot completes, or terminal copy fails | Use **Reset failed / purged capture**. Deletes only owned terminal artifacts, archives IDs, then returns to `IdentityPrepared`/`Mapped` with approvals cleared. Reassess/attest/validate before capture. It never restarts the source. |
| Abandon a pre-license attempt | **Abandon + remove owned artifacts** uses the same gates and archives IDs, then marks `Abandoned`. Snapshot setting/group/policy remain; use the whole-batch image option after every row is safe. |
| Reset/abandon is interrupted | Resume the SAME action for `ResettingCapture`/`Abandoning`. Prior durable removal approval is required; already-absent artifacts are reconciled without blindly replaying writes. |

### Read-only license recovery after consumed-import cleanup

Select exactly one `LicenseUnknown` row. Independently review Entra audit/service evidence proving the exact user, SKU and original migration assignment. Enter an **audit/request reference** (not a token or secret) and the **actual assignment UTC time**, such as `2026-09-17T10:15:00Z`, then select **Reconcile license (no write)**.

Recovery requires historical successful import evidence, an enabled unchanged user, one active **direct** exact-SKU assignment without errors, and exactly one Cloud PC with the same user/policy and creation time at or after the reviewed assignment (five seconds clock tolerance). It checks a compatible Windows 365 policy. It does not retrieve the consumed import, grant storage SAS, assign licenses or submit imports. If a Cloud PC is not yet attributable, wait/investigate; absent/ambiguous evidence never authorizes a retry. The reference is operator-reviewed evidence, not an automatic Entra audit-log query. Final independent restored-data validation remains mandatory.

### Safe reset/abandon boundaries

Reset/abandon requires no live or unknown import and no W365 license/Cloud PC. Purge a terminal unused import first. A pending copy must become terminal; explicitly revoke export if appropriate and monitor Azure before recovery. Unjournaled or replaced copy IDs, foreign snapshots and inaccessible listings are blocking. Two-pass ownership checks and a durable pending phase precede deletion. Use an exclusive administration window: these APIs do not provide a cross-service transaction against external admins. A fresh attempt uses new GUID artifact names; prior identifiers remain in attempt history.

### Journal locking and evidence

Mapping and loading validate a temporary candidate before committing; rejected candidates leave the active plan/journal unchanged. Saves use a flushed temporary file and atomic replacement. The app holds the journal's `.lock` exclusively and a per-user/per-plan lock under Local AppData, protecting Save As/copied journals on the same workstation. Locks are released on window close/module removal/process exit; an existing lock file by itself is not an active lock. Different plan IDs cannot overwrite one another. These are **local** locks, not distributed locks across administrators or computers; retain the exclusive administration window.

An adjacent `.events.jsonl` stores bounded redacted operation/request evidence automatically, with one rotated `.events.jsonl.1` backup (rotation at approximately 5 MiB, plus the final event). Request bodies/SAS/credentials are not logged. Graph results remain a session view; export the full report separately. Audit/journal write failure blocks further writes until access is restored. Protect journals, sidecars, history and reports as sensitive tenant/user/resource data.

Elapsed-time warnings use operator-review thresholds (capture/provisioning: 2h; import: 6h), **not service SLAs**. Recorded export/import-SAS expiry warnings appear when two hours or less remain. They do not change phases, renew access or retry operations. Inspect row details/prerequisites and live service evidence.

SAS URLs are not written to journals/reports. Graph response URL query strings and bearer tokens are redacted. Azure account keys are never requested. User-delegation SAS is HTTPS/read-only and time-limited; **revoking the snapshot export SAS does not revoke a separately issued staging-blob SAS**. Existing organizational PowerShell transcripts, monitoring, memory dumps and Azure copy metadata are outside the application's redaction boundary. Treat them as sensitive.

The app intentionally keeps the selected group, policy assignment and plan-owned user setting. **Do not remove users from that group just to remove the snapshot flag**: it also carries their provisioning policy. Use the whole-batch `image` setting change, or independently establish the intended steady-state policy before restructuring groups. The image-setting change is blocked if the existing group's membership expands beyond this batch.

## Offline validation

```powershell
pwsh -NoProfile -File .\tests\Test-Offline.ps1
pwsh -NoProfile -File .\tests\Test-Recovery.ps1
pwsh -NoProfile -File .\tests\Test-Logging.ps1
pwsh -NoProfile -File .\tests\Test-Workflow.ps1
pwsh -NoProfile -STA -File .\tests\Test-Journals.ps1 -Render
pwsh -NoProfile -STA -File .\Start-CpcMigration.ps1 -SmokeTest
pwsh -NoProfile -STA -File .\Start-CpcMigration.ps1 -SmokeTest -TenantId "22222222-2222-2222-2222-222222222222"
```

Tests check PowerShell parsing, import payloads, SAS redaction, RBAC, nullable Azure models, user/source continuity, license gates, explicit-vs-automatic stage approval, UTC expiry, single-use approvals, removed policy assignments and snapshot/copy/VHD/VMGS failure cases. Workflow tests cover forward/recovery action availability across phases, mixed selections, prepared-plan locks and read-only journal discovery. WPF smoke testing renders the license picker, saved guest timestamp and resource-review dialog, including acknowledgement and default-Cancel behavior; it also checks loaded-plan guidance, in-flight button disabling, expiry and click-time guards. **None of these tests certifies live API availability, Azure export permissions, target bootability or end-to-end migration.**
