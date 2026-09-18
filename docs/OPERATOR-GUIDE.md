# Migration Workbench — complete operator guide

This is the tab-by-tab reference for the standalone Azure VM → Windows 365 PowerShell/WPF workbench. Control names in parentheses identify the matching source control for maintenance; operators use the visible labels. Reviewed against the interface and handlers on **2026-09-17**.

**Read before operating:** [README: supported scope, setup and permissions](../README.md#supported-scope-and-deliberate-restrictions). This is a controlled pilot using Graph beta, not a supported production migration product. No MCP or hosted server is required. Import success and a provisioned Cloud PC are **not proof that the correct data was restored**.

## Contents

Start here: **[Simple button reference — what it does and when to use it](#simple-button-reference)**.

1. [Operating rules and selection](#operating-rules-and-selection)
2. [Global controls](#global-controls)
3. [Tab 1 — Connect & configure](#tab-1--connect--configure)
4. [Tab 2 — Select & map](#tab-2--select--map)
5. [Tab 3 — Migration](#tab-3--migration)
6. [Tab 4 — Prerequisite results](#tab-4--prerequisite-results)
7. [Tab 5 — Dashboard & Graph](#tab-5--dashboard--graph)
8. [Tab 6 — Activity log](#tab-6--activity-log)
9. [Saved migration journals dialog](#saved-migration-journals-dialog)
10. [Confirmation, result and file dialogs](#confirmation-result-and-file-dialogs)
11. [Phase dictionary and allowed next steps](#phase-dictionary-and-allowed-next-steps)
12. [Resume playbook](#resume-playbook)
13. [Troubleshooting and completion checklist](#troubleshooting-and-completion-checklist)

## Simple button reference

**For a normal successful migration, follow the numbered steps and Refresh between stages. Recovery buttons are for specific problems, not extra required migration steps.** The detailed tab sections below explain input formats and safety checks.

**Three rules:** check **Use** to choose the affected rows; hover a disabled button to see why; read **NEXT STEP** before continuing. Highlighting a row only shows details. **Repair** and **Use images** affect the whole batch, including unchecked rows. All actions still require the appropriate connection, idle app and safety checks.

### Connect & configure buttons

| Button | Simply put | When to use |
|---|---|---|
| **Check workstation prerequisites** | Checks required local PowerShell modules/capabilities. | Before starting, or after updating modules. Results appear in Prerequisite results. |
| **Install / update dependencies** | Installs/updates the required modules for your Windows user. | If modules are missing/outdated. Review the package-source prompt; restart the app afterward at a safe idle point. |
| **1 Sign in to Azure / detect subscriptions** | Signs in and lists subscriptions in the entered tenant. | After entering the tenant ID; then explicitly select a subscription. |
| **3 Connect selected subscription + Graph** | Connects Azure and Windows 365 management for your chosen scope. | After selecting the subscription; also when starting a fresh session to resume. |
| **4 Discover VMs / resource groups** | Loads source VMs and destination choices. | For a new draft after connecting. Rediscovery clears unsubmitted VM selections/UPN edits; it does not refresh migration progress. |
| **Refresh available licenses** | Updates license choices and available seat counts. | While configuring a draft if counts may have changed. Does not assign/reserve licenses or reset VM mappings. |
| **Resume / load journal** | Opens the saved-plan manager. | To continue an existing migration: connect first, load the original journal **before creating mappings**, then Refresh status. |
| **Manage saved journals / archive** | Lists saved plans and lets you archive eligible old ones. | For local housekeeping when idle; sign-in is not needed just to manage files. |

### Select & map buttons

| Button | Simply put | When to use |
|---|---|---|
| **Find groups for selected users + policy** | Finds existing groups shared by the target users and assigned to the selected policy. | After choosing a policy, checking VMs and entering their target UPNs. Then explicitly select the intended group. |
| **Create / update draft mappings** | Saves which VM belongs to which target user, plus destination settings. | After all draft inputs and group selection are ready. Cannot replace a prepared migration; resume its journal instead. |

### Migration buttons and polling

| Button/control | Simply put | When to use |
|---|---|---|
| **Save journal as... (optional)** | Changes where the whole recovery plan is saved. | Only if you want another protected location. The app already saves automatically. |
| **Load journal** | Opens the same saved-plan manager as Resume. | In a fresh connected session with no draft already open. Load the original plan, not an exported report. |
| **Export HTML / CSV / JSON** | Writes reports for the whole plan and current session evidence. | When you need a progress record, troubleshooting evidence or final report. Select a separate folder to avoid replacing older reports. |
| **Refresh status** | Checks cloud progress and updates the plan. Also revokes snapshot export when all staging copies finish. | First after loading, and while waiting for Copying → Staged, Importing → Imported or Provisioning → Provisioned. Never starts the next stage. |
| **Auto-refresh selected (30s)** | Repeats Refresh for Use-checked rows while the app is idle. | While waiting for cloud work. Uncheck to stop polling, not to cancel provisioning. Dialogs pause polling. |
| **1 Assess guest** | Reads Windows, join, encryption and agent information from the running source VM. | Before capture; repeat after fixing the guest. Not allowed once source evidence is frozen. |
| **2 Attest prerequisites** | Records **your confirmation** that backup, mapping, entitlements and other manual requirements are correct. | After reviewing guest/manual evidence, and again when reload, repair or reassessment cleared that confirmation. Does not automatically test or fix anything. |
| **3 Validate prerequisites** | Checks whether the selected rows are ready for their **next major action**. | Before **each** of Prepare, Capture, Import and Assign license. Uses saved guest evidence; approval is single-use and lasts 30 minutes. |
| **4 Prepare snapshot provisioning** | Creates the snapshot-mode user setting and assigns it to the migration group. | After Prepare validation passes; select the entire batch. Does not assign licenses. Then wait for propagation and validate for Capture. |
| **5 Stop + capture** | Stops the source VM, creates a snapshot and starts staging copies. | After Capture validation, user sign-out, backup and approved outage. Source stays stopped. Wait for **Staged**. |
| **6 Import to W365** | Submits the staged VHD/VMGS to Windows 365 for the target user. | At **Staged**, after Import validation. Wait for **Imported**; do not submit again because it is slow. |
| **7 Start migration / assign license** | Assigns the selected license and starts Cloud PC provisioning. | At **Imported**, after License validation. Consumes seats/can incur costs. Wait for **Provisioned**. |
| **8 Validate cutover (final)** | Records that **you and the user checked the new Cloud PC and its migrated data/apps**. | At **Provisioned**, after sign-in and acceptance testing—not merely because Graph reports success. Different from step 3. |
| **9 Cleanup staging** | Permanently deletes this plan's Azure staging blobs and managed snapshots. | After final validation and retention/backup approval, or to continue interrupted CleanupPending. Keeps the source VM and Cloud PC. |
| **Repair snapshot setting + assignments (batch)** | Repairs this plan's snapshot setting/matching group assignment. | Only if that prepared configuration needs repair and all rows are in an allowed pre-license phase. Not a provisioning retry. Affects **all rows** and clears attestation/approval. Existing-group membership/policy issues must be fixed separately. |

**Tabs 4 (Prerequisite results) and 6 (Activity log) have no action buttons.** Read their results/logs, then return to the relevant tab to act. Their text fields are read-only.

### Dashboard & Graph — completion and recovery buttons

**After licensing, the script has no Retry provisioning button.** Fix the underlying issue, then use the failed-provisioning popup's **Retry in Intune** if appropriate; keep the script on Refresh. Do not substitute Reprovision (a destructive rebuild) or the pre-license recovery buttons. Public documentation describes [provisioning Retry](https://learn.microsoft.com/en-us/windows-365/enterprise/provisioning#provisioning-retry), but does not explicitly guarantee imported-snapshot reuse for every retry scenario. Missing/consumed-snapshot errors need investigation, not a blind reimport.

| Button | Simply put | When to use |
|---|---|---|
| **Use images for future reprovision** | Turns off migration-snapshot mode by changing the existing setting to `image`. Keeps the setting/group assignment and current Cloud PCs unchanged. | After **all rows** are Validated/Cleaned/safely Abandoned, **before changing group membership**. Confirm success/allow propagation before adding normal-provisioning users. [Exact order and effects](#return-the-group-to-normal-image-provisioning-before-changing-membership). |
| **Purge unused W365 import** | Deletes a known terminal, unused W365 import—not Azure staging. | For reviewed recovery of Imported/ImportFailed rows **before licensing**, with no Cloud PC. Not needed after successful migration. |
| **Revoke Azure export** | Stops access through the Azure snapshot export SAS; can cause unfinished copies to fail. | For deliberate capture/copy recovery with an owned snapshot. Successful copies normally have export revoked by Refresh automatically. Does not revoke staging-blob SAS. |
| **Reconcile unknown import ID** | Links the actual existing import to a row whose submission result was uncertain. | Exactly one **ImportUnknown** row. Enter the real **W365 import snapshot GUID** in the adjacent box—not an Azure resource/copy ID. No new import is submitted. |
| **Reset failed / purged capture** | Deletes verified terminal Azure artifacts and prepares the row for a new capture attempt. | For reviewed **pre-license** recovery, or continuing ResettingCapture. No pending copies/live or unknown import/license/Cloud PC. Does not restart the source. |
| **Abandon + remove owned artifacts** | Deletes verified terminal Azure artifacts and marks the attempt abandoned. | When ending a safe **pre-license** attempt, or continuing Abandoning. Not a rollback of a provisioned Cloud PC. |
| **Reconcile license (no write)** | Checks and records evidence of an uncertain license assignment without assigning again. | Exactly one **LicenseUnknown** row. **Both boxes are required:** reviewed audit reference **and actual assignment time** with a time zone. Not for an ordinary provisioning failure. |

**Do not use any recovery button simply because it is enabled.** Read the detailed [recovery restrictions and input examples](#tab-5--dashboard--graph). Preserve the original journal and never guess IDs/times or edit its phase to bypass checks.

### Saved migration journals dialog

| Button/control | Simply put | When to use |
|---|---|---|
| **Refresh list** | Rescans local journals, not cloud progress. | If the list may have changed. |
| **Browse another journal…** | Opens a file picker for an original journal stored elsewhere. | When eligible to load in a fresh connected session and the journal is not listed. |
| **Show archived** | Displays archived journals too. | To inspect or resume archived history; does not move files. |
| **Resume selected** | Loads the selected trusted matching plan through the normal confirmation/checks. | After connecting in a fresh session and selecting the correct nonempty journal. Then Refresh status. |
| **Archive selected…** | Moves the journal and audit sidecars into an archive folder. No cloud changes or permanent deletion. | Only for empty startup, unused artifact-free draft or all-Cleaned/Abandoned plans. Current/open/unfinished plans are protected; **Validated alone is not enough**. |
| **Close** | Closes the dialog. | When finished or when you do not want to load a plan. Previously confirmed archives remain done. |

### Global and confirmation buttons

| Button/control | Simply put | When to use |
|---|---|---|
| **Microsoft Learn ↗** | Opens public migration documentation. | For product reference. Does not change the migration. |
| **Stop after current step** | Requests the local worker stop between steps. | While an operation is running and you want to stop further work. Current calls/cloud work may continue; **no rollback**. |
| Window **X** | Closes the idle app; releases local locks. | When local work has finished. If busy, it requests stop but prevents closing until the worker finishes. |
| Risk notice **Yes / No** | Accepts or cancels the specific risk notice. | Read the effect and scope; choose No if unsure. A detailed confirmation may follow. |
| Prerequisite acknowledgement checkbox | Confirms you reviewed current PASS results and the exact scope. | In Prepare/Capture/Import/License confirmation, after meeting the requirements. It does not bypass validation. |
| **Confirm operation** | Submits the reviewed action if all checks still pass. | Only after verifying the full scope/effects. Submission success is not asynchronous completion. |
| **Cancel** | Closes without submitting this requested action. | If unsure or inputs/scope are wrong. Does not undo earlier work. |
| Result **Close** / notice **OK** | Dismisses the displayed result/message. | After reading it. Does not start the next stage or record user acceptance. |
| File picker **Save / Open / Cancel** | Selects a save/export destination, selects a trusted journal, or exits the picker. | Review filename/location; normal action checks still follow. Reports are not resumable journals. See [file selection](#file-selection-and-exports). |

## Operating rules and selection

- **Use checkboxes select action targets.** Highlighting a row only displays its details. On Select & map, Use selects inventory VMs for the draft. On Migration, Use selects existing plan rows for operations and auto-refresh. These are different grids.
- **Repair snapshot setting + assignments (batch)** and **Use images for future reprovision** affect the **entire plan**, regardless of which rows are checked. Prepare for an existing-group plan requires every batch row checked. Save/report cover the whole plan/session, not only checked rows.
- A disabled button is intentional: hover over it for the reason, then read **NEXT STEP · checked rows**. Stage checks run again at click time and after confirmation. An enabled button is only permission to request an operation, not proof that its live checks will pass.
- Only one local worker operation runs at a time. Migration controls/selection are locked while it runs. **Stop after current step** is cooperative, not rollback. Closing during work requests stop and is refused until the worker finishes.
- Copy/import/provisioning continue server-side after the worker returns. Normal forward buttons stay disabled in **Copying / Importing / Provisioning**. Use Refresh; it never starts the next migration stage automatically. Applicable recovery controls remain separately guarded.
- Open review dialogs, notices, file pickers and journal manager pause polling/dispatch, **not Azure or W365 work**. Close the dialog to resume app polling.
- Prepare, Capture, Import and License each require **3 Validate prerequisites** for their own next stage. Approval is single-use, expires after 30 minutes and is not saved in a journal. Attestation alone is not approval. Changed state/evidence or reload invalidates approval; do not interpret an old Ready label/report as permission.
- Stay within one tenant/subscription and a reviewed batch. Keep an exclusive administration window: local locks cannot stop another administrator changing cloud resources or operating a copy on another computer.
- Never supply passwords, tokens, storage keys or SAS URLs in application inputs. Sign in only through Azure/Graph authentication prompts. Protect logs, journals and exports: user/resource IDs remain sensitive even when secrets are redacted.
- Keep the source stopped/write-frozen after capture. Do not recapture, reimport, reassign a license or restart the source to resolve a status-display problem.

## Global controls

| Control/display | What it does / how to use it |
|---|---|
| **Microsoft Learn ↗** (`DocsButton`) | Opens the public Windows 365 migration documentation in the default browser. It is not an in-app action and does not change the plan. The full local button reference is this guide. |
| Connection display (`ConnectionText`) | Shows connection information. Verify the intended tenant/subscription; changing a picker does not itself reconnect. |
| Controlled-pilot banner | Reminds you of Graph beta, Commercial/Enterprise/Gen2 restrictions and that source VMs are never deleted. |
| Plan/path footer (`PlanLabel`) | Identifies the current plan and storage paths. Hover when truncated. A startup journal is not necessarily the journal owning a previous migration. |
| Status footer (`StatusText`) | Shows current work, returns and errors. An operation returning does not mean asynchronous work finished. Read row errors and the result dialog. |
| Activity bar (`WorkProgress`) | Indeterminate while the local worker is busy. **Not a copy/import/provisioning percentage**. |
| **Stop after current step** (`CancelButton`) | Enabled during local work. Requests stop at the next cooperative boundary; the current API call and submitted cloud work may continue. No automatic undo, VM restart or resource cleanup. Wait for the returned phase and review the journal. |
| Window **X** / close | Releases local journal/plan locks after work finishes. During work, requests stop and prevents closing. Closing an idle window does not cancel cloud copy/import/provisioning. Resume the same journal afterward. |

## Tab 1 — Connect & configure

Use this tab for a **new** batch. To continue an existing migration, connect to its scope, then load its original journal **before creating mappings**. Do not recreate its policy/group/settings just because the app restarted.

### Connection and destination inputs

| Field | Required value and behavior |
|---|---|
| **Tenant ID (GUID)** (`TenantId`) | The intended Microsoft Entra tenant GUID, for example `22222222-2222-2222-2222-222222222222` (illustration only; replace it). Not a UPN, domain, subscription ID or secret. The optional startup `-TenantId` parameter prepopulates and locks it. Tenant/scope changes are locked once plan rows exist; use a fresh session for another scope. |
| **2 Select Azure subscription (name and ID)** (`SubscriptionPicker`) | Detect subscriptions first, then explicitly choose an enabled accessible subscription in this tenant. Nothing is automatically selected. The source, staging and snapshot destination must be in this subscription. Changing selection clears old discovery; connect again before using it. |
| **Existing Enterprise dedicated provisioning policy** (`PolicyPicker`) | Select the existing intended Windows 365 dedicated policy after discovery. Independently verify region, join, network/ANC and assignments. This field does not create/edit the policy. Changing it clears the candidate user-group selection; find groups again. |
| **Windows 365 Enterprise / CloudPC Lite — no Flex, Frontline or GPU** (`SkuPicker`) | Select the intended eligible SKU with enough available seats and suitable disk capacity. Zero-seat/disabled options cannot be chosen; unsupported/unresolved options are excluded. CloudPC Lite is an explicit selection exception, not certification of entitlement: verify service eligibility. No license is assigned by selecting it. |
| License summary (`LicenseInfo`) | Displays Available / Assigned / Enabled counts and SKU state. Counts are re-read for safety and are not a reservation. |
| **Target license disk capacity (GiB)** (`DiskSize`) | **Read-only.** Resolved from the selected SKU. Do not type used-space estimates here: the source provisioned OS-disk capacity must fit. Choose a different eligible SKU if needed. |
| **Customer-owned staging account (same subscription)** (`StoragePicker`) | Select an existing supported Storage/StorageV2 account. The app requires public endpoint enabled/default network Allow, but **private container** access. It does not change firewalls or create the account. Ensure blob data and user-delegation-key rights. |
| **Existing PRIVATE blob container** (`ContainerName`) | Existing container name only, default `cpc-migration`; replace if your approved container has another name. Not a URL, resource ID, SAS or folder path. It must exist in the selected account and disallow anonymous access. The app does not create it. |
| **Destination resource group for temporary managed snapshots** (`SnapshotGroup`) | Select an existing resource group in the connected subscription where temporary managed snapshots may be created/deleted. This is independent of the source VM filter on Tab 2. No resource group is created. |

Destination configuration and source mapping edits are locked once prepared. UI changes do not alter an already-created plan until a permitted **Create / update draft mappings** operation commits that draft.

### Buttons and guidance

| Button | Purpose, prerequisites and effect |
|---|---|
| **Check workstation prerequisites** (`LocalButton`) | Reports installed Az/Graph modules, runtime and Trusted Launch export capability in Tab 4. Does not sign in, install packages or validate the migration's cloud prerequisites. Review Fail versus Manual results. |
| **Install / update dependencies** (`InstallButton`) | After confirmation, installs/updates Az.Accounts, Az.Resources, Az.Compute, Az.Storage and Microsoft.Graph.Authentication from PSGallery for CurrentUser. Local package changes, internet/package policy required; no elevation/cloud changes. **Restart to load updated assemblies**, at an idle safe point using the original journal. |
| **1 Sign in to Azure / detect subscriptions** (`DetectSubscriptionsButton`) | Requires the tenant GUID. Signs into Azure and lists accessible enabled subscriptions; does not connect Graph yet. Clears old inventory. Select a subscription explicitly next. |
| **3 Connect selected subscription + Graph** (`ConnectButton`) | Requires the detected subscription selection. Authenticates the tenant/subscription and Graph with the documented delegated scopes; consent/roles/PIM/Conditional Access still apply. Does not create migration resources or assign licenses. |
| **4 Discover VMs / resource groups** (`DiscoverButton`) | Reads connected-scope inventory and destination choices. Rediscovery resets unsubmitted VM checks/UPN edits; it is not the way to restore a plan. Use Refresh status for migration progress. |
| **Refresh available licenses** (`RefreshLicensesButton`) | Updates SKU/seat counts without reloading the VM inventory/mappings. Does not buy/reserve/assign licenses. Prepared configuration remains locked. |
| **Resume / load journal** (`ResumeButton`) | Opens the [saved journals dialog](#saved-migration-journals-dialog). Loading requires a fresh connected session with no plan rows and matching scope. Restores recorded ownership, not approval. |
| **Manage saved journals / archive** (`JournalManagerButton`) | Opens the same dialog for local housekeeping, also without sign-in. Archive never cleans cloud resources. Resume/Browse still require a fresh matching connection. |
| Subscription guidance (`SubscriptionHint`) | Explains detection, explicit selection and reconnect requirements. |
| Resume guidance (`ResumeHintText`) / startup reminder | Points to saved same-scope plans and original-journal recovery. Nothing is auto-loaded. Choose by VM/user/phase/plan, not newest filename. |
| Before-you-begin checklist and boundary notes | Read-only summary, not checkboxes recording acceptance. Attestation is the explicit action on Tab 3. |

For first launch/runtime/signing and exact permissions, see [README: Start](../README.md#start) and [permissions](../README.md#permissions-and-existing-infrastructure).

## Tab 2 — Select & map

| Control | What to enter / what happens |
|---|---|
| **Source VM resource group** (`SourceGroupPicker`) | Select a source group or **All resource groups**. Filters visible inventory only; does not move VMs or change snapshot destination. Hidden checked VMs remain selected. |
| **Search VM / resource group / region** (`SearchBox`) | Optional text filter combined with the source-group filter. Clear to see more inventory. Not a UPN lookup or Azure-wide search. Hidden selections/UPN edits remain. |
| Scope/selection summary (`VmScopeText`) | Shows inventory scope/selection information. Review total selection, not only visible rows. |
| Inventory grid (`VmGrid`) — **Use** | Check each source VM to include in group search and mapping. Source actions do not run from this checkbox. |
| Inventory grid — **Target user UPN (edit)** | One existing target user UPN per checked VM, for example `pilot.user@contoso.com`. Not display name/object ID/password. Unique user per VM/batch; verify the actual source profile/data belongs to that user. User must resolve in this tenant and meet enabled/usage-location/license checks. |
| Inventory grid — **VM / Resource group / Region / VM size / OS / VM resource ID** | Read-only inventory. Review full resource ID to distinguish duplicate names. These fields cannot resize or relocate a VM. |
| **Find groups for selected users + policy** (`FindGroupsButton`) | Requires checked VMs, entered UPNs and a selected dedicated policy. Commits grid edits, resolves users, reads common direct memberships already directly assigned to that policy. Read-only in cloud; no group/assignment repair. |
| User-group dropdown (`UserGroupPicker`) | Explicitly choose the correct returned **name and ID**, even with one result. The group must contain exactly the mapped users as direct members; every member receives the snapshot setting. A broader unrelated-user group is unsafe. |
| User-group guidance (`UserGroupHint`) | Explains selection and policy requirements. Changing policy invalidates candidates; rerun group discovery after changing users/policy. Membership is rechecked at mapping/validation. |
| **Create / update draft mappings** (`MapButton`) | Requires complete Tab 1 destination settings, eligible SKU, checked source rows/unique UPNs and selected group. Reviews the entire checked inventory including hidden rows, then creates/replaces **only an unprepared local draft** and persists it. No VM stop, import or licensing. Previous attestation/validation no longer applies. Prepared or overlapping locally recorded migrations block replacement: resume their original journal instead. |

**Group boundaries:** no extra users, nested/dynamic/synced groups, unsupported/filtered assignment targets or inherited group licensing. The selected group must already be assigned to the intended policy. The app does not alter membership/policy assignments for new existing-group plans. Resolve prerequisites with the authorized Entra/Intune admin, not by guessing another group or deleting a conflicting setting.

## Tab 3 — Migration

### Journal, monitoring and report toolbar

| Button/input | Purpose and required scope |
|---|---|
| **Save journal as... (optional)** (`SaveButton`) | Saves the whole plan to a trusted writable JSON path and switches the active journal there. Automatic journaling already runs; this is not a required step before each action. The session log stays at its startup location. Save As is not a second independent migration and cannot overwrite a different plan. |
| **Load journal** (`LoadButton`) | Same manager/resume flow as Tab 1. Fresh connected session, no mappings already open, matching tenant/subscription and trusted original journal required. |
| **Export HTML / CSV / JSON** (`ExportButton`) | Exports the whole current plan/checks and session Graph/log data, not just checked rows. The HTML file dialog effectively selects a **directory**; the engine writes fixed report names there, even if a different HTML basename was entered. Existing reports with those names may be replaced. It is not a resumable journal. See [file dialogs](#confirmation-result-and-file-dialogs). |
| **Refresh status** (`RefreshButton`) | Requires Use-checked rows and a connection. Reads copy/import/Cloud PC state and saves results. **Not entirely cloud-read-only:** when every owned staging copy is complete, revokes snapshot export access before advancing to Staged. Does not recapture/reimport/license. Review Last error if phase does not advance. |
| **Auto-refresh selected (30s)** (`AutoRefresh`) | After review, polls the currently Use-checked rows approximately every 30 seconds when idle. Changing checked rows changes polling scope. Uncheck to stop polling; this does not stop cloud work. Pauses during operations/dialogs. Never auto-starts the next migration action. |

### Numbered actions

These are not nine buttons to click once in a row. **Step 3 is repeated for each major stage**, and Refresh is required between asynchronous stages. After reload/repair/reassessment, renew attestation when indicated.

| Button | When / what it does | Next step and risks |
|---|---|---|
| **1 Assess guest** (`GuestButton`) | Before capture, in Mapped/IdentityPrepared/CaptureFailed **only when evidence is not frozen** (no recorded snapshot/source identity). Source must be running. Executes read-only guest inspection as SYSTEM using Azure Run Command; collects OS/join/tenant/BitLocker/agent evidence. Requires Run Command permission. | Clears prior attestation/approval. Review evidence → 2 → 3. Does not uninstall agents, decrypt, generalize or repair the guest. Repeat after pre-capture remediation/reboot; never restart a captured source merely to use this button. |
| **2 Attest prerequisites** (`AttestButton`) | Requires saved guest evidence and a phase whose next stage is Prepare/Capture/Import/License. Records the operator's confirmation for every checked row; no cloud remediation. | Complete the checklist below, then 3. Not proof from an automated test, and not permission to skip failed checks. Disabled while Copying/Importing/Provisioning. |
| **3 Validate prerequisites** (`CheckButton`) | Requires attestation and guest evidence; select rows with the same next stage. Reads live cloud prerequisites and saved guest observations. For Import/License also checks retained snapshot/copies/structure; for License checks current successful unused import identity. May generate short-lived read-only SAS for inspection. | Review Tab 4/result dialog. Passing grants a single-use 30-minute approval for **that stage**. Does not stop VM/import/assign license. It does not recollect guest evidence. |
| **4 Prepare snapshot provisioning** (`PrepareButton`) | Mapped + Prepare approval; **all batch rows selected** for existing-group plans. Creates a plan-owned snapshot user setting and assigns it to the selected existing group. | Becomes IdentityPrepared. Wait for propagation, validate for Capture. Affects the whole selected group, but does not change its members/policy or assign a license. Legacy owned-group journals follow their original group-creation/assignment flow. |
| **5 Stop + capture** (`CaptureButton`) | IdentityPrepared or guarded CaptureFailed/Capturing recovery + Capture approval. Rechecks, deallocates source, creates a billable managed OS snapshot, grants 24-hour export access, starts OS VHD and applicable VMGS copies into staging. | **Outage and costs.** Sources remain stopped; no rollback/restart/delete. Normally returns Copying; Refresh until Staged. Recovery is not permission to overwrite unknown artifacts. |
| **6 Import to W365** (`ImportButton`) | Staged + Import approval. Rechecks staged artifacts and submits the per-user Graph beta import with read-only 48-hour SAS held in memory. | Importing → Refresh until Imported (`succeeded`, `notUsed`). No license assigned yet. Do not resubmit after a timeout/unknown response. |
| **7 Start migration / assign license** (`LicenseButton`) | Imported + License approval, live successful unused matching import, retained staging and valid user/policy/settings/license checks. Assigns the chosen exact SKU. | Consumes seats/can incur costs and starts Cloud PC provisioning. Provisioning → Refresh until Provisioned. Does not remove existing licenses. Unknown outcome requires audit recovery, never another blind assignment. |
| **8 Validate cutover (final)** (`ValidateButton`) | Provisioned, recorded successful import and license history; independent user/data validation completed. Verifies live Cloud PC identity/policy/status and records operator acceptance/time. | Becomes Validated. No new preflight from step 3 is required for this final action. This is **not** a substitute for signing in and checking restored content. No source restart/delete. |
| **9 Cleanup staging** (`CleanupButton`) | Validated or restartable CleanupPending with recorded acceptance; retention/backup requirements met. Deletes **owned Azure VHD/VMGS blobs and managed snapshots**. | Permanent deletion; normally Cleaned. Leaves source VM, Cloud PC, licenses, group, policy and user setting. Does not purge the W365 import or archive/delete the journal. |
| **Repair snapshot setting + assignments (batch)** (`RepairSnapshotButton`) | Entire plan; owned prepared setting/group required, no provisioning/license/Cloud PC conflicts. UI accepts Mapped/IdentityPrepared/Staged/Imported/CaptureFailed only; live checks remain authoritative. Repairs snapshot mode and this setting's group assignment. | Whole-batch change even if one row checked. No import/license write and no existing-group membership/policy repair. Clears all attestations/approvals; wait, re-attest, validate. Does **not** need passing migration preflight because it repairs some prerequisites. Legacy owned-group plans can repair their owned membership/policy assignment. |

### What the Attest dialog asks you to verify

For **every checked VM**, confirm all of the following before accepting:

1. Correct source VM/profile/data → target-user mapping, independently verified.
2. Supported Windows client release/edition and lifecycle/ESU where applicable.
3. Third-party VDI agents removed and reboot completed; candidate inventory is not exhaustive.
4. Normal source boot, healthy guest agent and a tested recovery backup.
5. Correct Enterprise/Lite SKU/capacity and required Windows/Intune/Entra entitlements; Lite-specific eligibility if applicable.
6. Intended policy region/join/network and CSE/Windows 365 endpoint reachability.
7. No conflicting policy/settings, filters/exclusions, inherited W365 licenses, unused imports, pending license changes or concurrent administrators.
8. Approved outage, source write-freeze, rollback and data-integrity validation plan.
9. Acceptance of the controlled-pilot/Graph beta support limitation.

The checklist is a confirmation, not nine editable settings or automated fixes. Answer No/Cancel if any item is unverified.

### Migration grid and read-only inspector

| Display/input | Meaning |
|---|---|
| **NEXT STEP · checked rows** (`NextStepText`) | Stage-specific instructions for the Use selection. Mixed stages or missing approval/evidence explain why actions are blocked. Resume-refresh requirements take priority. |
| Guest-remediation banner | Pre-capture only: after join/BitLocker/agent fixes, repeat Assess → Attest → Validate. After capture evidence is frozen; follow recovery instead. |
| Plan grid (`PlanGrid`) — **Use** | Editable action selection. Highlight alone does not target a row. |
| **VM / User** | Recorded mapping; read-only here. Do not alter journal identities to change the target. |
| **Phase** | Local workflow stage; see [phase dictionary](#phase-dictionary-and-allowed-next-steps). Distinct from service Import/Cloud PC status. |
| **Readiness** | Validation result such as NotChecked/Ready/Blocked. Ready is not completion and does not outlive an expired/consumed approval. |
| **Guest assessed (recorded)** | Collection timestamp of saved guest evidence, not the most recent cloud poll/validation time. |
| **Import** | Last accepted import status, such as inProgress/succeeded/failed. On lookup failure, historical status may remain; read Last error. |
| **Cloud PC** | Last observed service provisioning status. Provisioned is not proof of user/data acceptance. |
| **Detail / copy progress** | OS VHD and VMGS byte counts/statuses, or returned import detail. One small successful VMGS artifact does not mean the OS VHD finished. No invented import/provisioning percentage. |
| **Last error** | Last operation/status-read problem for this row. An old phase can be retained after a failed read; do not infer a failed import from a lookup error. |
| JSON inspector below grid (`RowJson`) | **Read-only, copyable** evidence/IDs for the highlighted row, including guest and artifact identifiers. No input is required. It is not a journal editor. |

## Tab 4 — Prerequisite results

No editable fields or action buttons on this tab. Return to Migration for assessment/attestation/validation.

| Grid (`CheckGrid`) column | Meaning |
|---|---|
| **VM / scope** | VM, Batch or Workstation to which a check applies. A batch failure can block otherwise healthy rows. |
| **Check** | The condition tested or manual responsibility. |
| **Result** | Pass = this check passed; Fail = blocking condition (red); Manual = operator responsibility/advisory (amber), **not automatic proof or automatically a failure**. |
| **Evidence / remediation** | Actual observations and corrective instructions; use the guest collection timestamp here to detect stale evidence. |
| **Checked UTC** | When validation ran, **not when Windows guest evidence was collected**. |

Read all failures plus manual items. Fix prerequisites through approved administration, then reassess only if guest evidence changed before capture, re-attest as required, and validate the current stage again. Validation never silently repairs group/network/OS issues.

## Tab 5 — Dashboard & Graph

### Status and Graph displays

| Display | Meaning / interaction |
|---|---|
| **MAPPED** (`TotalCard`) | Total plan rows, not just rows whose Phase equals Mapped and not only checked rows. |
| **CHECKS READY** (`ReadyCard`) | Rows with recorded Readiness = Ready. A summary, not an approval check; expiry/phase/live checks still gate actions. |
| **IMPORT SUCCEEDED** (`ImportedCard`) | Rows whose recorded ImportStatus is succeeded, including historical results after consumption. Not necessarily unused imports or completed migrations. |
| **CUTOVER VALIDATED** (`ValidatedCard`) | Rows in Validated or Cleaned. Requires recorded operator acceptance. |
| Phase chart (`ChartPanel`) | Counts of rows by phase for the whole plan. Not a byte/time percentage. |
| Graph request grid (`GraphGrid`) | Read-only **UTC / Verb / Graph endpoint / Client request ID**. Select a request to inspect its response. Request time identifies the observation; a previously selected response is not necessarily the latest status. |
| Graph response text (`GraphJson`) | Read-only copyable response for the highlighted request. No input needed. SAS query strings are redacted, but user IDs remain sensitive. API response success is not final cutover acceptance. |
| Recovery scope (`RecoveryScopeText`) | Identifies affected Migration **Use-checked** rows and whole-batch exceptions. Highlighting a Graph response does **not** change recovery targets. |

### Recovery buttons

Use these only after establishing the actual server outcome. They are not alternate ways to skip the normal workflow. No automatic retries of ambiguous mutation requests are performed.

| Button | Eligible scope, effect and cautions |
|---|---|
| **Purge unused W365 import** (`PurgeButton`) | Checked Imported/ImportFailed rows with known terminal `succeeded`/`failed`, `notUsed` imports, matching user and no license/Cloud PC. **Deletes the W365 import**, not Azure staging/snapshot. Records Purged. An uncertain response becomes PurgeUnknown; do not retry blindly. |
| **Revoke Azure export** (`RevokeButton`) | Checked Capturing/CaptureFailed/Copying/CopyFailed rows with an owned snapshot. Revokes its export access; can interrupt pending copies and marks capture/copy rows CopyFailed where applicable. Does not revoke separate staging-blob SAS, restart VMs or delete artifacts. Normally Refresh revokes export on successful staging completion, so no need after Staged. |
| **Use images for future reprovision** (`ImageButton`) | **Entire plan**, all rows Validated/Cleaned/Abandoned; validates setting/group ownership and rechecks abandoned users have no Cloud PC/license. Changes the dedicated setting from snapshot to image for **future reprovisioning**. Does not reprovision current PCs, remove membership/policy or delete the setting. |
| **Reconcile unknown import ID** (`ReconcileButton`) | Exactly one Use-checked **ImportUnknown** row and the known nonzero import GUID in the adjacent box. Reads the existing result and verifies user, unique filename and attempt time before recording the ID/refreshing. No new import. Foreign/unverifiable evidence blocks; do not invent a matching filename or edit the journal. |
| **Reset failed / purged capture** (`ResetCaptureButton`) | Guarded pre-license recovery: Mapped/IdentityPrepared/Capturing/CaptureFailed/Copying/CopyFailed/Staged/Purged, or replay ResettingCapture with prior durable approval. Requires no live/unknown import, W365 license or Cloud PC, and terminal owned copies. **Deletes owned staging/snapshot artifacts**, archives attempt IDs, resets toward IdentityPrepared/ Mapped with approvals cleared. Never restarts source or silently overwrites blobs. |
| **Abandon + remove owned artifacts** (`AbandonButton`) | Same pre-license/ownership/terminal-copy restrictions as reset, or replay Abandoning with prior approval. Deletes owned Azure artifacts, keeps attempt history and marks Abandoned rather than preparing a retry. Group/settings/policy remain. Not a rollback of provisioned Cloud PCs. |
| **Reconcile license (no write)** (`ReconcileLicenseButton`) | Exactly one Use-checked **LicenseUnknown** row plus reviewed reference and actual assignment time. Checks the exact active direct SKU/user and a unique matching Cloud PC/policy/creation time using historical successful import evidence. Records attribution locally; **no license/import write**, and does not need the consumed-import lookup. No matching PC/evidence means investigate/wait, not retry assignment. |

Reset/abandon **reject pending copies even if their button is enabled**. Purge a terminal unused import first where applicable. Interrupted recovery must use the same action, not switch reset ↔ abandon to bypass its durable evidence. Use [README recovery boundaries](../README.md#safe-resetabandon-boundaries) for ownership and concurrency limits.

### Recovery textboxes

These fields are disabled outside the applicable single-row recovery phase. While that phase is eligible, fields are editable even if the submit button is disabled because input is incomplete. They clear when the selected row/phase/plan changes to prevent applying another user's evidence.

| Input | Required value / example |
|---|---|
| Snapshot-ID box next to **Reconcile unknown import ID** (`ImportId`) | The **actual W365 imported snapshot ID** from trustworthy service evidence, in nonzero GUID form. Not the Azure managed-snapshot resource ID, VHD copy ID, Cloud PC ID, filename, SAS or user ID. GUID format alone is insufficient: backend correlation must pass. |
| First box under **LicenseUnknown recovery (read-only)** (`LicenseEvidence`) | Nonblank reviewed Entra audit/request reference proving this exact migration's user/SKU assignment, at most **2,000 characters**. Example format: `Reviewed Entra audit event <actual-event-id> for this user and SKU`. Supply the real reference, not this placeholder, a guess or a token. Stored as operator evidence, not automatically fetched/verified against Entra audit logs. |
| Second box (`LicenseAssignedUtc`) | **Actual assignment time from that evidence**, ISO 8601 with `Z` or explicit offset; example format `2026-09-17T10:15:00Z`. Must not be future time and must satisfy backend ordering against the import/attempt/Cloud PC. Never substitute current time or local time without a zone. |

## Tab 6 — Activity log

| Field | Purpose |
|---|---|
| Paths (`LogLocationText`) | Read-only, selectable/copyable session-log and current recovery-journal paths. No value to enter. Verify which journal is active before closing or sharing evidence. |
| Activity text (`LogBox`) | Read-only scrolling session activity/error history. Useful for tracing what was submitted versus merely observed. Not a command console; typing/pasting here does not run recovery. |

Startup write-tests the script folder, then falls back to the executing user's Documents/MigrateLog with a notice. If neither location works, startup stops. Session logs persist across Save As/Load within that app run; the active journal switches. Adjacent bounded audit sidecars accompany journals. Logs/journals are not a full disk backup, and exported activity is not a replacement for the durable session log.

## Saved migration journals dialog

Opened by Tab 1 **Resume / load journal**, **Manage saved journals / archive**, or Tab 3 **Load journal**. No row is automatically selected. Local inventory is advisory; actual load/archive revalidates content, scope and locks.

| Control | Purpose / requirement |
|---|---|
| **Refresh list** (`Refresh`) | Rescans local journal metadata only. Does **not** refresh cloud status; use Migration's Refresh status after loading. |
| **Browse another journal…** (`Browse`) | Opens a JSON file picker for a trusted journal outside listed folders. Requires a fresh connected session eligible to load. Choosing a file returns it for normal load confirmation/validation, not automatic adoption of resources. |
| **Show archived** (`ShowArchived`) | Includes managed archive subfolders in the list. Does not restore/move files or change cloud state. You can resume an eligible archived journal directly. |
| Journal grid (`Journals`) | Single-row selection, read-only. Columns **Open here / Category / VM · phase · user / Last saved UTC / Archived / Plan ID** distinguish active, draft and unfinished plans. Open here and Archived are indicators, not editable checkboxes. |
| Details box (`Details`) | Read-only full path, plan/tenant/subscription, summary and archive eligibility/reason. Select/copy paths; verify ownership rather than choosing by age alone. |
| **Resume selected** (`Resume`) | Selected nonempty matching-scope journal, fresh connected app, not the current plan. Returns path to normal trusted-journal confirmation/load. Refresh FIRST afterward. Lock/schema/identity failures still block loading. |
| **Archive selected…** (`Archive`) | Confirm a local move of eligible JSON + adjacent audit sidecars to a unique JournalArchive subfolder. Empty startup, truly artifact-free unprepared draft or **all Cleaned/Abandoned** only; Validated alone is not sufficient. Current/open/unfinished/stale/unsafe-path plans are blocked. No cloud deletion or permanent file deletion. |
| **Close** (`Close`) / dialog X | Closes the manager without loading a journal. Any explicitly completed archive remains done. App polling resumes when the modal closes. |

Archive rechecks content fingerprints and holds journal-path/plan locks. Session logs and lock files stay where they are. Review the reported destination if archive fails; rollback is best-effort. Archive organizes files, **does not reclaim disk space**. Archived prepared history still participates in duplicate-source mapping checks; archiving/deleting history is not permission to remigrate.

Discovery covers the script directory, Documents/MigrateLog and current journal directory; the manager can include their managed archive folders. Recognition is limited to supported JSON journals up to 32 MiB; malformed files are left untouched. Another directory requires Browse. Offline housekeeping can list unconnected startup journals, but cannot resume without connection. Protect archives like active journals; locks are local to the Windows user/workstation, not distributed.

## Confirmation, result and file dialogs

### Action/risk confirmation

Some actions first display an explicit Yes/No risk notice, then the detailed review. **No/Cancel aborts that requested operation**; it does not undo previously submitted cloud work. Authentication/consent prompts are separate: enter credentials only there.

The detailed review displays action/risk, tenant/subscription, plan/journal, policy, SKU, staging/group/setting, selected VM/user/artifact IDs and operation inputs. The large text area is **read-only and copyable**; unresolved IDs are not invented. Review every batch member and the full resource IDs.

| Dialog control | How it works |
|---|---|
| **Customer/admin prerequisites are completed; I reviewed PASS validation for this stage and confirm this exact scope.** | Acknowledgement checkbox for Prepare/Capture/Import/License. Only check after a current successful validation and actual review. Enables Confirm operation in the dialog; backend expiry/live checks still run afterward. |
| **Confirm operation** | Submits the reviewed request if gates still pass. Does not guarantee server-side completion. |
| **Cancel** | Default/escape action; closes without submitting this operation. Pressing Enter must not be relied on as approval. |
| Red issue cards / **NEXT** text | Failed checks/operation error plus remediation. Copyable, not editable. An operation error with no failed prerequisite checks is explicitly distinguished from a failed-check count. |
| Amber Manual cards | Responsibilities requiring independent operator evidence. Not a substitute for resolving red failures. |
| Result dialog **Close** | Acknowledges returned results only; does not authorize another stage. A successful submission may still be Copying/Importing/Provisioning. |
| Notice **OK**, risk/archive **Yes / No** | Read the notice; choose Yes only for the exact requested action. Closing a notice is not cutover validation. Archive confirms local files only; Cleanup/Purge/Reset/Abandon have separate destructive effects. |

### File selection and exports

- **Save journal as...**: JSON save picker, default basename `migration-plan.json`; select a protected writable destination. Cancel leaves the current path unchanged. Existing foreign-plan/active-plan protections still apply after selection.
- **Browse another journal…**: JSON open picker; select the **original trusted journal**, not prerequisite/Graph report JSON. File-picker Open does not bypass load scope/ownership checks.
- **Export HTML / CSV / JSON**: HTML save picker, default basename `migration-report.html`. **Only its directory is used**. The engine writes the following fixed names; use a new report folder per evidence snapshot to avoid replacement:
  - `migration-report.html`: phase summary, migration rows and prerequisites.
  - `migration-results.csv`: plan-row fields excluding nested Guest; formula-like text is escaped for spreadsheets.
  - `prerequisites.json`: recorded check evidence.
  - `graph-results.redacted.json`: this session's captured Graph results.
  - `activity.log`: current in-memory activity export, separate from the automatic durable session log.
- Reports contain sensitive identifiers. They do not contain authorization receipts and **cannot be loaded to resume**. The engine's fixed filenames/overwrite behavior are current behavior, not a selectable output-format checkbox.

## Phase dictionary and allowed next steps

Normal path: **Mapped → IdentityPrepared → Copying → Staged → Importing → Imported → Provisioning → Provisioned → Validated → Cleaned**. Submission/capture states are recorded for crash recovery, not invitations to repeat a write.

Every row action also requires a connection, idle worker, appropriate Use selection and successful post-load Refresh. Major actions need renewed stage approval. This table describes intent; live identity/ownership/permission checks can still reject an action.

| Phase | Meaning / permitted direction |
|---|---|
| Mapped | Local draft. Assess guest → Attest → Validate for Prepare → Prepare. No snapshot/import/license yet. |
| IdentityPrepared | Setting/group preparation recorded; **do not repeat step 4**. After propagation and evidence review, Attest if needed → Validate for Capture → Stop + capture. |
| Capturing | Capture began/interrupted before normal copy submission completed. During a running worker wait; after recovery inspect saved IDs/error. Guarded capture continuation/revoke/reset may be available; no blind new capture. |
| CaptureFailed | Capture did not complete cleanly. Review actual source/snapshot/copy outcome. Fresh validation is needed before a permitted continuation; reassessment only if unfrozen. Reset may be necessary. |
| Copying | Azure staging copies submitted. Normal forward actions disabled; Refresh until all applicable copies complete and export revocation succeeds. |
| CopyFailed | Failed/aborted copy or explicit export revocation recovery. Resolve actual copy outcome; reset/abandon only with terminal owned artifacts. Import is blocked. |
| Staged | All copies verified and export revoked. Attest if needed → Validate for Import → Import to W365. |
| ImportSubmitting | Import request boundary was journaled. On reload becomes ImportUnknown, not an automatic retry. |
| ImportUnknown | Import may have been accepted but ID/outcome is uncertain. Obtain genuine service evidence and use single-row Reconcile unknown import ID. |
| Importing | Import ID recorded; completion not yet accepted. Refresh until Imported or ImportFailed; forward buttons disabled. |
| Imported | Matching `succeeded` + `notUsed` import accepted. Attest if needed → Validate for License → Start migration / assign license. Optional purge is a destructive recovery alternative, not the normal next step. |
| ImportFailed | Known failed import. Inspect service details; purge only after confirming terminal/unused and no license/PC, then consider reset. No blind reimport. |
| LicenseSubmitting | License request boundary recorded. On reload becomes LicenseUnknown. |
| LicenseUnknown | Assignment outcome uncertain. **Only audit-based license reconciliation**, not ordinary validation/assignment, can establish attribution. No evidence means investigate, not retry. |
| Provisioning | License assignment recorded and Cloud PC creation pending. Refresh; no repeat license/import. A returned failed Cloud PC status requires investigation—no automatic rollback. |
| Provisioned | Service reports provisioned for the recorded assignment. User sign-in/data/app/Intune/network acceptance → Validate cutover (final). |
| Validated | Operator acceptance recorded. Retain artifacts as required, then optionally Cleanup staging. Eligible for whole-batch future-image change, **not journal archive until Cleaned/Abandoned**. |
| CleanupPending | Approved cleanup interrupted. Review error and repeat Cleanup to continue verified removal; do not treat permission errors as absence. |
| Cleaned | Owned Azure staging/snapshot cleanup complete. Source VM/Cloud PC/license/settings remain. Keep journal; eligible for archive and safe whole-batch image change. |
| PurgeSubmitting | W365 purge request boundary recorded. On reload becomes PurgeUnknown. |
| PurgeUnknown | Purge outcome uncertain; no automated reconcile/retry button for this phase. Preserve evidence and obtain service/manual recovery guidance. |
| Purged | W365 import removed; Azure artifacts may remain. Reset failed / purged capture for a reviewed new attempt, or Abandon. |
| ResettingCapture | Previously approved deletion/reset interrupted. Resume **Reset failed / purged capture** only with durable recorded approval and current ownership checks. |
| Abandoning | Previously approved deletion/abandon interrupted. Resume **Abandon + remove owned artifacts** under the same guards. |
| Abandoned | Pre-license attempt safely abandoned; source not restarted/deleted. Plan setting/group remain; use images when the entire batch is eligible. Journal may be archived. |

There is no automatic phase called “migration fully verified by Graph.” **Validated** is explicit human acceptance, and Cleaned describes only staging cleanup.

## Resume playbook

1. Wait until local work finishes before closing/relaunching. Cloud copy/import/provisioning may continue while the app is closed. Code/module updates only apply on the next launch.
2. Start with the same tenant (including `-TenantId` if used), detect and explicitly select the same subscription, connect Azure + Graph. **Do not create a new draft.**
3. Open Resume / load journal or Load journal. Identify the original plan by VM, user, scope, phase and IDs—not timestamp alone. Use Browse for other locations/Show archived for archived history.
4. Review the trusted-journal confirmation. Load must obtain schema/scope/identity/path/plan locks; do not modify JSON or remove an active lock to force it.
5. Check the intended Use rows and **Refresh status FIRST**. Other actions remain blocked until each affected row refreshes successfully. Unselected or failed refreshes do not unlock them.
6. Follow NEXT STEP for the **current refreshed phase**. Completed actions are not repeated. Load clears attestations and approvals, so renew Attest/Validate only where the next stage needs them. Guest evidence persists; recollect only before capture when allowed/needed.
7. Keep source write-freeze and exclusive administration throughout app downtime. The journal cannot prove nobody restarted/modified the source externally.

Examples:

- **Copying** → Refresh until **Staged** → Attest if needed → Validate for Import → Import.
- **Importing** → Refresh until **Imported** → Attest if needed → Validate for License → Start migration.
- **Provisioning** → Refresh until **Provisioned** → independently verify restored user experience → Validate cutover; no new guest assessment/preflight/license.
- **Validated** → after successful resume Refresh, review retention → optional Cleanup. Do not recapture/reimport to “restore” a completed stage.
- **Any refresh error** → inspect Last error and the latest Graph observation. No manual journal phase change to bypass the refresh gate. A consumed/missing import can leave historical success visible while independent Cloud PC monitoring continues; unresolved resume blocking needs reviewed recovery, not repeated writes.

## Troubleshooting and completion checklist

| Symptom | Safe response |
|---|---|
| Button disabled | Hover reason, check Use selection/current phase/next-step banner, successful resume Refresh, attestation and current-stage approval. Select same-stage rows for validation. Do not try a recovery button just to evade the gate. |
| “Ready” but next button blocked | Approval may be expired/consumed or for another stage. Run the indicated explicit validation; attest first only if required. A dashboard count is not permission. |
| Guest failures unchanged after fixing Windows | Before capture only: running VM → Assess guest → Attest → Validate. Validate alone reads saved evidence. Fully decrypt BitLocker; suspension/decrypting is insufficient. After capture, investigate recovery without restarting the source. |
| Small copy says Success | Check **both OS VHD and VMGS** progress. Wait for **Staged**, which requires all copies plus export revocation. |
| Graph says succeeded but row still Importing | Compare the latest response time, known import ID and user with Last error. Current code accepts the exact journaled UPN **or exact nonzero Entra user object ID** returned in `assignedUserPrincipalName`. Reload updated code at idle and Refresh the original plan; never reimport or manually set phase. Foreign/missing identities still block. |
| Import lookup unavailable after provisioning | Historical result may be retained; absence is not proof of failed import or correct restored data. Monitor the Cloud PC independently, inspect the actual endpoint/content, and preserve evidence. Do not clear the error by repeating import/license. |
| Provisioning failed or unusually slow | Inspect current service status/error and request IDs. Threshold warnings (2h capture/provisioning, 6h import) are advisory, **not SLAs**. No automatic license removal/reprovision/source restart. |
| Snapshot/setting conflict from an earlier run | Resume its original owning journal. New draft mappings do not restore ownership. Do not delete the setting/group/journal to bypass conflict checks. |
| No eligible group/SKU | Verify exact direct group membership/policy assignment, lack of inherited licenses, entitlements/capacity/seats and propagation. Group search and license refresh do not remediate assignments or purchase seats. |
| Unknown import/license/purge outcome | Do not replay the mutation. Use the applicable verified reconciliation flow or manual service investigation; absent objects or a present SKU alone do not establish original request outcome/timing. |

**Before step 8:** verify intended user can sign in, source snapshot/profile/files/apps are present, enrollment and network work, and user acceptance is recorded. Graph status alone cannot prove source-data provenance.

**Before step 9:** confirm backup/retention and recovery requirements permit permanent deletion of staging/snapshot artifacts. Do not delete the source VM as part of this tool's cleanup; source retirement is a separate reviewed process.

**After batch completion:** optionally change to images for future reprovision when all rows qualify; retain group/policy membership. Export protected evidence, preserve the owning journal/audit/logs, and archive only eligible local journals. Archive, Cleanup, Purge and Use images are **four different operations**, not interchangeable cleanup buttons.

### Return the group to normal image provisioning before changing membership

**Decide and complete the switch after validating the migration batch, but BEFORE adding/removing group members.** Provisioning alone is not enough: all plan rows must be **Validated / Cleaned / safely Abandoned**. For an existing-group plan, the workbench requires the group to still contain exactly the recorded batch users; membership changes can block the switch.

1. Finish provisioning and independent data/user acceptance, then record **8 Validate cutover (final)** for every successful migration. Cleanup is optional and separate; safely abandoned rows must satisfy their recovery checks.
2. While the original group membership is unchanged, click **Use images for future reprovision** on **Dashboard & Graph**. Review the **entire batch**, including unchecked rows, and confirm the operation succeeds. Allow service propagation before onboarding additional users; if the result is uncertain, verify the setting through Graph before proceeding.
3. Only afterward make reviewed membership changes for normal provisioning. New eligible, appropriately licensed users assigned the policy through this group can provision from the policy's image, subject to normal service prerequisites and effective assignments. The switch itself does not add users, assign licenses or trigger provisioning.

**What actually changes:** the app PATCHes the existing Windows 365 **user-setting object** so `provisioningSourceType` changes from `snapshot` to `image`. It does not remove a property directly from an Entra user/group. The setting remains assigned to the group, and users receive it through membership:

The request also carries forward its existing name, local-admin/reset flags and supported restore/disaster-recovery settings to satisfy Graph's required-field checks; these are not deliberately changed. The app reads the setting back and confirms `image` plus the original group assignment before reporting success. If already `image`, it verifies without another PATCH. A failed/unconfirmed read-back means **keep membership unchanged** and review the latest Graph response—not repeat migration stages. Older app versions that report `requiredFieldsNotProvided` on this button need to be closed when idle and relaunched with the updated code, then load the original journal and Refresh before trying again.

**User-setting object (`snapshot` → `image`) → assigned to group → applies to member users.**

- The setting ID in `PATCH …/userSettings/{userSettingId}` identifies the **setting**, not a user or group. Group assignment is a separate `POST …/userSettings/{userSettingId}/assign` operation; the switch does not change that assignment.
- The setting object, its assignment, user memberships, provisioning policy and licenses remain. Its name can still begin with **Snapshot-**: this button does not rename it.
- Current Cloud PCs and migrated data are untouched. A later deliberate **Reprovision** is a separate destructive rebuild using the then-current policy/image, not restoration of the migrated snapshot.
- **Do not remove migrated users from their provisioning-policy group merely to turn off snapshot mode.** Loss of effective policy assignment can affect continued Cloud PC entitlement; establish the intended ongoing assignment before restructuring groups.
- If group membership has already changed, stop and review with the responsible administrator. Do not edit the journal or remove unrelated users just to bypass the workbench's scope protection.

## Administrator references

- [Administrator start page](README.md): what the tool does and where to begin.
- [Project README](../README.md): installation, supported scope, permissions and security limitations.
- [Microsoft migration guidance](https://learn.microsoft.com/en-us/windows-365/enterprise/migration-to-windows365): supported migration scenario and product requirements.
- [Windows 365 requirements](https://learn.microsoft.com/en-us/windows-365/enterprise/requirements): licensing, identity and management prerequisites.

Use the guide that matches the installed tool version. Before broad rollout, complete an approved recoverable pilot and verify user sign-in, migrated applications and data. A successful service response alone is not user acceptance or proof that every recovery scenario works.