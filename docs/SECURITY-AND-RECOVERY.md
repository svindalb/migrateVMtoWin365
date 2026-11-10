# Security and recovery

Current behavior and known limitations for the **2026-11-10** revision. This is controlled-pilot tooling using Graph beta, not production certification. Read the [README](../README.md) and [operator guide](OPERATOR-GUIDE.md) before operating. Keep backups and an exclusive administration window.

## Persistence faults

- Journal replacement, audit append and session-log failures latch a **session persistence fault**. Durable checkpoints run before dispatched mutations, including guest Run Command. Copy completion checks durability before revoking snapshot export. Further remote operations, including automatic Refresh, are blocked while faulted.
- A write failure cannot roll back a request already accepted by Azure/Graph. Preserve the running session and review the reported phase/server outcome. Submission/unknown states remain subject to normal reconciliation; never blindly repeat a mutation.
- Fix disk space/access/path problems through approved workstation administration. **Restore journal writes** is local-only: it reopens the same existing session log, saves/flushes/read-verifies the current in-memory journal, verifies audit/log writes, then clears approvals. Failure remains blocking; an ordinary successful save does not clear the fault.
- After successful restoration, Refresh affected rows and revalidate the next major stage. Restoration never replays a cloud request or claims to reconstruct missing evidence. If the original session log is missing, review/restore that evidence before recovering the session; do not edit phases/IDs.

## Missing historical imports after licensing

A genuine HTTP **404** import-result response can become an `ImportLookupWarning`, rather than a blocking `LastError`, only for LicenseUnknown/Provisioning/Provisioned/Validated/CleanupPending with recorded successful import evidence and one currently matching Cloud PC (assigned UPN, policy, recorded PC ID if present, provisioning/provisioned state). Separate directory reads verify the recorded nonzero user object ID still has the mapped UPN; Cloud PC responses do not need a `userId` property. License/acceptance evidence is required where applicable. This can release the post-load UI guard.

Other lookup failures, including permission/transient errors, mismatched identity and pre-license stages, remain blocking. A 404 is **not proof** of consumption or restored data. LicenseUnknown still requires reviewed audit/time evidence and the creation evidence described below; releasing Refresh does not guarantee reconciliation can complete. New licensing requires a fresh succeeded, unused import. Final acceptance requires independent user/data checks.

## Previous Cloud PC during a new migration

- Before any recorded licensing attempt, a returned PC is an **existing-PC conflict**, not this migration's result. Its ID is shown in `ObservedCloudPcId`; fresh observations do not populate `CloudPcId`. All statuses/policies remain conflicts, including `deprovisioning`.
- After a successful complete scoped lookup with both directory identity checks returns no matching PCs, Refresh or prerequisite validation clears obsolete pre-license ID/status/name. A `PreLicenseCloudPcObservationCleared` audit event preserves old IDs/status first. Load alone does not clear them. Failed/partial reads do not count as absence; persistence failures still block progression.
- Only explicitly recognized pre-license phases without license-attempt, assignment, reconciliation, acceptance or `inUse` evidence qualify. Post-license/unknown-license identities are retained; repeated Refresh cannot replace them. Recorded `inUse` evidence is retained and blocks Refresh when a later import response omits/regresses it. Empty lookup is not proof of deletion of an already-attributed PC.
- Clearing an observation does not advance phase, remove artifacts, grant approval or change guest evidence. Normal prerequisite/license checks remain required.

The row JSON pane reflects the highlighted row in the latest applied operation result, not a live journal-file read. It follows VM resource ID across row replacement and clears when selection disappears. Inspection is independent of **Use** checkboxes. `StatusRefreshSucceeded` and `GuestAssessmentText` are output/UI fields, not persisted journal fields. Code updates load only at an idle restart; resume the same journal, never recreate the plan to fix a display problem.

## Timestamp and source identity

- ISO timestamps require an explicit zone and invariant parsing. Typed DateTimeOffset and UTC/Local DateTime preserve their represented instant; Unspecified DateTime and zone-less strings fail closed.
- Assess guest reads immutable VM ID, managed OS disk resource ID and disk unique ID before/after Run Command. Replacement discards candidate evidence. Validation/capture compare those identities; reassessment clears old evidence/attestation first.
- Old **pre-capture** evidence without bindings must be reassessed on the approved running source. Old **captured** evidence is never retroactively bound: ownership checks and manual provenance review remain. Do not restart a frozen source to satisfy a new check.
- Artifact-free Mapped/Abandoned drafts without a UserId may resolve the mapped UPN for reset/abandon, verify the user and absence of W365 entitlement/PC, then persist the resolved ID. Existing immutable IDs are never silently replaced; non-draft/artifact-bearing unresolved rows fail closed.

## Private storage and legacy journals

Default: **LocalAppData → CpcMigration → data** for the executing Windows user. New directories have protected ACLs granting only that user, SYSTEM and local Administrators. Existing destinations must satisfy principal/owner rules; existing permissions are never silently repaired.

Save journal and report-export pickers start in that validated private directory regardless of the script/loaded-journal location. Validation failure blocks the picker; no fallback is selected. An explicitly chosen alternate destination still undergoes backend privacy checks. Cancel leaves the active journal unchanged.

Startup, Save As, Load, active writes, report export and archive check local fixed-drive paths, file/directory ACLs and reparse-point traversal. Network paths, alternate streams, symlinks/junctions/cloud placeholders and broader allowed principals are rejected. There is **no Documents/shared-folder fallback** or elevation request.

These are local access controls, not encryption or protection against the same Windows user/administrators. They are not an atomic kernel-enforced defense against privileged concurrent directory replacement. Journal-path/plan locks protect the same workstation/user, not distributed operators. Coordinate other administrators.

Read-only discovery includes the private default, application folder, legacy Documents/MigrateLog, current journal directory and managed archives. It does not move/delete files or repair ACLs. If a trusted legacy journal is in a rejected location, arrange an approved byte-preserving private copy **with its audit sidecars**, retain the original/history and operate only one copy. Review predecessor references separately; copying does not update them or confer ownership.

## Diagnostics and retention

- Successful Graph bodies are transient engine input, not stored Graph history/session logs. Request summaries retain method, masked endpoint, client request ID, outcome and count/status. Queries/resource identifiers are removed from diagnostic request paths.
- Displayed-result records contain action/counts/error flag, not repeated catalogs/rows/guest payloads. Bounded redacted errors remain in the UI/reports. Selected-plan identifiers, operator references and ownership fields can remain sensitive.
- **Session log:** 5 MiB per segment, current plus three rotations. **Audit sidecar:** approximately 5 MiB plus at most one bounded record, with one backup. Diagnostic records are at most 64 KiB. Older sessions/journals are not automatically pruned. Journals/reports are not size-limited diagnostic logs.
- Reports are explicit sensitive snapshots, not resumable journals or a replacement for retained diagnostic segments. Review organizational retention/sharing rules; regex redaction is not anonymization or a general secret guarantee.
- No storage account keys are requested. User-delegation SAS is HTTPS/read-only and time-limited. Snapshot export SAS and staging-blob SAS are **different grants**: revoking the former does not revoke the latter. External transcripts, monitoring, dumps and cloud copy metadata are outside application redaction.
- Keep operational evidence out of GitHub. The upload allowlist deliberately excludes journals, logs, reports, archives and internal review history; ignore rules are defense in depth, not a scanner or protection for files already tracked.

## Cloud PC lookup identity

Cloud PC lists use **assigned UPN only**, with no tenant-wide fallback. Separate directory reads bind that UPN to the recorded user object ID before/after pagination (an unresolved draft first resolves its UPN). Renames, different/missing directory IDs, directory-read failures and unrelated/missing Cloud PC identities block the lookup; results are withheld until the requested batch is verified. Direct PC detail checks also reverify directory binding and preserve PC ID/policy checks.

These reads are not an atomic transaction. Coordinate identity changes; broader directory/group/license reads remain necessary for safety, but their successful bodies are not persisted in diagnostics.

## API and validation limitations

- **Graph beta:** public contracts can change and are not supported for production applications. The operator reported a completed pilot and Graph-confirmed image mode on 2026-11-10; that is not proof of every response variant, pagination scenario or recovery path. Offline mocks do not certify live behavior.
- **Cloud PC filter:** the [list contract](https://learn.microsoft.com/en-us/graph/api/virtualendpoint-list-cloudpcs?view=graph-rest-beta) supports filtering; the [resource schema](https://learn.microsoft.com/en-us/graph/api/resources/cloudpc?view=graph-rest-beta) documents `userPrincipalName`, not `userId`. Do not reintroduce a Cloud PC `userId` filter or response-field requirement. The separate [directory user](https://learn.microsoft.com/en-us/graph/api/user-get?view=graph-rest-1.0) has the immutable `id` used for identity verification.
- **LicenseUnknown recovery remains limited:** `Reconcile license` requires Cloud PC creation-time evidence (`createdDateTime`), which the public Cloud PC schema does not document. Its absence explicitly blocks reconciliation. Do not substitute `provisionedDateTime` (latest provisioning/reprovisioning, not object creation), invent times or replay license assignment. A supported provenance design/service review remains needed. Synthetic creation-time tests do not prove this recovery path works against the public contract. **Normal Refresh and final cutover do not depend on this field.**
- The wrapper retries only selected GET failures with bounded backoff and configures Graph HTTP retries to zero at connection. It does not explicitly replay mutations. This is not an exactly-once delivery guarantee across SDK middleware/network/service behavior; ambiguous outcomes require investigation.
- Tests were run on **Windows ARM64 / PowerShell 7.6.9**. The declared PowerShell 7.2 minimum was not runtime-tested. Multi-VM, join/network/security variants and broader interruption/recovery coverage need separately approved validation.

For an authorized manual lookup, read the directory user by its recorded ID and compare `id,userPrincipalName`; then query Cloud PCs with that exact UPN (double embedded apostrophes in an OData literal). Follow every next page and reconcile expected records. A successful empty list must not be used to disregard contradictory evidence of an existing device. Never edit journal identities to force a match.

## Reset, cleanup and completion are different actions

Reset/abandon remove only verified terminal owned artifacts before licensing under live no-PC/no-license/import checks. Cleanup removes owned Azure staging/snapshots **after recorded acceptance**, preserving source/Cloud PC/journal. Archive moves eligible local evidence without deleting cloud resources. Use images changes the existing user setting for future provisioning, not the current Cloud PC. None of these actions authorizes deleting history or restarting the captured source.

Retain the completed journal/audit/logs according to policy and keep provisioning-policy membership intact. See the [operator completion sequence](OPERATOR-GUIDE.md#return-the-group-to-normal-image-provisioning-before-changing-membership).