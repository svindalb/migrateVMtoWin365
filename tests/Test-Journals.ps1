#requires -Version 7.2
param([switch]$Render)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'CpcMigration.Journals.psm1') -Force
$script:Passed = 0
function Assert-Journal([bool]$Condition, [string]$Name) { if (-not $Condition) { throw "FAIL: $Name" }; $script:Passed++ }
function Assert-Refused([scriptblock]$Action, [string]$Name) { $failed = $false; try { & $Action | Out-Null } catch { $failed = $true }; Assert-Journal $failed $Name }
$root = Join-Path ([IO.Path]::GetTempPath()) ('cpcm-journals-' + [guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($root)
$ids = [collections.generic.list[string]]::new()
function Write-Fixture([string]$Name, [string]$Phase = '') {
    $id = [guid]::NewGuid().ToString(); $ids.Add($id)
    $s = @{ SchemaVersion = 1; PlanId = $id; TenantId = 'tenant'; SubscriptionId = 'sub'; GroupId = ''; UserSettingId = ''; Rows = @() }
    if ($Phase) { $s.Rows = @(@{ VM = $Name; VmId = 'vm'; Phase = $Phase; UserPrincipalName = 'user@example.invalid' }) }
    $p = Join-Path $root "$Name.json"
    [IO.File]::WriteAllText($p, ($s | ConvertTo-Json -Depth 10))
    return $p
}
function Get-Fixture([string]$Path) { @(Get-CpcJournalInventory -Directories @($root) | Where-Object Path -EQ $Path)[0] }
try {
    $empty = Write-Fixture 'empty'; $draft = Write-Fixture 'draft' 'Mapped'; $active = Write-Fixture 'active' 'Staged'
    Assert-Journal (Get-Fixture $empty).CanArchive 'Empty startup archivable'
    Assert-Journal (Get-Fixture $draft).CanArchive 'Unprepared draft archivable'
    Assert-Journal (-not (Get-Fixture $active).CanArchive) 'Staged migration protected'
    foreach ($phase in @('IdentityPrepared','Capturing','CaptureFailed','Copying','CopyFailed','ImportSubmitting','ImportUnknown','Importing','ImportFailed','Imported','LicenseSubmitting','LicenseUnknown','Provisioning','Provisioned','Validated','CleanupPending','PurgeSubmitting','PurgeUnknown','Purged','ResettingCapture','Abandoning','Unknown')) {
        $p = Write-Fixture $phase $phase; $item = Get-Fixture $p
        Assert-Journal (-not $item.CanArchive) "$phase disabled in inventory"
        Assert-Refused { Move-CpcJournalToArchive $p $item.Fingerprint } "$phase rejected on execution"
        Assert-Journal ([IO.File]::Exists($p)) "$phase journal retained"
    }
    $prepared = Write-Fixture 'prepared-draft' 'Mapped'
    $s = Get-Content $prepared -Raw | ConvertFrom-Json -AsHashtable; $s.UserSettingId = 'setting'
    [IO.File]::WriteAllText($prepared, ($s | ConvertTo-Json -Depth 10))
    Assert-Journal (-not (Get-Fixture $prepared).CanArchive) 'Recorded setting protects mapped phase'
    $tainted = Write-Fixture 'tainted' 'Mapped'
    $s = Get-Content $tainted -Raw | ConvertFrom-Json -AsHashtable; $s.Rows[0].VhdCopyId = 'copy'
    [IO.File]::WriteAllText($tainted, ($s | ConvertTo-Json -Depth 10))
    Assert-Journal (-not (Get-Fixture $tainted).CanArchive) 'Artifact-bearing draft protected'
    $item = Get-Fixture $draft
    Assert-Refused { Move-CpcJournalToArchive $draft $item.Fingerprint -CurrentPlanId $item.PlanId } 'Current plan protected'
    $lease = [IO.File]::Open("$draft.lock", 'OpenOrCreate', 'ReadWrite', 'None')
    try { Assert-Refused { Move-CpcJournalToArchive $draft $item.Fingerprint } 'Other process path lease protected' } finally { $lease.Dispose() }
    $lockFolder = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CpcMigration/locks'; $null = [IO.Directory]::CreateDirectory($lockFolder)
    $lease = [IO.File]::Open((Join-Path $lockFolder "$($item.PlanId).lock"), 'OpenOrCreate', 'ReadWrite', 'None')
    try { Assert-Refused { Move-CpcJournalToArchive $draft $item.Fingerprint } 'Other journal copy plan lease protected' } finally { $lease.Dispose() }
    [IO.File]::AppendAllText($draft, ' ')
    Assert-Refused { Move-CpcJournalToArchive $draft $item.Fingerprint } 'Changed journal requires refresh'
    $item = Get-Fixture $draft
    [IO.File]::WriteAllText("$draft.events.jsonl.1", 'older audit'); [IO.File]::WriteAllText("$draft.events.jsonl", 'audit')
    $lease = [IO.File]::Open("$draft.events.jsonl", 'Open', 'ReadWrite', 'None')
    try { Assert-Refused { Move-CpcJournalToArchive $draft $item.Fingerprint } 'Sidecar move failure refuses archive' } finally { $lease.Dispose() }
    Assert-Journal ([IO.File]::Exists($draft) -and [IO.File]::Exists("$draft.events.jsonl.1")) 'Partial archive rollback restores audit and journal'
    $before = (Get-FileHash $draft).Hash
    $destination = Move-CpcJournalToArchive $draft $item.Fingerprint
    Assert-Journal (-not [IO.File]::Exists($draft) -and [IO.File]::Exists($destination)) 'Draft moved out of active list'
    Assert-Journal ((Get-FileHash $destination).Hash -eq $before) 'Archive preserves exact journal bytes'
    Assert-Journal ([IO.File]::Exists("$destination.events.jsonl") -and [IO.File]::Exists("$destination.events.jsonl.1")) 'Both audit sidecars preserved'
    Assert-Journal (@(Get-CpcJournalInventory @($root) | Where-Object PlanId -EQ $item.PlanId).Count -eq 0) 'Archived hidden by default'
    $archived = @(Get-CpcJournalInventory @($root) -IncludeArchived | Where-Object PlanId -EQ $item.PlanId)
    Assert-Journal ($archived.Count -eq 1 -and $archived[0].Archived -and -not $archived[0].CanArchive) 'Show archived locates recoverable original'
    foreach ($phase in @('Cleaned','Abandoned')) {
        $p = Write-Fixture "terminal-$phase" $phase
        $s = Get-Content $p -Raw | ConvertFrom-Json -AsHashtable; $s.GroupId = 'retained-group'; $s.UserSettingId = 'retained-setting'; $s.Rows[0].SnapshotId = 'historical-id'; $s.Rows[0].LicenseAssignedUtc = 'historical-time'
        [IO.File]::WriteAllText($p, ($s | ConvertTo-Json -Depth 10))
        $item = Get-Fixture $p
        Assert-Journal $item.CanArchive "$phase historical IDs retained but archive allowed"
        Assert-Journal ([IO.File]::Exists((Move-CpcJournalToArchive $p $item.Fingerprint))) "$phase archived without deleting history"
    }
    Assert-Journal (@(Get-CpcJournalInventory @($root,$root) -TenantId 'other').Count -eq 0) 'Scope filters foreign journals'
    $count = @(Get-CpcJournalInventory @($root)).Count
    Assert-Journal (@(Get-CpcJournalInventory @($root,$root)).Count -eq $count) 'Duplicate directories deduplicated'
    [IO.File]::WriteAllText((Join-Path $root 'bad.json'), 'broken'); [IO.File]::WriteAllText((Join-Path $root 'other.json'), '{}')
    Assert-Journal (@(Get-CpcJournalInventory @($root)).Count -eq $count) 'Malformed/unrelated JSON ignored'
    $unbound = Write-Fixture 'unbound'
    $s = Get-Content $unbound -Raw | ConvertFrom-Json -AsHashtable; $s.TenantId = ''; $s.SubscriptionId = ''
    [IO.File]::WriteAllText($unbound, ($s | ConvertTo-Json -Depth 10))
    Assert-Journal (@(Get-CpcJournalInventory @($root) -TenantId 'tenant' -SubscriptionId 'sub' | Where-Object Path -EQ $unbound).Count -eq 1) 'Unconnected startup visible for housekeeping'
    $mixed = Write-Fixture 'mixed' 'Cleaned'
    $s = Get-Content $mixed -Raw | ConvertFrom-Json -AsHashtable; $s.Rows += @{ VM = 'unfinished'; Phase = 'Provisioning'; UserPrincipalName = 'other@example.invalid' }
    [IO.File]::WriteAllText($mixed, ($s | ConvertTo-Json -Depth 10))
    Assert-Journal (-not (Get-Fixture $mixed).CanArchive) 'Unchecked/other unfinished batch row prevents archive'
    $unsafe = Write-Fixture 'unsafe-sidecar'
    $item = Get-Fixture $unsafe
    [IO.File]::WriteAllText("$unsafe.events.jsonl", 'sensitive-audit-fixture')
    $auditInfo = [IO.FileInfo]::new("$unsafe.events.jsonl")
    $acl = [IO.FileSystemAclExtensions]::GetAccessControl($auditInfo)
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-1-0'), 'Read', 'Allow'))
    [IO.FileSystemAclExtensions]::SetAccessControl($auditInfo, $acl)
    $beforeAcl = [IO.FileSystemAclExtensions]::GetAccessControl($auditInfo).GetSecurityDescriptorSddlForm('Access, Owner, Group')
    Assert-Refused { Move-CpcJournalToArchive $unsafe $item.Fingerprint } 'Archive rejects broad sidecar ACL'
    Assert-Journal ([IO.File]::Exists($unsafe) -and [IO.File]::ReadAllText("$unsafe.events.jsonl") -eq 'sensitive-audit-fixture') 'Rejected archive preserves original journal and audit'
    Assert-Journal ([IO.FileSystemAclExtensions]::GetAccessControl($auditInfo).GetSecurityDescriptorSddlForm('Access, Owner, Group') -eq $beforeAcl) 'Archive does not silently repair existing ACL'
    if ($Render) {
        Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
        $dialog = New-CpcJournalManager -Directories @($root) -TenantId 'tenant' -SubscriptionId 'sub' -CanResume $true
        $result = @{ Error = '' }
        $dialog.Add_ContentRendered({
            try {
                $c = $dialog.Tag.Controls
                Assert-Journal (-not $c.Resume.IsEnabled -and -not $c.Archive.IsEnabled) 'No automatic selection'
                $c.Journals.SelectedItem = @($c.Journals.Items | Where-Object Path -EQ $active)[0]
                Assert-Journal ($c.Resume.IsEnabled -and -not $c.Archive.IsEnabled) 'Rendered active plan offers Resume only'
                Assert-Journal ($c.Details.Text.Contains($active) -and $c.Details.Text.Contains('Staged')) 'Selection identifies phase and exact path'
                $c.Journals.SelectedItem = @($c.Journals.Items | Where-Object Path -EQ $empty)[0]
                Assert-Journal (-not $c.Resume.IsEnabled -and $c.Archive.IsEnabled) 'Empty startup offers archive not resume'
                $c.ShowArchived.IsChecked = $true
                Assert-Journal (@($c.Journals.Items | Where-Object Archived).Count -eq 3) 'Rendered archived toggle refreshes inventory'
                $c.Journals.SelectedItem = @($c.Journals.Items | Where-Object Path -EQ $active)[0]
                $c.Resume.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
                Assert-Journal ($dialog.Tag.Path -eq $active) 'Resume returns selected path without loading or changing cloud state'
            } catch { $result.Error = $_.Exception.ToString() } finally { $dialog.Close() }
        }.GetNewClosure())
        $null = $dialog.ShowDialog()
        if ($result.Error) { throw $result.Error }
        $offline = New-CpcJournalManager -Directories @($root) -TenantId 'tenant' -SubscriptionId 'sub' -CanResume $false
        $offline.Tag.Controls.Journals.SelectedItem = @($offline.Tag.Controls.Journals.Items | Where-Object Path -EQ $empty)[0]
        Assert-Journal (-not $offline.Tag.Controls.Resume.IsEnabled -and -not $offline.Tag.Controls.Browse.IsEnabled -and $offline.Tag.Controls.Archive.IsEnabled) 'Offline housekeeping available without allowing resume'
        $offline.Close()
    }
    Write-Host "Journal tests: $script:Passed passed; no cloud calls or real journal changes."
} finally {
    [IO.Directory]::Delete($root, $true)
    foreach ($id in $ids) { $p = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) "CpcMigration/locks/$id.lock"; if ([IO.File]::Exists($p)) { [IO.File]::Delete($p) } }
}