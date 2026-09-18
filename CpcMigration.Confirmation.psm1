#requires -Version 7.2
Set-StrictMode -Version 3.0

function Get-CpcConfirmationText([string]$Action, $State, $Rows, $Data = @{}) {
    $effects = @{
        Connect = 'Sign in to Azure and Microsoft Graph for the tenant/subscription below. Consent may be requested. No migration resources are created.'
        DetectSubscriptions = 'Sign in to Azure for the specified tenant and list enabled accessible subscriptions (names and IDs). Graph is not connected yet. Clear old resource inventory; explicitly select a subscription and connect before discovering resource groups/VMs. No cloud resources are changed.'
        FindGroups = 'Read direct group memberships for every checked VM target user and intersect them with direct assignments on the selected Enterprise dedicated provisioning policy. Show candidate group names and IDs; the admin must select one explicitly. No membership, settings or policy is changed.'
        Map = 'Create or replace the unprepared local VM-to-user plan. Re-read licenses and resolve disk capacity. Prior validation no longer applies.'
        Check = 'VALIDATE PREREQUISITES for the next stage: storage kind/private container/network, license eligibility/seats/capacity, VM/disk/guest evidence, user identity and current policy/group/snapshot-setting assignments. After capture, also inspect snapshot ownership/Gen2/capacity, VHD/VMGS copy IDs and completion, PageBlob and fixed VHD footer checksum. Before licensing, verify the live imported snapshot belongs to this user and succeeded. No VM stop/import/license write. Short-lived read-only SAS may be generated in memory.'
        Guest = 'Execute read-only guest assessment as SYSTEM using Azure Run Command. Read OS, Entra join, BitLocker and agent evidence. Invalidate prior attestation/validation; no agent uninstall.'
        Attest = 'Record your manual confirmation of mapping, Windows support, entitlements, full agent removal, bootability, backup, network, policy filters and source write-freeze. This is not automatic proof. Validate prerequisites afterward.'
        Prepare = 'Create the dedicated migration group and snapshot user setting, add selected users, preserve existing policy targets and append this group. An exclusive policy-admin window is required. No license assigned. Newly created Graph IDs are returned only after creation and will be shown in the completion details.'
        RepairSnapshot = 'ADMIN GRAPH REPAIR — ENTIRE BATCH: PATCH the existing plan-owned user setting to provisioningSourceType=snapshot; assign it to the migration group; restore missing batch-user memberships; append that group to the selected policy while preserving existing policy targets. Requires an exclusive administration window. Refuses unrelated members/settings, conflicting assignments, existing Cloud PCs/licenses or already-provisioning rows. Does not import or assign licenses. Clears ALL prior validation and customer attestations; attest and Validate prerequisites again after propagation.'
        Capture = 'OUTAGE / BILLABLE: stop and deallocate the selected source VMs; create owned managed snapshots; grant 24-hour export access; copy OS VHD and Trusted Launch VMGS to private staging. Generated snapshot/blob names and Azure copy IDs are shown after capture starts. Sources remain stopped. No automatic restart, rollback or source deletion.'
        Import = 'IMPORT TO WINDOWS 365: revalidate source remains stopped, assigned policy and snapshot setting, storage, snapshot and VHD/VMGS copies/footer. Submit one snapshot import per target user with read-only 48-hour SAS held only in memory. The service-generated import ID is shown afterward. Retain staging until completion. No license is assigned yet.'
        License = 'START MIGRATION / PROVISIONING: assign the exact selected Enterprise / CloudPC Lite SKU to each target user after successful unused import. Consumes seats, may incur costs, and triggers Cloud PC provisioning. Recheck user/policy/settings/licenses, storage and snapshot evidence before writes. No existing licenses removed. Cloud PC ID becomes available asynchronously via Refresh status.'
        Validate = 'FINAL CUTOVER VALIDATION (not preflight): confirm user sign-in, correct source data/profile/apps, Intune, network and acceptance. Check current Cloud PC identity, policy and provisioned status. Records operator acceptance; does not prove full source-content integrity automatically.'
        Purge = 'DELETE terminal unused imported W365 snapshots before license assignment. Not a rollback; Azure staging/snapshots remain.'
        Cleanup = 'PERMANENT DELETE: remove owned staging VHD/VMGS blobs and managed snapshots for validated migrations only. Verify retention/backup first. Source VMs, Cloud PCs, policies, groups and licenses remain.'
        RevokeExport = 'REVOKE snapshot export access. In-progress copies may fail. Staging user-delegation SAS is separate and expires independently. No source restart.'
        UseImage = 'Change the batch-owned setting to IMAGE for future reprovisioning for the ENTIRE batch. All rows must be validated/cleaned or safely abandoned; abandoned users must have no Cloud PC/W365 license. Unexpected members/assignments block this operation. Existing Cloud PCs and policy/group memberships are unchanged.'
        ReconcileImport = 'Link the supplied import ID to the selected ImportUnknown row only after checking user identity, unique filename and attempt timestamp. Does not resubmit import.'
        ReconcileLicense = 'READ-ONLY LICENSE RECOVERY: confirm the supplied Entra audit/request reference and actual UTC time establish THIS migration user/SKU assignment. Verify one active direct license and matching Cloud PC user, policy and creation time. Retain historical import evidence if consumed import was removed. No license/import POST is repeated. Operator evidence is journaled, not independently retrieved from Entra audit logs. Final data/cutover validation remains mandatory.'
        ResetCapture = 'PERMANENT DELETE / RETRY PREPARATION: remove only owned terminal Azure snapshots and VHD/VMGS copies for pre-license attempts. Requires no live/unknown import, Cloud PC or W365 license. Purge terminal unused imports first. Pending copies and unjournaled/changed IDs are blocked. Retain prior attempt IDs in history; reset for fresh capture with new names. Reassess guest if needed, attest and validate. No automatic source restart, overwrite, import or license submission.'
        Abandon = 'PERMANENT DELETE / ABANDON: remove only terminal owned staging/snapshot artifacts under the same ownership and no-provisioning gates as reset. Mark selected rows Abandoned. No source restart/deletion or license/group/policy changes. Snapshot setting remains until ALL rows are validated/cleaned or abandoned, then explicitly use images for future reprovisioning.'
        Save = 'Write the journal with an exclusive lifetime lock. A different plan cannot be overwritten. Bounded redacted event sidecars are saved automatically. Contains tenant/user/resource identifiers, but no SAS or credentials.'
        Load = 'Load only a trusted unmodified journal into a fresh connected app. Recorded resource IDs drive future operations. Refresh status FIRST, then follow the current phase. Attestation and preflight approval are cleared; renew them for the next stage when required. Do not repeat completed capture/import/license steps. Reassess only when pre-capture guest evidence needs refreshing; never restart/reassess a captured source just because the journal was loaded.'
        Export = 'Write HTML, CSV and JSON reports to the directory below. Reports contain user/resource identifiers. Existing report filenames may be replaced.'
        Refresh = 'Refresh server-side status. When all journaled copies finish, revoke export access on the owned Azure snapshot and mark staging complete. Does not stop/restart a VM or submit an import.'
    }
    $effect = if ($effects.ContainsKey($Action)) { $effects[$Action] } else { 'Review the selected operation and scope.' }
    $config = if ($State -is [collections.IDictionary]) { $State['Configuration'] } else { $null }
    if ($config -and $config['ExistingGroupId']) {
        if ($Action -eq 'Prepare') { $effect = 'ENTIRE GROUP: create a plan-owned SNAPSHOT user setting and assign it to the explicitly selected existing user group. All group members must be mapped and selected. The group must already be assigned to the selected Enterprise dedicated policy. Existing group membership and policy assignments are NOT modified. Users receive the setting through group membership, not direct user assignment. Use an exclusive administration window and wait for propagation; no license assigned.' }
        if ($Action -eq 'RepairSnapshot') { $effect = 'ENTIRE BATCH / EXISTING GROUP: restore snapshot mode and assignment on this plan-owned user setting only. Revalidate the selected existing group, exact mapped membership and Enterprise policy assignment. No group membership or policy assignments are repaired automatically; correct these in Intune/Entra first. No import or license write. All attestations/approvals are invalidated; re-attest and validate after propagation.' }
    }
    $lines = [collections.generic.list[string]]::new()
    $lines.Add("ACTION: $Action`r`n$effect`r`n")
    $lines.Add('SCOPE — full identifiers below; unknown IDs are not invented. No secrets/SAS URLs are displayed.')
    $lines.Add(($State | ConvertTo-Json -Depth 15))
    $lines.Add("`r`nSELECTED RESOURCES ($(@($Rows).Count)) — each VM/user/artifact:")
    foreach ($row in @($Rows)) {
        $view = [ordered]@{}
        foreach ($key in @('VM','Name','VmId','Id','ResourceGroup','Location','UserPrincipalName','UserDisplayName','UserId','Phase','Readiness','CheckedUtc',
            'SourceVmUniqueId','SourceDiskId','ObservedSourceVmUniqueId','ObservedSourceDiskId','SnapshotName','SnapshotId','VhdBlob','VmgsBlob','VhdCopyId','VmgsCopyId','ImportId','ImportStatus','UsageStatus','CloudPcId','CloudPcName','CloudPcStatus','LastError')) {
            $value = if ($row -is [collections.IDictionary]) { $row[$key] } elseif ($row.PSObject.Properties[$key]) { $row.$key } else { $null }
            $view[$key] = if ([string]::IsNullOrEmpty([string]$value)) { '(not yet resolved / created)' } else { $value }
        }
        $lines.Add(($view | ConvertTo-Json -Depth 5))
    }
    $lines.Add("`r`nOPERATION INPUTS:`r`n" + ($Data | ConvertTo-Json -Depth 8))
    return $lines -join "`r`n"
}

function Get-CpcCheckRemediation([string]$Check) {
    switch -Regex ($Check) {
        '^Operation failed$' { return 'Read the operation error and current row phase first. Refresh status after a service error; use the indicated recovery action for unknown outcomes. Do not assume validation failed or retry an import/license write. If only stage approval is missing, Validate prerequisites for that stage; attest first only when not already recorded.' }
        'Selected user group' { return 'Find groups for the mapped users and selected Enterprise policy, then choose the intended group explicitly. It must contain exactly the batch users as direct members. Resolve changed membership, licensing or policy assignments in Entra/Intune; the app does not modify an existing group. Revalidate afterward.' }
        'Live Azure VM agent' { return 'Check Azure VM agent status on the running source, resolve agent errors, then Assess guest, attest and Validate prerequisites again before capture.' }
        'Migration identity prepared' { return 'Initial setup: use 4 Prepare snapshot provisioning. If plan-owned objects already exist, use Repair snapshot setting + assignments (batch). Then validate again.' }
        'Migration group membership|Selected provisioning policy assigned|Selected policy assigned to migration group|Snapshot user setting assigned' { return 'Click Repair snapshot setting + assignments (batch) for the plan-owned setting. For a selected EXISTING group, correct membership and Enterprise policy assignments in Entra/Intune first; these are not modified automatically. Legacy owned-group journals can also repair membership/policy assignments. Wait for propagation, attest again, then Validate prerequisites.' }
        'conflicting.*setting' { return 'Was this user setting created by an earlier migration run? Resume its original journal in a fresh connected session; creating draft mappings does not restore ownership. Otherwise review the identified assignments in Intune/Entra with their owner. Do not delete unrelated settings to bypass validation.' }
        'conflicting.*policy' { return 'Review and resolve conflicting assignments in Intune/Entra first. This app does not remove unrelated assignments. Then validate again.' }
        'Operator attestation' { return 'Customer/admin must complete the manual prerequisite checklist, then click 2 Attest prerequisites. Do not attest based only on automated results.' }
        'Guest assessment|Guest evidence|Agent ready|Entra joined to this tenant|No encrypted guest volumes|Client Windows' { return 'Before capture: after correcting Windows, return to the Migration tab and repeat 1 Assess guest (VM running), 2 Attest prerequisites, then 3 Validate prerequisites. Validate alone does not refresh guest evidence, even after a restart. After capture: evidence is frozen; use recovery review, not a source restart or reassessment.' }
        'Assessment boundaries' { return 'Review these manual responsibilities and record 2 Attest prerequisites when satisfied. This Manual item is informational, not an automated failure; do not bypass any failed checks.' }
        'Private page-blob|storage' { return 'Use a supported Storage/StorageV2 account and private container; review the displayed network settings with the storage admin. No firewall changes are made automatically.' }
        'License' { return 'Refresh available licenses; verify eligible Enterprise/Lite SKU, free seats and required entitlements. Resolve premature/external licenses before continuing.' }
        'Elapsed time' { return 'Review copy/import/provisioning telemetry and recorded expiry. Thresholds are advisory, not service SLAs. Never resubmit ambiguous writes. Use explicit recovery after confirming the server outcome.' }
        'Region|ANC|dedicated provisioning' { return 'Configure a dedicated, region-valid provisioning policy and healthy ANC where required in Intune. The repair button does not change region/network configuration.' }
        'Snapshot|VHD|VMGS|Stage-specific' { return 'Review the detailed artifact/import failure. Refresh copy/import status; reconcile wrong ownership, copy IDs or VHD/VMGS integrity. Do not overwrite or resubmit ambiguous imports.' }
        'RBAC' { return 'Ask the authorized admin to activate/assign the indicated least-privilege permission at the displayed scope. The app does not grant itself permissions.' }
        default { return 'Customer/admin: correct the failed condition shown in the evidence, review the operator guide, and click Validate prerequisites again. Do not bypass the check.' }
    }
}

function New-CpcReviewDialog($Owner, [string]$Text, [string]$Title = 'Review operation', [switch]$RequirePreflight, [switch]$InformationOnly, $Checks = @(), [string]$OperationError = '') {
    Add-Type -AssemblyName PresentationFramework
    $dialog = [windows.window]::new()
    $dialog.Title = $Title; $dialog.Owner = $Owner; $dialog.WindowStartupLocation = 'CenterOwner'
    $dialog.Width = 940; $dialog.Height = 740; $dialog.MinWidth = 620; $dialog.MinHeight = 440
    $panel = [windows.controls.dockpanel]::new(); $panel.Margin = '18'
    $bottom = [windows.controls.stackpanel]::new(); [windows.controls.dockpanel]::SetDock($bottom,'Bottom')
    $ack = [windows.controls.checkbox]::new(); $ack.Margin = '0,12,0,12'
    $ack.Content = 'Customer/admin prerequisites are completed; I reviewed PASS validation for this stage and confirm this exact scope.'
    if ($RequirePreflight) { $bottom.Children.Add($ack) | Out-Null }
    $buttons = [windows.controls.stackpanel]::new(); $buttons.Orientation = 'Horizontal'; $buttons.HorizontalAlignment = 'Right'
    $cancel = [windows.controls.button]::new(); $cancel.Content = if ($InformationOnly) { 'Close' } else { 'Cancel' }
    $cancel.IsCancel = $true; $cancel.IsDefault = $true; $cancel.Padding = '20,8'; $cancel.Margin = '8,0,0,0'
    $buttons.Children.Add($cancel) | Out-Null
    $ok = $null
    if (-not $InformationOnly) {
        $ok = [windows.controls.button]::new(); $ok.Content = 'Confirm operation'; $ok.Padding = '20,8'; $ok.Margin = '8,0,0,0'
        $ok.IsEnabled = -not $RequirePreflight
        $ok.Add_Click({ $dialog.DialogResult = $true }.GetNewClosure())
        if ($RequirePreflight) {
            $ack.Add_Checked({ $ok.IsEnabled = $true }.GetNewClosure())
            $ack.Add_Unchecked({ $ok.IsEnabled = $false }.GetNewClosure())
        }
        $buttons.Children.Add($ok) | Out-Null
    }
    $bottom.Children.Add($buttons) | Out-Null; $panel.Children.Add($bottom) | Out-Null
    $issues = [windows.controls.stackpanel]::new()
    $failures = @($Checks | Where-Object Status -EQ 'Fail')
    $manual = @($Checks | Where-Object Status -EQ 'Manual')
    $issueCards = [collections.generic.list[object]]::new()
    if ($failures.Count -or $manual.Count -or $OperationError) {
        $issueScroll = [windows.controls.scrollviewer]::new(); $issueScroll.MaxHeight = 300; $issueScroll.VerticalScrollBarVisibility = 'Auto'
        [windows.controls.dockpanel]::SetDock($issueScroll,'Top')
        $heading = [windows.controls.textblock]::new(); $heading.FontWeight = 'Bold'; $heading.FontSize = 17; $heading.Margin = '0,0,0,8'
        $heading.Text = if ($failures.Count) { "BLOCKED — $($failures.Count) failed checks. Customer/admin action required." } elseif ($OperationError) { 'OPERATION BLOCKED / ERROR — review the reason below. No failed prerequisite checks were reported.' } else { 'Manual customer/admin responsibilities — automated checks do not prove these.' }
        $heading.Foreground = if ($failures.Count -or $OperationError) { '#B91C1C' } else { '#92400E' }
        $heading.TextWrapping = 'Wrap'; $issues.Children.Add($heading) | Out-Null
        $items = @()
        if ($OperationError) { $items += @{ VM = 'Operation'; Check = 'Operation failed'; Status = 'Fail'; Detail = $OperationError } }
        $items += $failures; $items += $manual
        foreach ($item in $items) {
            $card = [windows.controls.textbox]::new(); $card.IsReadOnly = $true; $card.TextWrapping = 'Wrap'
            $card.Foreground = if ($item.Status -eq 'Fail') { '#B91C1C' } else { '#92400E' }
            $card.Background = if ($item.Status -eq 'Fail') { '#FEF2F2' } else { '#FFFBEB' }
            $card.FontWeight = 'SemiBold'; $card.Padding = '10'; $card.Margin = '0,0,0,6'
            $card.Text = "[$($item.Status)] $($item.VM) — $($item.Check)`r`n$($item.Detail)`r`nNEXT: $(Get-CpcCheckRemediation $item.Check)"
            $issues.Children.Add($card) | Out-Null; $issueCards.Add($card)
        }
        $issueScroll.Content = $issues; $panel.Children.Add($issueScroll) | Out-Null
    }
    $box = [windows.controls.textbox]::new(); $box.IsReadOnly = $true; $box.Text = $Text; $box.TextWrapping = 'Wrap'
    $box.VerticalScrollBarVisibility = 'Auto'; $box.FontFamily = 'Consolas'; $box.FontSize = 13; $box.Padding = '12'
    $panel.Children.Add($box) | Out-Null; $dialog.Content = $panel
    $dialog.Tag = @{ Acknowledgement = $ack; Confirm = $ok; Cancel = $cancel; Details = $box; IssueCards = $issueCards; Heading = if ($failures.Count -or $manual.Count -or $OperationError) { $heading } else { $null } }
    return $dialog
}

function Show-CpcReviewDialog($Owner, [string]$Text, [string]$Title = 'Review operation', [switch]$RequirePreflight, [switch]$InformationOnly, $Checks = @(), [string]$OperationError = '') {
    $dialog = New-CpcReviewDialog $Owner $Text $Title -RequirePreflight:$RequirePreflight -InformationOnly:$InformationOnly -Checks $Checks -OperationError $OperationError
    return $dialog.ShowDialog() -eq $true
}

Export-ModuleMember -Function Get-CpcConfirmationText,Get-CpcCheckRemediation,New-CpcReviewDialog,Show-CpcReviewDialog