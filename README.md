# Administrator documentation

## What is this tool?

The **Azure VM → Windows 365 Migration Workbench** is a Windows desktop tool for migrating a supported Azure VM's Windows environment to a Windows 365 Cloud PC. It connects directly to Azure and Microsoft Graph. **No MCP server or hosted backend is required.**

The tool guides an administrator through selecting a source VM and target user, checking prerequisites, stopping and capturing the VM, importing its snapshot, assigning a license, monitoring provisioning, recording user acceptance and cleaning up owned staging artifacts.

**Use only for an approved, recoverable pilot.** It is not a Microsoft-supported migration product. The migration APIs use Microsoft Graph beta; offline tests and a successful pilot do not certify every environment or recovery scenario.

## Where to start

1. **[Installation and prerequisites](../README.md#start)** — PowerShell, required modules, startup and tenant selection. Review the root README's supported scope and permissions before connecting.
2. **[Simple button reference](docs/OPERATOR-GUIDE.md#simple-button-reference)** — what each button does and when to use it.
3. **[Full operator guide](docs/OPERATOR-GUIDE.md)** — every tab, input, selection rule, confirmation, stage and recovery action.
4. **[Resume an existing migration](docs/OPERATOR-GUIDE.md#resume-playbook)** — use the original journal rather than creating another draft.
5. **[Saved journal management](docs/OPERATOR-GUIDE.md#saved-migration-journals-dialog)** — locate completed/unfinished plans and safely archive eligible history.

## Normal migration, briefly

**Connect → map → assess and attest → validate and prepare → validate and capture → wait for Staged → validate and import → wait for Imported → validate and assign license → wait for Provisioned → test and accept → clean up staging when retention permits.**

Use **Refresh status** while waiting. Every major stage needs its own validation approval. After the entire batch is eligible, **Use images** can return the group's setting to image-based future provisioning; confirm the result and allow propagation before changing membership. See the [exact completion order](docs/OPERATOR-GUIDE.md#return-the-group-to-normal-image-provisioning-before-changing-membership).

## Important safety rules

- Capture stops the source VM. Plan downtime and backups first; the tool does not automatically restart it.
- Provisioning success is not proof that all files/apps work. Test the new Cloud PC with its user before recording final acceptance.
- Recovery buttons are for specific failure states, not extra steps in a successful migration. Do not repeat import or licensing because progress is slow.
- Keep migration journals, audit records and logs protected. Reports are not recovery journals. Use **Show archived** to locate archived history.
- Do not manually edit journal phases/IDs or delete lock files while the app may be running.
- Keep migrated users' effective provisioning-policy membership. **Use images** does not reprovision their current Cloud PCs.

This folder contains administrator-facing guidance only; no developer handoff or historical engineering audit is required to operate the tool.
