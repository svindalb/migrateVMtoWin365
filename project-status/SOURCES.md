# Research and API contract notes

Reviewed **2026-09-17**. Scope: customer-owned Azure VMs → Windows 365 Enterprise snapshot-based provisioning. Not Cloud PC region moves, generalized custom images, or the internal Enterprise V1 → CDP platform migration.

## Public documentation reviewed

| Reference | Implementation consequence |
|---|---|
| [Migration to Windows 365](https://learn.microsoft.com/en-us/windows-365/enterprise/migration-to-windows365) | Fixed VHD, Gen2, Windows client, no data disks, stopped/deallocated source, healthy Azure VM agent, incompatible third-party agent removal, user binding, snapshot flag, license after upload; Enterprise scope |
| [Windows 365 requirements](https://learn.microsoft.com/en-us/windows-365/enterprise/requirements) | Windows E3, Intune, Entra ID P1 and W365 licensing; tenant/enrollment/admin-role/ANC and regional requirements |
| [Import snapshot](https://learn.microsoft.com/en-us/graph/api/cloudpcsnapshot-importsnapshot?view=graph-rest-beta) | Exact Graph request: `assignedUserId` and `sourceFiles`; asynchronous result even when HTTP is 200 |
| [Snapshot import action detail](https://learn.microsoft.com/en-us/graph/api/resources/cloudpcsnapshotimportactiondetail?view=graph-rest-beta) | `sourceType = sasUrl`, `sasUrl`, `fileType = dataFile` or `virtualMachineGuestState`; storageBlobInfo takes precedence if supplied |
| [Snapshot import action result](https://learn.microsoft.com/en-us/graph/api/resources/cloudpcsnapshotimportactionresult?view=graph-rest-beta) | `snapshotId`, `filename`, `importStatus`, `usageStatus`, `assignedUserPrincipalName`, timestamps, policy/error detail |
| [Retrieve snapshot import result](https://learn.microsoft.com/en-us/graph/api/cloudpcsnapshot-retrievesnapshotimportresults?view=graph-rest-beta) | Poll function URL `retrieveSnapshotImportResult(snapshotId='…')`; use HTTP contract rather than inconsistent generated SDK snippets |
| [Purge imported snapshot](https://learn.microsoft.com/en-us/graph/api/cloudpcsnapshot-purgeimportedsnapshot?view=graph-rest-beta) | POST body `snapshotIds`; restrict destructive operation to known unused imports |
| [Cloud PC snapshot resource](https://learn.microsoft.com/en-us/graph/api/resources/cloudpcsnapshot?view=graph-rest-beta) | Distinguishes imported artifacts from existing Cloud PC restore points |
| [Cloud PC user setting](https://learn.microsoft.com/en-us/graph/api/resources/cloudpcusersetting?view=graph-rest-beta) | Separate snapshot-provisioning flag; default source is `image` |
| [Update user setting](https://learn.microsoft.com/en-us/graph/api/cloudpcusersetting-update?view=graph-rest-beta) | Source-mode PATCH carries forward live name, admin/reset flags and supported restore/DR settings; a source-only PATCH was rejected in the pilot |
| [Assign user setting](https://learn.microsoft.com/en-us/graph/api/cloudpcusersetting-assign?view=graph-rest-beta) | Assign dedicated setting to a security group, not a user object directly |
| [Assign provisioning policy](https://learn.microsoft.com/en-us/graph/api/cloudpcprovisioningpolicy-assign?view=graph-rest-beta) | Existing assignments must be preserved; no atomic append operation is assumed |
| [Domain join configuration](https://learn.microsoft.com/en-us/graph/api/resources/cloudpcdomainjoinconfiguration?view=graph-rest-beta) | Use `domainJoinType`, not deprecated `type`; inspect region/regionGroup/ANC and target identity mode |
| [Virtual endpoint](https://learn.microsoft.com/en-us/graph/api/resources/virtualendpoint?view=graph-rest-beta) | Cloud PC/provisioning-policy/user-setting inventory surface |
| [New-AzSnapshotConfig](https://learn.microsoft.com/en-us/powershell/module/az.compute/new-azsnapshotconfig) | No assumed `-SecurityType` parameter; application uses documented Compute REST snapshot security profile |
| [Create/update snapshot REST](https://learn.microsoft.com/en-us/rest/api/compute/snapshots/create-or-update) | Copy source resource ID, generation and explicit TrustedLaunch security profile |
| [Grant-AzSnapshotAccess](https://learn.microsoft.com/en-us/powershell/module/az.compute/grant-azsnapshotaccess) | OS export SAS and `-SecureVMGuestStateSAS` for Trusted Launch |
| [PSAccessUri model](https://learn.microsoft.com/en-us/dotnet/api/microsoft.azure.commands.compute.automation.models.psaccessuri) | VMGS URL property is `SecurityDataAccessSAS`, not an invented `VMGSSAS` property |
| [Snapshot export sample](https://learn.microsoft.com/en-us/azure/virtual-machines/scripts/virtual-machines-powershell-sample-copy-snapshot-to-storage-account) | Managed snapshot → customer-owned storage server-side copy |
| [Start-AzStorageBlobCopy](https://learn.microsoft.com/en-us/powershell/module/az.storage/start-azstorageblobcopy) | Absolute source SAS + OAuth destination context; asynchronous copy state must be checked |
| [Copy Blob REST](https://learn.microsoft.com/en-us/rest/api/storageservices/copy-blob) | Preserves source blob type; OAuth destination does not authenticate a protected source |
| [New-AzStorageBlobSASToken](https://learn.microsoft.com/en-us/powershell/module/az.storage/new-azstorageblobsastoken) | Connected-account context creates a user-delegation SAS; no fabricated `-UserDelegation` flag |
| [Create user-delegation SAS in PowerShell](https://learn.microsoft.com/en-us/azure/storage/blobs/storage-blob-user-delegation-sas-create-powershell) | Read-only, HTTPS, bounded expiration; no account keys |
| [Secure disk transfers](https://learn.microsoft.com/en-us/azure/virtual-machines/disks-secure-upload-download) | Entra-protected disk export needs more than a plain source SAS; this implementation rejects it instead of weakening controls |
| [Current-caller resource permissions](https://learn.microsoft.com/en-us/rest/api/authorization/permissions/list-for-resource) | Check effective allow-list at resource scopes; not a guarantee against all policy/network restrictions |
| [Current-caller resource-group permissions](https://learn.microsoft.com/en-us/rest/api/authorization/permissions/list-for-resource-group) | Evaluate permissions for creating new snapshots at their destination scope |
| [Azure role-definition semantics](https://learn.microsoft.com/en-us/azure/role-based-access-control/role-definitions) | `NotActions` subtracts from its own role grant; another role may still allow an operation |

## Internal references consulted

These links require internal authorization. The application itself contains **no internal backend endpoints or internal-document dependency**. Share this source index only according to your internal information-handling policy.

1. [Scenario: import-vhd](https://eng.ms/docs/experiences-devices/wd-windows/wcx/cloud-pc/cloudpc-service/device-platform/resources/llm-wiki-arch-doc/w365enterprise/wiki/scenarios/import-vhd)
   - Retrieved full scenario; marked agent/code-verified in its own metadata, verification date 2026-07-30.
   - Describes two independent prerequisites: snapshot user setting and an assigned region-valid provisioning policy.
   - Describes duplicate-import rejection and asynchronous capacity/storage operations.
   - Describes downstream consumption and cleanup of imported artifacts after provisioning. This is why the workbench continues polling the Cloud PC independently when the old import-result lookup is unavailable.
   - Internal analysis explicitly identifies uncertainty about which layer enforces the snapshot-user-setting flag. The app does not treat the internal analysis as proof of tenant availability.

2. [Microsoft Graph Reference: Cloud PC Snapshot](https://eng.ms/docs/experiences-devices/wd-windows/wcx/cloud-pc/cloudpc-service/device-platform/resources/llm-wiki-arch-doc/w365enterprise/wiki/graph-api/references/snapshot)
   - Retrieved full API/workload mapping; analyzed 2026-08-26.
   - Confirms import/status/purge are distinct operations.
   - Includes backend and internal list routes; these were **not** substituted for the documented public Graph HTTP routes.

3. [ImportSnapshot Graph API (alpha) draft](https://microsoft.sharepoint-df.com/teams/CloudPCEngineeringTeam/Shared%20Documents/General/Engineering%20Specs/Snapshot%20Service/ImportSnapshot%20Graph%20API%20%28alpha%29.docx?web=1) and [ImportSnapshot Error Code draft](https://microsoft.sharepoint-df.com/teams/CloudPCEngineeringTeam/Shared%20Documents/General/Engineering%20Specs/Snapshot%20Service/ImportSnapshot%20Error%20Code.docx?web=1)
   - Search excerpts inspected, not an assertion that all revisions/full documents were reviewed.
   - Explicitly marked schema under review; contain older field/enumeration forms.
   - Used to flag contradictions, **not** as executable API contracts.

Search also returned **Enterprise V1 → CDP** migration design documents. Those describe internal migration of already-existing Cloud PCs, not import of customer Azure VMs. They were excluded from this implementation.

## Exact public Graph operations used

Base: `https://graph.microsoft.com`.

| Purpose | Method and route | Relevant body |
|---|---|---|
| User validation | `GET /v1.0/users/{id-or-upn}` | Selected identity/license fields |
| User groups | `GET /v1.0/users/{id}/transitiveMemberOf/microsoft.graph.group` | None; pagination followed |
| License inventory | `GET /v1.0/subscribedSkus` | None |
| Create migration group | `POST /v1.0/groups` | Mail-disabled security group |
| Add group member | `POST /v1.0/groups/{id}/members/$ref` | `@odata.id` referencing the resolved user object |
| Create user setting | `POST /beta/deviceManagement/virtualEndpoint/userSettings` | `provisioningSourceType: snapshot` |
| Assign user setting | `POST …/userSettings/{id}/assign` | `assignments[].target.groupId` |
| Assign provisioning policy | `POST …/provisioningPolicies/{id}/assign` | Preserved targets plus dedicated group |
| Import snapshot | `POST …/snapshots/importSnapshot` | `assignedUserId`, `sourceFiles[]` |
| Read import | `GET …/snapshots/retrieveSnapshotImportResult(snapshotId='{id}')` | None |
| Purge unused import | `POST …/snapshots/purgeImportedSnapshot` | `snapshotIds: [id]` |
| Trigger provisioning | `POST /v1.0/users/{id}/assignLicense` | `addLicenses: [{skuId,disabledPlans:[]}]`, `removeLicenses:[]` |
| Monitor Cloud PC | `GET …/cloudPCs` and `GET …/cloudPCs/{id}` | None |
| Future reprovision source | `PATCH …/userSettings/{id}` | `@odata.type`, existing `displayName`, `localAdminEnabled`, `resetEnabled`, existing non-null `restorePointSetting` / `crossRegionDisasterRecoverySetting`, and `provisioningSourceType: image`; fresh GET verifies source and assignment |

An OS import entry uses `sourceType: sasUrl`, `fileType: dataFile`, `sasUrl: <read-only-HTTPS-SAS>`. Trusted Launch adds `fileType: virtualMachineGuestState` with a separate SAS from the **same managed snapshot**. Storage resource details and SAS are not mixed in a request.

## Documentation discrepancies / conservative choices

- Pilot source-only user-setting PATCH returned HTTP 400 `requiredFieldsNotProvided` (2026-09-17; server request `b8a56bb9-287f-4cab-a79c-84fa73e7bcb7`). Its message said "Failed to create a new user setting" even though the request was PATCH to the existing setting ID; this is not evidence that a second setting was created. Both UseImage and snapshot repair now retain required live name/admin/reset values and supported restore/DR settings. Missing required values block the write rather than defaulting. Read-only GET metadata, assignments and deprecated fields are not echoed. UseImage verifies `image` and the original assignment with a fresh GET before logging success; already-image settings skip PATCH. No automatic mutation replay. Offline contract tests passed. Corrected UseImage live service acceptance was verified from recorded Graph responses at **2026-09-17 15:17:42 UTC**: snapshot before PATCH, image afterward, same setting/name/group assignment and unchanged admin/reset flags. This does not establish propagation to every consumer or live-test the separate repair workflow.
- Product overview parameter names `userId`, `snapshotLocation`, optional `policyId` are **descriptive**, not the current import action's exact body. This application follows the Graph reference: `assignedUserId` + `sourceFiles`. Policy is resolved through assignments.
- The product overview initially limits the scenario to Commercial. Individual Graph API availability tables include Global and US Government L4. This application chooses the **narrower Commercial-only workflow**, not a claim of government end-to-end support.
- API examples sometimes omit `snapshotId` even though the result resource documents it. If the real response omits it, the app stops at **ImportUnknown** rather than guessing or retrying.
- The import-result reference page has a plural URL slug but documents the **singular** `retrieveSnapshotImportResult` function. Some generated SDK snippets instead show a snapshot entity GET; the app follows the page's HTTP request.
- Internal mappings mention `listSnapshotImportResults`; no matching authoritative public method page was obtained during this review. This app monitors **journaled import IDs**, not an invented tenant-wide import listing. Preexisting unjournaled imports require operator review/service conflict handling.
- Draft `external` source enum, singular draft `snapshotImportActionDetail` and older `used` usage state are **not** used. Public enums are `sasUrl` and `notUsed` / `inUse` / `expired`.
- Trusted Launch VMGS is not safely interchangeable with a normal OS VHD. Its export type is preserved; copy completion is verified. Public references reviewed do not constitute a complete independent VMGS integrity-validation specification.
- The app uses read-only Graph GET retries for transient throttling/service errors, respecting a bounded Retry-After interval. SDK automatic retries are disabled so ambiguous POSTs are not silently repeated. Read errors remain errors, not evidence of absence.

## Validation evidence and remaining pilot work

### License-discovery adaptation

License selection now adapts `Get-W365ConfigFromText`, `Get-ServicePlanMap` and `Get-W365Licenses` from [example get licenses.txt](../example%20get%20licenses.txt). Both Graph collections are paginated: `/v1.0/subscribedSkus` supplies seat counts; `/beta/deviceManagement/virtualEndpoint/servicePlans` supplies plan metadata. Enterprise leveling SKUs resolve through their child provisioning-plan names. The supplied CloudPC Lite mapping uses service plan ID `6b97ad6a-be15-4cbe-afbb-4eb74ecb0243` and 2/4/128 configuration, separate from ordinary Enterprise plans with identical specs.

Unlike the example's Enterprise/Business resize picker, this migration picker permits **only Enterprise and CloudPC Lite**. A Flex/Frontline/shared/GPU/Business/Reserve/DR marker in any SKU or child-plan name excludes the whole SKU. Known excluded service-plan IDs are also rejected. Suspended or unknown-count SKUs cannot be selected. License assignment still uses the subscribed **SKU ID**, not the Cloud PC service-plan ID. The Lite exception comes from the user-provided example and does not establish end-to-end migration support for every Lite entitlement.

Offline tests and a WPF render test ran locally with **PowerShell 7.6.6 on Windows ARM64**. No modules were installed for those tests, no Azure/Graph sign-in was performed and no source VM was touched.

Before wider use, test an approved sample for each required join/network/VM security configuration, verify actual Graph payload/response behavior, complete a restore/data acceptance exercise and exercise interrupted-copy/import/license recovery. Check updated documentation again, because all migration actions are beta and internal reference dates are not deployment guarantees.