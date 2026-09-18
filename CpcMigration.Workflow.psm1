#requires -Version 7.2
Set-StrictMode -Version 3.0

# Read-only UI policy. The core remains authoritative for live scope, ownership,
# integrity and single-use approval checks. This module never changes a plan.
function Get-WorkflowValue($Object, [string]$Name, $Default = $null) {
    if ($Object -is [collections.IDictionary]) { if ($Object.Contains($Name)) { return $Object[$Name] } }
    elseif ($null -ne $Object -and $Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return $Default
}

function Get-WorkflowStage($Row) {
    switch ([string](Get-WorkflowValue $Row 'Phase')) {
        'Mapped' { 'Prepare' }
        { $_ -in @('IdentityPrepared','CaptureFailed','Capturing') } { 'Capture' }
        'Staged' { 'Import' }
        'Imported' { 'License' }
        default { '' }
    }
}

function Test-WorkflowApproval($State, $Row, [string]$Stage, [datetimeoffset]$Now) {
    $receipt = Get-WorkflowValue (Get-WorkflowValue $State 'Preflight') ([string](Get-WorkflowValue $Row 'VmId'))
    if (-not $receipt -or (Get-WorkflowValue $receipt 'Stage') -ne $Stage -or (Get-WorkflowValue $Row 'Readiness') -ne 'Ready') { return $false }
    try {
        $expiry = Get-WorkflowValue $receipt 'ExpiresUtc'
        if ($expiry -is [datetime]) {
            if ($expiry.Kind -eq [DateTimeKind]::Unspecified) { return $false }
            $expiry = [datetimeoffset]::new($expiry)
        } elseif ($expiry -isnot [datetimeoffset]) {
            if ([string]$expiry -notmatch '(Z|[+-]\d{2}:\d{2})$') { return $false }
            $expiry = [datetimeoffset]::Parse([string]$expiry, [cultureinfo]::InvariantCulture)
        }
        return $Now -lt $expiry
    } catch { return $false }
}

function Get-CpcActionAvailability {
    param([string]$Action, $State, [object[]]$Rows = @(), [bool]$Busy = $false, [datetimeoffset]$Now = [datetimeoffset]::UtcNow, $Data = $null)
    $reason = ''
    $all = @(Get-WorkflowValue $State 'Rows' @())
    $rowsToCheck = @($Rows)
    if ($Busy) { $reason = 'Wait for the current operation to finish. Server-side work may continue afterward; use Refresh status.' }
    elseif (-not (Get-WorkflowValue $State 'Connected' $false)) { $reason = 'Connect the intended tenant and subscription first.' }
    elseif ($Action -eq 'Load') {
        if ($all.Count) { $reason = 'A plan is already open. Restart, connect, then Resume / load journal before creating mappings.' }
    }
    elseif ($Action -eq 'Map') {
        if ((Get-WorkflowValue $State 'GroupId') -or (Get-WorkflowValue $State 'UserSettingId') -or @($all | Where-Object { (Get-WorkflowValue $_ 'Phase') -ne 'Mapped' }).Count) {
            $reason = 'Prepared mappings are locked. Continue this plan using the next step; do not replace it. Resume a different migration in a fresh session using its original journal.'
        }
    }
    else {
        if ($Action -in @('RepairSnapshot','UseImage')) { $rowsToCheck = $all }
        if (-not $rowsToCheck.Count) { $reason = 'Check Use for one or more migration rows. Actions apply to checked rows, not just the highlighted row.' }
        elseif ($Action -ne 'Refresh' -and @($rowsToCheck | Where-Object { (Get-WorkflowValue $_ 'VmId') -in @(Get-WorkflowValue $State 'ResumePendingVmIds' @()) }).Count) { $reason = 'Journal restored: Refresh status for these rows first. Resolve any refresh errors before continuing; saved phases are not live confirmation.' }
        elseif ($Action -in @('ReconcileImport','ReconcileLicense') -and $rowsToCheck.Count -ne 1) { $reason = 'Select exactly one row for reconciliation.' }
        elseif ($Action -eq 'Prepare' -and (Get-WorkflowValue (Get-WorkflowValue $State 'Config') 'ExistingGroupId') -and $rowsToCheck.Count -ne $all.Count) { $reason = 'Prepare changes a group-wide setting. Select every row in the batch and validate together.' }
        else {
            foreach ($row in $rowsToCheck) {
                $phase = [string](Get-WorkflowValue $row 'Phase')
                $stage = Get-WorkflowStage $row
                $allowed = switch ($Action) {
                    'Guest' { $phase -in @('Mapped','IdentityPrepared','CaptureFailed') -and -not (Get-WorkflowValue $row 'SnapshotId') -and -not (Get-WorkflowValue $row 'SourceVmUniqueId') }
                    'Attest' { $stage -ne '' -and $null -ne (Get-WorkflowValue $row 'Guest') }
                    'Check' { $stage -ne '' -and $null -ne (Get-WorkflowValue $row 'Guest') -and (Get-WorkflowValue $row 'Attested' $false) }
                    'Prepare' { $phase -eq 'Mapped' }
                    'Capture' { $stage -eq 'Capture' }
                    'Import' { $phase -eq 'Staged' }
                    'License' { $phase -eq 'Imported' }
                    'Refresh' { $true }
                    'Validate' { $phase -eq 'Provisioned' -and (Get-WorkflowValue $row 'ImportStatus') -eq 'succeeded' -and (Get-WorkflowValue $row 'ImportId') -and (Get-WorkflowValue $row 'LicenseAssignedUtc') }
                    'Cleanup' { $phase -in @('Validated','CleanupPending') -and (Get-WorkflowValue $row 'ValidatedUtc') }
                    'Purge' { $phase -in @('Imported','ImportFailed') -and (Get-WorkflowValue $row 'ImportId') -and -not (Get-WorkflowValue $row 'LicenseAssignedUtc') }
                    'RevokeExport' { [bool](Get-WorkflowValue $row 'SnapshotId') -and $phase -in @('Capturing','CaptureFailed','Copying','CopyFailed') }
                    'ReconcileImport' { $phase -eq 'ImportUnknown' }
                    'ReconcileLicense' { $phase -eq 'LicenseUnknown' }
                    'RepairSnapshot' { (Get-WorkflowValue $State 'GroupId') -and (Get-WorkflowValue $State 'UserSettingId') -and $phase -in @('Mapped','IdentityPrepared','Staged','Imported','CaptureFailed') -and -not (Get-WorkflowValue $row 'LicenseAssignedUtc') }
                    'UseImage' { (Get-WorkflowValue $State 'UserSettingId') -and $phase -in @('Validated','Cleaned','Abandoned') }
                    { $_ -in @('ResetCapture','Abandon') } {
                        $replay = if ($Action -eq 'Abandon') { 'Abandoning' } else { 'ResettingCapture' }
                        $phase -in (@('Mapped','IdentityPrepared','Capturing','CaptureFailed','Copying','CopyFailed','Staged','Purged') + $replay) -and
                            -not (Get-WorkflowValue $row 'LicenseAssignedUtc') -and
                            (-not (Get-WorkflowValue $row 'ImportId') -or $phase -in @('Purged',$replay)) -and
                            ($phase -ne $replay -or (Get-WorkflowValue $row 'ArtifactRemovalApproved' $false))
                    }
                    default { $false }
                }
                if (-not $allowed) {
                    $reason = "$(Get-WorkflowValue $row 'VM'): $Action is unavailable in $phase or its required evidence is missing. $(Get-CpcWorkflowHint $State @($row) -Now $Now)"
                    break
                }
                if ($Action -in @('Prepare','Capture','Import','License') -and
                    (-not (Get-WorkflowValue $row 'Attested' $false) -or -not (Test-WorkflowApproval $State $row $Action $Now))) {
                    $steps = if (Get-WorkflowValue $row 'Attested' $false) { '3 Validate prerequisites' } else { '2 Attest prerequisites, then 3 Validate prerequisites' }
                    $reason = "$(Get-WorkflowValue $row 'VM'): complete $steps for $Action. Approval is single-use, expires after 30 minutes and is not restored from journals."
                    break
                }
            }
            if (-not $reason -and $Action -eq 'Check' -and @($rowsToCheck | ForEach-Object { Get-WorkflowStage $_ } | Select-Object -Unique).Count -ne 1) {
                $reason = 'Select rows at the same next migration stage before validating; the selection spans different stages.'
            }
        }
    }
    if (-not $reason -and $null -ne $Data) {
        if ($Action -eq 'ReconcileImport') {
            $id = [guid]::Empty
            if (-not [guid]::TryParse([string](Get-WorkflowValue $Data 'ImportId'), [ref]$id) -or $id -eq [guid]::Empty) { $reason = 'Enter the known import snapshot ID (nonzero GUID) from service evidence. Do not guess an ID or resubmit import.' }
        }
        if ($Action -eq 'ReconcileLicense') {
            $time = [string](Get-WorkflowValue $Data 'AssignedUtc')
            $parsed = [datetimeoffset]::MinValue
            if ([string]::IsNullOrWhiteSpace([string](Get-WorkflowValue $Data 'Evidence')) -or ([string](Get-WorkflowValue $Data 'Evidence')).Length -gt 2000 -or $time -notmatch '(Z|[+-]\d{2}:\d{2})$' -or
                -not [datetimeoffset]::TryParse($time, [cultureinfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$parsed) -or $parsed -gt $Now) { $reason = 'Enter the reviewed Entra audit/request reference and actual assignment time as ISO 8601 with Z or an explicit offset, not a future time. Never use the current time as a substitute for audit evidence.' }
        }
    }
    if (-not $reason -and ($Action -in @('Prepare','Capture','Import','License','RepairSnapshot','Cleanup','Purge','Validate','ResetCapture','Abandon','UseImage','RevokeExport','ReconcileImport','ReconcileLicense') -or ($Action -eq 'Refresh' -and @($rowsToCheck | Where-Object { (Get-WorkflowValue $_ 'Phase') -eq 'Copying' }).Count)) -and -not (Get-WorkflowValue $State 'StatePath')) { $reason = 'An automatic recovery journal is required before changes. Restart and verify logging if it is unavailable.' }
    [pscustomobject]@{ Allowed = -not [bool]$reason; Reason = $reason }
}

function Get-CpcWorkflowHint {
    param($State, [object[]]$Rows = @(), [datetimeoffset]$Now = [datetimeoffset]::UtcNow)
    if (-not $Rows.Count) { return 'Select migration rows using their Use checkboxes. Resuming? Connect, then Resume / load journal; do not create new mappings for an existing migration.' }
    if (@($Rows | Where-Object { (Get-WorkflowValue $_ 'VmId') -in @(Get-WorkflowValue $State 'ResumePendingVmIds' @()) }).Count) { return 'Journal restored: Refresh status for checked rows first. Saved stages may be stale. Resolve any refresh errors, then follow the next step. Do not repeat completed capture/import/license operations.' }
    $stages = @($Rows | ForEach-Object { Get-WorkflowStage $_ } | Select-Object -Unique)
    $selectionHint = if ($stages.Count -gt 1) { "Selection spans different stages. Check only rows at the same next stage before validating or advancing.`n" } else { '' }
    $hints = foreach ($row in $Rows) {
        $phase = [string](Get-WorkflowValue $row 'Phase')
        $stage = Get-WorkflowStage $row
        $text = if ($stage) {
            $label = switch ($stage) { Prepare { '4 Prepare snapshot provisioning' }; Capture { '5 Stop + capture' }; Import { '6 Import to W365' }; License { '7 Start migration / assign license' } }
            $prefix = if ($phase -eq 'IdentityPrepared') { 'Step 4 is already complete. ' } elseif ($phase -in @('Capturing','CaptureFailed')) { 'Interrupted/failed capture: review status and errors before resuming or resetting. ' } else { '' }
            if (-not (Get-WorkflowValue $row 'Guest')) {
                if ((Get-WorkflowValue $row 'SourceVmUniqueId') -or (Get-WorkflowValue $row 'SnapshotId') -or $phase -in @('Staged','Imported','Capturing')) { "${prefix}Captured guest evidence is missing. Stop and review recovery; do not restart/reassess the source or create replacement mappings." }
                else { "${prefix}Run 1 Assess guest before proceeding." }
            }
            elseif (-not (Get-WorkflowValue $row 'Attested' $false)) { "${prefix}Next: 2 Attest prerequisites, then 3 Validate prerequisites for $label. Repeat Assess guest only if pre-capture Windows evidence needs refreshing." }
            elseif (-not (Test-WorkflowApproval $State $row $stage $Now)) { "${prefix}Next: 3 Validate prerequisites for $label; resolve any failed checks. Guest reassessment is not required solely because the journal was loaded." }
            else { "${prefix}Next: $label. Review and confirm its scope; live safety checks still apply." }
        } else {
            switch ($phase) {
                'Copying' { 'Copy to Azure staging is in progress. Refresh status / enable auto-refresh until Staged. Do not recapture, import to W365 or assign a license yet.' }
                'Importing' { 'W365 import is in progress. Refresh status until Imported; do not resubmit or assign a license yet.' }
                'Provisioning' { 'Cloud PC provisioning is in progress. Refresh status until Provisioned; do not repeat the license assignment.' }
                'Provisioned' { 'Next: 8 Validate cutover (final), after verifying user sign-in, applications and data.' }
                { $_ -in @('Validated','CleanupPending') } { 'Next: 9 Cleanup staging, only after retention requirements are satisfied. CleanupPending can resume the same cleanup.' }
                'ImportUnknown' { 'Do not resubmit import. Reconcile the known import ID, or investigate the server outcome before continuing.' }
                'LicenseUnknown' { 'Do not repeat license assignment. Refresh status or use Reconcile license with reviewed audit evidence.' }
                { $_ -in @('ImportSubmitting','LicenseSubmitting','PurgeSubmitting') } { 'Submission outcome is not yet confirmed. Wait/refresh; do not repeat the write. On restart, load this journal for reconciliation.' }
                'ImportFailed' { 'Review the import failure. Purge the known terminal unused import before resetting capture; do not resubmit directly.' }
                'PurgeUnknown' { 'Purge outcome is unknown. Investigate/reconcile externally; do not repeat the purge or remove staging blindly.' }
                { $_ -in @('CopyFailed','Purged') } { 'Review the failure/closed import, then use Reset failed / purged capture or Abandon. No direct import or new capture until recovery completes.' }
                'ResettingCapture' { 'Resume Reset failed / purged capture to finish the previously approved recovery.' }
                'Abandoning' { 'Resume Abandon to finish the previously approved recovery.' }
                { $_ -in @('Cleaned','Abandoned') } { 'No further migration step for this row. Use images for future reprovision only when the entire batch is complete or abandoned.' }
                default { 'Unknown stage: stop and review the journal/version. No forward migration action is enabled.' }
            }
        }
        "$(Get-WorkflowValue $row 'VM') [$phase]: $text"
    }
    return $selectionHint + (($hints | Select-Object -Unique) -join "`n")
}

function Get-CpcGuestAssessmentText($Row) {
    $stamp = Get-WorkflowValue (Get-WorkflowValue $Row 'Guest') 'CheckedUtc'
    if (-not $stamp) { return 'Not assessed' }
    if ($stamp -is [datetime] -or $stamp -is [datetimeoffset]) { return $stamp.ToString('o', [cultureinfo]::InvariantCulture) }
    return [string]$stamp
}

function Find-CpcResumeJournals {
    param([string[]]$Directories, [string]$TenantId = '', [string]$SubscriptionId = '', [string]$ExcludePlanId = '', [string[]]$VmIds = @())
    # Advisory local discovery only. Never auto-load, adopt cloud IDs or overwrite
    # files. The normal Load action still validates schema/scope and obtains locks.
    foreach ($directory in @($Directories | Where-Object { $_ } | Select-Object -Unique)) {
        foreach ($file in @(Get-ChildItem -LiteralPath $directory -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
            if ($file.Length -gt 32MB -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) { continue }
            try {
                $s = [IO.File]::ReadAllText($file.FullName) | ConvertFrom-Json -AsHashtable -ErrorAction Stop
                $rows = @(Get-WorkflowValue $s 'Rows' @())
                if ((Get-WorkflowValue $s 'SchemaVersion') -ne 1 -or -not $rows.Count -or -not (Get-WorkflowValue $s 'PlanId') -or (Get-WorkflowValue $s 'PlanId') -eq $ExcludePlanId) { continue }
                if ($TenantId -and (Get-WorkflowValue $s 'TenantId') -ne $TenantId) { continue }
                if ($SubscriptionId -and (Get-WorkflowValue $s 'SubscriptionId') -ne $SubscriptionId) { continue }
                $matching = @($rows | Where-Object { -not $VmIds.Count -or (Get-WorkflowValue $_ 'VmId') -in $VmIds })
                if (-not $matching.Count) { continue }
                $prepared = [bool](Get-WorkflowValue $s 'GroupId') -or [bool](Get-WorkflowValue $s 'UserSettingId') -or @($rows | Where-Object { (Get-WorkflowValue $_ 'Phase') -ne 'Mapped' }).Count -gt 0
                [pscustomobject]@{ Path = $file.FullName; PlanId = $s.PlanId; Prepared = $prepared; ModifiedUtc = $file.LastWriteTimeUtc; Summary = (($matching | ForEach-Object { "$(Get-WorkflowValue $_ 'VM') [$(Get-WorkflowValue $_ 'Phase')]" }) -join ', ') }
            } catch { continue }
        }
    }
}

Export-ModuleMember -Function Get-CpcActionAvailability,Get-CpcWorkflowHint,Get-CpcGuestAssessmentText,Find-CpcResumeJournals