#requires -Version 7.2
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'CpcMigration.Workflow.psm1') -Force
$script:Passed = 0
function Assert-Workflow([bool]$Condition, [string]$Name) {
    if (-not $Condition) { throw "FAIL: $Name" }
    $script:Passed++
}
$now = [datetimeoffset]::UtcNow
function New-Row([string]$Phase) {
    @{ VM = 'fixture'; VmId = 'vm-1'; Phase = $Phase; Selected = $true; Readiness = 'Ready'; Attested = $true
       Guest = @{ CheckedUtc = $now.UtcDateTime }; SnapshotId = ''; SourceVmUniqueId = ''; ImportId = 'import'; ImportStatus = 'succeeded'
       LicenseAssignedUtc = ''; ValidatedUtc = ''; ArtifactRemovalApproved = $false }
}
$s = @{ Connected = $true; Rows = @(); GroupId = ''; UserSettingId = ''; Config = @{}; Preflight = @{}; StatePath = 'offline-only'; PlanId = 'current' }
$forward = @('Guest','Attest','Check','Prepare','Capture','Import','License','Validate','Cleanup')
$matrix = @{
    Mapped = @('Guest','Attest','Check','Prepare')
    IdentityPrepared = @('Guest','Attest','Check','Capture')
    Capturing = @('Attest','Check','Capture')
    CaptureFailed = @('Guest','Attest','Check','Capture')
    Copying = @(); CopyFailed = @(); Staged = @('Attest','Check','Import')
    ImportSubmitting = @(); ImportUnknown = @(); Importing = @(); ImportFailed = @()
    Imported = @('Attest','Check','License'); LicenseSubmitting = @(); LicenseUnknown = @(); Provisioning = @()
    Provisioned = @('Validate'); Validated = @('Cleanup'); CleanupPending = @('Cleanup')
    Cleaned = @(); PurgeSubmitting = @(); PurgeUnknown = @(); Purged = @(); ResettingCapture = @(); Abandoning = @(); Abandoned = @(); Unknown = @()
}
foreach ($phase in $matrix.Keys) {
    $r = New-Row $phase; $s.Rows = @($r)
    if ($phase -in @('Provisioned','Validated','CleanupPending','Cleaned')) { $r.LicenseAssignedUtc = $now.ToString('o') }
    if ($phase -in @('Validated','CleanupPending','Cleaned')) { $r.ValidatedUtc = $now.ToString('o') }
    $stage = switch ($phase) { Mapped { 'Prepare' }; { $_ -in @('IdentityPrepared','Capturing','CaptureFailed') } { 'Capture' }; Staged { 'Import' }; Imported { 'License' }; default { '' } }
    $s.Preflight['vm-1'] = @{ Stage = $stage; ExpiresUtc = $now.AddMinutes(30).ToString('o') }
    foreach ($action in $forward) {
        $gate = Get-CpcActionAvailability $action $s @($r) -Now $now
        Assert-Workflow ($gate.Allowed -eq ($action -in $matrix[$phase])) "$phase / $action availability"
        if (-not $gate.Allowed) { Assert-Workflow (-not [string]::IsNullOrWhiteSpace($gate.Reason)) "$phase / $action disabled reason" }
    }
    Assert-Workflow (Get-CpcActionAvailability 'Refresh' $s @($r)).Allowed "Refresh retained in $phase"
    Assert-Workflow (-not [string]::IsNullOrWhiteSpace((Get-CpcWorkflowHint $s @($r)))) "$phase has next-step guidance"
}
$r = New-Row 'IdentityPrepared'; $s.Rows = @($r); $s.GroupId = 'group'; $s.UserSettingId = 'setting'; $s.Preflight = @{}
$r.Attested = $false
Assert-Workflow (Get-CpcWorkflowHint $s @($r) -Now $now).Contains('Step 4 is already complete') 'Prepared resume skips Prepare'
Assert-Workflow (Get-CpcActionAvailability 'Attest' $s @($r)).Allowed 'Loaded prepared evidence can be reattested without reassessment'
Assert-Workflow (-not (Get-CpcActionAvailability 'Check' $s @($r)).Allowed) 'Require attestation before validating'
Assert-Workflow (-not (Get-CpcActionAvailability 'Prepare' $s @($r)).Allowed) 'Prepared resume cannot repeat Prepare'
Assert-Workflow (-not (Get-CpcActionAvailability 'Map' $s @($r)).Allowed) 'Prepared mappings locked'
Assert-Workflow (-not (Get-CpcActionAvailability 'Load' $s @()).Allowed) 'Cannot replace open plan via Load'
$r.Attested = $true
foreach ($expiry in @('', 'nonsense', '2026-09-17T12:00:00', $now.AddSeconds(-1).ToString('o'), $now.ToString('o'))) {
    $s.Preflight['vm-1'] = @{ Stage = 'Capture'; ExpiresUtc = $expiry }
    Assert-Workflow (-not (Get-CpcActionAvailability 'Capture' $s @($r) -Now $now).Allowed) 'Malformed/expired approval disables Capture'
}
foreach ($expiry in @($now.AddMinutes(30), $now.AddMinutes(30).UtcDateTime, $now.AddMinutes(30).ToOffset([timespan]::FromHours(3)).ToString('o'))) {
    $s.Preflight['vm-1'] = @{ Stage = 'Capture'; ExpiresUtc = $expiry }
    Assert-Workflow (Get-CpcActionAvailability 'Capture' $s @($r) -Now $now).Allowed 'Unexpired typed/offset approval enables Capture'
}
$s.Preflight['vm-1'].Stage = 'Prepare'
Assert-Workflow (-not (Get-CpcActionAvailability 'Capture' $s @($r)).Allowed) 'Wrong-stage approval blocked'
$s.Preflight['vm-1'].Stage = 'Capture'; $r.Readiness = 'Blocked'
Assert-Workflow (-not (Get-CpcActionAvailability 'Capture' $s @($r)).Allowed) 'Failed checks block capture despite receipt'
$r.Readiness = 'Ready'; $r.SnapshotId = 'snapshot'
Assert-Workflow (-not (Get-CpcActionAvailability 'Guest' $s @($r)).Allowed) 'Captured source cannot be reassessed'
$r.SnapshotId = ''; $r.SourceVmUniqueId = 'immutable'
Assert-Workflow (-not (Get-CpcActionAvailability 'Guest' $s @($r)).Allowed) 'Frozen source cannot be reassessed'
$r.SourceVmUniqueId = ''; $r.Guest = $null
Assert-Workflow (-not (Get-CpcActionAvailability 'Attest' $s @($r)).Allowed) 'Missing guest prevents attestation'
Assert-Workflow ((Get-CpcGuestAssessmentText $r) -eq 'Not assessed') 'Missing timestamp display'
$r.Guest = @{ CheckedUtc = [datetime]::new(2026,9,17,12,44,20,[DateTimeKind]::Utc) }
Assert-Workflow ((Get-CpcGuestAssessmentText $r) -eq '2026-09-17T12:44:20.0000000Z') 'UTC guest display is invariant'
$other = New-Row 'Staged'; $other.VmId = 'vm-2'; $s.Rows = @($r,$other)
Assert-Workflow (-not (Get-CpcActionAvailability 'Check' $s $s.Rows).Allowed) 'Mixed-stage validation blocked'
Assert-Workflow (-not (Get-CpcActionAvailability 'Import' $s $s.Rows).Allowed) 'Mixed-stage import blocked'
$r.Phase = 'Mapped'; $other.Phase = 'Mapped'; $s.GroupId = ''; $s.UserSettingId = ''; $s.Config.ExistingGroupId = 'group'
$s.Preflight['vm-1'] = @{ Stage = 'Prepare'; ExpiresUtc = $now.AddMinutes(30).ToString('o') }
Assert-Workflow (-not (Get-CpcActionAvailability 'Prepare' $s @($r)).Allowed) 'Whole-group Prepare requires all rows'
Assert-Workflow (Get-CpcActionAvailability 'Map' $s @()).Allowed 'Unprepared draft mappings can be updated'
$s.Rows = @(); Assert-Workflow (Get-CpcActionAvailability 'Load' $s @()).Allowed 'Fresh connected session can resume'
foreach ($action in @($forward + @('Refresh','Map','Load','RepairSnapshot','UseImage','RevokeExport','Purge','ReconcileImport','ReconcileLicense','ResetCapture','Abandon'))) {
    Assert-Workflow (-not (Get-CpcActionAvailability $action $s @($r) -Busy $true).Allowed) "Busy blocks $action"
    $s.Connected = $false
    Assert-Workflow (-not (Get-CpcActionAvailability $action $s @($r)).Allowed) "Disconnected blocks $action"
    $s.Connected = $true
    if ($action -notin @('Map','Load')) { Assert-Workflow (-not (Get-CpcActionAvailability $action $s @()).Allowed) "No selection blocks $action" }
}
$s.Config = @{}; $s.GroupId = 'group'; $s.UserSettingId = 'setting'
foreach ($case in @(@('ImportUnknown','ReconcileImport'), @('LicenseUnknown','ReconcileLicense'), @('ImportFailed','Purge'), @('CleanupPending','Cleanup'), @('ResettingCapture','ResetCapture'), @('Abandoning','Abandon'))) {
    $r = New-Row $case[0]; $r.ValidatedUtc = $now.ToString('o'); $r.ArtifactRemovalApproved = $true; $s.Rows = @($r)
    Assert-Workflow (Get-CpcActionAvailability $case[1] $s @($r)).Allowed "Recovery remains reachable: $($case[1])"
}
$r = New-Row 'Copying'; $r.SnapshotId = 'snapshot'; $s.Rows = @($r)
Assert-Workflow (Get-CpcActionAvailability 'RevokeExport' $s @($r)).Allowed 'Explicit export revocation retained during copy'
Assert-Workflow (-not (Get-CpcActionAvailability 'RepairSnapshot' $s @($r)).Allowed) 'Batch repair blocked while copying'
$r.Phase = 'IdentityPrepared'; $other.Phase = 'Copying'; $s.Rows = @($r,$other)
Assert-Workflow (-not (Get-CpcActionAvailability 'RepairSnapshot' $s @($r)).Allowed) 'Repair checks whole batch including unchecked copying row'
$r.Phase = 'Cleaned'; $other.Phase = 'Abandoned'
Assert-Workflow (Get-CpcActionAvailability 'UseImage' $s @()).Allowed 'Whole completed batch can switch future provisioning mode'
$other.Phase = 'Provisioning'
Assert-Workflow (-not (Get-CpcActionAvailability 'UseImage' $s @($r)).Allowed) 'Unchecked unfinished row blocks image switch'

$r = New-Row 'Abandoned'; $r.ImportId = ''; $r.AttemptHistory = @(@{ SnapshotName = 'never-created'; SnapshotId = ''; VhdBlob = ''; ImportId = '' }); $s.Rows = @($r); $s.GroupId = ''; $s.UserSettingId = ''
$gate = Get-CpcActionAvailability 'UseImage' $s @($r)
Assert-Workflow (-not $gate.Allowed -and $gate.Reason -match 'never created or owned') 'Unowned setting explains disabled Use images'
$gate = Get-CpcActionAvailability 'ResetCapture' $s @($r)
Assert-Workflow $gate.Allowed 'Artifact-free unprepared abandoned draft can be reset'
Assert-Workflow ((Get-CpcWorkflowHint $s @($r)) -match 'Reset it to Mapped') 'Artifact-free abandoned draft gives the guarded reset next step'
$r.AttemptHistory[0].ImportId = 'historical-import'
$gate = Get-CpcActionAvailability 'ResetCapture' $s @($r)
Assert-Workflow (-not $gate.Allowed -and $gate.Reason -match 'historical artifact evidence') 'Abandoned attempt with historical artifacts remains terminal'

$r = New-Row 'Staged'; $s.Rows = @($r); $s.ResumePendingVmIds = @($r.VmId)
foreach ($action in @('Guest','Attest','Check','Import','Purge','ResetCapture','Abandon','RepairSnapshot')) {
    $gate = Get-CpcActionAvailability $action $s @($r)
    Assert-Workflow (-not $gate.Allowed -and $gate.Reason -match 'Refresh status') "Resume refresh required for $action"
}
Assert-Workflow (Get-CpcActionAvailability 'Refresh' $s @($r)).Allowed 'Resume allows refresh itself'
Assert-Workflow ((Get-CpcWorkflowHint $s @($r)) -match 'Refresh status') 'Resume hint prioritizes refresh'
$s.ResumePendingVmIds = @()
$gate = Get-CpcActionAvailability 'Import' $s @($r)
Assert-Workflow ($gate.Reason -match '3 Validate' -and $gate.Reason -notmatch '2 Attest') 'Existing attestation does not prompt repeat step 2'
$r.SnapshotId = 'snapshot'
Assert-Workflow (-not (Get-CpcActionAvailability 'RevokeExport' $s @($r)).Allowed) 'Staged export is already revoked; do not offer needless revoke'
$r.Guest = $null
Assert-Workflow ((Get-CpcWorkflowHint $s @($r)) -match 'Captured guest evidence is missing' -and (Get-CpcWorkflowHint $s @($r)) -notmatch 'Run 1 Assess') 'Missing frozen evidence routes recovery not reassessment'
$r.Phase = 'ImportUnknown'
foreach ($id in @('', 'bogus', [guid]::Empty.ToString())) { Assert-Workflow (-not (Get-CpcActionAvailability 'ReconcileImport' $s @($r) -Data @{ ImportId = $id }).Allowed) 'Invalid import ID disables reconciliation' }
Assert-Workflow (Get-CpcActionAvailability 'ReconcileImport' $s @($r) -Data @{ ImportId = [guid]::NewGuid().ToString() }).Allowed 'Known valid ID enables reviewed import reconciliation'
$r.Phase = 'LicenseUnknown'
foreach ($data in @(@{}, @{ Evidence = 'audit'; AssignedUtc = 'yesterday' }, @{ Evidence = ''; AssignedUtc = $now.ToString('o') }, @{ Evidence = 'audit'; AssignedUtc = $now.AddHours(1).ToString('o') })) {
    Assert-Workflow (-not (Get-CpcActionAvailability 'ReconcileLicense' $s @($r) -Data $data -Now $now).Allowed) 'Missing/invalid license evidence blocks submit'
}
Assert-Workflow (Get-CpcActionAvailability 'ReconcileLicense' $s @($r) -Data @{ Evidence = 'reviewed audit'; AssignedUtc = $now.AddMinutes(-10).ToString('o') } -Now $now).Allowed 'Valid license audit inputs enable explicit recovery'
$s.StatePath = ''
Assert-Workflow (-not (Get-CpcActionAvailability 'ReconcileLicense' $s @($r)).Allowed) 'Reconciliation requires durable journal'
$r.Phase = 'Copying'
Assert-Workflow (-not (Get-CpcActionAvailability 'Refresh' $s @($r)).Allowed) 'Copy refresh may revoke export and requires journal'
$s.StatePath = 'offline-only'

$temp = Join-Path ([IO.Path]::GetTempPath()) ('cpcm-workflow-' + [guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($temp)
try {
    $original = @{ SchemaVersion = 1; PlanId = 'original'; TenantId = 'tenant'; SubscriptionId = 'sub'; GroupId = 'group'; UserSettingId = 'setting'; Rows = @(@{ VmId = 'vm-1'; VM = 'source'; Phase = 'IdentityPrepared' }) }
    $draft = @{ SchemaVersion = 1; PlanId = 'draft'; TenantId = 'tenant'; SubscriptionId = 'sub'; Rows = @(@{ VmId = 'vm-1'; VM = 'source'; Phase = 'Mapped' }) }
    $completed = @{ SchemaVersion = 1; PlanId = 'completed'; TenantId = 'tenant'; SubscriptionId = 'sub'; GroupId = 'group'; UserSettingId = 'setting'; Rows = @(@{ VmId = 'vm-1'; VM = 'source'; Phase = 'Cleaned' }) }
    $mixed = @{ SchemaVersion = 1; PlanId = 'mixed'; TenantId = 'tenant'; SubscriptionId = 'sub'; GroupId = 'group'; UserSettingId = 'setting'; Rows = @(@{ VmId = 'vm-1'; VM = 'source'; Phase = 'Cleaned' }, @{ VmId = 'vm-2'; VM = 'other'; Phase = 'Provisioning' }) }
    $foreign = $original.Clone(); $foreign.TenantId = 'other'; $foreign.PlanId = 'foreign'
    foreach ($item in @($original,$draft,$completed,$mixed,$foreign)) { [IO.File]::WriteAllText((Join-Path $temp ($item.PlanId + '.json')), ($item | ConvertTo-Json -Depth 6)) }
    [IO.File]::WriteAllText((Join-Path $temp 'malformed.json'), 'not json')
    [IO.File]::WriteAllText((Join-Path $temp 'unrelated.json'), '{"hello":"world"}')
    $before = (Get-FileHash (Join-Path $temp 'original.json')).Hash
    $found = @(Find-CpcResumeJournals @($temp,$temp) -TenantId 'tenant' -SubscriptionId 'sub')
    Assert-Workflow ($found.Count -eq 4) 'Resume finder filters scope, malformed/unrelated files and duplicate folders'
    $found = @(Find-CpcResumeJournals @($temp) -TenantId 'tenant' -SubscriptionId 'sub' -ExcludePlanId 'draft' -VmIds @('vm-1'))
    Assert-Workflow ($found.Count -eq 3 -and @($found | Where-Object { $_.PlanId -eq 'original' -and $_.Prepared -and -not $_.NewCycleEligible -and $_.Summary -match 'IdentityPrepared' }).Count -eq 1) 'Overlap identifies unfinished prepared journal'
    Assert-Workflow (@($found | Where-Object { $_.PlanId -eq 'completed' -and $_.NewCycleEligible }).Count -eq 1) 'All-terminal prior plan permits explicit new cycle review'
    Assert-Workflow (@($found | Where-Object { $_.PlanId -eq 'mixed' -and -not $_.NewCycleEligible }).Count -eq 1) 'Unmatched unfinished batch row prevents new cycle approval'
    Assert-Workflow (@(Find-CpcResumeJournals @($temp) -TenantId 'tenant' -VmIds @('vm-other')).Count -eq 0) 'Unrelated VM mapping not blocked'
    Assert-Workflow (@(Find-CpcResumeJournals @($temp) -SubscriptionId 'other').Count -eq 0) 'Other subscription omitted'
    Assert-Workflow ($before -eq (Get-FileHash (Join-Path $temp 'original.json')).Hash) 'Resume discovery never modifies original journal'
} finally { [IO.Directory]::Delete($temp,$true) }
$s.PersistenceFault = 'offline fault'; $s.Connected = $false
Assert-Workflow (Get-CpcActionAvailability 'RestorePersistence' $s @()).Allowed 'Persistence recovery needs no connection or row selection'
Assert-Workflow (-not (Get-CpcActionAvailability 'RestorePersistence' $s @() -Busy $true).Allowed) 'Cannot restore during active operation'
foreach ($phase in @('Copying','Provisioning','Validated')) {
    $r = New-Row $phase; $s.Rows = @($r)
    foreach ($action in @('Refresh','RevokeExport','Cleanup','Guest','UseImage')) {
        Assert-Workflow (-not (Get-CpcActionAvailability $action $s @($r)).Allowed) "Persistence fault blocks $phase / $action"
    }
}
$s.PersistenceFault = ''
Assert-Workflow (-not (Get-CpcActionAvailability 'RestorePersistence' $s @()).Allowed) 'Healthy session cannot request recovery'
Write-Host "Workflow tests: $script:Passed passed; no cloud calls."