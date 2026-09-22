# Assistant and developer project context

This folder contains the documents needed to understand, maintain and continue development of the standalone PowerShell/WPF migration workbench. It is separate from the [administrator documentation](../docs/README.md).

## Read in this order

1. **[PROJECT-STATUS.md](PROJECT-STATUS.md)** — current checkpoint through 2026-09-22, including the completed pilot, operator-requested test-history disposal, repeat-migration-cycle support, current validation results, guardrails and remaining work. Start here; it supersedes older status claims in historical reviews.
2. **[Project README](../README.md)** — project overview, startup, prerequisites, supported scope and architecture boundaries.
3. **[SOURCES.md](SOURCES.md)** — API contracts, observed service behavior and research references. Includes internal links; review before sharing outside the intended audience.
4. **[WORKFLOW-SAFETY-REVIEW.md](WORKFLOW-SAFETY-REVIEW.md)** — dated workflow/UI safeguard review, 2026-09-22 repeat-cycle addendum and regression coverage.
5. **[PROJECT-REVIEW.md](PROJECT-REVIEW.md)** — original whole-project audit and remediation history. Do not interpret old findings/test counts as current without checking the checkpoint and source.

Read the [operator guide](../docs/OPERATOR-GUIDE.md) when modifying behavior exposed to administrators. Verify the relevant source and tests before editing; documentation is not a substitute for current code or live evidence.

## New-session prompt

> Read project-status/PROJECT-STATUS.md and README.md before continuing. Keep the tool standalone with no MCP server dependency. The pilot is completed and its image-source switch was confirmed. Local logs/journals were deleted at the operator's request for handover; the pilot cannot be resumed here. Do not replay migration operations or modify cloud resources/journals unless requested. My next task is: [describe the task].

## Keep the handoff current

- Update the status document after meaningful fixes, validation runs and live milestones. Distinguish user reports, local recorded evidence, offline tests and live verification.
- Update the administrator guide whenever a button, input, stage or recovery behavior changes.
- Retain historical audits with their dates; do not silently rewrite them as new validation results.
- Keep tokens, passwords and SAS out of all documents. Pilot identifiers and internal references still require appropriate access controls.
- Documentation reorganization alone must not move/delete migration evidence or change runtime behavior. The completed pilot's logs/journals were subsequently deleted under an explicit operator cleanup request; preserve evidence for future active tests.