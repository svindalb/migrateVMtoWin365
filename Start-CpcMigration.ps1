#requires -Version 7.2
<#
.SYNOPSIS
Standalone Azure VM -> Windows 365 migration workbench. No MCP/server needed.
.DESCRIPTION
Run in PowerShell 7 on Windows with -STA. Cloud operations require explicit UI
actions and confirmation. -SmokeTest constructs the UI without authenticating.
.PARAMETER TenantId
Optional non-empty tenant GUID. Prepopulates and locks the tenant field, and
passes RequiredTenantId to every core operation. Does not authenticate; use
Detect subscriptions, then Connect explicitly. Omit to enter the tenant in the UI.
.PARAMETER SmokeTest
Runs offline rendered UI checks, including startup tenant locking when supplied.
.EXAMPLE
pwsh.exe -NoProfile -STA -File .\Start-CpcMigration.ps1 -TenantId 22222222-2222-2222-2222-222222222222
.EXAMPLE
.\Launch-CpcMigration.cmd -TenantId 22222222-2222-2222-2222-222222222222 -SmokeTest
#>
[CmdletBinding()]
param(
    [switch]$SmokeTest,
    [ValidateScript({ $_ -ne [guid]::Empty }, ErrorMessage = 'TenantId must be a non-empty GUID.')]
    [guid]$TenantId
)

$ErrorActionPreference = 'Stop'
# Parameter binding validates the GUID before loading WPF or importing modules.
$script:RequiredTenantId = if ($PSBoundParameters.ContainsKey('TenantId')) { $TenantId.ToString('D') } else { '' }
if (-not $IsWindows) { throw 'This WPF application requires Windows.' }
if ([threading.thread]::CurrentThread.ApartmentState -ne 'STA') {
    throw 'Start this script in an STA PowerShell 7 process. See the launch instructions in README.md.'
}
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
Import-Module (Join-Path $PSScriptRoot 'CpcMigration.Confirmation.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'CpcMigration.Workflow.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'CpcMigration.Journals.psm1') -Force
$script:Root = $PSScriptRoot
[xml]$xaml = Get-Content (Join-Path $PSScriptRoot 'CpcMigration.xaml') -Raw
$window = [Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($xaml))
$ui = @{}
foreach ($node in $xaml.SelectNodes('//*[@Name]')) { $ui[$node.Name] = $window.FindName($node.Name) }
if ($script:RequiredTenantId) {
    $ui.TenantId.Text = $script:RequiredTenantId
    $ui.TenantId.IsEnabled = $false
}
$script:Last = $null
$script:Job = $null
$script:Busy = $false
$script:ModalDepth = 0
$script:CompletingJob = $false
$script:ResumePendingIds = [collections.generic.hashset[string]]::new([StringComparer]::OrdinalIgnoreCase)
$script:ReconciliationSelectionKey = ''
$script:ActionControls = @{
    MapButton = 'Map'; LoadButton = 'Load'; ResumeButton = 'Load'
    GuestButton = 'Guest'; AttestButton = 'Attest'; CheckButton = 'Check'; PrepareButton = 'Prepare'
    CaptureButton = 'Capture'; ImportButton = 'Import'; LicenseButton = 'License'; ValidateButton = 'Validate'
    RefreshButton = 'Refresh'; CleanupButton = 'Cleanup'; RepairSnapshotButton = 'RepairSnapshot'
    PurgeButton = 'Purge'; RevokeButton = 'RevokeExport'; ImageButton = 'UseImage'
    ReconcileButton = 'ReconcileImport'; ReconcileLicenseButton = 'ReconcileLicense'
    ResetCaptureButton = 'ResetCapture'; AbandonButton = 'Abandon'
}
$script:ActionTips = @{}
foreach ($name in $script:ActionControls.Keys) { $script:ActionTips[$name] = [string]$ui[$name].ToolTip }
$script:UpdatingScope = $false
$script:Inventory = [collections.objectmodel.observablecollection[object]]::new()
$script:PlanRows = [collections.objectmodel.observablecollection[object]]::new()
$ui.VmGrid.ItemsSource = $script:Inventory
$ui.PlanGrid.ItemsSource = $script:PlanRows
$script:Signals = [hashtable]::Synchronized(@{ Cancel = $false; Queue = [collections.concurrent.concurrentqueue[string]]::new() })
$runspace = [runspacefactory]::CreateRunspace()
$runspace.ApartmentState = 'STA'
$runspace.ThreadOptions = 'ReuseThread'
$runspace.Open()
$init = [powershell]::Create()
$init.Runspace = $runspace
$null = $init.AddCommand('Import-Module').AddParameter('Name',(Join-Path $PSScriptRoot 'CpcMigration.Core.psm1'))
$null = $init.Invoke()
if ($init.HadErrors) { throw ($init.Streams.Error -join "`n") }
$init.Dispose()

function Invoke-UiModal([scriptblock]$Body) {
    # WPF ShowDialog/MessageBox pump the Dispatcher. Suppress operation polling
    # and auto-refresh until the complete nested review stack has unwound.
    $script:ModalDepth++
    try { & $Body } finally { $script:ModalDepth-- }
}

function Test-UiIdle {
    return -not ($script:Job -or $script:Busy -or $script:CompletingJob -or $script:ModalDepth)
}

function Show-CpcReviewDialog($Owner, [string]$Text, [string]$Title = 'Review operation', [switch]$RequirePreflight, [switch]$InformationOnly, $Checks = @(), [string]$OperationError = '') {
    Invoke-UiModal { CpcMigration.Confirmation\Show-CpcReviewDialog $Owner $Text $Title -RequirePreflight:$RequirePreflight -InformationOnly:$InformationOnly -Checks $Checks -OperationError $OperationError }
}

function Show-Notice([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { $Text = 'The operation could not report its details. Review Activity log and the automatic session log before continuing.' }
    Invoke-UiModal { [windows.messagebox]::Show($window,$Text,'Windows 365 Migration','OK','Information') } | Out-Null
}

function Get-OperationFailureText($Result, $Errors, [bool]$HadErrors) {
    # HadErrors can remain true after a caught terminating error, with an empty
    # error stream. The core's returned OperationError is authoritative in that case.
    $details = @()
    if ($Result -and -not [string]::IsNullOrWhiteSpace([string]$Result.OperationError)) { $details += [string]$Result.OperationError }
    foreach ($record in $Errors) {
        if ($null -ne $record -and -not [string]::IsNullOrWhiteSpace([string]$record)) { $details += [string]$record }
    }
    if ($details.Count) { return ($details | Select-Object -Unique) -join "`n" }
    if ($HadErrors) { return 'The worker reported an error without details. Review Activity log and the automatic session log before continuing.' }
    if (-not $Result) { return 'The worker returned no operation result. Review Activity log before continuing.' }
    return ''
}

function Confirm-Change([string]$Text) {
    return (Invoke-UiModal { [windows.messagebox]::Show($window,$Text,'Confirm cloud changes','YesNo','Warning','No') }) -eq 'Yes'
}

function Get-SelectedIds {
    $ui.PlanGrid.CommitEdit([Windows.Controls.DataGridEditingUnit]::Cell,$true) | Out-Null
    $ui.PlanGrid.CommitEdit([Windows.Controls.DataGridEditingUnit]::Row,$true) | Out-Null
    return @($script:PlanRows | Where-Object Selected | ForEach-Object VmId)
}

function Update-WorkflowControls {
    $rows = @($script:PlanRows | Where-Object Selected)
    $plan = if ($script:Last) { $script:Last.PlanId } else { '' }
    $key = $plan + ':' + (($rows | ForEach-Object { "$($_.VmId)|$($_.Phase)" } | Sort-Object) -join ';')
    if ($key -ne $script:ReconciliationSelectionKey) {
        $ui.ImportId.Clear(); $ui.LicenseEvidence.Clear(); $ui.LicenseAssignedUtc.Clear()
        $script:ReconciliationSelectionKey = $key
    }
    $scope = if ($rows.Count) { ($rows | Select-Object -First 4 | ForEach-Object { "$($_.VM) [$($_.Phase)] — $($_.UserPrincipalName)" }) -join '; ' } else { 'None — check Use on the Migration tab.' }
    $ui.RecoveryScopeText.Text = "Recovery scope: $($rows.Count) checked row(s). $scope`nRepair snapshot setting and Use images act on the ENTIRE batch, including unchecked rows. Evidence fields clear when selection or phase changes."
    foreach ($name in $script:ActionControls.Keys) {
        $state = Get-CpcActionAvailability $script:ActionControls[$name] $script:Last $rows -Busy:($script:Busy -or [bool]$script:Job)
        $ui[$name].IsEnabled = $state.Allowed
        $ui[$name].ToolTip = if ($state.Allowed) { $script:ActionTips[$name] } else { $state.Reason + "`n" + $script:ActionTips[$name] }
    }
    # Keep evidence fields editable when the phase allows reconciliation, even
    # though the submit button is disabled until those fields are valid.
    $ui.ImportId.IsEnabled = $ui.ReconcileButton.IsEnabled
    $ui.LicenseEvidence.IsEnabled = $ui.ReconcileLicenseButton.IsEnabled
    $ui.LicenseAssignedUtc.IsEnabled = $ui.ReconcileLicenseButton.IsEnabled
    foreach ($name in @('ReconcileButton','ReconcileLicenseButton')) {
        if ($ui[$name].IsEnabled) {
            $data = @{ ImportId = $ui.ImportId.Text.Trim(); Evidence = $ui.LicenseEvidence.Text.Trim(); AssignedUtc = $ui.LicenseAssignedUtc.Text.Trim() }
            $gate = Get-CpcActionAvailability $script:ActionControls[$name] $script:Last $rows -Data $data
            $ui[$name].IsEnabled = $gate.Allowed
            if (-not $gate.Allowed) { $ui[$name].ToolTip = $gate.Reason }
        }
    }
    $ui.AutoRefresh.IsEnabled = -not ($script:Busy -or $script:Job) -and $ui.RefreshButton.IsEnabled
    $ui.AutoRefresh.ToolTip = 'Refreshes only checked rows. Paused while a worker or review dialog is active. Does not advance automatically to import or licensing.'
    $ui.NextStepText.Text = if ($script:Busy -or $script:Job) { 'An operation is running. Wait for its result; no other operation can start. Server-side copies/imports may continue after the worker returns.' } else { Get-CpcWorkflowHint $script:Last $rows }
    # Configuration pickers edit draft mappings only. A prepared plan must retain
    # its ownership/configuration rather than inviting an ineffective remap.
    $draft = $ui.MapButton.IsEnabled
    foreach ($name in @('PolicyPicker','SkuPicker','StoragePicker','ContainerName','SnapshotGroup','FindGroupsButton','UserGroupPicker','VmGrid')) { $ui[$name].IsEnabled = $draft }
}

function Get-LocalResumeCandidates([string[]]$VmIds = @()) {
    if (-not $script:Last) { return @() }
    $directories = @($script:Root, (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'MigrateLog'))
    if ($script:Last.StatePath) { $directories += [IO.Path]::GetDirectoryName($script:Last.StatePath) }
    # Archiving completed history must not become a way to bypass the prepared
    # plan overlap warning. Keep archives out of ordinary resume reminders.
    if ($VmIds.Count) {
        $directories += @($directories | Select-Object -Unique | ForEach-Object {
            Get-ChildItem -LiteralPath (Join-Path $_ 'JournalArchive') -Directory -ErrorAction SilentlyContinue |
                Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } | ForEach-Object FullName
        })
    }
    return @(Find-CpcResumeJournals -Directories $directories -TenantId $script:Last.TenantId -SubscriptionId $script:Last.SubscriptionId -ExcludePlanId $script:Last.PlanId -VmIds $VmIds | Sort-Object -Property @{ Expression = 'Prepared'; Descending = $true }, @{ Expression = 'ModifiedUtc'; Descending = $true })
}

function Show-ResumeReminder {
    if ($SmokeTest -or -not $script:Last.Connected -or $script:PlanRows.Count) { return }
    $candidates = @(Get-LocalResumeCandidates)
    if (-not $candidates.Count) { return }
    $summary = ($candidates | Select-Object -First 5 | ForEach-Object { "$($_.Summary)`n$($_.Path)" }) -join "`n`n"
    $ui.ResumeHintText.Text = "Found $($candidates.Count) saved migration journal(s). Tenant: $($script:Last.TenantId); subscription: $($script:Last.SubscriptionId). Resuming? Use Resume / load journal BEFORE creating draft mappings. Settings, snapshots and imports survive an app restart; a new plan does not own them."
    Show-Notice ($ui.ResumeHintText.Text + "`n`n$summary`n`nChoose the trusted original journal, not simply the newest file. Other save locations can be browsed. No journal is loaded automatically.")
}

function Show-JournalManager {
    if (-not (Test-UiIdle)) { return }
    $directories = @($script:Root, (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'MigrateLog'))
    if ($script:Last -and $script:Last.StatePath) { $directories += [IO.Path]::GetDirectoryName($script:Last.StatePath) }
    $tenant = if ($script:RequiredTenantId) { $script:RequiredTenantId } elseif ($script:Last) { $script:Last.TenantId } else { '' }
    $sub = if ($script:Last) { $script:Last.SubscriptionId } else { '' }
    $plan = if ($script:Last) { $script:Last.PlanId } else { '' }
    $canResume = (Get-CpcActionAvailability 'Load' $script:Last @()).Allowed
    $dialog = New-CpcJournalManager -Owner $window -Directories $directories -TenantId $tenant -SubscriptionId $sub -CurrentPlanId $plan -CanResume $canResume
    $null = Invoke-UiModal { $dialog.ShowDialog() }
    if ($dialog.Tag.Path -and (Confirm-Change 'Load this trusted journal to resume its recorded migration? Ownership and scope will be validated. Refresh server status after loading; attestations and approvals must be renewed.')) { Start-Operation 'Load' @{ Path = $dialog.Tag.Path } }
}

function Set-Working([bool]$Busy) {
    $script:Busy = $Busy
    $ui.JournalManagerButton.IsEnabled = -not $Busy
    foreach ($name in @('ResetCaptureButton','AbandonButton','ReconcileLicenseButton','LicenseEvidence','LicenseAssignedUtc','ImportId')) { $ui[$name].IsEnabled = -not $Busy }
    foreach ($name in @('ConnectButton','DetectSubscriptionsButton','DiscoverButton','RefreshLicensesButton','LocalButton','InstallButton','MapButton','SaveButton','LoadButton','ExportButton','GuestButton','AttestButton','CheckButton','PrepareButton','RepairSnapshotButton','CaptureButton','ImportButton','RefreshButton','LicenseButton','ValidateButton','PurgeButton','CleanupButton','ReconcileButton','RevokeButton','ImageButton')) {
        $ui[$name].IsEnabled = -not $Busy
    }
    $ui.SettingsPanel.IsEnabled = -not $Busy
    $ui.VmGrid.IsEnabled = -not $Busy
    $ui.PlanGrid.IsEnabled = -not $Busy
    $ui.SourceGroupPicker.IsEnabled = -not $Busy
    $ui.SearchBox.IsEnabled = -not $Busy
    $ui.FindGroupsButton.IsEnabled = -not $Busy
    $ui.UserGroupPicker.IsEnabled = -not $Busy
    $scopeEditable = -not $Busy -and $script:PlanRows.Count -eq 0
    $ui.SubscriptionPicker.IsEnabled = $scopeEditable
    $ui.TenantId.IsEnabled = $scopeEditable -and -not $script:RequiredTenantId
    $ui.DetectSubscriptionsButton.IsEnabled = $scopeEditable
    $ui.CancelButton.IsEnabled = $Busy
    $ui.WorkProgress.IsIndeterminate = $Busy
    Update-WorkflowControls
}

function Get-OperationReview([string]$Action, [hashtable]$Data = @{}) {
    $ids = if ($Data.ContainsKey('VmIds')) { @($Data.VmIds) } else { @(Get-SelectedIds) }
    $rows = @($script:PlanRows | Where-Object { $_.VmId -in $ids })
    if ($Action -in @('UseImage','RepairSnapshot','Save','Export')) { $rows = @($script:PlanRows) }
    if ($Action -eq 'Map') { $rows = @($script:Inventory | Where-Object Selected) }
    $config = if ($Action -eq 'Map') { $Data.Config } elseif ($script:Last) { $script:Last.Config } else { @{} }
    $catalog = if ($script:Last) { $script:Last.Catalog } else { @{ Policies = @(); Skus = @(); Storage = @(); Subscriptions = @() } }
    $tenant = if ($Action -in @('Connect','DetectSubscriptions')) { $Data.TenantId } elseif ($script:Last) { $script:Last.TenantId } else { $ui.TenantId.Text }
    $sub = if ($Action -eq 'Connect') { $Data.SubscriptionId } elseif ($Action -eq 'DetectSubscriptions') { '(select after discovery)' } elseif ($script:Last) { $script:Last.SubscriptionId } else { [string]$ui.SubscriptionPicker.SelectedValue }
    $scope = [ordered]@{
        TenantId = $tenant; SubscriptionId = $sub
        Subscription = @($catalog.Subscriptions | Where-Object Id -EQ $sub | Select-Object Name,Id)
        PlanId = if ($script:Last) { $script:Last.PlanId } else { '(not created)' }
        Journal = if ($script:Last) { $script:Last.StatePath } else { '' }
        Configuration = $config
        SourceResourceGroupFilter = [string]$ui.SourceGroupPicker.SelectedValue
        Policy = @($catalog.Policies | Where-Object id -EQ $config.PolicyId | Select-Object displayName,id,provisioningType,domainJoinConfigurations)
        License = @($catalog.Skus | Where-Object SkuId -EQ $config.SkuId | Select-Object DisplayName,SkuPartNumber,SkuId,ServicePlanName,ServicePlanId,Available,StorageGB)
        Storage = @($catalog.Storage | Where-Object Id -EQ $config.StorageId | Select-Object Name,Id,Location)
        GroupName = if ($config.ExistingGroupId) { $config.ExistingGroupName } elseif ($script:Last) { 'CPCMigration-' + $script:Last.PlanId } else { '(not selected)' }
        GroupId = if ($config.ExistingGroupId) { $config.ExistingGroupId } elseif ($script:Last -and $script:Last.GroupId) { $script:Last.GroupId } else { '(legacy group ID returned after Prepare)' }
        SnapshotSettingName = if ($script:Last) { 'Snapshot-' + $script:Last.PlanId } else { '(not created)' }
        SnapshotSettingId = if ($script:Last -and $script:Last.UserSettingId) { $script:Last.UserSettingId } else { '(server ID returned after Prepare)' }
        ExplicitPreflight = if ($script:Last) { $script:Last.Preflight } else { @{} }
    }
    return Get-CpcConfirmationText $Action $scope $rows $Data
}

function Start-Operation([string]$Action,[hashtable]$Data = @{}, [switch]$Automatic) {
    if (-not (Test-UiIdle)) { return }
    if ($Automatic -and $Action -ne 'Refresh') { throw 'Only status refresh may run automatically. Migration actions always require operator confirmation.' }
    # Use the validated startup value, never mutable UI text or caller data.
    if ($script:RequiredTenantId) { $Data.RequiredTenantId = $script:RequiredTenantId }
    if ($Action -eq 'Connect' -and -not $ui.SubscriptionPicker.SelectedValue) { Show-Notice 'Detect subscriptions and select one first.'; return }
    if ($Action -notin @('LocalCheck','Install','DetectSubscriptions','Connect','Save','Export')) {
        if (-not $script:Last -or -not $script:Last.Connected -or
            [string]$ui.SubscriptionPicker.SelectedValue -ne $script:Last.SubscriptionId -or $ui.TenantId.Text.Trim() -ne $script:Last.TenantId) {
            Show-Notice 'Connect the selected subscription and tenant first. Changing a picker does not change the active Azure context.'
            return
        }
    }
    if (-not $Data.ContainsKey('VmIds')) { $Data.VmIds = @(Get-SelectedIds) }
    if ($Action -in @($script:ActionControls.Values)) {
        $selectedRows = @($script:PlanRows | Where-Object { $_.VmId -in $Data.VmIds })
        $gate = Get-CpcActionAvailability $Action $script:Last $selectedRows -Data $Data
        if (-not $gate.Allowed) { if (-not $Automatic) { Show-Notice $gate.Reason }; Update-WorkflowControls; return }
    }
    if ($Action -eq 'Map') {
        $overlap = @(Get-LocalResumeCandidates @($Data.Mappings | ForEach-Object VmId) | Where-Object Prepared)
        if ($overlap.Count) {
            $paths = ($overlap | ForEach-Object { "$($_.Summary)`n$($_.Path)" }) -join "`n`n"
            Show-Notice "These VMs already appear in a prepared local migration journal. Creating draft mappings cannot replace its cloud settings or restore ownership. Resume the original journal instead; do not delete assignments or recreate the plan to bypass this warning.`n`n$paths`n`nIf a draft is already open, restart, connect, then Resume / load journal before mapping."
            return
        }
    }
    # Startup initializes the journal; never mutate if it is unavailable.
    if ($Action -in @('Prepare','RepairSnapshot','Capture','Import','License','Purge','Cleanup','Validate','ResetCapture','Abandon','ReconcileLicense') -and (-not $script:Last -or -not $script:Last.StatePath)) {
        Show-Notice 'The automatic recovery journal is unavailable. Restart the application and verify its log/journal paths before making cloud changes.'
        return
    }
    if ($Action -in @('Check','Guest','Attest','Prepare','Capture','Import','Refresh','License','Validate','Purge','Cleanup','ReconcileImport','ResetCapture','Abandon','ReconcileLicense') -and -not $Data.VmIds.Count) {
        Show-Notice 'Select one or more mapped rows in the Migration tab.'
        return
    }
    $major = $Action -in @('Prepare','Capture','Import','License')
    if (-not $Automatic -and $Action -notin @('LocalCheck','Discover','RefreshLicenses','Install')) {
        if (-not (Show-CpcReviewDialog $window (Get-OperationReview $Action $Data) "Confirm: $Action" -RequirePreflight:$major)) { return }
    }
    # A lengthy confirmation may outlive the approval even with timers paused.
    if ($Action -in @($script:ActionControls.Values)) {
        $gate = Get-CpcActionAvailability $Action $script:Last $selectedRows -Data $Data
        if (-not $gate.Allowed) { if (-not $Automatic) { Show-Notice $gate.Reason }; Update-WorkflowControls; return }
    }
    $script:Signals.Cancel = $false
    $ps = [powershell]::Create()
    $ps.Runspace = $runspace
    $null = $ps.AddCommand('Invoke-CpcOperation').AddParameter('Action',$Action).AddParameter('Data',$Data).AddParameter('Signals',$script:Signals)
    Set-Working $true
    $ui.StatusText.Text = "Working: $Action — cloud operations run off the UI thread"
    $script:Job = @{ PowerShell = $ps; Handle = $ps.BeginInvoke(); Action = $Action }
}

function Update-Picker($Control,$Items,[string]$Display,[string]$Id) {
    $selected = $Control.SelectedValue
    $Control.DisplayMemberPath = $Display
    $Control.SelectedValuePath = $Id
    $Control.ItemsSource = @($Items)
    if ($selected) { $Control.SelectedValue = $selected }
}

function Update-VmFilter {
    $ui.VmGrid.CommitEdit([windows.controls.datagrideditingunit]::Cell,$true) | Out-Null
    $ui.VmGrid.CommitEdit([windows.controls.datagrideditingunit]::Row,$true) | Out-Null
    $text = $ui.SearchBox.Text
    $group = [string]$ui.SourceGroupPicker.SelectedValue
    $view = [windows.data.collectionviewsource]::GetDefaultView($ui.VmGrid.ItemsSource)
    $view.Filter = [predicate[object]]{
        param($item)
        (-not $group -or $item.ResourceGroup -eq $group) -and
            "$($item.Name) $($item.ResourceGroup) $($item.Location)".IndexOf($text,[StringComparison]::OrdinalIgnoreCase) -ge 0
    }.GetNewClosure()
    $active = if ($script:Last -and $script:Last.Connected) { $script:Last.SubscriptionId } else { '(not connected)' }
    $ui.VmScopeText.Text = "Connected subscription: $active | Visible: $($ui.VmGrid.Items.Count) / $($script:Inventory.Count). Hidden checked VMs remain selected and are included in mapping confirmation."
}

function Clear-DiscoveryView {
    $script:Inventory.Clear()
    foreach ($name in @('SourceGroupPicker','SnapshotGroup','PolicyPicker','StoragePicker','SkuPicker','UserGroupPicker')) { $ui[$name].ItemsSource = @(); $ui[$name].SelectedIndex = -1 }
    Update-VmFilter
}

function Update-Dashboard {
    $ui.ChartPanel.Children.Clear()
    $total = $script:PlanRows.Count
    $ui.TotalCard.Text = [string]$total
    $ui.ReadyCard.Text = [string]@($script:PlanRows | Where-Object Readiness -EQ 'Ready').Count
    $ui.ImportedCard.Text = [string]@($script:PlanRows | Where-Object ImportStatus -EQ 'succeeded').Count
    $ui.ValidatedCard.Text = [string]@($script:PlanRows | Where-Object Phase -In @('Validated','Cleaned')).Count
    foreach ($group in ($script:PlanRows | Group-Object Phase | Sort-Object Name)) {
        $panel = [windows.controls.stackpanel]::new()
        $panel.Margin = '0,3,0,6'
        $text = [windows.controls.textblock]::new()
        $text.Text = "$($group.Name)  ·  $($group.Count) / $total"
        $text.Foreground = '#CBD5E1'
        $bar = [windows.controls.progressbar]::new()
        $bar.Maximum = [math]::Max(1,$total)
        $bar.Value = $group.Count
        $bar.Height = 8
        $bar.Margin = '0,4,0,0'
        $bar.Foreground = '#38BDF8'
        $panel.Children.Add($text) | Out-Null
        $panel.Children.Add($bar) | Out-Null
        $ui.ChartPanel.Children.Add($panel) | Out-Null
    }
}

function Set-OperationResult($Result,[string]$Action) {
    $script:Last = $Result
    if ($Action -eq 'Load' -and -not $Result.OperationError) {
        $script:ResumePendingIds.Clear()
        foreach ($row in $Result.Rows) { $null = $script:ResumePendingIds.Add($row.VmId) }
    }
    if ($Action -eq 'Refresh' -and -not $Result.OperationError) {
        foreach ($row in $Result.Rows) {
            if ($row.PSObject.Properties['StatusRefreshSucceeded'] -and $row.StatusRefreshSucceeded) { $null = $script:ResumePendingIds.Remove($row.VmId) }
        }
    }
    $Result | Add-Member -NotePropertyName ResumePendingVmIds -NotePropertyValue @($script:ResumePendingIds | ForEach-Object { $_ }) -Force
    $selection = @(Get-SelectedIds)
    $hadRows = $script:PlanRows.Count -gt 0
    $script:PlanRows.Clear()
    foreach ($row in $Result.Rows) {
        if ($hadRows) { $row.Selected = $row.VmId -in $selection }
        $row | Add-Member -NotePropertyName GuestAssessmentText -NotePropertyValue (Get-CpcGuestAssessmentText $row) -Force
        $script:PlanRows.Add($row)
    }
    $ui.CheckGrid.ItemsSource = @($Result.Checks)
    $ui.GraphGrid.ItemsSource = @($Result.GraphResults)
    if ($Action -in @('DetectSubscriptions','Connect','Discover')) {
        $script:UpdatingScope = $true
        try {
            Update-Picker $ui.SubscriptionPicker $Result.Catalog.Subscriptions 'DisplayName' 'Id'
            if ($Action -eq 'DetectSubscriptions' -and -not $Result.Rows.Count) { $ui.SubscriptionPicker.SelectedIndex = -1 }
            elseif ($Result.Connected) { $ui.SubscriptionPicker.SelectedValue = $Result.SubscriptionId }
        } finally { $script:UpdatingScope = $false }
        $ui.SubscriptionHint.Text = if ($Result.Connected) { "Active: $($Result.SubscriptionId). Discover inventory, then select a source resource group in Select & map." } else { 'Choose a detected subscription, then Connect selected subscription + Graph.' }
    }
    if ($Action -in @('DetectSubscriptions','Connect') -and -not $Result.OperationError) { Clear-DiscoveryView }
    if ($Action -in @('DetectSubscriptions','Connect') -and -not $Result.Connected) { Clear-DiscoveryView }
    if ($Action -eq 'Discover') {
        $script:Inventory.Clear()
        foreach ($vm in $Result.Catalog.Vms) {
            $script:Inventory.Add([pscustomobject]@{ Selected = $false; UserPrincipalName = ''; Name = $vm.Name; ResourceGroup = $vm.ResourceGroup; Location = $vm.Location; Size = $vm.Size; OS = $vm.OS; Id = $vm.Id })
        }
        Update-Picker $ui.PolicyPicker @($Result.Catalog.Policies | Where-Object {
            $_.provisioningType -eq 'dedicated' -and
            (-not $_.managedBy -or $_.managedBy -eq 'windows365') -and
            (-not $_.userExperienceType -or $_.userExperienceType -eq 'cloudPc')
        }) 'displayName' 'id'
        Update-Picker $ui.StoragePicker $Result.Catalog.Storage 'Name' 'Id'
        $groups = @([pscustomobject]@{ Name = ''; DisplayName = 'All resource groups' }) + @($Result.Catalog.ResourceGroups)
        Update-Picker $ui.SourceGroupPicker $groups 'DisplayName' 'Name'
        if ($ui.SourceGroupPicker.SelectedIndex -lt 0) { $ui.SourceGroupPicker.SelectedIndex = 0 }
        Update-Picker $ui.SnapshotGroup $Result.Catalog.ResourceGroups 'DisplayName' 'Name'
        Update-VmFilter
    }
    Update-Picker $ui.SkuPicker $Result.Catalog.Skus 'SelectionLabel' 'SkuId'
    if ($Action -eq 'FindGroups') {
        Update-Picker $ui.UserGroupPicker $Result.Catalog.Groups 'DisplayName' 'Id'
        $ui.UserGroupPicker.SelectedIndex = -1
        $ui.UserGroupHint.Text = if ($Result.OperationError) { $Result.OperationError } else { "Found $($Result.Catalog.Groups.Count) candidate groups. Choose explicitly; all direct members must be in this batch. Existing group/policy memberships will not be modified." }
    }
    if ($Action -eq 'Load' -or ($Action -eq 'Discover' -and $Result.Rows.Count)) {
        $ui.PolicyPicker.SelectedValue = $Result.Config.PolicyId
        $ui.SkuPicker.SelectedValue = $Result.Config.SkuId
        $ui.StoragePicker.SelectedValue = $Result.Config.StorageId
        $ui.DiskSize.Text = [string]$Result.Config.TargetDiskGiB
        $ui.ContainerName.Text = $Result.Config.Container
        $ui.SnapshotGroup.SelectedValue = $Result.Config.SnapshotResourceGroup
        if ($Result.Config.ExistingGroupId) {
            Update-Picker $ui.UserGroupPicker @([pscustomobject]@{ Id = $Result.Config.ExistingGroupId; PolicyId = $Result.Config.PolicyId; Name = $Result.Config.ExistingGroupName; DisplayName = "$($Result.Config.ExistingGroupName) [$($Result.Config.ExistingGroupId)]" }) 'DisplayName' 'Id'
            $ui.UserGroupPicker.SelectedValue = $Result.Config.ExistingGroupId
        }
    }
    $ui.PlanLabel.Text = "Plan $($Result.PlanId) | Group $($Result.GroupId) | Journal: $($Result.StatePath) | Log: $($Result.LogPath)"
    if ($Result.LogPath) { $ui.LogLocationText.Text = "Automatic log: $($Result.LogPath)`r`nRecovery journal: $($Result.StatePath)" }
    $ui.ConnectionText.Text = if ($Result.Connected) { 'Connected · Commercial cloud' } else { 'Not connected' }
    Update-Dashboard
    Update-WorkflowControls
    if ($Action -eq 'Load' -and -not $Result.OperationError) {
        $ui.ResumeHintText.Text = 'Original journal restored. Refresh status, then follow Next step on the Migration tab. Completed stages are not repeated; stage approvals and attestation must be renewed when needed.'
        $ui.Tabs.SelectedIndex = 2
    }
}

$timer = [windows.threading.dispatchertimer]::new()
$timer.Interval = [timespan]::FromMilliseconds(250)
$script:OperationTick = {
    if ($script:ModalDepth -or $script:CompletingJob) { return }
    $message = ''
    while ($script:Signals.Queue.TryDequeue([ref]$message)) {
        $ui.LogBox.AppendText($message + "`r`n")
        $ui.LogBox.ScrollToEnd()
        $message = ''
    }
    if ($script:Job -and $script:Job.Handle.IsCompleted) {
        $script:CompletingJob = $true
        $job = $script:Job
        try {
            $output = @($job.PowerShell.EndInvoke($job.Handle))
            $result = if ($output.Count) { $output[-1] } else { $null }
            $failureText = Get-OperationFailureText $result $job.PowerShell.Streams.Error $job.PowerShell.HadErrors
            $hasReview = $job.Action -in @('Check','Prepare','RepairSnapshot','Capture','Import','License','Validate','Cleanup','Purge','RevokeExport','UseImage','ReconcileImport','ResetCapture','Abandon','ReconcileLicense')
            if ($output.Count) {
                Set-OperationResult $output[-1] $job.Action
                if ($job.Action -eq 'Connect' -and -not $failureText) { Show-ResumeReminder }
                if ($hasReview) {
                    $checks = $script:Last.Checks | Format-Table VM,Check,Status,Detail -Wrap | Out-String -Width 150
                    $resultText = "OPERATION RETURNED: $($job.Action). This is not a success declaration. Review phases, failures, IDs and validation results below. Import/provisioning may still be running.`r`nOPERATION ERROR: $($script:Last.OperationError)`r`n`r`n" +
                        (Get-OperationReview $job.Action) + "`r`nPREREQUISITE EVIDENCE:`r`n$checks"
                    Show-CpcReviewDialog $window $resultText "Result: $($job.Action)" -InformationOnly -Checks $script:Last.Checks -OperationError $failureText | Out-Null
                }
            }
            if ($failureText -and (-not $hasReview -or -not $output.Count)) { Show-Notice "$($job.Action) failed:`n`n$failureText" }
            $rowErrors = if ($result) { @($result.Rows | Where-Object LastError).Count } else { 0 }
            $ui.StatusText.Text = if ($failureText) { "Failed: $($job.Action). Review Activity log for details." } elseif ($rowErrors) { "Returned: $($job.Action) — $rowErrors row error(s). Review Last error; this is not a success declaration." } else { "Finished: $($job.Action). Follow Next step; server-side work may still be running." }
        } catch { Show-Notice $_.Exception.Message }
        finally { $job.PowerShell.Dispose(); $script:Job = $null; $script:CompletingJob = $false; Set-Working $false }
    }
    if (-not $script:Job) { Update-WorkflowControls }
}
$timer.Add_Tick($script:OperationTick)
$timer.Start()
$refreshTimer = [windows.threading.dispatchertimer]::new()
$refreshTimer.Interval = [timespan]::FromSeconds(30)
$script:RefreshTick = {
    if ($ui.AutoRefresh.IsChecked -and (Test-UiIdle) -and $script:Last -and $script:Last.Connected -and @(Get-SelectedIds).Count) {
        Start-Operation 'Refresh' -Automatic
    }
}
$refreshTimer.Add_Tick($script:RefreshTick)
$refreshTimer.Start()

$ui.ConnectButton.Add_Click({
    Start-Operation 'Connect' @{ TenantId = $ui.TenantId.Text.Trim(); SubscriptionId = [string]$ui.SubscriptionPicker.SelectedValue }
})
$ui.DetectSubscriptionsButton.Add_Click({ Start-Operation 'DetectSubscriptions' @{ TenantId = $ui.TenantId.Text.Trim() } })
$ui.SubscriptionPicker.Add_SelectionChanged({
    if ($script:UpdatingScope) { return }
    if (-not $script:Last -or [string]$ui.SubscriptionPicker.SelectedValue -ne $script:Last.SubscriptionId) {
        Clear-DiscoveryView
        $ui.SubscriptionHint.Text = 'Subscription selection changed. Connect this selection, then discover its resource groups and VMs.'
    }
})
$ui.SourceGroupPicker.Add_SelectionChanged({ Update-VmFilter })
$ui.PolicyPicker.Add_SelectionChanged({
    $ui.UserGroupPicker.ItemsSource = @()
    $ui.UserGroupHint.Text = 'Policy selection changed. Find groups for the checked VMs / target UPNs again.'
})
$ui.FindGroupsButton.Add_Click({
    $ui.VmGrid.CommitEdit([windows.controls.datagrideditingunit]::Cell,$true) | Out-Null
    $ui.VmGrid.CommitEdit([windows.controls.datagrideditingunit]::Row,$true) | Out-Null
    $mappings = @($script:Inventory | Where-Object Selected | ForEach-Object { @{ VmId = $_.Id; UserPrincipalName = $_.UserPrincipalName } })
    Start-Operation 'FindGroups' @{ PolicyId = [string]$ui.PolicyPicker.SelectedValue; Mappings = $mappings }
})
$ui.DiscoverButton.Add_Click({ Start-Operation 'Discover' })
$ui.RefreshLicensesButton.Add_Click({ Start-Operation 'RefreshLicenses' })
$ui.SkuPicker.Add_SelectionChanged({
    if ($ui.SkuPicker.SelectedItem) {
        $license = $ui.SkuPicker.SelectedItem
        $ui.DiskSize.Text = [string]$license.StorageGB
        $ui.LicenseInfo.Text = "Available: $($license.Available)   Assigned: $($license.Consumed)   Enabled: $($license.Enabled)   State: $($license.CapabilityStatus)"
    } else {
        $ui.DiskSize.Text = ''
        $ui.LicenseInfo.Text = 'Choose an eligible license. Zero-seat / disabled SKUs cannot be selected. Counts are refreshed before assignment.'
    }
})
$ui.LocalButton.Add_Click({ Start-Operation 'LocalCheck'; $ui.Tabs.SelectedIndex = 3 })
$ui.InstallButton.Add_Click({
    if (Confirm-Change 'Install/update Az.Accounts, Az.Resources, Az.Compute, Az.Storage and Microsoft.Graph.Authentication from PSGallery for the current user? Restart this app afterward to load updated assemblies. No elevation or cloud changes. Review your package-source policy first.') { Start-Operation 'Install' }
})
$ui.MapButton.Add_Click({
    $ui.VmGrid.CommitEdit([windows.controls.datagrideditingunit]::Cell,$true) | Out-Null
    $ui.VmGrid.CommitEdit([windows.controls.datagrideditingunit]::Row,$true) | Out-Null
    $size = 0
    if (-not $ui.UserGroupPicker.SelectedItem -or $ui.UserGroupPicker.SelectedItem.PolicyId -ne [string]$ui.PolicyPicker.SelectedValue) { Show-Notice 'Find groups for the selected users and Enterprise policy, then explicitly choose a user group. Membership is rechecked when mapping.'; return }
    if (-not $ui.SkuPicker.SelectedItem -or -not $ui.SkuPicker.SelectedItem.CanSelect) { Show-Notice 'Select an Enterprise or CloudPC Lite license with available seats.'; return }
    if (-not [int]::TryParse($ui.DiskSize.Text,[ref]$size)) { Show-Notice 'Select a license with a resolved disk capacity.'; return }
    $mappings = @($script:Inventory | Where-Object Selected | ForEach-Object { @{ VmId = $_.Id; UserPrincipalName = $_.UserPrincipalName } })
    $config = @{ PolicyId = [string]$ui.PolicyPicker.SelectedValue; SkuId = [string]$ui.SkuPicker.SelectedValue; TargetDiskGiB = $size; StorageId = [string]$ui.StoragePicker.SelectedValue; Container = $ui.ContainerName.Text.Trim(); SnapshotResourceGroup = [string]$ui.SnapshotGroup.SelectedValue }
    $config.ExistingGroupId = [string]$ui.UserGroupPicker.SelectedValue
    $config.ExistingGroupName = [string]$ui.UserGroupPicker.SelectedItem.Name
    Start-Operation 'Map' @{ Mappings = $mappings; Config = $config }
    if ($script:Job) { $ui.Tabs.SelectedIndex = 2 }
})
$ui.GuestButton.Add_Click({
    if (Confirm-Change 'Run a read-only PowerShell guest assessment via Azure Run Command on selected RUNNING VMs? Azure executes this command as SYSTEM. It reads OS/join/BitLocker/agent information; it does not uninstall software or change the guest. Requires VM Run Command permission.') { Start-Operation 'Guest' }
})
$ui.AttestButton.Add_Click({
    if (Confirm-Change @'
For EVERY selected VM, confirm all of the following:
• Correct VM/profile/data -> target user mapping, independently verified.
• Supported Windows client release/edition; Windows 10 lifecycle/ESU reviewed.
• Third-party VDI agents removed and reboot completed; candidate inventory is NOT exhaustive.
• Source boots normally, recovery backup tested, guest agent healthy.
• Target license is the intended Enterprise / CloudPC Lite option; resolved disk capacity is appropriate; user has required Intune/Entra/Windows entitlements (including any Lite-specific eligibility).
• Target policy region, join type and network are correct; CSE/Windows 365 endpoints reachable.
• No conflicting policy/user-setting assignment filters or exclusions, inherited W365 licenses, existing unused import, pending license changes or concurrent admins.
• Approved outage, source write-freeze, rollback and data-integrity validation plan exist.
• Graph beta/pilot support limitation accepted.

This records operator evidence, not an automated test result. Confirm only after validation.
'@) { Start-Operation 'Attest' }
})
$ui.CheckButton.Add_Click({ Start-Operation 'Check'; $ui.Tabs.SelectedIndex = 3 })
$ui.RepairSnapshotButton.Add_Click({ Start-Operation 'RepairSnapshot' })
$ui.PrepareButton.Add_Click({
    $message = if ($script:Last -and $script:Last.Config.ExistingGroupId) { 'Create a dedicated snapshot user setting and assign it to the explicitly selected existing group? This affects EVERY member of that group; every member must be mapped and all batch rows selected. Existing group membership and Enterprise policy assignment are not changed. Resolve conflicting settings first and use an exclusive administration window. No license is assigned.' } else { 'Legacy plan: create a dedicated security group and snapshot user setting, add selected users and append the group to the policy preserving existing targets. Requires an exclusive administration window. No license is assigned.' }
    if (Confirm-Change $message) { Start-Operation 'Prepare' }
})
$ui.CaptureButton.Add_Click({
    if (Confirm-Change 'OUTAGE: deallocate selected Azure VMs, create billable managed OS snapshots, grant temporary export SAS (24h), and start copies into your private staging container. Trusted Launch also copies VMGS. Sources remain stopped; NO automatic rollback/restart/delete. Confirm user sign-out, approved downtime and backup.') { Start-Operation 'Capture' }
})
$ui.ImportButton.Add_Click({
    if (Confirm-Change 'Import the selected staged VHD/VMGS into Windows 365 via Microsoft Graph beta? Generates read-only 48-hour user-delegation SAS URLs in memory. Staging must remain accessible until import succeeds. Each snapshot belongs to one user; do not reuse it. No license is assigned yet.') { Start-Operation 'Import' }
})
$ui.RefreshButton.Add_Click({ Start-Operation 'Refresh' })
$ui.AutoRefresh.Add_Checked({
    if (-not (Show-CpcReviewDialog $window (Get-OperationReview 'Refresh') 'Enable automatic status refresh')) { $ui.AutoRefresh.IsChecked = $false }
})
$ui.LicenseButton.Add_Click({
    if (Confirm-Change 'Assign the selected Windows 365 Enterprise license to each selected user AFTER successful unused snapshot import? This consumes licenses, can incur costs, and triggers provisioning. Existing licenses are not removed. Confirm target SKU/disk/entitlements and source write-freeze again.') { Start-Operation 'License' }
})
$ui.ValidateButton.Add_Click({
    if (Confirm-Change 'Record migration completion ONLY if the user can sign in and you independently verified the correct source snapshot/profile/data/apps, Intune enrollment, network and user acceptance. Requires a provisioned Cloud PC and recorded successful import before licensing. The service may already have deleted the imported artifact: if usage is not inUse, Graph alone does NOT prove source-data provenance. This records your independent validation. No source restart/delete.') { Start-Operation 'Validate' }
})
$ui.PurgeButton.Add_Click({
    if (Confirm-Change 'DELETE the selected unused imported snapshots from Windows 365? Only failed/succeeded unused imports before license assignment are allowed. This is not rollback and does not delete Azure snapshots or blobs.') { Start-Operation 'Purge' }
})
$ui.CleanupButton.Add_Click({
    if (Confirm-Change 'PERMANENT CLEANUP: delete plan-owned Azure staging VHD/VMGS blobs and managed snapshots for validated migrations. Confirm your retention/backup requirements are met. Source VMs, Cloud PCs, licenses, groups and policies remain unchanged.') { Start-Operation 'Cleanup' }
})
$ui.RevokeButton.Add_Click({
    if (Confirm-Change 'Revoke Azure snapshot export SAS for selected rows? This can interrupt pending server-side blob copies. It does NOT revoke already-issued user-delegation SAS on staging blobs; those expire separately. No VM is restarted or deleted.') { Start-Operation 'RevokeExport' }
})
$ui.ImageButton.Add_Click({
    if (Confirm-Change 'Switch this batch-owned user setting to image for FUTURE reprovisioning? ALL rows must be validated/cleaned or safely abandoned. Abandoned users must still have no Cloud PC/W365 license. Current Cloud PCs and policy/group membership remain unchanged.') { Start-Operation 'UseImage' }
})
$ui.CancelButton.Add_Click({
    $script:Signals.Cancel = $true
    $ui.StatusText.Text = 'Stop requested — waiting for current API call. No rollback; server-side work may continue.'
})
$ui.SaveButton.Add_Click({
    $dialog = [Microsoft.Win32.SaveFileDialog]::new()
    $dialog.Filter = 'Migration journal (*.json)|*.json'
    $dialog.FileName = 'migration-plan.json'
    if (Invoke-UiModal { $dialog.ShowDialog($window) }) { Start-Operation 'Save' @{ Path = $dialog.FileName } }
})
$ui.LoadButton.Add_Click({ Show-JournalManager })
$ui.ResumeButton.Add_Click({ Show-JournalManager })
$ui.JournalManagerButton.Add_Click({ Show-JournalManager })
$ui.ExportButton.Add_Click({
    $dialog = [Microsoft.Win32.SaveFileDialog]::new()
    $dialog.Filter = 'HTML report (*.html)|*.html'
    $dialog.FileName = 'migration-report.html'
    if (Invoke-UiModal { $dialog.ShowDialog($window) }) { Start-Operation 'Export' @{ Directory = [IO.Path]::GetDirectoryName($dialog.FileName) } }
})
$ui.ReconcileButton.Add_Click({
    Start-Operation 'ReconcileImport' @{ ImportId = $ui.ImportId.Text.Trim() }
})
$ui.ReconcileLicenseButton.Add_Click({ Start-Operation 'ReconcileLicense' @{ Evidence = $ui.LicenseEvidence.Text.Trim(); AssignedUtc = $ui.LicenseAssignedUtc.Text.Trim() } })
$ui.ResetCaptureButton.Add_Click({ Start-Operation 'ResetCapture' })
$ui.AbandonButton.Add_Click({ Start-Operation 'Abandon' })
$ui.GraphGrid.Add_SelectionChanged({
    if ($ui.GraphGrid.SelectedItem) { $ui.GraphJson.Text = $ui.GraphGrid.SelectedItem.Result }
})
$ui.PlanGrid.Add_SelectionChanged({
    if ($ui.PlanGrid.SelectedItem) {
        $ui.RowJson.Text = $ui.PlanGrid.SelectedItem | ConvertTo-Json -Depth 15
    }
})
$ui.SearchBox.Add_TextChanged({ Update-VmFilter })
$ui.DocsButton.Add_Click({ Start-Process 'https://learn.microsoft.com/en-us/windows-365/enterprise/migration-to-windows365' })
$window.Add_Closing({
    param($sourceWindow,$closingArgs)
    if ($script:Job) {
        $closingArgs.Cancel = $true
        $script:Signals.Cancel = $true
        Show-Notice 'Stop requested. Wait for the current operation to finish before closing. Server-side copies/imports/provisioning can continue after the app closes.'
    }
})

try {
    # Initialize before any sign-in or user operation. Smoke tests use an isolated
    # temporary folder and still exercise real automatic log/journal creation.
    $script:SmokeLogFolder = ''
    $loggingFolder = $PSScriptRoot
    if ($SmokeTest) { $script:SmokeLogFolder = Join-Path ([IO.Path]::GetTempPath()) ('cpcm-ui-log-' + [guid]::NewGuid().ToString('N')); $loggingFolder = $script:SmokeLogFolder }
    $startup = [powershell]::Create()
    $startup.Runspace = $runspace
    try {
        $startupData = @{ Directory = $loggingFolder }
        if ($script:RequiredTenantId) { $startupData.RequiredTenantId = $script:RequiredTenantId }
        $null = $startup.AddCommand('Invoke-CpcOperation').AddParameter('Action','InitializeLogging').AddParameter('Data',$startupData).AddParameter('Signals',$script:Signals)
        $startupResults = @($startup.Invoke())
        if ($startup.HadErrors -or $startupResults.Count -ne 1) { throw ('Unable to initialize automatic logging: ' + ($startup.Streams.Error -join "`n")) }
        $loggingResult = $startupResults[0]
        if ($loggingResult.OperationError -or -not $loggingResult.LogPath -or -not $loggingResult.StatePath) { throw ('Unable to initialize automatic logging: ' + $loggingResult.OperationError) }
        if ($SmokeTest) {
            if (-not [IO.File]::Exists($loggingResult.LogPath) -or -not [IO.File]::Exists($loggingResult.StatePath)) { throw 'Startup did not automatically create log and journal.' }
        } else {
            Set-OperationResult $loggingResult 'InitializeLogging'
            if ($loggingResult.LogLocationChanged) { Show-Notice "Log location changed because the script folder is not writable for this session.`n`nLog: $($loggingResult.LogPath)`nJournal: $($loggingResult.StatePath)" }
            $ui.StatusText.Text = "Logging automatically: $($loggingResult.LogPath)"
        }
    } finally { $startup.Dispose() }
    if ($SmokeTest) {
        $expectedTenant = if ($PSBoundParameters.ContainsKey('TenantId')) { $TenantId.ToString('D') } else { '' }
        if ($ui.TenantId.Text -ne $expectedTenant -or $ui.TenantId.IsEnabled -ne (-not $expectedTenant)) { throw 'Startup tenant prepopulation / locking is incorrect.' }
        foreach ($busy in @($true,$false,$true,$false)) {
            Set-Working $busy
            foreach ($name in @('ResetCaptureButton','AbandonButton','ReconcileLicenseButton','LicenseEvidence','LicenseAssignedUtc')) {
                if (-not $ui[$name] -or $ui[$name].IsEnabled) { throw "Recovery control $name must stay disabled before connection and selection, including idle state." }
            }
            if ($ui.TenantId.IsEnabled -ne (-not $busy -and -not $expectedTenant) -or $ui.TenantId.Text -ne $expectedTenant) { throw 'Busy/idle transitions changed startup tenant locking / value.' }
            if ($ui.SubscriptionPicker.IsEnabled -ne (-not $busy) -or $ui.DetectSubscriptionsButton.IsEnabled -ne (-not $busy)) { throw 'Startup tenant must not prevent explicit subscription detection / selection.' }
        }
        if ($script:Job -or $script:Last) { throw 'Startup must not implicitly authenticate or start an operation.' }
        $caughtError = 'A command that prompts the user failed because the host does not support user interaction.'
        foreach ($hadErrors in @($true,$false)) {
            if ((Get-OperationFailureText @{ OperationError = $caughtError } @() $hadErrors) -ne $caughtError) { throw 'Caught operation error was lost when the worker error stream was empty.' }
        }
        if ((Get-OperationFailureText @{ OperationError = '' } @() $true) -notmatch 'without details') { throw 'HadErrors with an empty stream would show a blank notice.' }
        if (Get-OperationFailureText @{ OperationError = '' } @() $false) { throw 'Successful operation must not show an error notice.' }
        if ((Get-OperationFailureText $null @() $false) -notmatch 'no operation result') { throw 'Missing result must be reported.' }
        if ((Get-OperationFailureText @{ OperationError = '' } @('offline stream failure') $true) -ne 'offline stream failure') { throw 'Worker stream error must remain visible.' }
        # Replace the worker entry point only in smoke mode; exercise the actual
        # dispatch path without executing any core operation or cloud command.
        $stub = [powershell]::Create()
        try {
            $stub.Runspace = $runspace
            $null = $stub.AddScript({
                function global:Invoke-CpcOperation {
                    param($Action,$Data,$Signals)
                    [pscustomobject]@{ OfflineStub = $true; Action = $Action; Data = $Data }
                }
            })
            $null = $stub.Invoke()
            if ($stub.HadErrors) { throw ($stub.Streams.Error -join "`n") }
        } finally { $stub.Dispose() }
        $probeData = @{}
        if ($expectedTenant) { $probeData.RequiredTenantId = '11111111-1111-1111-1111-111111111111' }
        Start-Operation 'LocalCheck' $probeData
        try {
            $probe = @($script:Job.PowerShell.EndInvoke($script:Job.Handle))
            if ($script:Job.PowerShell.HadErrors -or $probe.Count -ne 1 -or -not $probe[0].OfflineStub -or $probe[0].Action -ne 'LocalCheck') { throw 'Offline dispatch probe failed.' }
            if ($expectedTenant) {
                if ($probe[0].Data.RequiredTenantId -cne $expectedTenant) { throw 'Core dispatch did not enforce the startup RequiredTenantId.' }
            } elseif ($probe[0].Data.ContainsKey('RequiredTenantId')) { throw 'Omitting TenantId must not add a startup tenant constraint.' }
        } finally {
            if ($script:Job) { $script:Job.PowerShell.Dispose(); $script:Job = $null }
            Set-Working $false
        }
        $fixture = [pscustomobject]@{
            Rows = @([pscustomobject]@{ Selected = $true; VmId = 'fixture'; VM = 'OFFLINE-SMOKE'; UserPrincipalName = 'test@example.invalid'; Phase = 'Mapped'; Readiness = 'NotChecked'; ImportStatus = ''; CloudPcStatus = '' })
            Checks = @(); Catalog = @{ Subscriptions = @(
                [pscustomobject]@{ Name = 'Offline subscription A'; Id = '33333333-3333-3333-3333-333333333333'; DisplayName = 'Offline subscription A [33333333-3333-3333-3333-333333333333]' },
                [pscustomobject]@{ Name = 'Offline subscription B'; Id = '77777777-7777-7777-7777-777777777777'; DisplayName = 'Offline subscription B [77777777-7777-7777-7777-777777777777]' }
            ); ResourceGroups = @(
                [pscustomobject]@{ Name = 'source-a'; DisplayName = 'source-a [eastus]' },
                [pscustomobject]@{ Name = 'source-b'; DisplayName = 'source-b [westus]' }
            ); Vms = @(
                [pscustomobject]@{ Name = 'shared-name'; ResourceGroup = 'source-a'; Location = 'eastus'; Size = 'Standard_D2s_v5'; OS = 'Windows'; Id = '/subscriptions/33333333-3333-3333-3333-333333333333/resourceGroups/source-a/providers/Microsoft.Compute/virtualMachines/shared-name' },
                [pscustomobject]@{ Name = 'shared-name'; ResourceGroup = 'source-b'; Location = 'westus'; Size = 'Standard_D2s_v5'; OS = 'Windows'; Id = '/subscriptions/33333333-3333-3333-3333-333333333333/resourceGroups/source-b/providers/Microsoft.Compute/virtualMachines/shared-name' }
            ); Policies = @(
                [pscustomobject]@{ id = 'legacy'; displayName = 'Legacy compatible'; provisioningType = 'dedicated' },
                [pscustomobject]@{ id = 'w365'; displayName = 'Windows 365'; provisioningType = 'dedicated'; managedBy = 'windows365'; userExperienceType = 'cloudPc' },
                [pscustomobject]@{ id = 'devbox'; displayName = 'Wrong service'; provisioningType = 'dedicated'; managedBy = 'devBox'; userExperienceType = 'cloudPc' },
                [pscustomobject]@{ id = 'apps'; displayName = 'Wrong experience'; provisioningType = 'dedicated'; managedBy = 'windows365'; userExperienceType = 'cloudApp' }
            ); Skus = @(
                [pscustomobject]@{ SkuId = '55555555-5555-5555-5555-555555555555'; StorageGB = 128; Available = 7; Consumed = 3; Enabled = 10; CapabilityStatus = 'Enabled'; CanSelect = $true; SelectionLabel = 'CloudPC Lite 2 vCPU / 4 GB / 128 GB | Available: 7' },
                [pscustomobject]@{ SkuId = '66666666-6666-6666-6666-666666666666'; StorageGB = 256; Available = 0; Consumed = 10; Enabled = 10; CapabilityStatus = 'Enabled'; CanSelect = $false; SelectionLabel = 'Windows 365 Enterprise 4 vCPU / 16 GB / 256 GB | Available: 0' }
            ); Storage = @() }; GraphResults = @()
            Connected = $false; TenantId = '22222222-2222-2222-2222-222222222222'; SubscriptionId = ''; OperationError = ''
            GroupId = ''; UserSettingId = ''; PlanId = 'offline-smoke'; StatePath = ''; Config = @{ SnapshotResourceGroup = 'source-b' }; LogPath = $loggingResult.LogPath
        }
        $savedRows = $fixture.Rows
        $fixture.Rows = @()
        Set-OperationResult $fixture 'DetectSubscriptions'
        if ($ui.SubscriptionPicker.Items.Count -ne 2 -or $ui.SubscriptionPicker.SelectedIndex -ne -1) { throw 'Detected subscriptions must require explicit selection.' }
        $ui.SubscriptionPicker.SelectedIndex = 0
        if ($ui.SubscriptionPicker.SelectedValue -ne '33333333-3333-3333-3333-333333333333') { throw 'Subscription picker must bind the ID rather than display name.' }
        $fixture.SubscriptionId = [string]$ui.SubscriptionPicker.SelectedValue
        $fixture.Rows = $savedRows
        Set-OperationResult $fixture 'Discover'
        if ($ui.PolicyPicker.Items.Count -ne 2 -or @($ui.PolicyPicker.Items | Where-Object id -In @('devbox','apps')).Count) { throw 'Policy picker exposed incompatible service/experience.' }
        if ($ui.SnapshotGroup.SelectedValue -ne 'source-b') { throw 'Snapshot destination selection was not restored from plan configuration.' }
        $script:Inventory[0].Selected = $true
        $script:Inventory[0].UserPrincipalName = 'preserved@example.invalid'
        $ui.SourceGroupPicker.SelectedValue = 'source-b'
        if ($ui.VmGrid.Items.Count -ne 1 -or $ui.VmGrid.Items[0].ResourceGroup -ne 'source-b') { throw 'Source resource-group filter did not isolate the correct VM.' }
        $ui.SearchBox.Text = 'eastus'
        if ($ui.VmGrid.Items.Count -ne 0) { throw 'Resource-group and text search filters must combine, not replace each other.' }
        $ui.SearchBox.Text = 'WESTUS'
        if ($ui.VmGrid.Items.Count -ne 1) { throw 'VM search must be case-insensitive.' }
        if (-not $script:Inventory[0].Selected -or $script:Inventory[0].UserPrincipalName -ne 'preserved@example.invalid') { throw 'Filtering lost hidden selection or UPN edits.' }
        $ui.SourceGroupPicker.SelectedIndex = 0
        $ui.SearchBox.Text = ''
        if ($ui.VmGrid.Items.Count -ne 2 -or $ui.SnapshotGroup.SelectedValue -ne 'source-b') { throw 'All-groups filtering must not change snapshot destination selection.' }
        $mapReview = Get-OperationReview 'Map' @{ Config = @{} }
        if ($mapReview -notmatch 'preserved@example.invalid' -or $mapReview -notmatch 'resourceGroups/source-a') { throw 'Mapping review lost selected VM resource IDs / UPNs.' }
        $fixture.Config.PolicyId = '44444444-4444-4444-4444-444444444444'
        $fixture.Catalog.Groups = @(
            [pscustomobject]@{ Id = '66666666-6666-6666-6666-666666666666'; Name = 'First user group'; DisplayName = 'First user group [66666666-6666-6666-6666-666666666666]'; PolicyId = $fixture.Config.PolicyId },
            [pscustomobject]@{ Id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'; Name = 'Second user group'; DisplayName = 'Second user group [aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa]'; PolicyId = $fixture.Config.PolicyId }
        )
        Set-OperationResult $fixture 'FindGroups'
        if ($ui.UserGroupPicker.Items.Count -ne 2 -or $ui.UserGroupPicker.SelectedIndex -ne -1) { throw 'Multiple user groups must be displayed without automatic selection.' }
        $ui.UserGroupPicker.SelectedIndex = 1
        if ($ui.UserGroupPicker.SelectedValue -ne 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa') { throw 'Admin must be able to select the second user group by ID.' }
        $fixture.Config.ExistingGroupId = [string]$ui.UserGroupPicker.SelectedValue
        $fixture.Config.ExistingGroupName = $ui.UserGroupPicker.SelectedItem.Name
        $review = Get-OperationReview 'Prepare'
        if ($review -notmatch 'Second user group' -or $review -notmatch 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' -or $review -notmatch 'NOT modified') { throw 'Existing-group confirmation must show the chosen name/ID and no membership/policy changes.' }
        foreach ($action in @('ReconcileLicense','ResetCapture','Abandon')) {
            $recoveryReview = Get-OperationReview $action @{ Evidence = 'OFFLINE-AUDIT-REFERENCE'; AssignedUtc = '2026-09-17T10:00:00Z' }
            if ($recoveryReview -notmatch 'OFFLINE-SMOKE' -or $recoveryReview -notmatch 'OFFLINE-AUDIT-REFERENCE' -or $recoveryReview -notmatch 'READ-ONLY|PERMANENT DELETE') { throw 'Recovery confirmation omitted exact scope, evidence or operation risk.' }
        }
        Set-OperationResult $fixture 'Load'
        if ($ui.UserGroupPicker.SelectedValue -ne $fixture.Config.ExistingGroupId) { throw 'Loaded group selection was not restored.' }
        $ui.PolicyPicker.ItemsSource = @([pscustomobject]@{ id = 'different-policy'; displayName = 'Changed policy' })
        $ui.PolicyPicker.SelectedIndex = 0
        if ($ui.UserGroupPicker.Items.Count -ne 0) { throw 'Policy changes must invalidate user group choices.' }
        Set-Working $false
        if ($ui.SubscriptionPicker.IsEnabled -or $ui.TenantId.IsEnabled -or $ui.DetectSubscriptionsButton.IsEnabled) { throw 'Scope selectors must lock once a plan exists.' }
        $ui.SkuPicker.SelectedIndex = 0
        if ($ui.DiskSize.Text -ne '128' -or $ui.LicenseInfo.Text -notmatch 'Available: 7') { throw 'License picker did not update disk capacity / seat counts.' }
        Set-OperationResult $fixture 'RefreshLicenses'
        if ($ui.SkuPicker.SelectedIndex -ne 0) { throw 'License refresh lost selected SKU.' }
        $ui.Tabs.SelectedIndex = 0
        # Render, then close on the dispatcher; no module installation or tenant calls.
        $script:SmokeFailure = ''
        $window.Add_ContentRendered({
            try {
                if (-not $ui.LogLocationText.IsReadOnly -or -not $ui.LogLocationText.Text.Contains($loggingResult.LogPath)) { throw 'Automatic log path is not shown in the copyable Activity log field.' }
                if ($ui.TenantId.Text -ne $expectedTenant -or $ui.TenantId.IsEnabled) { throw 'Rendered tenant value / plan scope lock is incorrect.' }
                if ($ui.CheckButton.ToolTip -notmatch 'saved guest assessment' -or $ui.GuestButton.ToolTip -notmatch 'Repeat after guest fixes') { throw 'Guest refresh guidance must be available on the workflow controls.' }
                if (@($ui.PlanGrid.Columns | Where-Object Header -EQ 'Guest assessed (recorded)').Count -ne 1) { throw 'Migration grid must distinguish guest collection time from validation time.' }
                # Exercise actual controls against server-side phases after the
                # worker returns, not merely busy-state disabling.
                $fixture.Connected = $true; $fixture.TenantId = $ui.TenantId.Text.Trim()
                $fixture.StatePath = $loggingResult.StatePath
                $fixture | Add-Member -NotePropertyName Preflight -NotePropertyValue @{} -Force
                $r = $fixture.Rows[0]
                $r | Add-Member -NotePropertyName Guest -NotePropertyValue @{ CheckedUtc = [datetime]::new(2026,9,17,12,44,20,[DateTimeKind]::Utc) } -Force
                $r | Add-Member -NotePropertyName Attested -NotePropertyValue $false -Force
                $r.Phase = 'IdentityPrepared'; $fixture.GroupId = 'group'; $fixture.UserSettingId = 'setting'
                Set-OperationResult $fixture 'Load'; Set-Working $false
                if ($ui.AttestButton.IsEnabled -or -not $ui.RefreshButton.IsEnabled -or $ui.NextStepText.Text -notmatch 'Refresh status') { throw 'Load must require live refresh before attest or migration actions.' }
                $r | Add-Member -NotePropertyName StatusRefreshSucceeded -NotePropertyValue $false -Force
                Set-OperationResult $fixture 'Refresh'
                if ($ui.AttestButton.IsEnabled) { throw 'Failed/unselected refresh cannot release resume guard.' }
                $r.StatusRefreshSucceeded = $true; Set-OperationResult $fixture 'Refresh'
                if ($ui.MapButton.IsEnabled -or $ui.LoadButton.IsEnabled -or $ui.PrepareButton.IsEnabled -or $ui.CaptureButton.IsEnabled -or -not $ui.AttestButton.IsEnabled -or $ui.NextStepText.Text -notmatch 'Step 4 is already complete') { throw 'Loaded prepared plan must guide reattestation without allowing remap/Prepare/Capture.' }
                $ui.Tabs.SelectedIndex = 2; $ui.PlanGrid.UpdateLayout()
                $guestColumn = @($ui.PlanGrid.Columns | Where-Object Header -EQ 'Guest assessed (recorded)')[0]
                $ui.PlanGrid.ScrollIntoView($script:PlanRows[0], $guestColumn); $ui.PlanGrid.UpdateLayout()
                $guestCell = $guestColumn.GetCellContent($script:PlanRows[0])
                if (-not $guestCell -or $guestCell.Text -ne '2026-09-17T12:44:20.0000000Z') { throw 'Rendered guest timestamp cell must contain the saved observation time.' }
                $r.Attested = $true; Update-WorkflowControls
                if (-not $ui.CheckButton.IsEnabled -or $ui.CaptureButton.IsEnabled) { throw 'Attestation enables validation, not unapproved capture.' }
                $r.Readiness = 'Ready'; $fixture.Preflight['fixture'] = @{ Stage = 'Capture'; ExpiresUtc = [datetimeoffset]::UtcNow.AddMinutes(30).ToString('o') }; Update-WorkflowControls
                if (-not $ui.CaptureButton.IsEnabled -or $ui.PrepareButton.IsEnabled) { throw 'Only correct approved major stage should be enabled.' }
                $fixture.Preflight['fixture'].ExpiresUtc = [datetimeoffset]::UtcNow.AddSeconds(-1).ToString('o'); Update-WorkflowControls
                if ($ui.CaptureButton.IsEnabled) { throw 'Expired approval must immediately disable capture.' }
                foreach ($phase in @('Copying','Importing','Provisioning')) {
                    $r.Phase = $phase; Update-WorkflowControls
                    foreach ($name in @('GuestButton','AttestButton','CheckButton','PrepareButton','CaptureButton','ImportButton','LicenseButton','ValidateButton','CleanupButton','RepairSnapshotButton')) {
                        if ($ui[$name].IsEnabled) { throw "$name must be disabled while $phase is in progress." }
                    }
                    if (-not $ui.RefreshButton.IsEnabled -or $ui.NextStepText.Text -notmatch 'Refresh status') { throw 'In-flight stage must guide status polling.' }
                    $rejectedAutomatic = $false
                    try { Start-Operation 'Import' -Automatic } catch { $rejectedAutomatic = $_.Exception.Message -match 'Only status refresh' }
                    if (-not $rejectedAutomatic) { throw 'Automatic flag must not bypass import confirmation.' }
                    if ($script:Job) { throw 'Click-time guard dispatched an out-of-stage import to the worker.' }
                }
                $r.Phase = 'ImportUnknown'; $ui.ImportId.Text = ''; Update-WorkflowControls
                if ($ui.ReconcileButton.IsEnabled -or -not $ui.ImportId.IsEnabled) { throw 'Import evidence must be editable while empty reconciliation is disabled.' }
                $ui.ImportId.Text = '77777777-7777-7777-7777-777777777777'; Update-WorkflowControls
                if (-not $ui.ReconcileButton.IsEnabled) { throw 'Known import ID should enable explicit reconciliation.' }
                $r.Selected = $false; Update-WorkflowControls
                if ($ui.ImportId.Text -or $ui.ReconcileButton.IsEnabled) { throw 'Reconciliation evidence must not carry over to another selection.' }
                $r.Selected = $true; Update-WorkflowControls
                Invoke-UiModal {
                    if (Test-UiIdle) { throw 'Modal review must suspend worker dispatch.' }
                    Invoke-UiModal { if ($script:ModalDepth -ne 2) { throw 'Nested review lost modal guard.' } }
                    & $script:RefreshTick
                    Start-Operation 'Refresh' -Automatic
                    if ($script:Job) { throw 'Review started a background refresh.' }
                    $script:Job = @{ Handle = @{ IsCompleted = $true }; PowerShell = $null }
                    try { & $script:OperationTick; if (-not $script:Job) { throw 'Completed job reentered during modal review.' } } finally { $script:Job = $null }
                }
                if ($script:ModalDepth -ne 0 -or -not (Test-UiIdle)) { throw 'Modal guard failed to unwind.' }
                try { Invoke-UiModal { throw 'fixture dialog failure' } } catch { }
                if ($script:ModalDepth -ne 0) { throw 'Failed dialog left modal guard locked.' }
                $r.Selected = $false; Update-WorkflowControls
                if ($ui.RefreshButton.IsEnabled -or $ui.NextStepText.Text -notmatch 'Use checkboxes') { throw 'Unchecked selection must not enable row actions.' }
                $r.Selected = $true; $r.Phase = 'Mapped'; $fixture.GroupId = ''; $fixture.UserSettingId = ''; Update-WorkflowControls
                if (-not $ui.MapButton.IsEnabled) { throw 'Unprepared draft mappings should remain editable.' }
                $ui.Tabs.SelectedIndex = 0
                $errorReview = New-CpcReviewDialog $window 'fixture' 'Operation error' -InformationOnly -OperationError 'Stage approval missing'
                if ($errorReview.Tag.Heading.Text -match '0 failed checks' -or $errorReview.Tag.Heading.Text -notmatch 'No failed prerequisite checks') { throw 'Operation-only failure must not imply a failed check count.' }
                $errorReview.Close()
                $reviewDialog = New-CpcReviewDialog $window (Get-OperationReview 'Import') 'Offline confirmation smoke test' -RequirePreflight -Checks @(
                    @{ VM = 'OFFLINE-SMOKE'; Check = 'Snapshot user setting assigned'; Status = 'Fail'; Detail = 'Snapshot setting has not been assigned.' },
                    @{ VM = 'OFFLINE-SMOKE'; Check = 'Entra joined to this tenant'; Status = 'Fail'; Detail = 'Guest assessment collected: 2026-09-17T12:18:34Z. Recorded AzureAdJoined=False.' },
                    @{ VM = 'OFFLINE-SMOKE'; Check = 'No encrypted guest volumes'; Status = 'Fail'; Detail = 'Guest assessment collected: 2026-09-17T12:18:34Z. Recorded volumes not FullyDecrypted=1.' },
                    @{ VM = 'Batch'; Check = 'Assessment boundaries'; Status = 'Manual'; Detail = 'Customer must verify backup and data integrity.' }
                )
                $failedCard = $reviewDialog.Tag.IssueCards[0]
                if ($failedCard.Foreground.Color.R -ne 185 -or $failedCard.Foreground.Color.G -ne 28 -or $failedCard.Foreground.Color.B -ne 28 -or $failedCard.Text -notmatch 'Repair snapshot setting') { throw 'Failed prerequisite must be red and include the corrective UI action.' }
                if ($reviewDialog.Tag.IssueCards.Count -ne 4 -or $reviewDialog.Tag.IssueCards[3].Text -notmatch '\[Manual\]' -or $reviewDialog.Tag.IssueCards[3].Text -notmatch 'not an automated failure') { throw 'Manual responsibilities must remain distinct from failed automatic checks.' }
                foreach ($card in @($reviewDialog.Tag.IssueCards[1], $reviewDialog.Tag.IssueCards[2])) {
                    if ($card.Text -notmatch '2026-09-17T12:18:34Z' -or $card.Text -notmatch '1 Assess guest' -or $card.Text -notmatch '2 Attest prerequisites' -or $card.Text -notmatch '3 Validate prerequisites') { throw 'Guest failure cards must show collection time and complete refresh sequence.' }
                }
                if ($reviewDialog.Tag.Confirm.IsEnabled -or -not $reviewDialog.Tag.Cancel.IsDefault) { throw 'Confirmation must default to Cancel and require acknowledgement.' }
                $reviewDialog.Tag.Acknowledgement.IsChecked = $true
                if (-not $reviewDialog.Tag.Confirm.IsEnabled) { throw 'Explicit acknowledgement did not enable confirmation.' }
                $reviewDialog.Tag.Acknowledgement.IsChecked = $false
                if ($reviewDialog.Tag.Confirm.IsEnabled) { throw 'Removing acknowledgement did not disable confirmation.' }
                $reviewDialog.Add_ContentRendered({ param($reviewWindow,$renderEvent); $reviewWindow.Close() })
                $reviewDialog.ShowDialog() | Out-Null
                $ui.SkuPicker.IsDropDownOpen = $true
                $ui.SkuPicker.UpdateLayout()
                $unavailableItem = $ui.SkuPicker.ItemContainerGenerator.ContainerFromIndex(1)
                if (-not $unavailableItem -or $unavailableItem.IsEnabled) { throw 'Zero-seat option was not disabled.' }
            } catch { $script:SmokeFailure = $_.Exception.Message }
            finally { $ui.SkuPicker.IsDropDownOpen = $false; $window.Close() }
        })
    }
    $window.ShowDialog() | Out-Null
    if ($SmokeTest -and $script:SmokeFailure) { throw $script:SmokeFailure }
    if ($SmokeTest) { 'PASS: WPF window constructed and rendered; no cloud calls made.' }
} finally {
    $timer.Stop(); $refreshTimer.Stop()
    $shutdown = [powershell]::Create()
    $shutdown.Runspace = $runspace
    try { $null = $shutdown.AddCommand('Remove-Module').AddParameter('Name','CpcMigration.Core').Invoke() }
    finally {
        $shutdown.Dispose(); $runspace.Close(); $runspace.Dispose()
        if ($SmokeTest -and $script:SmokeLogFolder -and [IO.Directory]::Exists($script:SmokeLogFolder)) { [IO.Directory]::Delete($script:SmokeLogFolder, $true) }
    }
}