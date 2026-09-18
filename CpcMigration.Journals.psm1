#requires -Version 7.2
Set-StrictMode -Version 3.0

function Assert-JournalLocalPath([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    # Match the engine's same-workstation locking boundary. Do not archive
    # network paths or paths traversing junctions/symlinks.
    if ($full.StartsWith('\\')) { throw 'Archiving requires a local path, not a network share.' }
    $part = $full
    while ($part) {
        if (Test-Path -LiteralPath $part) {
            if ((Get-Item -LiteralPath $part -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Journal archive paths must not traverse links or junctions.' }
        }
        $part = [IO.Path]::GetDirectoryName($part)
    }
    return $full
}

function Get-JournalArchiveReason($State) {
    if ($State -isnot [collections.IDictionary] -or $State.SchemaVersion -ne 1 -or -not $State.Contains('Rows')) { return 'Unrecognized journal schema; manual review required.' }
    $id = [guid]::Empty
    if (-not [guid]::TryParse([string]$State.PlanId, [ref]$id)) { return 'Invalid plan identity; manual review required.' }
    $rows = @($State.Rows)
    if ($rows.Count -and @($rows | Where-Object { $_.Phase -notin @('Cleaned','Abandoned') }).Count -eq 0) { return '' }
    if ($State.GroupId -or $State.UserSettingId) { return 'Prepared plan owns cloud settings. Keep it available until every row is Cleaned or Abandoned.' }
    foreach ($row in $rows) {
        if ($row.Phase -ne 'Mapped') { return 'Migration is unfinished. Resume and complete cleanup/abandon through the migration workflow first.' }
        foreach ($field in @('SnapshotId','SnapshotName','SourceVmUniqueId','VhdBlob','VmgsBlob','VhdCopyId','VmgsCopyId','ImportId','LicenseAssignedUtc','CaptureStartedUtc','ImportStartedUtc')) {
            if ($row[$field]) { return 'Draft contains migration artifact evidence; manual recovery review required.' }
        }
    }
    return ''
}

function Get-CpcJournalInventory {
    param([string[]]$Directories, [string]$TenantId = '', [string]$SubscriptionId = '', [string]$CurrentPlanId = '', [switch]$IncludeArchived)
    $seen = [collections.generic.hashset[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($directory in @($Directories | Where-Object { $_ } | Select-Object -Unique)) {
        $folders = @([pscustomobject]@{ Path = $directory; Archived = $false })
        if ($IncludeArchived) {
            $folders += @(Get-ChildItem -LiteralPath (Join-Path $directory 'JournalArchive') -Directory -ErrorAction SilentlyContinue | Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } | ForEach-Object { [pscustomobject]@{ Path = $_.FullName; Archived = $true } })
        }
        foreach ($folder in $folders) {
            foreach ($file in @(Get-ChildItem -LiteralPath $folder.Path -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
                if (-not $seen.Add($file.FullName) -or $file.Length -gt 32MB -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) { continue }
                try {
                    $text = [IO.File]::ReadAllText($file.FullName)
                    $s = ConvertFrom-Json -InputObject $text -AsHashtable -ErrorAction Stop
                    if ($s -isnot [collections.IDictionary] -or $s.SchemaVersion -ne 1 -or -not $s.Contains('Rows') -or -not $s.PlanId) { continue }
                    # Include unconnected startup journals so they can be tidied.
                    if ($TenantId -and $s.TenantId -and $s.TenantId -ne $TenantId) { continue }
                    if ($SubscriptionId -and $s.SubscriptionId -and $s.SubscriptionId -ne $SubscriptionId) { continue }
                    $rows = @($s.Rows)
                    $reason = Get-JournalArchiveReason $s
                    $current = $s.PlanId -eq $CurrentPlanId
                    if ($current) { $reason = 'Currently open plan (including other copies); cannot archive.' }
                    if ($folder.Archived) { $reason = 'Already archived. Browse this journal to resume if needed.' }
                    $kind = if (-not $rows.Count) { 'Empty startup' } elseif (@($rows | Where-Object { $_.Phase -notin @('Cleaned','Abandoned') }).Count -eq 0) { 'Completed / abandoned' } elseif (-not $reason) { 'Unprepared draft' } else { 'KEEP — migration / recovery' }
                    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([text.encoding]::UTF8.GetBytes($text)))
                    [pscustomobject]@{
                        Path = $file.FullName; PlanId = [string]$s.PlanId; TenantId = [string]$s.TenantId; SubscriptionId = [string]$s.SubscriptionId
                        Summary = if ($rows.Count) { ($rows | ForEach-Object { "$($_.VM) [$($_.Phase)] — $($_.UserPrincipalName)" }) -join '; ' } else { '(no mappings)' }
                        Kind = $kind; ModifiedUtc = $file.LastWriteTimeUtc.ToString('u'); Archived = [bool]$folder.Archived; Current = $current
                        CanArchive = -not [bool]$reason; ArchiveReason = $reason; Fingerprint = $hash; RowCount = $rows.Count
                    }
                } catch { continue }
            }
        }
    }
}

function Move-CpcJournalToArchive {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$ExpectedFingerprint, [string]$CurrentPlanId = '')
    $full = Assert-JournalLocalPath $Path
    $pathLease = $null; $planLease = $null; $destination = ''; $moved = [collections.generic.list[object]]::new()
    try {
        # Same order and lock names as the migration engine; retained until all
        # filesystem work completes. Never remove lock files (race hazard).
        $pathLease = [IO.File]::Open("$full.lock", 'OpenOrCreate', 'ReadWrite', 'None')
        if ((Get-Item -LiteralPath $full).Length -gt 32MB) { throw 'Journal exceeds the manager size limit.' }
        $text = [IO.File]::ReadAllText($full)
        $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([text.encoding]::UTF8.GetBytes($text)))
        if ($hash -ne $ExpectedFingerprint) { throw 'Journal changed since it was listed. Refresh the journal manager and review it again.' }
        $s = ConvertFrom-Json -InputObject $text -AsHashtable
        $reason = Get-JournalArchiveReason $s
        if ($reason) { throw $reason }
        if ($s.PlanId -eq $CurrentPlanId) { throw 'Cannot archive the currently open plan.' }
        $lockFolder = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CpcMigration/locks'
        $null = [IO.Directory]::CreateDirectory($lockFolder)
        $planLease = [IO.File]::Open((Join-Path $lockFolder "$(([guid]$s.PlanId).ToString()).lock"), 'OpenOrCreate', 'ReadWrite', 'None')
        $archiveRoot = Assert-JournalLocalPath (Join-Path ([IO.Path]::GetDirectoryName($full)) 'JournalArchive')
        $destination = Join-Path $archiveRoot ([datetime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N'))
        $null = [IO.Directory]::CreateDirectory($destination)
        # Move audit evidence first and journal last. Session logs deliberately
        # stay put: Save As / Load means they can cover multiple journal paths.
        foreach ($source in @("$full.events.jsonl.1", "$full.events.jsonl", $full)) {
            if (-not [IO.File]::Exists($source)) { continue }
            $null = Assert-JournalLocalPath $source
            $target = Join-Path $destination ([IO.Path]::GetFileName($source))
            [IO.File]::Move($source, $target, $false)
            $moved.Add(@{ Source = $source; Target = $target })
        }
        return Join-Path $destination ([IO.Path]::GetFileName($full))
    } catch {
        $failure = $_.Exception.Message
        $rollbackErrors = @()
        for ($i = $moved.Count - 1; $i -ge 0; $i--) {
            try { [IO.File]::Move($moved[$i].Target, $moved[$i].Source, $false) } catch { $rollbackErrors += $_.Exception.Message }
        }
        if ($destination -and [IO.Directory]::Exists($destination) -and -not [IO.Directory]::EnumerateFileSystemEntries($destination).GetEnumerator().MoveNext()) { [IO.Directory]::Delete($destination) }
        throw "Archive refused/failed: $failure. Original files are retained or restored where possible. Archive location: $destination. $($rollbackErrors -join '; ')"
    } finally {
        if ($planLease) { $planLease.Dispose() }
        if ($pathLease) { $pathLease.Dispose() }
    }
}

function New-CpcJournalManager {
    param($Owner, [string[]]$Directories, [string]$TenantId = '', [string]$SubscriptionId = '', [string]$CurrentPlanId = '', [bool]$CanResume = $false)
    [xml]$markup = Get-Content (Join-Path $PSScriptRoot 'CpcMigration.Journals.xaml') -Raw
    $dialog = [Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($markup))
    if ($Owner) { $dialog.Owner = $Owner }
    $c = @{}
    foreach ($node in $markup.SelectNodes('//*[@Name]')) { $c[$node.Name] = $dialog.FindName($node.Name) }
    $state = @{ Path = ''; Controls = $c }
    $dialog.Tag = $state
    $update = {
        $item = $c.Journals.SelectedItem
        $c.Resume.IsEnabled = $CanResume -and $null -ne $item -and $item.RowCount -gt 0 -and $item.TenantId -eq $TenantId -and $item.SubscriptionId -eq $SubscriptionId -and -not $item.Current
        $c.Resume.ToolTip = 'Connect the matching tenant/subscription in a fresh session first. Loading always validates the journal and obtains locks; no automatic selection or adoption.'
        $c.Archive.IsEnabled = $null -ne $item -and $item.CanArchive
        if ($item) {
            $archiveNote = if ($item.CanArchive) { 'Eligible for archive, subject to exclusive path/plan locks. This is not a cloud cleanup action.' } else { $item.ArchiveReason }
            $c.Archive.ToolTip = $archiveNote
            $c.Details.Text = "$($item.Summary)`nPlan: $($item.PlanId)`nTenant: $($item.TenantId) | Subscription: $($item.SubscriptionId)`nPath: $($item.Path)`n$archiveNote"
        }
    }.GetNewClosure()
    $refresh = {
        $c.Journals.ItemsSource = @(Get-CpcJournalInventory -Directories $Directories -TenantId $TenantId -SubscriptionId $SubscriptionId -CurrentPlanId $CurrentPlanId -IncludeArchived:([bool]$c.ShowArchived.IsChecked) | Sort-Object @{ Expression = 'Current'; Descending = $true }, @{ Expression = { $_.Kind -eq 'KEEP — migration / recovery' }; Descending = $true }, @{ Expression = 'ModifiedUtc'; Descending = $true })
        & $update
    }.GetNewClosure()
    $c.Journals.Add_SelectionChanged($update)
    $c.Refresh.Add_Click($refresh)
    $c.ShowArchived.Add_Checked($refresh); $c.ShowArchived.Add_Unchecked($refresh)
    $c.Close.Add_Click({ $dialog.Close() }.GetNewClosure())
    $c.Resume.Add_Click({ if ($c.Resume.IsEnabled) { $state.Path = $c.Journals.SelectedItem.Path; $dialog.Close() } }.GetNewClosure())
    $c.Browse.IsEnabled = $CanResume
    $c.Browse.ToolTip = 'Connect in a fresh session first. Browse also supports journals saved outside the listed folders.'
    $c.Browse.Add_Click({
        $picker = [Microsoft.Win32.OpenFileDialog]::new(); $picker.Filter = 'Migration journal (*.json)|*.json'
        if ($picker.ShowDialog($dialog)) { $state.Path = $picker.FileName; $dialog.Close() }
    }.GetNewClosure())
    $c.Archive.Add_Click({
        $item = $c.Journals.SelectedItem
        if (-not $item -or -not $item.CanArchive) { return }
        $message = "Archive this journal and its adjacent audit evidence? No cloud resources will be changed or deleted. Session logs stay where they are. Archived journals remain available through Show archived.`n`n$($item.Kind): $($item.Summary)`nPlan: $($item.PlanId)`n$($item.Path)`n`nOnly proceed after reviewing your retention requirements."
        if ([Windows.MessageBox]::Show($dialog, $message, 'Confirm journal archive', 'YesNo', 'Warning', 'No') -ne 'Yes') { return }
        try {
            $archived = Move-CpcJournalToArchive -Path $item.Path -ExpectedFingerprint $item.Fingerprint -CurrentPlanId $CurrentPlanId
            & $refresh
            $c.Details.Text = "Archived successfully. No cloud resources changed. Select Show archived to find and resume it later.`n$archived"
        } catch { [Windows.MessageBox]::Show($dialog, $_.Exception.Message, 'Archive blocked', 'OK', 'Warning') | Out-Null }
    }.GetNewClosure())
    & $refresh
    return $dialog
}

Export-ModuleMember -Function Get-CpcJournalInventory,Move-CpcJournalToArchive,New-CpcJournalManager