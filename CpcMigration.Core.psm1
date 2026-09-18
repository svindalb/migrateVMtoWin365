#requires -Version 7.2
Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$script:GraphRoot = 'https://graph.microsoft.com'
$script:Endpoint = '/beta/deviceManagement/virtualEndpoint'
$script:Modules = @('Az.Accounts', 'Az.Resources', 'Az.Compute', 'Az.Storage', 'Microsoft.Graph.Authentication')
$script:S = $null
$script:Signals = $null
$script:RequiredTenantId = ''
$script:JournalLease = $null
$script:PlanLease = $null
$script:LogStream = $null
$script:LogPath = ''
$script:LogLocationChanged = $false
$ExecutionContext.SessionState.Module.OnRemove = {
    if ($script:JournalLease) { $script:JournalLease.Stream.Dispose() }
    if ($script:PlanLease) { $script:PlanLease.Stream.Dispose() }
    if ($script:LogStream) { $script:LogStream.Dispose() }
}

function Get-Value($Object, [string]$Name, $Default = $null) {
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
    } elseif ($Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return $Default
}

function Protect-CpcText([string]$Text) {
    # Redact complete URL query strings, including escaped JSON forms, not just sig=.
    # Preserve backslashes that escape closing quotes in nested JSON strings.
    $Text = $Text -replace '(?i)(https?://[^\s"<>?\\]+)\?[^\s"<>\\]*', '$1?[REDACTED]'
    $Text = $Text -replace '(?i)(Bearer\s+)[A-Za-z0-9._~+/-]+=*', '$1[REDACTED]'
    $Text = $Text -replace '(?i)("(?:access_token|refresh_token|client_secret|password)"\s*:\s*")[^"]*"', '$1[REDACTED]"'
    return ($Text -replace '(?i)((?:sig|access_token|refresh_token|client_secret)=)[^&\s"<>]+', '$1[REDACTED]')
}

function Write-CpcSessionRecord([string]$Kind, $Details) {
    if (-not $script:LogStream) { return } # Headless/offline helpers can run without a UI session.
    $line = Protect-CpcText (@{ Utc = [datetime]::UtcNow.ToString('o'); Kind = $Kind; PlanId = $script:S.PlanId; Details = $Details } | ConvertTo-Json -Depth 40 -Compress)
    $bytes = [text.encoding]::UTF8.GetBytes($line + "`n")
    $script:LogStream.Write($bytes, 0, $bytes.Length)
    $script:LogStream.Flush($true)
}

function Get-CpcDocumentsDirectory {
    $documents = [Environment]::GetFolderPath('MyDocuments')
    if ([string]::IsNullOrWhiteSpace($documents)) { throw 'Windows could not resolve the executing user Documents folder.' }
    return $documents
}

function Initialize-CpcLogging([string]$PreferredDirectory = $PSScriptRoot) {
    if ($script:LogStream) { return }
    if ($script:S.StatePath -or $script:S.Rows.Count) { throw 'Automatic logging must initialize before loading or mapping a plan.' }
    $original = $script:S
    $primaryError = ''
    for ($attempt = 0; $attempt -lt 2; $attempt++) {
        $stream = $null
        try {
            $folder = if ($attempt -eq 0) { [IO.Path]::GetFullPath($PreferredDirectory) } else { Join-Path (Get-CpcDocumentsDirectory) 'MigrateLog' }
            $null = [IO.Directory]::CreateDirectory($folder)
            $name = 'migration-' + [datetime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N')
            $logPath = Join-Path $folder ($name + '.log')
            $candidate = $original.Clone()
            $candidate.StatePath = Join-Path $folder ($name + '.json')
            # Real create/write/flush checks as the executing user, not an ACL guess.
            # Unique session files never overwrite another run's log/journal.
            $stream = [IO.File]::Open($logPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
            $header = [text.encoding]::UTF8.GetBytes("Windows 365 migration session log (UTC; redacted). Contains sensitive tenant/user/resource identifiers.`n")
            $stream.Write($header, 0, $header.Length); $stream.Flush($true)
            $auditProbe = [IO.File]::Open(($candidate.StatePath + '.events.jsonl'), [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
            try { $auditProbe.Flush($true) } finally { $auditProbe.Dispose() }
            Save-CpcState -State $candidate
            $script:S = $candidate
            $script:LogStream = $stream; $stream = $null
            $script:LogPath = $logPath; $script:LogLocationChanged = $attempt -eq 1
            break
        } catch {
            if ($attempt -eq 0) { $primaryError = Protect-CpcText $_.Exception.Message }
            else { throw ('Cannot initialize log/journal in the script folder or Documents\MigrateLog. No migration started. Script-folder error: ' + $primaryError + '; fallback error: ' + (Protect-CpcText $_.Exception.Message)) }
        } finally { if ($stream) { $stream.Dispose() } }
    }
    if ($script:LogLocationChanged) { Write-CpcLog "Log location changed: script-folder logging was unavailable ($primaryError). Using $script:LogPath" }
    Write-CpcLog "Automatic session log: $script:LogPath"
    Write-CpcLog "Automatic recovery journal: $($script:S.StatePath). Save is optional; all operation results are logged automatically."
}

function Write-CpcLog([string]$Text) {
    $entry = '{0:yyyy-MM-dd HH:mm:ss}Z  {1}' -f [datetime]::UtcNow, (Protect-CpcText $Text)
    Write-CpcSessionRecord 'Activity' $entry
    $script:S.Logs.Add($entry)
    if ($script:S.Logs.Count -gt 2000) { $script:S.Logs.RemoveAt(0) }
    Write-CpcAudit 'Log' @{ Message = $entry }
    if ($script:Signals) { $script:Signals.Queue.Enqueue($entry) }
}

function Open-CpcJournalLease([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    if ($script:JournalLease -and $script:JournalLease.Path -eq $full) { return $script:JournalLease }
    $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($full))
    try { $stream = [IO.File]::Open("$full.lock", [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
    catch { throw 'Journal is locked by another application or cannot be locked. Close the other instance or choose an accessible journal path.' }
    return @{ Path = $full; Stream = $stream }
}

function Open-CpcPlanLease($State) {
    $id = Assert-CpcGuid $State.PlanId 'Plan ID'
    if ($script:PlanLease -and $script:PlanLease.Id -eq $id) { return $script:PlanLease }
    # A path-only lock cannot protect Save As / copied journals for the same plan.
    # Serialize the plan identity across this Windows user's local app instances.
    $folder = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CpcMigration/locks'
    $null = [IO.Directory]::CreateDirectory($folder)
    try { $stream = [IO.File]::Open((Join-Path $folder "$id.lock"), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
    catch { throw 'This plan identity is already open in another instance (including another journal copy), or its local lock is inaccessible.' }
    return @{ Id = $id; Stream = $stream }
}

function Write-CpcAudit([string]$EventName, $Details) {
    if ($EventName -ne 'Log') { Write-CpcSessionRecord $EventName $Details }
    if (-not $script:S -or -not $script:S.StatePath) { return }
    if (-not $script:JournalLease -or $script:JournalLease.Path -ne [IO.Path]::GetFullPath($script:S.StatePath)) {
        throw 'Journal is not exclusively locked; save/load the plan before continuing.'
    }
    $path = $script:S.StatePath + '.events.jsonl'
    # Bounded durable evidence, no request bodies, credentials or SAS queries.
    if ([IO.File]::Exists($path) -and ([IO.FileInfo]$path).Length -ge 5MB) { [IO.File]::Move($path, "$path.1", $true) }
    $line = Protect-CpcText (@{ Utc = [datetime]::UtcNow.ToString('o'); PlanId = $script:S.PlanId; Event = $EventName; Details = $Details } | ConvertTo-Json -Depth 10 -Compress)
    $stream = [IO.File]::Open($path, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    try { $bytes = [text.encoding]::UTF8.GetBytes($line + "`n"); $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) }
    finally { $stream.Dispose() }
}

function Assert-CpcContinue {
    if ($script:Signals -and $script:Signals.Cancel) {
        throw 'Stopped between steps. In-flight Azure/Graph operations are NOT rolled back. Refresh status before continuing.'
    }
}

function Assert-CpcGuid([string]$Value, [string]$Label) {
    $guid = [guid]::Empty
    if (-not [guid]::TryParse($Value, [ref]$guid)) { throw "$Label must be a GUID." }
    return $guid.ToString()
}

function Initialize-CpcState {
    $script:RefreshSucceededIds = [collections.generic.hashset[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $script:S = @{
        SchemaVersion = 1; PlanId = [guid]::NewGuid().ToString(); TenantId = ''; SubscriptionId = ''
        Rows = [System.Collections.Generic.List[object]]::new()
        Checks = [System.Collections.Generic.List[object]]::new()
        Logs = [System.Collections.Generic.List[string]]::new()
        GraphResults = [System.Collections.Generic.List[object]]::new()
        Catalog = @{ Subscriptions = @(); ResourceGroups = @(); Vms = @(); Policies = @(); Skus = @(); Storage = @(); Groups = @() }
        Config = @{ PolicyId = ''; SkuId = ''; TargetDiskGiB = 0; StorageId = ''; Container = ''; SnapshotResourceGroup = '' }
        GroupId = ''; UserSettingId = ''; StatePath = ''; Connected = $false
        Preflight = @{} # Session-only, single-use approvals; never restored from a journal.
    }
}

function Save-CpcState($State = $script:S, $Lease = $null) {
    if (-not $State.StatePath) { return }
    if (-not $Lease) { $Lease = Open-CpcJournalLease $State.StatePath }
    $committed = $false
    $planLease = $null
    try {
    $planLease = Open-CpcPlanLease $State
    # Explicit whitelist: no tokens, storage contexts, SAS URLs or request bodies persisted.
    $persist = [ordered]@{}
    foreach ($key in @('SchemaVersion','PlanId','TenantId','SubscriptionId','Config','GroupId','UserSettingId','Rows','Checks')) {
        $persist[$key] = $State[$key]
    }
    $json = Protect-CpcText ($persist | ConvertTo-Json -Depth 30)
    $path = $Lease.Path
    if ([IO.File]::Exists($path)) {
        $prior = [IO.File]::ReadAllText($path) | ConvertFrom-Json -AsHashtable
        if ((Get-Value $prior 'PlanId') -ne $State.PlanId) { throw 'Refusing to overwrite a different migration plan. Choose a new journal path.' }
    }
    $stream = [IO.File]::Open("$path.tmp", [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $bytes = [text.encoding]::UTF8.GetBytes($json); $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) }
    finally { $stream.Dispose() }
    [IO.File]::Move("$path.tmp", $path, $true)
    if ($script:JournalLease -and $script:JournalLease -ne $Lease) { $script:JournalLease.Stream.Dispose() }
    $script:JournalLease = $Lease
    if ($script:PlanLease -and $script:PlanLease -ne $planLease) { $script:PlanLease.Stream.Dispose() }
    $script:PlanLease = $planLease
    $committed = $true
    } finally {
        if (-not $committed -and $Lease -ne $script:JournalLease) { $Lease.Stream.Dispose() }
        if (-not $committed -and $planLease -and $planLease -ne $script:PlanLease) { $planLease.Stream.Dispose() }
    }
}

function Assert-CpcContext {
    if (-not $script:S.Connected) { throw 'Connect to Azure and Microsoft Graph first.' }
    Assert-CpcTenantScope $script:S.TenantId
    $az = Get-AzContext
    $mg = Get-MgContext
    if ([string]$az.Tenant.Id -ne $script:S.TenantId -or [string]$mg.TenantId -ne $script:S.TenantId) {
        throw 'Tenant mismatch. Cross-tenant migration is not supported.'
    }
    if ([string]$az.Subscription.Id -ne $script:S.SubscriptionId) { throw 'Azure subscription context changed. Reconnect to the plan subscription.' }
    if ([string]$az.Environment.Name -ne 'AzureCloud' -or [string]$mg.Environment -ne 'Global') {
        throw 'This implementation supports Commercial cloud only.'
    }
}

function Assert-CpcTenantScope([string]$TenantId) {
    if ($script:RequiredTenantId -and $TenantId -ne $script:RequiredTenantId) { throw "This session is locked to startup tenant $script:RequiredTenantId. Open a new instance for a different organization." }
}

function Get-CpcGraphFailureDetail([System.Management.Automation.ErrorRecord]$Record) {
    # Invoke-MgGraphRequest often puts the service JSON in ErrorDetails rather
    # than Exception.Message. Never inspect request headers/body (may hold SAS).
    $detail = [string](Get-Value (Get-Value $Record 'ErrorDetails') 'Message' '')
    if ([string]::IsNullOrWhiteSpace($detail)) {
        $detail = [string](Get-Value $Record.Exception 'ResponseContent' '')
    }
    if ([string]::IsNullOrWhiteSpace($detail)) {
        $response = Get-Value $Record.Exception 'Response'
        $content = Get-Value $response 'Content'
        if ($content -is [System.Net.Http.HttpContent]) {
            try { $detail = $content.ReadAsStringAsync().GetAwaiter().GetResult() }
            catch { $detail = '' } # Disposed/unavailable content must not mask the original error.
        }
    }
    $detail = Protect-CpcText $detail
    if ($detail.Length -gt 12000) { $detail = $detail.Substring(0, 12000) + ' [truncated]' }
    return $detail
}

function Invoke-CpcGraph {
    param([ValidateSet('GET','POST','PATCH','DELETE')][string]$Method = 'GET', [string]$Path, $Body)
    $uri = if ($Path.StartsWith('https://')) { $Path } else { "$script:GraphRoot$Path" }
    $parsed = [uri]$uri
    if ($parsed.Scheme -ne 'https' -or $parsed.Host -ne 'graph.microsoft.com' -or $parsed.UserInfo) {
        throw 'Rejected Graph URL outside the trusted Microsoft Graph host.'
    }
    $requestId = [guid]::NewGuid().ToString()
    $params = @{
        Method = $Method; Uri = $uri; OutputType = 'Hashtable'; ErrorAction = 'Stop'
        Headers = @{ 'client-request-id' = $requestId; 'return-client-request-id' = 'true'; Prefer = 'include-unknown-enum-members' }
    }
    # Cast membership queries use Graph's advanced directory index. Apply on
    # every page, including nextLink requests; recent changes may need propagation.
    if ($Method -eq 'GET' -and $parsed.AbsolutePath -match '/(?:memberOf|transitiveMemberOf)/microsoft\.graph\.group$') {
        $params.Headers.ConsistencyLevel = 'eventual'
        if ($parsed.Query -notmatch '(?i)(?:[?&])(?:\$|%24)count=true(?:&|$)') {
            if ($parsed.Query -match '(?i)(?:[?&])(?:\$|%24)count=') { throw 'Membership queries require $count=true.' }
            $params.Uri += $(if ($parsed.Query) { '&' } else { '?' }) + '$count=true'
        }
    }
    if ($null -ne $Body) { $params.Body = $Body | ConvertTo-Json -Depth 25 -Compress; $params.ContentType = 'application/json' }
    # No automatic mutation retries: an HTTP timeout can occur AFTER server acceptance.
    for ($attempt = 0; $attempt -lt 4; $attempt++) {
        Write-CpcAudit 'GraphRequest' @{ Method = $Method; Path = (Protect-CpcText $Path); ClientRequestId = $requestId; Attempt = $attempt }
        try {
            $result = Invoke-MgGraphRequest @params
            Write-CpcSessionRecord 'GraphResult' @{ Method = $Method; Path = $Path; ClientRequestId = $requestId; Result = $result }
            $safe = Protect-CpcText ($result | ConvertTo-Json -Depth 25)
            $script:S.GraphResults.Add([pscustomobject]@{ Time = [datetime]::UtcNow; Method = $Method; Path = (Protect-CpcText $Path); ClientRequestId = $requestId; Result = $safe })
            if ($script:S.GraphResults.Count -gt 250) { $script:S.GraphResults.RemoveAt(0) }
            Write-CpcAudit 'GraphResponse' @{ Method = $Method; Path = (Protect-CpcText $Path); ClientRequestId = $requestId; Outcome = 'Returned' }
            return $result
        } catch {
            $failure = $_
            $status = Get-Value $_.Exception 'ResponseStatusCode' (Get-Value $_.Exception 'StatusCode' 0)
            $response = Get-Value $_.Exception 'Response'
            if ($response) { $status = Get-Value $response 'StatusCode' $status }
            $detail = Get-CpcGraphFailureDetail $failure
            $message = Protect-CpcText $failure.Exception.Message
            if ($detail) { $message += " Service response: $detail" }
            $evidence = @{ Method = $Method; Path = (Protect-CpcText $Path); ClientRequestId = $requestId; StatusCode = [int]$status; Error = $message }
            Write-CpcAudit 'GraphFailure' $evidence
            $script:S.GraphResults.Add([pscustomobject]@{ Time = [datetime]::UtcNow; Method = $Method; Path = (Protect-CpcText $Path); ClientRequestId = $requestId; Result = ($evidence | ConvertTo-Json -Depth 5) })
            if ($script:S.GraphResults.Count -gt 250) { $script:S.GraphResults.RemoveAt(0) }
            if ($Method -eq 'GET' -and [int]$status -in @(429,503,504) -and $attempt -lt 3) {
                $delay = [math]::Pow(2, $attempt + 1)
                $headers = Get-Value $response 'Headers'
                $retryAfter = Get-Value $headers 'RetryAfter'
                $delta = Get-Value $retryAfter 'Delta'
                if ($delta) { $delay = [math]::Max($delay, $delta.TotalSeconds) }
                if ($delay -gt 120) { throw 'Graph requested a long retry delay. Retry this read later.' }
                Write-CpcLog "Graph read throttled; retry in $delay seconds. Request $requestId."
                Start-Sleep -Seconds $delay
                Assert-CpcContinue
                continue
            }
            throw ("Graph $Method failed. Client request $requestId. " + $message)
        }
    }
}

function New-CpcUserSettingSourceBody($Setting, [ValidateSet('image','snapshot')][string]$Source) {
    # The service rejects a provisioningSourceType-only PATCH with
    # requiredFieldsNotProvided. Carry forward the live writable settings;
    # never send the GET envelope, assignments, timestamps or deprecated fields.
    $name = Get-Value $Setting 'displayName'
    $admin = Get-Value $Setting 'localAdminEnabled'
    $reset = Get-Value $Setting 'resetEnabled'
    if ($name -isnot [string] -or [string]::IsNullOrWhiteSpace($name) -or
        $admin -isnot [bool] -or $reset -isnot [bool]) {
        throw 'User setting is missing displayName/localAdminEnabled/resetEnabled. Refusing to guess existing settings; no PATCH submitted.'
    }
    $body = @{
        '@odata.type' = '#microsoft.graph.cloudPcUserSetting'
        displayName = $name; localAdminEnabled = $admin; resetEnabled = $reset
        provisioningSourceType = $Source
    }
    foreach ($field in @('restorePointSetting','crossRegionDisasterRecoverySetting')) {
        $value = Get-Value $Setting $field
        if ($null -ne $value) {
            $body[$field] = $value | ConvertTo-Json -Depth 20 -Compress | ConvertFrom-Json -AsHashtable
        }
    }
    return $body
}

function Get-CpcGraphCollection([string]$Path) {
    $seen = [System.Collections.Generic.HashSet[string]]::new()
    do {
        if (-not $seen.Add($Path)) { throw 'Repeated Graph pagination link.' }
        $result = Invoke-CpcGraph -Path $Path
        foreach ($item in @(Get-Value $result 'value' @())) { $item }
        $Path = Get-Value $result '@odata.nextLink' ''
        Assert-CpcContinue
    } while ($Path)
}

function Get-CpcImportResult([string]$SnapshotId) {
    $id = Assert-CpcGuid $SnapshotId 'Imported snapshot ID'
    Invoke-CpcGraph -Path "$script:Endpoint/snapshots/retrieveSnapshotImportResult(snapshotId='$id')"
}

function Test-CpcImportUserIdentity($Result, $Row) {
    # Observed Graph beta responses put either UPN or the assigned user's object
    # ID in assignedUserPrincipalName. Match only this journal's resolved user;
    # do not infer identity from filename, status, or an arbitrary GUID.
    $returned = [string](Get-Value $Result 'assignedUserPrincipalName' '')
    if ([string]::IsNullOrWhiteSpace($returned)) { return $false }
    $upn = [string](Get-Value $Row 'UserPrincipalName' '')
    if ($upn -and $returned -eq $upn) { return $true }
    $actual = [guid]::Empty; $expected = [guid]::Empty
    return [guid]::TryParse($returned, [ref]$actual) -and
        [guid]::TryParse([string](Get-Value $Row 'UserId' ''), [ref]$expected) -and
        $expected -ne [guid]::Empty -and $actual -eq $expected
}

function New-CpcImportBody([string]$UserId, [string]$VhdSas, [string]$VmgsSas) {
    $id = Assert-CpcGuid $UserId 'User ID'
    $files = @()
    foreach ($entry in @(@{ Type = 'dataFile'; Url = $VhdSas }, @{ Type = 'virtualMachineGuestState'; Url = $VmgsSas })) {
        if (-not $entry.Url) { continue }
        $uri = [uri]$entry.Url
        if ($uri.Scheme -ne 'https' -or $uri.Host -notmatch '\.blob\.core\.windows\.net$' -or $uri.Query -notmatch '(^|[?&])sig=') {
            throw 'Import requires an HTTPS SAS URL on Commercial Azure Blob Storage.'
        }
        $files += @{ sourceType = 'sasUrl'; fileType = $entry.Type; sasUrl = $entry.Url }
    }
    if (-not $VhdSas) { throw 'An OS VHD SAS is required.' }
    return @{ assignedUserId = $id; sourceFiles = $files }
}

function Test-CpcPermission($Permissions, [string]$Action, [switch]$DataAction) {
    $allowKey = if ($DataAction) { 'dataActions' } else { 'actions' }
    $denyKey = if ($DataAction) { 'notDataActions' } else { 'notActions' }
    foreach ($entry in @($Permissions)) {
        $allowed = @(@(Get-Value $entry $allowKey @()) | Where-Object { $Action -like $_ }).Count -gt 0
        $excluded = @(@(Get-Value $entry $denyKey @()) | Where-Object { $Action -like $_ }).Count -gt 0
        if ($allowed -and -not $excluded) { return $true }
    }
    return $false
}

function Get-CpcPermissions([string]$Scope) {
    $path = "$Scope/providers/Microsoft.Authorization/permissions?api-version=2022-04-01"
    do {
        $r = Invoke-AzRestMethod -Path $path -Method GET
        if ($r.StatusCode -ge 300) { throw "Unable to assess permissions on $Scope ($($r.StatusCode))." }
        $body = $r.Content | ConvertFrom-Json -AsHashtable
        foreach ($p in $body.value) { $p }
        $next = Get-Value $body 'nextLink' ''
        if ($next) {
            $u = [uri]$next
            if ($u.Host -ne 'management.azure.com') { throw 'Untrusted ARM pagination URL.' }
            $path = $u.PathAndQuery
        } else { $path = '' }
    } while ($path)
}

function Add-CpcCheck([string]$Vm, [string]$Check, [string]$Status, [string]$Detail) {
    $script:S.Checks.Add([pscustomobject]@{ VM = $Vm; Check = $Check; Status = $Status; Detail = (Protect-CpcText $Detail); CheckedUtc = [datetime]::UtcNow.ToString('o') })
}

function Assert-CpcConfig($c = $script:S.Config) {
    $null = Assert-CpcGuid $c.PolicyId 'Policy ID'
    $null = Assert-CpcGuid $c.SkuId 'License SKU ID'
    if ([int]$c.TargetDiskGiB -lt 64 -or [int]$c.TargetDiskGiB -gt 4096) { throw 'Select a license with a supported disk capacity (GiB), 64–4096.' }
    if ($c.StorageId -notmatch '^/subscriptions/([^/]+)/resourceGroups/([^/]+)/providers/Microsoft.Storage/storageAccounts/([a-z0-9]{3,24})$') { throw 'Select a valid Azure storage account.' }
    if ($Matches[1] -ne $script:S.SubscriptionId) { throw 'Staging account must be in the selected subscription.' }
    if ($c.Container -notmatch '^[a-z0-9](?:[a-z0-9-]{1,61})[a-z0-9]$' -or $c.Container.Contains('--')) { throw 'Enter an existing private blob container name (3–63 lowercase characters).' }
    if ($c.SnapshotResourceGroup -notmatch '^[\w.()-]{1,90}$' -or $c.SnapshotResourceGroup.EndsWith('.')) { throw 'Enter an existing snapshot resource group name.' }
}

function Get-CpcStorage {
    Assert-CpcConfig
    $parts = $script:S.Config.StorageId.Split('/')
    $account = Get-AzStorageAccount -ResourceGroupName $parts[4] -Name $parts[8]
    # Use Entra OAuth and user delegation SAS; never retrieve account keys.
    $ctx = New-AzStorageContext -StorageAccountName $account.StorageAccountName -UseConnectedAccount
    return @{ Account = $account; Context = $ctx }
}

function Clear-CpcResourceInventory {
    foreach ($key in @('ResourceGroups','Vms','Policies','Skus','Storage','Groups')) { $script:S.Catalog[$key] = @() }
    $script:S.Preflight.Clear()
    if (-not $script:S.Rows.Count) {
        $script:S.Config = @{ PolicyId = ''; SkuId = ''; TargetDiskGiB = 0; StorageId = ''; Container = ''; SnapshotResourceGroup = '' }
    }
}

function Get-CpcSubscriptions($Data) {
    # Discovery authenticates Azure only; no subscription is silently chosen for migration.
    if ($script:S.Rows.Count -or $script:S.GroupId -or $script:S.UserSettingId) { throw 'Subscription scope is locked once a plan exists. Open a new application instance to change scope.' }
    $tenant = Assert-CpcGuid $Data.TenantId 'Tenant ID'
    Assert-CpcTenantScope $tenant
    $script:S.Connected = $false
    $script:S.SubscriptionId = ''
    $script:S.TenantId = $tenant
    $script:S.Catalog.Subscriptions = @()
    Clear-CpcResourceInventory
    Import-Module Az.Accounts -ErrorAction Stop
    Disable-AzContextAutosave -Scope Process | Out-Null
    # The WPF worker has no interactive console host. Keep browser authentication,
    # but use our explicit subscription picker instead of Az's console prompt.
    Update-AzConfig -LoginExperienceV2 Off -Scope Process -ErrorAction Stop | Out-Null
    Connect-AzAccount -Tenant $tenant -Environment AzureCloud -Scope Process | Out-Null
    $script:S.Catalog.Subscriptions = @(Get-AzSubscription -TenantId $tenant | Where-Object {
        [string]$_.TenantId -eq $tenant -and [string]$_.State -eq 'Enabled'
    } | ForEach-Object {
        [pscustomobject]@{ Name = $_.Name; Id = [string]$_.Id; TenantId = [string]$_.TenantId; DisplayName = "$($_.Name) [$($_.Id)]" }
    } | Sort-Object Name,Id)
    if (-not $script:S.Catalog.Subscriptions.Count) { throw 'No enabled accessible subscriptions found in this tenant. Verify Azure RBAC, tenant and subscription state.' }
    Write-CpcLog "Detected $($script:S.Catalog.Subscriptions.Count) enabled subscriptions in tenant $tenant. Select one, then Connect selected subscription + Graph. No migration subscription selected automatically."
}

function Connect-CpcServices($Data) {
    $script:S.Preflight.Clear()
    $tenant = Assert-CpcGuid $Data.TenantId 'Tenant ID'
    Assert-CpcTenantScope $tenant
    $sub = Assert-CpcGuid $Data.SubscriptionId 'Subscription ID'
    if (($script:S.Rows.Count -or $script:S.GroupId -or $script:S.UserSettingId) -and ($script:S.TenantId -ne $tenant -or $script:S.SubscriptionId -ne $sub)) {
        throw 'Open a new application instance for a different tenant or subscription.'
    }
    if (@($script:S.Catalog.Subscriptions | Where-Object { $_.Id -eq $sub -and (Get-Value $_ 'TenantId') -eq $tenant }).Count -ne 1) {
        throw 'Detect subscriptions for this tenant first, then choose an accessible subscription from the list.'
    }
    $script:S.Connected = $false
    Clear-CpcResourceInventory
    foreach ($module in $script:Modules) { Import-Module $module -ErrorAction Stop }
    Disable-AzContextAutosave -Scope Process | Out-Null
    Update-AzConfig -LoginExperienceV2 Off -Scope Process -ErrorAction Stop | Out-Null
    Connect-AzAccount -Tenant $tenant -Subscription $sub -Environment AzureCloud -Scope Process | Out-Null
    $available = @(Get-AzSubscription -TenantId $tenant | Where-Object { [string]$_.Id -eq $sub -and [string]$_.TenantId -eq $tenant -and [string]$_.State -eq 'Enabled' })
    if ($available.Count -ne 1) { throw 'The selected subscription is no longer enabled or accessible. Verify access before reconnecting.' }
    Set-AzContext -Tenant $tenant -Subscription $sub -Scope Process | Out-Null
    Connect-MgGraph -TenantId $tenant -Environment Global -ContextScope Process -NoWelcome -Scopes @(
        'CloudPC.ReadWrite.All','User.Read.All','Group.ReadWrite.All','LicenseAssignment.ReadWrite.All','Organization.Read.All'
    ) | Out-Null
    Set-MgRequestContext -MaxRetry 0 -ClientTimeout 120 | Out-Null
    $script:S.TenantId = $tenant
    $script:S.SubscriptionId = $sub
    $script:S.Connected = $true
    try { Assert-CpcContext }
    catch { $script:S.Connected = $false; throw }
    Write-CpcLog "Connected to tenant $tenant and subscription $sub. No cloud resources changed."
}

function Get-CpcLicenseConfiguration([string]$Text) {
    # Adapted from Get-W365ConfigFromText in example get licenses.txt.
    $config = @{ VCpu = 0; RamGB = 0; StorageGB = 0 }
    $text = $Text -replace '/', ' '
    if ($text -match '(?i)(\d+)\s*_?\s*vcpu') { $config.VCpu = [int]$Matches[1] }
    elseif ($text -match '(?i)(?:^|[_\s])(\d+)\s*c(?=[_\s\d])') { $config.VCpu = [int]$Matches[1] }
    $gb = [regex]::Matches($text, '(?i)(\d+)\s*_?\s*gb')
    if ($gb.Count -ge 2) { $config.RamGB = [int]$gb[0].Groups[1].Value; $config.StorageGB = [int]$gb[-1].Groups[1].Value }
    return $config
}

function ConvertTo-CpcLicenseCatalog($SubscribedSkus, $ServicePlans = @()) {
    # Reuse the example's SKU/child-plan config matching and enabled-minus-consumed
    # counts, but reject an ENTIRE SKU if any identity signals an excluded family.
    $liteId = '6b97ad6a-be15-4cbe-afbb-4eb74ecb0243'
    $litePattern = '(?i)cloudpc[_ ]?add-?on|cloudpc[_ ]?lite'
    $excluded = '(?i)gpu|frontline|flex|shared|business|reserve|cpc[_ -][sb](?:[_ -]|$)|cross[_ -]?region|disaster[_ -]?recovery'
    $enterprise = '(?i)(?:^|[_ -])cpc_e(?:[_ -]|$)|windows[_ ]?365[_ ]?enterprise'
    $planMap = @{}
    $blockedIds = @{}
    foreach ($plan in @($ServicePlans)) {
        $id = [string](Get-Value $plan 'id' '')
        $name = [string](Get-Value $plan 'displayName' '')
        $type = [string](Get-Value $plan 'type' '')
        if ("$name $type" -match $excluded) { if ($id) { $blockedIds[$id] = $true }; continue }
        if ($id -eq $liteId -or $name -match $litePattern) { continue }
        if ("$name $type" -notmatch '(?i)enterprise' -or -not $id) { continue }
        $config = Get-CpcLicenseConfiguration $name
        foreach ($field in @(@('VCpu','vCpuCount'), @('RamGB','ramInGB'), @('StorageGB','storageInGB'))) {
            $value = Get-Value $plan $field[1] 0
            if ($value) { $config[$field[0]] = [int]$value }
        }
        if ($config.VCpu -and $config.RamGB -and $config.StorageGB) {
            $key = "$($config.VCpu)|$($config.RamGB)|$($config.StorageGB)"
            if (-not $planMap.ContainsKey($key)) { $planMap[$key] = @() }
            $planMap[$key] += @{ Id = $id; Name = $name }
        }
    }
    $licenses = foreach ($sku in @($SubscribedSkus)) {
        $part = [string](Get-Value $sku 'skuPartNumber' '')
        $children = @(Get-Value $sku 'servicePlans' @())
        $names = @($part) + @($children | ForEach-Object { [string](Get-Value $_ 'servicePlanName' '') })
        $childIds = @($children | ForEach-Object { [string](Get-Value $_ 'servicePlanId' '') })
        if (@($names | Where-Object { $_ -match $excluded }).Count -or @($childIds | Where-Object { $blockedIds.ContainsKey($_) }).Count) { continue }
        $isLite = @($names | Where-Object { $_ -match $litePattern }).Count -gt 0 -or $liteId -in $childIds
        $config = $null; $token = ''; $servicePlanId = ''; $display = ''
        if ($isLite) {
            # Explicit exception from the supplied example; never merge with standard 2/4/128.
            $config = @{ VCpu = 2; RamGB = 4; StorageGB = 128 }
            $token = 'CloudPC_Lite'; $servicePlanId = $liteId
            $display = 'CloudPC Lite 2 vCPU / 4 GB / 128 GB'
        } else {
            $configs = @{}
            foreach ($name in $names) {
                if ($name -notmatch $enterprise) { continue }
                $parsed = Get-CpcLicenseConfiguration $name
                if ($parsed.VCpu -and $parsed.RamGB -and $parsed.StorageGB) {
                    $key = "$($parsed.VCpu)|$($parsed.RamGB)|$($parsed.StorageGB)"
                    $configs[$key] = @{ Config = $parsed; Token = $name }
                }
            }
            # Unknown/contradictory configurations cannot become selectable targets.
            if ($configs.Count -ne 1) { continue }
            $key = @($configs.Keys)[0]; $config = $configs[$key].Config; $token = $configs[$key].Token
            if ($planMap.ContainsKey($key) -and $planMap[$key].Count -eq 1) {
                $servicePlanId = $planMap[$key][0].Id; $token = $planMap[$key][0].Name
            }
            $display = "Windows 365 Enterprise $($config.VCpu) vCPU / $($config.RamGB) GB / $($config.StorageGB) GB"
        }
        $skuId = [string](Get-Value $sku 'skuId' '')
        $validId = [guid]::Empty
        if (-not [guid]::TryParse($skuId, [ref]$validId)) { continue }
        $prepaid = Get-Value $sku 'prepaidUnits'
        $enabled = 0L; $consumed = 0L
        $countsKnown = [long]::TryParse([string](Get-Value $prepaid 'enabled'), [ref]$enabled) -and
            [long]::TryParse([string](Get-Value $sku 'consumedUnits'), [ref]$consumed) -and $enabled -ge 0 -and $consumed -ge 0
        $status = [string](Get-Value $sku 'capabilityStatus' 'Unknown')
        $available = if ($countsKnown -and $status -eq 'Enabled') { [math]::Max(0L, $enabled - $consumed) } else { 0L }
        [pscustomobject]@{
            SkuId = $skuId; SkuPartNumber = $part; DisplayName = $display; Edition = 'Enterprise'; IsLite = $isLite
            ServicePlanId = $servicePlanId; ServicePlanName = $token; VCpu = $config.VCpu; RamGB = $config.RamGB; StorageGB = $config.StorageGB
            Enabled = $enabled; Consumed = $consumed; Available = $available; CountsKnown = $countsKnown
            CapabilityStatus = $status; CanSelect = $available -gt 0
            SelectionLabel = "$display | Available: $available | Assigned: $consumed / Enabled: $enabled | $part [$status]"
        }
    }
    return @($licenses | Sort-Object IsLite,VCpu,RamGB,StorageGB,SkuPartNumber)
}

function Update-CpcLicenseCatalog {
    Assert-CpcContext
    # Never leave stale selectable seats behind if either Graph collection fails.
    $script:S.Catalog.Skus = @()
    $skus = @(Get-CpcGraphCollection '/v1.0/subscribedSkus')
    $plans = @(Get-CpcGraphCollection "$script:Endpoint/servicePlans")
    $script:S.Catalog.Skus = @(ConvertTo-CpcLicenseCatalog $skus $plans)
    Write-CpcLog "Refreshed Enterprise / CloudPC Lite licenses: $($script:S.Catalog.Skus.Count) eligible SKUs. Flex, Frontline, GPU and other families excluded."
}

function Assert-CpcLicenseTarget($Catalog, [string]$SkuId, [int]$Required = 1, [int]$DiskGiB = 0) {
    $found = @($Catalog | Where-Object SkuId -EQ $SkuId)
    if ($found.Count -ne 1) { throw 'Selected SKU is not an eligible Enterprise / CloudPC Lite license. Refresh licenses; Flex, Frontline, GPU, Business and unrelated SKUs are blocked.' }
    $license = $found[0]
    if (-not $license.CountsKnown -or $license.CapabilityStatus -ne 'Enabled' -or $license.Available -lt $Required) {
        throw "Insufficient assignable licenses for $($license.SkuPartNumber): available $($license.Available), required $Required, state $($license.CapabilityStatus)."
    }
    if ($DiskGiB -and $DiskGiB -ne $license.StorageGB) { throw 'Journal disk capacity does not match the resolved license. Create a corrected plan before migration.' }
    return $license
}

function Get-CpcInventory {
    Assert-CpcContext
    foreach ($key in @('ResourceGroups','Vms','Storage','Policies','Skus','Groups')) { $script:S.Catalog[$key] = @() }
    $script:S.Catalog.ResourceGroups = @(Get-AzResourceGroup | ForEach-Object {
        [pscustomobject]@{ Name = $_.ResourceGroupName; Id = $_.ResourceId; Location = $_.Location; DisplayName = "$($_.ResourceGroupName) [$($_.Location)]" }
    } | Sort-Object Name)
    $script:S.Catalog.Vms = @(Get-AzVM | ForEach-Object {
        [pscustomobject]@{ Name = $_.Name; ResourceGroup = $_.ResourceGroupName; Location = $_.Location; Id = $_.Id; Size = $_.HardwareProfile.VmSize; OS = [string]$_.StorageProfile.OsDisk.OsType }
    })
    $script:S.Catalog.Storage = @(Get-AzStorageAccount | ForEach-Object {
        [pscustomobject]@{ Name = $_.StorageAccountName; Id = $_.Id; Location = $_.Location }
    })
    $script:S.Catalog.Policies = @(Get-CpcGraphCollection "$script:Endpoint/provisioningPolicies?`$expand=assignments")
    Update-CpcLicenseCatalog
    Write-CpcLog "Discovered $($script:S.Catalog.Vms.Count) VMs and $($script:S.Catalog.Policies.Count) provisioning policies."
}

function Test-CpcGroupTarget($Target) {
    return (Get-Value $Target '@odata.type') -eq '#microsoft.graph.cloudPcManagementGroupAssignmentTarget' -and
        -not [string]::IsNullOrWhiteSpace([string](Get-Value $Target 'groupId')) -and
        [string]::IsNullOrWhiteSpace([string](Get-Value $Target 'deviceAndAppManagementAssignmentFilterId'))
}

function Test-CpcPolicyTarget($Policy) {
    # Older beta responses omit these optional properties. Explicit incompatible
    # or unknown owners/experiences must never masquerade as Enterprise desktops.
    return (Get-Value $Policy 'provisioningType') -eq 'dedicated' -and
        (Get-Value $Policy 'managedBy' 'windows365') -eq 'windows365' -and
        (Get-Value $Policy 'userExperienceType' 'cloudPc') -eq 'cloudPc'
}

function Get-CpcGroupChoices($Data) {
    Assert-CpcContext
    $script:S.Catalog.Groups = @()
    $policyId = Assert-CpcGuid $Data.PolicyId 'Policy ID'
    $policy = Invoke-CpcGraph -Path "$script:Endpoint/provisioningPolicies/$policyId`?`$expand=assignments"
    if (-not (Test-CpcPolicyTarget $policy)) { throw 'Choose a Windows 365 Enterprise dedicated desktop provisioning policy first.' }
    $upns = @($Data.Mappings | ForEach-Object { ([string]$_.UserPrincipalName).Trim() } | Sort-Object -Unique)
    if (-not $upns.Count -or @($upns | Where-Object { $_ -notmatch '^[^@\s]+@[^@\s]+$' }).Count) { throw 'Check the source VMs and enter their target user UPNs before finding groups.' }
    $common = @((Get-Value $policy 'assignments' @()) | Where-Object { Test-CpcGroupTarget (Get-Value $_ 'target') } | ForEach-Object { $_.target.groupId } | Sort-Object -Unique)
    foreach ($upn in $upns) {
        $key = [uri]::EscapeDataString($upn)
        $user = Invoke-CpcGraph -Path "/v1.0/users/$key`?`$select=id"
        $memberships = @(Get-CpcGraphCollection "/v1.0/users/$($user.id)/memberOf/microsoft.graph.group?`$select=id" | ForEach-Object { $_.id })
        $common = @($common | Where-Object { $_ -in $memberships })
    }
    $choices = foreach ($id in $common) {
        $id = Assert-CpcGuid $id 'Group ID'
        $g = Invoke-CpcGraph -Path "/v1.0/groups/$id`?`$select=id,displayName,securityEnabled,groupTypes,onPremisesSyncEnabled,assignedLicenses"
        if ((Get-Value $g 'securityEnabled') -eq $true -and (Get-Value $g 'onPremisesSyncEnabled') -ne $true -and
            'DynamicMembership' -notin @(Get-Value $g 'groupTypes' @()) -and -not @(Get-Value $g 'assignedLicenses' @()).Count) {
            [pscustomobject]@{ Id = $id; Name = $g.displayName; PolicyId = $policyId; PolicyName = Get-Value $policy 'displayName'; DisplayName = "$($g.displayName) [$id]" }
        }
    }
    $script:S.Catalog.Groups = @($choices | Sort-Object Name,Id)
    if (-not $script:S.Catalog.Groups.Count) { throw 'No eligible common user group is directly assigned to this Enterprise policy. Use a static cloud security group containing the target users, assign it to the policy, then find groups again. Nested, dynamic, synced or license-bearing groups are not supported.' }
    Write-CpcLog 'Select a group explicitly. Group membership and whole-batch scope will be validated live; no setting, membership or policy was changed.'
}

function Assert-CpcSelectedGroup($Config, $Rows) {
    # Existing groups are borrowed, never owned. Protect every affected member.
    $id = Assert-CpcGuid (Get-Value $Config 'ExistingGroupId') 'Selected user group ID'
    if ($script:S.GroupId -and $script:S.GroupId -ne $id) { throw 'Selected group differs from the journaled migration group.' }
    $group = Invoke-CpcGraph -Path "/v1.0/groups/$id`?`$select=id,displayName,securityEnabled,groupTypes,onPremisesSyncEnabled,assignedLicenses"
    if ((Get-Value $group 'id') -ne $id -or (Get-Value $group 'securityEnabled') -ne $true -or
        (Get-Value $group 'onPremisesSyncEnabled') -eq $true -or 'DynamicMembership' -in @(Get-Value $group 'groupTypes' @())) { throw 'Selected user group must be an accessible static cloud security group (no synced/dynamic group).' }
    $parents = @(Get-CpcGraphCollection "/v1.0/groups/$id/transitiveMemberOf/microsoft.graph.group?`$select=id,assignedLicenses")
    if (@(Get-Value $group 'assignedLicenses' @()).Count -or @($parents | Where-Object { @(Get-Value $_ 'assignedLicenses' @()).Count }).Count) { throw 'Selected group or ancestor has license assignments; automatic licensing could bypass snapshot import sequencing.' }
    $policy = Invoke-CpcGraph -Path "$script:Endpoint/provisioningPolicies/$($Config.PolicyId)?`$expand=assignments"
    $targets = @((Get-Value $policy 'assignments' @()) | Where-Object { (Test-CpcGroupTarget (Get-Value $_ 'target')) -and $_.target.groupId -eq $id })
    if (-not (Test-CpcPolicyTarget $policy) -or $targets.Count -ne 1) { throw 'Selected group must already be directly assigned, without filters, to the selected Windows 365 Enterprise dedicated desktop policy. Fix the assignment in Intune; this app will not alter it.' }
    $ids = foreach ($row in $Rows) {
        $key = [uri]::EscapeDataString($row.UserPrincipalName)
        $user = Invoke-CpcGraph -Path "/v1.0/users/$key`?`$select=id,userPrincipalName"
        if ((Get-Value $row 'UserId') -and $row.UserId -ne $user.id) { throw 'Target user identity changed; group selection must be reviewed.' }
        Assert-CpcGuid $user.id 'Target user ID'
    }
    $ids = @($ids | Sort-Object -Unique)
    $members = @(Get-CpcGraphCollection "/v1.0/groups/$id/members?`$select=id")
    if (-not $ids.Count -or $members.Count -ne $ids.Count -or @($members | Where-Object { (Get-Value $_ 'id') -notin $ids -or (Get-Value $_ '@odata.type') -ne '#microsoft.graph.user' }).Count -or
        @($ids | Where-Object { $_ -notin @($members | ForEach-Object { $_.id }) }).Count) {
        throw 'The selected group must contain exactly the mapped batch users as direct members. Extra users, nested groups or missing users block a group-wide snapshot setting. Use a dedicated existing migration group or map its entire eligible membership; no membership is changed automatically.'
    }
    return $group
}

function Set-CpcMappings($Data) {
    Assert-CpcContext
    $null = Assert-CpcGuid (Get-Value $Data.Config 'ExistingGroupId') 'Selected user group ID (find groups and choose one first)'
    if ($script:S.GroupId -or @($script:S.Rows | Where-Object { $_.Phase -ne 'Mapped' }).Count) {
        throw 'This plan is already prepared. Use a new app instance for a new migration batch; mappings are locked after preparation.'
    }
    if (-not @($Data.Mappings).Count) { throw 'Select at least one Azure VM and supply its target user UPN.' }
    $new = [System.Collections.Generic.List[object]]::new()
    $users = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $vms = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($m in $Data.Mappings) {
        if (-not $m.UserPrincipalName -or -not $users.Add($m.UserPrincipalName.Trim())) { throw 'Each selected VM must have a unique target user UPN.' }
        if (-not $vms.Add($m.VmId)) { throw 'A VM was selected twice.' }
        $vm = @($script:S.Catalog.Vms | Where-Object Id -EQ $m.VmId)
        if ($vm.Count -ne 1 -or $m.VmId -notlike "/subscriptions/$($script:S.SubscriptionId)/resourceGroups/*/providers/Microsoft.Compute/virtualMachines/*") { throw 'Selected VM is not in the current subscription inventory.' }
        $new.Add([ordered]@{
            Selected = $true; VmId = $m.VmId; VM = $vm[0].Name; ResourceGroup = $vm[0].ResourceGroup; Location = $vm[0].Location
            UserPrincipalName = $m.UserPrincipalName.Trim(); UserId = ''; Phase = 'Mapped'; Readiness = 'NotChecked'; Detail = ''
            Guest = $null; Attested = $false; CheckedUtc = ''; SnapshotName = ''; SnapshotId = ''; VhdBlob = ''; VmgsBlob = ''
            VhdCopyId = ''; VmgsCopyId = ''; ImportId = ''; ImportStatus = ''; UsageStatus = ''; CloudPcId = ''; CloudPcStatus = ''
            SourceVmUniqueId = ''; SourceDiskId = ''; CaptureStartedUtc = ''; ImportStartedUtc = ''; LicenseAssignedUtc = ''; ValidatedUtc = ''; LastError = ''
        })
    }
    Update-CpcLicenseCatalog
    $group = Assert-CpcSelectedGroup $Data.Config $new
    $config = $Data.Config.Clone()
    $config.ExistingGroupName = [string]$group.displayName
    $license = Assert-CpcLicenseTarget $script:S.Catalog.Skus $Data.Config.SkuId $new.Count
    $config.TargetDiskGiB = [int]$license.StorageGB
    Assert-CpcConfig $config
    $candidate = $script:S.Clone()
    $candidate.Config = $config; $candidate.Preflight = @{}; $candidate.Rows = $new
    Save-CpcState -State $candidate
    $script:S = $candidate
    Write-CpcLog "Saved $($new.Count) VM-to-user mappings. $($license.DisplayName); $($license.Available) available licenses."
}

function Get-CpcSelected($Data) {
    $ids = @($Data.VmIds)
    $rows = @($script:S.Rows | Where-Object { $_.VmId -in $ids })
    if (-not $rows.Count) { throw 'Select one or more mapped rows.' }
    return $rows
}

function Test-CpcLocal {
    $script:S.Checks.Clear()
    foreach ($module in $script:Modules) {
        $found = @(Get-Module -ListAvailable $module | Sort-Object Version -Descending)
        $detail = if ($found.Count) { [string]$found[0].Version } else { 'Use Install dependencies. Installation is CurrentUser only.' }
        Add-CpcCheck 'Workstation' $module $(if ($found.Count) { 'Pass' } else { 'Fail' }) $detail
    }
    Add-CpcCheck 'Workstation' 'Runtime' 'Pass' "PowerShell $($PSVersionTable.PSVersion); UI requires Windows STA."
    if (Get-Module -ListAvailable Az.Compute) {
        Import-Module Az.Compute
        $vmgsSupported = (Get-Command Grant-AzSnapshotAccess).Parameters.ContainsKey('SecureVMGuestStateSAS')
        Add-CpcCheck 'Workstation' 'Trusted Launch export capability' $(if ($vmgsSupported) { 'Pass' } else { 'Fail' }) 'Requires Grant-AzSnapshotAccess -SecureVMGuestStateSAS. Update Az.Compute and restart the app if missing; standard Gen2 export does not need the switch.'
    }
    Add-CpcCheck 'Workstation' 'API support' 'Manual' 'Migration uses Graph beta. Obtain approval for a controlled pilot; beta APIs can change.'
}

function Test-CpcGuestEvidenceFresh($Timestamp) {
    # ConvertFrom-Json can materialize ISO timestamps as DateTime. Passing that
    # object to Parse(string) formats it first, losing UTC and mixing cultures.
    try {
        if ($Timestamp -is [datetimeoffset]) { $instant = $Timestamp }
        elseif ($Timestamp -is [datetime]) {
            if ($Timestamp.Kind -eq [DateTimeKind]::Unspecified) { return $false }
            $instant = [datetimeoffset]::new($Timestamp)
        } else {
            $text = [string]$Timestamp
            if ($text -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$') { return $false }
            $instant = [datetimeoffset]::Parse($text, [cultureinfo]::InvariantCulture, [Globalization.DateTimeStyles]::None)
        }
        $age = [datetimeoffset]::UtcNow - $instant
        return $age.TotalHours -ge 0 -and $age.TotalHours -lt 24
    } catch { return $false }
}

function Get-CpcGuestCheckDetail($Row, [string]$Check) {
    if ($Check -notmatch '^(Guest assessment captured|Guest evidence fresh.*|Client Windows 10.*|Entra joined to this tenant|Agent ready during guest assessment|No encrypted guest volumes)$') { return $null }
    $guest = $Row.Guest
    $next = if ($Row.SourceVmUniqueId) {
        'Evidence is frozen for the captured source. Do not restart or reassess it to clear this check; review the captured attempt and use the recovery workflow if necessary.'
    } else {
        'Validate prerequisites reuses saved guest evidence; it does not reread Windows. After fixing the VM, select it on the Migration tab and repeat 1 Assess guest (VM running), 2 Attest prerequisites, then 3 Validate prerequisites. Reassessment clears prior attestation and approval.'
    }
    if (-not $guest) { return "No saved guest assessment. $next" }
    $stamp = Get-Value $guest 'CheckedUtc' 'unknown'
    if ($stamp -is [datetime] -or $stamp -is [datetimeoffset]) { $stamp = $stamp.ToString('o', [cultureinfo]::InvariantCulture) }
    $values = switch -Regex ($Check) {
        '^Entra joined' { "Recorded AzureAdJoined=$($guest.AzureAdJoined); TenantId='$($guest.TenantId)'; required tenant='$($script:S.TenantId)'." }
        '^No encrypted' { "Recorded BitLockerKnown=$($guest.BitLockerKnown); volumes not FullyDecrypted=$($guest.EncryptedVolumes). Requires known status and zero such volumes; suspended protection or decryption in progress is not FullyDecrypted." }
        '^Agent ready' { "Recorded AgentReady=$($guest.AgentReady)." }
        '^Client Windows' { "Recorded ProductType=$($guest.ProductType); Build=$($guest.Build); Edition=$($guest.Edition)." }
        default { 'These are saved observations, not a live reading of the guest.' }
    }
    return "Guest assessment collected: $stamp. $values $next"
}

function Test-CpcRows($Rows, [switch]$Preparing) {
    Assert-CpcContext
    Assert-CpcConfig
    foreach ($row in $Rows) { $row.Readiness = 'Blocked' }
    $script:S.Checks.Clear()
    $storage = Get-CpcStorage
    $account = $storage.Account
    $container = Get-AzStorageContainer -Name $script:S.Config.Container -Context $storage.Context
    $publicAccess = [string](Get-Value $container 'PublicAccess')
    $storageSafe = $account.Kind -in @('Storage','StorageV2') -and $publicAccess -eq 'Off' -and
        [string]$account.PublicNetworkAccess -eq 'Enabled' -and [string]$account.NetworkRuleSet.DefaultAction -eq 'Allow'
    # Intentionally conservative: no automatic firewall relaxation or private-link exceptions.
    Add-CpcCheck 'Batch' 'Private page-blob staging / service reachability' $(if ($storageSafe) { 'Pass' } else { 'Fail' }) "Account $($script:S.Config.StorageId); kind $($account.Kind); SKU $(Get-Value (Get-Value $account 'Sku') 'Name' 'unknown'); container $($script:S.Config.Container); public access $publicAccess; network $($account.PublicNetworkAccess) / $($account.NetworkRuleSet.DefaultAction). Requires private Storage/StorageV2 and Enabled/Allow networking. SAS does not bypass firewalls; no settings changed."
    $policies = @(Get-CpcGraphCollection "$script:Endpoint/provisioningPolicies?`$expand=assignments")
    $chosen = @($policies | Where-Object { $_.id -eq $script:S.Config.PolicyId })
    if ($chosen.Count -ne 1) { throw 'Provisioning policy no longer exists or is inaccessible.' }
    $policy = $chosen[0]
    $policyValid = Test-CpcPolicyTarget $policy
    Add-CpcCheck 'Batch' 'Enterprise dedicated provisioning policy' $(if ($policyValid) { 'Pass' } else { 'Fail' }) "Policy $(Get-Value $policy 'displayName' 'unnamed') [$($policy.id)]; type $(Get-Value $policy 'provisioningType'). Requires dedicated Enterprise policy; Lite-specific entitlement must be verified."
    $joinConfigs = @(Get-Value $policy 'domainJoinConfigurations' @())
    $regionConfigured = $joinConfigs.Count -gt 0
    foreach ($join in $joinConfigs) {
        $ancId = [string](Get-Value $join 'onPremisesConnectionId' '')
        $joinType = [string](Get-Value $join 'domainJoinType' '')
        $valid = $joinType -in @('azureADJoin','hybridAzureADJoin') -and
            ($ancId -or (Get-Value $join 'regionName') -or (Get-Value $join 'regionGroup'))
        if ($ancId) {
            $null = Assert-CpcGuid $ancId 'Azure network connection ID'
            $anc = Invoke-CpcGraph -Path "$script:Endpoint/onPremisesConnections/$ancId"
            $valid = $valid -and (Get-Value $anc 'healthCheckStatus') -eq 'passed'
        }
        $regionConfigured = $regionConfigured -and $valid
    }
    Add-CpcCheck 'Batch' 'Region/join configuration and ANC health' $(if ($regionConfigured) { 'Pass' } else { 'Fail' }) 'Requires an explicit supported join configuration with region/region-group or healthy ANC. New/unknown region schema fails closed; confirm geography and capacity with the service.'
    $skus = @(Get-CpcGraphCollection '/v1.0/subscribedSkus')
    $plans = @(Get-CpcGraphCollection "$script:Endpoint/servicePlans")
    $script:S.Catalog.Skus = @(ConvertTo-CpcLicenseCatalog $skus $plans)
    $capacity = $false
    $reconcileUsers = @{}
    foreach ($row in @($Rows | Where-Object { $_.Phase -eq 'LicenseUnknown' -and $_.UserId })) {
        $existing = Invoke-CpcGraph -Path "/v1.0/users/$($row.UserId)?`$select=assignedLicenses"
        if ($script:S.Config.SkuId -in @((Get-Value $existing 'assignedLicenses' @()) | ForEach-Object { $_.skuId })) { $reconcileUsers[$row.UserId] = $true }
    }
    try {
        $required = @($Rows | Where-Object { -not $_.LicenseAssignedUtc -and -not $reconcileUsers.ContainsKey($_.UserId) }).Count
        $license = Assert-CpcLicenseTarget $script:S.Catalog.Skus $script:S.Config.SkuId $required ([int]$script:S.Config.TargetDiskGiB)
        $capacity = $true
        Add-CpcCheck 'Batch' 'License eligibility / availability' 'Pass' "$($license.SelectionLabel); required for selection: $required"
    } catch { Add-CpcCheck 'Batch' 'License eligibility / availability' 'Fail' $_.Exception.Message }
    $pcs = @(Get-CpcGraphCollection "$script:Endpoint/cloudPCs")
    $settings = @(Get-CpcGraphCollection "$script:Endpoint/userSettings?`$expand=assignments")
    $rgScope = "/subscriptions/$($script:S.SubscriptionId)/resourceGroups/$($script:S.Config.SnapshotResourceGroup)"
    $snapPerms = @(Get-CpcPermissions $rgScope)
    $storagePerms = @(Get-CpcPermissions $script:S.Config.StorageId)
    $batchPermOk = $true
    foreach ($op in @('Microsoft.Compute/snapshots/read','Microsoft.Compute/snapshots/write','Microsoft.Compute/snapshots/beginGetAccess/action','Microsoft.Compute/snapshots/endGetAccess/action')) {
        $ok = Test-CpcPermission $snapPerms $op
        $batchPermOk = $batchPermOk -and $ok
        Add-CpcCheck 'Batch' 'Snapshot RBAC' $(if ($ok) { 'Pass' } else { 'Fail' }) $op
    }
    $sasAllowed = Test-CpcPermission $storagePerms 'Microsoft.Storage/storageAccounts/blobServices/generateUserDelegationKey/action'
    $batchPermOk = $batchPermOk -and $sasAllowed
    Add-CpcCheck 'Batch' 'User delegation SAS RBAC' $(if ($sasAllowed) { 'Pass' } else { 'Fail' }) 'Requires generateUserDelegationKey at account scope or above.'
    $containerScope = "$($script:S.Config.StorageId)/blobServices/default/containers/$($script:S.Config.Container)"
    $blobPerms = @(Get-CpcPermissions $containerScope)
    foreach ($op in @('Microsoft.Storage/storageAccounts/blobServices/containers/blobs/read','Microsoft.Storage/storageAccounts/blobServices/containers/blobs/write')) {
        $ok = Test-CpcPermission $blobPerms $op -DataAction
        $batchPermOk = $batchPermOk -and $ok
        Add-CpcCheck 'Batch' 'Blob data RBAC' $(if ($ok) { 'Pass' } else { 'Fail' }) $op
    }
    foreach ($row in $Rows) {
        Assert-CpcContinue
        $row.Readiness = 'Blocked'
        try {
            $vm = Get-AzVM -ResourceGroupName $row.ResourceGroup -Name $row.VM
            $instance = Get-AzVM -ResourceGroupName $row.ResourceGroup -Name $row.VM -Status
            $diskId = [string]$vm.StorageProfile.OsDisk.ManagedDisk.Id
            if (-not $diskId) { throw 'A managed OS disk is required.' }
            $diskParts = $diskId.Split('/')
            $disk = Get-AzDisk -ResourceGroupName $diskParts[4] -DiskName $diskParts[8]
            $sameInspectedSource = (-not (Get-Value $row 'ObservedSourceDiskId') -or $row.ObservedSourceDiskId -eq $diskId) -and
                (-not (Get-Value $row 'ObservedSourceVmUniqueId') -or $row.ObservedSourceVmUniqueId -eq [string]$vm.VmId)
            if (-not (Get-Value $row 'ObservedSourceDiskId')) { $row.ObservedSourceDiskId = $diskId }
            if (-not (Get-Value $row 'ObservedSourceVmUniqueId')) { $row.ObservedSourceVmUniqueId = [string]$vm.VmId }
            $securityType = [string](Get-Value $vm.SecurityProfile 'SecurityType' '')
            $power = @($instance.Statuses | Where-Object Code -Like 'PowerState/*' | ForEach-Object Code) -join ','
            $tests = [ordered]@{
                'Same inspected source VM and disk' = $sameInspectedSource
                'Windows OS disk' = [string]$vm.StorageProfile.OsDisk.OsType -eq 'Windows'
                'Generation 2' = [string]$disk.HyperVGeneration -eq 'V2'
                'No data disks' = @($vm.StorageProfile.DataDisks).Count -eq 0
                'Persistent OS disk' = [string](Get-Value $vm.StorageProfile.OsDisk.DiffDiskSettings 'Option' '') -ne 'Local'
                'Target disk capacity' = $disk.DiskSizeGB -le [int]$script:S.Config.TargetDiskGiB
                'No confidential VM' = $securityType -in @('','Standard','TrustedLaunch')
                'SAS export permitted' = [string]$disk.DataAccessAuthMode -ne 'AzureActiveDirectory' -and [string]$disk.NetworkAccessPolicy -notin @('DenyAll','AllowPrivate')
                'Supported disk encryption' = [string](Get-Value $disk.Encryption 'Type' '') -notmatch 'CustomerKey' -and -not (Get-Value $disk.EncryptionSettingsCollection 'Enabled' $false)
                'VM idle power state' = $power -in @('PowerState/running','PowerState/deallocated')
            }
            if ($securityType -eq 'TrustedLaunch') {
                $tests['VMGS export cmdlet available'] = (Get-Command Grant-AzSnapshotAccess).Parameters.ContainsKey('SecureVMGuestStateSAS')
            }
            if (-not $row.SourceVmUniqueId -and $power -eq 'PowerState/running') {
                $agentStatuses = @(Get-Value (Get-Value $instance 'VMAgent') 'Statuses' @())
                $tests['Live Azure VM agent ready before capture'] = @($agentStatuses | Where-Object { (Get-Value $_ 'Code') -eq 'ProvisioningState/succeeded' }).Count -gt 0
            }
            if ($row.SourceVmUniqueId) {
                $tests['Same source VM instance and OS disk'] = $row.SourceVmUniqueId -eq [string]$vm.VmId -and $row.SourceDiskId -eq $diskId
                $tests['Source remains deallocated after capture'] = $power -eq 'PowerState/deallocated'
            }
            $vmPerms = @(Get-CpcPermissions $row.VmId)
            $tests['VM deallocate RBAC'] = Test-CpcPermission $vmPerms 'Microsoft.Compute/virtualMachines/deallocate/action'
            $key = [uri]::EscapeDataString($row.UserPrincipalName)
            $user = Invoke-CpcGraph -Path "/v1.0/users/$key`?`$select=id,displayName,userPrincipalName,accountEnabled,usageLocation,assignedLicenses"
            if ($row.UserId -and $row.UserId -ne $user.id) { throw 'Target UPN now resolves to a different user object. Start a new plan; remapping refused.' }
            $row.UserId = $user.id
            $row.UserPrincipalName = $user.userPrincipalName
            $row.UserDisplayName = [string](Get-Value $user 'displayName' '')
            $tests['Enabled target user and usage location'] = $user.accountEnabled -eq $true -and -not [string]::IsNullOrEmpty($user.usageLocation)
            $tests['No existing Cloud PC'] = @($pcs | Where-Object { (Get-Value $_ 'userPrincipalName') -eq $row.UserPrincipalName -or (Get-Value $_ 'userId') -eq $row.UserId }).Count -eq 0
            $assignedSkuIds = @($user.assignedLicenses | ForEach-Object { $_.skuId })
            # Detect existing W365 entitlements across ALL families, not only allowed targets.
            $cloudSkus = @($skus | Where-Object { ($_.skuPartNumber + ',' + (($_.servicePlans | ForEach-Object servicePlanName) -join ',')) -match '(?i)CLOUDPC|WINDOWS[_ ]?365|CPC_' } | ForEach-Object skuId)
            $tests['No premature Windows 365 license'] = @($assignedSkuIds | Where-Object { $_ -in $cloudSkus -or $_ -eq $script:S.Config.SkuId }).Count -eq 0
            if ($row.Phase -eq 'LicenseUnknown' -and $reconcileUsers.ContainsKey($row.UserId) -and $script:S.Config.SkuId -in $assignedSkuIds) {
                # Reconciliation records an already-present license without repeating a write.
                $tests['No premature Windows 365 license'] = @($assignedSkuIds | Where-Object { $_ -in $cloudSkus -and $_ -ne $script:S.Config.SkuId }).Count -eq 0
                $existingPcs = @($pcs | Where-Object { (Get-Value $_ 'userPrincipalName') -eq $row.UserPrincipalName -or (Get-Value $_ 'userId') -eq $row.UserId })
                $tests['No existing Cloud PC'] = $existingPcs.Count -eq 0 -or ($existingPcs.Count -eq 1 -and (Get-Value $existingPcs[0] 'provisioningPolicyId') -eq $script:S.Config.PolicyId)
            }
            $groups = @(Get-CpcGraphCollection "/v1.0/users/$($row.UserId)/transitiveMemberOf/microsoft.graph.group?`$select=id")
            $groupIds = @($groups | ForEach-Object { $_.id })
            $applicable = @($policies | Where-Object {
                @((Get-Value $_ 'assignments' @()) | Where-Object { (Get-Value (Get-Value $_ 'target') 'groupId') -in $groupIds }).Count -gt 0
            })
            $tests['No conflicting provisioning policy'] = @($applicable | Where-Object { $_.id -ne $script:S.Config.PolicyId }).Count -eq 0
            $otherSettings = @($settings | Where-Object {
                $_.id -ne $script:S.UserSettingId -and @((Get-Value $_ 'assignments' @()) | Where-Object { (Get-Value (Get-Value $_ 'target') 'groupId') -in $groupIds }).Count -gt 0
            })
            $tests['No conflicting user setting'] = $otherSettings.Count -eq 0
            if (-not $Preparing -and $row.Phase -ne 'Mapped') {
                $tests['Migration identity prepared'] = -not [string]::IsNullOrWhiteSpace($script:S.GroupId) -and -not [string]::IsNullOrWhiteSpace($script:S.UserSettingId)
                $tests['Migration group membership propagated'] = $script:S.GroupId -in $groupIds
                $tests['Selected provisioning policy assigned'] = @($applicable | Where-Object { $_.id -eq $script:S.Config.PolicyId }).Count -eq 1
                $tests['Selected policy assigned to migration group'] = @((Get-Value $policy 'assignments' @()) | Where-Object {
                    (Get-Value (Get-Value $_ 'target') 'groupId') -eq $script:S.GroupId
                }).Count -eq 1
                $ours = @($settings | Where-Object { $_.id -eq $script:S.UserSettingId -and (Get-Value $_ 'provisioningSourceType') -eq 'snapshot' })
                $tests['Snapshot user setting assigned'] = $ours.Count -eq 1 -and @((Get-Value ($ours | Select-Object -First 1) 'assignments' @()) | Where-Object { (Get-Value (Get-Value $_ 'target') 'groupId') -eq $script:S.GroupId }).Count -eq 1
            }
            $guest = $row.Guest
            $tests['Guest assessment captured'] = $null -ne $guest
            if ($guest) {
                $tests['Client Windows 10+ (not Server/multi-session)'] = [int]$guest.ProductType -eq 1 -and [int]$guest.Build -ge 10240 -and $guest.Edition -notmatch 'Server|Multi|Virtual'
                $tests['Entra joined to this tenant'] = $guest.AzureAdJoined -eq $true -and $guest.TenantId -eq $script:S.TenantId
                $tests['Agent ready during guest assessment'] = $guest.AgentReady -eq $true
                $tests['No encrypted guest volumes'] = $guest.BitLockerKnown -eq $true -and $guest.EncryptedVolumes -eq 0
                if (-not $row.SourceVmUniqueId) { $tests['Guest evidence fresh (24h before capture)'] = Test-CpcGuestEvidenceFresh $guest.CheckedUtc }
            }
            $tests['Operator attestation recorded'] = $row.Attested -eq $true
            foreach ($test in $tests.GetEnumerator()) {
                $detail = Get-CpcGuestCheckDetail $row $test.Key
                if ($test.Key -eq 'No conflicting user setting' -and -not $test.Value) {
                    $conflicts = ($otherSettings | ForEach-Object { "$(Get-Value $_ 'displayName' '(unnamed)') [$(Get-Value $_ 'id' '(unknown ID)')]" }) -join '; '
                    $detail = "Other assigned user settings: $conflicts. Current plan: $($script:S.PlanId); owned setting: '$($script:S.UserSettingId)'. If this is a setting created during an earlier run, restart and Resume / load its original journal after connecting, BEFORE creating draft mappings. A new draft does not restore ownership or replace cloud settings. Do not delete unrelated assignments to bypass this check."
                }
                if (-not $detail) { $detail = if ($test.Key -eq 'Target disk capacity') { "OS disk $($disk.DiskSizeGB) GiB <= resolved license target $($script:S.Config.TargetDiskGiB) GiB" } elseif ($test.Value) { 'Check passed.' } else { 'Failure or unknown is blocking; see operator guide.' } }
                Add-CpcCheck $row.VM $test.Key $(if ($test.Value) { 'Pass' } else { 'Fail' }) $detail
            }
            $all = @($tests.Values | Where-Object { -not $_ }).Count -eq 0 -and $storageSafe -and $policyValid -and $regionConfigured -and $capacity -and $batchPermOk
            $row.Readiness = if ($all) { 'Ready' } else { 'Blocked' }
            $row.CheckedUtc = [datetime]::UtcNow.ToString('o')
            $row.Detail = "$power; $($disk.DiskSizeGB) GiB; $securityType"
        } catch {
            $row.LastError = Protect-CpcText $_.Exception.Message
            Add-CpcCheck $row.VM 'Assessment' 'Fail' $row.LastError
        }
    }
    if (Get-Value $script:S.Config 'ExistingGroupId') {
        try {
            $group = Assert-CpcSelectedGroup $script:S.Config @($script:S.Rows)
            Add-CpcCheck 'Batch' 'Selected user group / Enterprise policy / whole-batch scope' 'Pass' "$($group.displayName) [$($group.id)]. Every direct member is mapped; existing membership and policy assignment will not be modified."
        } catch {
            foreach ($row in $Rows) { $row.Readiness = 'Blocked' }
            Add-CpcCheck 'Batch' 'Selected user group / Enterprise policy / whole-batch scope' 'Fail' $_.Exception.Message
        }
    }
    Add-CpcCheck 'Batch' 'Assessment boundaries' 'Manual' 'RBAC lists do not prove absence of deny assignments, locks, conditional access, ABAC or capacity restrictions. CSE/network, bootability, app compatibility, current supported OS release, recovery and user/profile match require operator validation.'
    Save-CpcState
    Write-CpcLog 'Prerequisite assessment finished. Ready is not a guarantee of service-side import/provisioning success.'
}

function Get-CpcNextStage($Row) {
    switch ([string]$Row.Phase) {
        'Mapped' { return 'Prepare' }
        { $_ -in @('IdentityPrepared','CaptureFailed','Capturing') } { return 'Capture' }
        'Staged' { return 'Import' }
        'Imported' { return 'License' }
        'LicenseUnknown' { throw 'License outcome is ambiguous. Use Reconcile license with reviewed audit evidence; Validate prerequisites cannot authorize another license assignment.' }
        default { throw "$($Row.VM): no new migration action is allowed in phase $($Row.Phase). Refresh/reconcile the current operation first. Use Validate cutover only after provisioning." }
    }
}

function Get-CpcPreflightFingerprint($Row) {
    $identity = [ordered]@{
        Plan = $script:S.PlanId; Tenant = $script:S.TenantId; Subscription = $script:S.SubscriptionId
        Config = $script:S.Config; Group = $script:S.GroupId; Setting = $script:S.UserSettingId
    }
    foreach ($key in @('VmId','VM','ResourceGroup','Location','UserPrincipalName','UserId','Phase','Guest','Attested',
        'SourceVmUniqueId','SourceDiskId','ObservedSourceVmUniqueId','ObservedSourceDiskId','SnapshotName','SnapshotId','VhdBlob','VmgsBlob','VhdCopyId','VmgsCopyId','ImportId','LicenseAssignedUtc')) {
        $identity[$key] = Get-Value $Row $key
    }
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([text.encoding]::UTF8.GetBytes(($identity | ConvertTo-Json -Depth 30 -Compress))))
}

function Assert-CpcPreflight($Rows, [string]$Action) {
    # Automatic checks cannot grant this approval. Only the explicit Validate prerequisites action can.
    foreach ($row in $Rows) {
        $approval = Get-Value $script:S.Preflight $row.VmId
        if (-not $approval -or $approval.Stage -ne $Action -or
            $approval.Fingerprint -ne (Get-CpcPreflightFingerprint $row) -or
            [datetimeoffset]::UtcNow -ge [datetimeoffset]::Parse($approval.ExpiresUtc) -or $row.Readiness -ne 'Ready') {
            throw "$($row.VM): click Validate prerequisites first and obtain PASS for $Action. Approval is single-use, expires after 30 minutes and is invalid after phase/configuration/evidence changes or journal reload. Final Validate cutover is a different step."
        }
    }
    foreach ($row in $Rows) { $script:S.Preflight.Remove($row.VmId) }
}

function Test-CpcStagedArtifacts($Row) {
    $snap = Assert-CpcOwnedSnapshot $Row
    if ((Get-Value $snap 'ProvisioningState') -ne 'Succeeded' -or (Get-Value $snap 'HyperVGeneration') -ne 'V2') { throw 'Snapshot must be successfully provisioned Generation 2.' }
    $size = [int](Get-Value $snap 'DiskSizeGB' 0)
    if ($size -le 0 -or $size -gt [int]$script:S.Config.TargetDiskGiB) { throw 'Snapshot disk size is missing or exceeds the selected license capacity.' }
    $trusted = (Get-Value (Get-Value $snap 'SecurityProfile') 'SecurityType' '') -eq 'TrustedLaunch'
    if ($trusted -and (-not $Row.VmgsBlob -or -not $Row.VmgsCopyId)) { throw 'Trusted Launch snapshot requires its matching VMGS blob and completed copy.' }
    $prefix = "$($script:S.PlanId)/$($Row.UserId)/$($Row.SnapshotName)/"
    $storage = Get-CpcStorage
    foreach ($part in @(@{ Name = $Row.VhdBlob; CopyId = $Row.VhdCopyId; OS = $true }, @{ Name = $Row.VmgsBlob; CopyId = $Row.VmgsCopyId; OS = $false })) {
        if (-not $part.Name -and -not $part.OS) { continue }
        if (-not $part.Name -or -not $part.CopyId -or -not $part.Name.StartsWith($prefix,[StringComparison]::Ordinal)) { throw 'Missing or unowned staging artifact / copy ID.' }
        $copy = Get-AzStorageBlobCopyState -Container $script:S.Config.Container -Blob $part.Name -Context $storage.Context
        if ([string]$copy.CopyId -ne $part.CopyId -or [string]$copy.Status -ne 'Success' -or
            [long]$copy.TotalBytes -le 0 -or [long]$copy.BytesCopied -ne [long]$copy.TotalBytes) { throw 'Staging copy must have the journaled copy ID and a complete successful byte count.' }
        $blob = Get-AzStorageBlob -Container $script:S.Config.Container -Blob $part.Name -Context $storage.Context
        if ($part.OS -and [string]$blob.BlobType -ne 'PageBlob') { throw 'OS VHD staging blob must be a PageBlob.' }
        if ($part.OS) {
            $sas = $null
            try { $sas = New-CpcBlobSas $storage.Context $part.Name 1; $null = Test-CpcVhdFooter $sas }
            finally { $sas = $null }
        }
    }
    Add-CpcCheck $Row.VM 'Snapshot / staged VHD / VMGS integrity' 'Pass' "Snapshot $($Row.SnapshotId); VHD $($Row.VhdBlob); copy $($Row.VhdCopyId). Ownership, Gen2, capacity, copy IDs/bytes, PageBlob and fixed VHD footer checksum checked. Footer is not a full-content integrity check."
}

function Test-CpcStageEvidence($Row, [string]$Stage) {
    if ($Stage -eq 'Import') { Test-CpcStagedArtifacts $Row }
    if ($Stage -eq 'License') {
        # Staging remains retained through provisioning; recheck it before trigger.
        Test-CpcStagedArtifacts $Row
        $result = Get-CpcImportResult $Row.ImportId
        if (-not (Test-CpcImportUserIdentity $result $Row) -or
            (Get-Value $result 'importStatus') -ne 'succeeded' -or
            (Get-Value $result 'usageStatus') -notin $(if ($Row.Phase -eq 'LicenseUnknown') { @('notUsed','inUse') } else { @('notUsed') })) {
            throw 'Live import must belong to the selected user, be succeeded and unused before a new license assignment.'
        }
        Add-CpcCheck $Row.VM 'Live import identity / completion' 'Pass' "Import $($Row.ImportId); user $($Row.UserPrincipalName) [$($Row.UserId)]; status $($result.importStatus); usage $($result.usageStatus)."
    }
}

function Test-CpcPreflight($Rows) {
    Assert-CpcContext
    foreach ($row in $Rows) { $script:S.Preflight.Remove($row.VmId) }
    $stages = @($Rows | ForEach-Object { Get-CpcNextStage $_ } | Select-Object -Unique)
    if ($stages.Count -ne 1) { throw 'Select rows at the same migration stage, then Validate prerequisites again.' }
    $stage = $stages[0]
    Test-CpcRows $Rows -Preparing:($stage -eq 'Prepare')
    foreach ($row in $Rows) {
        if ($row.Readiness -ne 'Ready') { continue }
        try { Test-CpcStageEvidence $row $stage }
        catch { $row.Readiness = 'Blocked'; Add-CpcCheck $row.VM 'Stage-specific validation' 'Fail' $_.Exception.Message }
    }
    # Entire selection must pass; no partial approval hidden inside a failing batch.
    if (@($Rows | Where-Object Readiness -NE 'Ready').Count) {
        Write-CpcLog 'Validation FAILED. No stage approvals issued. Review failed checks, fix them and click Validate prerequisites again.'
    } else {
        foreach ($row in $Rows) {
            $script:S.Preflight[$row.VmId] = @{
                Stage = $stage; ValidatedUtc = [datetime]::UtcNow.ToString('o')
                ExpiresUtc = [datetime]::UtcNow.AddMinutes(30).ToString('o'); Fingerprint = Get-CpcPreflightFingerprint $row
            }
        }
        Write-CpcLog "Validation PASSED for $stage. Single-use approval expires in 30 minutes; live prerequisites will still run again before changes."
    }
    Save-CpcState
}

function Invoke-CpcGuestAssessment($Rows) {
    Assert-CpcContext
    foreach ($row in $Rows) {
        if ($row.Phase -notin @('Mapped','IdentityPrepared','CaptureFailed') -or $row.SnapshotId -or (Get-Value $row 'SourceVmUniqueId')) { throw 'Guest evidence is frozen or this stage cannot be assessed. Refresh/review recovery; do not restart the captured source or create a replacement plan.' }
    }
    foreach ($row in $Rows) { $script:S.Preflight.Remove($row.VmId) }
    $guestScript = @'
$ErrorActionPreference = 'Stop'
$os = Get-CimInstance Win32_OperatingSystem
$edition = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').EditionID
$ds = (& dsregcmd.exe /status) -join "`n"
$joined = $ds -match 'AzureAdJoined\s*:\s*YES'
$tenant = if ($ds -match 'TenantId\s*:\s*([a-fA-F0-9-]{36})') { $Matches[1] } else { '' }
$known = $false; $encrypted = -1
try { $volumes = @(Get-BitLockerVolume -ErrorAction Stop); $encrypted = @($volumes | Where-Object { $_.VolumeStatus -ne 'FullyDecrypted' }).Count; $known = $true } catch {}
$apps = @(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match 'Citrix|Horizon|VMware|Omnissa|Anyware|Teradici|Remote Desktop Agent|Remote Desktop Services' } | Select-Object -ExpandProperty DisplayName -Unique)
$result = @{ ProductType = [int]$os.ProductType; Build = [int]$os.BuildNumber; Caption = $os.Caption; Edition = $edition; AzureAdJoined = $joined; TenantId = $tenant; BitLockerKnown = $known; EncryptedVolumes = $encrypted; AgentCandidates = @($apps | Select-Object -First 20); CheckedUtc = [datetime]::UtcNow.ToString('o') }
'CPC_GUEST_BEGIN' + ($result | ConvertTo-Json -Compress -Depth 5) + 'CPC_GUEST_END'
'@
    foreach ($row in $Rows) {
        Assert-CpcContinue
        $status = Get-AzVM -ResourceGroupName $row.ResourceGroup -Name $row.VM -Status
        if (@($status.Statuses | Where-Object Code -EQ 'PowerState/running').Count -ne 1) { throw "$($row.VM) must be running for guest assessment. The app will not automatically start it." }
        Write-CpcLog "Running read-only guest assessment through Azure Run Command on $($row.VM)."
        $r = Invoke-AzVMRunCommand -ResourceGroupName $row.ResourceGroup -VMName $row.VM -CommandId RunPowerShellScript -ScriptString $guestScript
        $message = ($r.Value | ForEach-Object Message) -join "`n"
        if ($message -notmatch '(?s)CPC_GUEST_BEGIN(.*?)CPC_GUEST_END') { throw 'Guest assessment did not return valid evidence; inspect Run Command in Azure.' }
        $row.Guest = $Matches[1] | ConvertFrom-Json -AsHashtable
        $agent = Get-Value $status 'VMAgent'
        $agentStatuses = @(Get-Value $agent 'Statuses' @())
        $row.Guest.AgentReady = @($agentStatuses | Where-Object { $_.Code -eq 'ProvisioningState/succeeded' }).Count -gt 0
        $row.Attested = $false
        $row.Readiness = 'NotChecked'
        Save-CpcState
        Write-CpcLog "$($row.VM): $($row.Guest.Caption); detected agent candidates: $($row.Guest.AgentCandidates -join ', '). This is not an exhaustive third-party-agent inventory."
    }
}

function Prepare-CpcIdentity($Rows) {
    Assert-CpcContext
    Assert-CpcPreflight $Rows 'Prepare'
    $existingGroup = [string](Get-Value $script:S.Config 'ExistingGroupId')
    if ($existingGroup -and (@($Rows).Count -ne $script:S.Rows.Count)) { throw 'Prepare applies a group-wide setting: select every row in this batch and validate together.' }
    if (@($Rows | Where-Object { $_.Phase -notin @('Mapped','IdentityPrepared') }).Count) { throw 'Identity preparation is only allowed before capture.' }
    Test-CpcRows $Rows -Preparing
    if (@($Rows | Where-Object Readiness -NE 'Ready').Count) { throw 'All selected rows must pass prerequisite checks before preparing identity.' }
    if ($existingGroup) {
        $null = Assert-CpcSelectedGroup $script:S.Config @($script:S.Rows)
        $script:S.GroupId = $existingGroup
        Save-CpcState
    }
    # Legacy journals without ExistingGroupId retain the original dedicated-group flow.
    if (-not $script:S.GroupId) {
        $name = 'CPCMigration-' + $script:S.PlanId
        $existing = @(Get-CpcGraphCollection "/v1.0/groups?`$filter=displayName eq '$name'&`$select=id,displayName")
        if ($existing.Count) { throw 'A same-named group already exists but is not journaled. Reconcile the previous request before retrying.' }
        $group = Invoke-CpcGraph -Method POST -Path '/v1.0/groups' -Body @{
            displayName = $name; description = "Dedicated migration group; plan $($script:S.PlanId)"; mailEnabled = $false; mailNickname = ('cpcm' + $script:S.PlanId.Replace('-','')); securityEnabled = $true; groupTypes = @()
        }
        $script:S.GroupId = $group.id
        Save-CpcState
    }
    if (-not $script:S.UserSettingId) {
        $settingName = 'Snapshot-' + $script:S.PlanId
        $existing = @(Get-CpcGraphCollection "$script:Endpoint/userSettings" | Where-Object { $_.displayName -eq $settingName })
        if ($existing.Count) { throw 'A same-named user setting exists but is not journaled. Reconcile before retry.' }
        $setting = Invoke-CpcGraph -Method POST -Path "$script:Endpoint/userSettings" -Body @{
            displayName = $settingName; provisioningSourceType = 'snapshot'; localAdminEnabled = $false; resetEnabled = $false
        }
        $script:S.UserSettingId = $setting.id
        Save-CpcState
    }
    $target = @{ '@odata.type' = '#microsoft.graph.cloudPcManagementGroupAssignmentTarget'; groupId = $script:S.GroupId }
    if ($existingGroup) {
        $null = Assert-CpcSelectedGroup $script:S.Config @($script:S.Rows)
        $setting = Invoke-CpcGraph -Path "$script:Endpoint/userSettings/$($script:S.UserSettingId)?`$expand=assignments"
        if ((Get-Value $setting 'displayName') -ne "Snapshot-$($script:S.PlanId)" -or (Get-Value $setting 'provisioningSourceType') -ne 'snapshot' -or
            @((Get-Value $setting 'assignments' @()) | Where-Object { -not (Test-CpcGroupTarget (Get-Value $_ 'target')) -or $_.target.groupId -ne $existingGroup }).Count) {
            throw 'Snapshot setting ownership, snapshot mode or assignment scope changed. Review the setting and use the controlled repair action; refusing to assign an image setting or overwrite unrelated targets.'
        }
    }
    $null = Invoke-CpcGraph -Method POST -Path "$script:Endpoint/userSettings/$($script:S.UserSettingId)/assign" -Body @{ assignments = @(@{ target = $target }) }
    if ($existingGroup) {
        foreach ($row in $Rows) { $row.Phase = 'IdentityPrepared'; $row.Readiness = 'NotChecked' }
        Save-CpcState
        Write-CpcLog "Snapshot user setting assigned to the explicitly selected existing group $existingGroup. Existing policy assignment and membership unchanged. Wait for propagation and validate again; no license assigned."
        return
    }
    $policyPath = "$script:Endpoint/provisioningPolicies/$($script:S.Config.PolicyId)"
    $current = Invoke-CpcGraph -Path "$policyPath`?`$expand=assignments"
    $assignments = @((Get-Value $current 'assignments' @()) | ForEach-Object { @{ target = $_.target } })
    if (@($assignments | Where-Object { $_.target.groupId -eq $script:S.GroupId }).Count -eq 0) {
        # assign replaces the collection. Preserve current targets; require an exclusive admin window.
        $assignments += @{ target = $target }
        $null = Invoke-CpcGraph -Method POST -Path "$policyPath/assign" -Body @{ assignments = $assignments }
    }
    $members = @(Get-CpcGraphCollection "/v1.0/groups/$($script:S.GroupId)/members?`$select=id" | ForEach-Object { $_.id })
    foreach ($row in $Rows) {
        Assert-CpcContinue
        if ($row.UserId -notin $members) {
            $null = Invoke-CpcGraph -Method POST -Path "/v1.0/groups/$($script:S.GroupId)/members/`$ref" -Body @{ '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$($row.UserId)" }
        }
        $row.Phase = 'IdentityPrepared'; $row.Readiness = 'NotChecked'
        Save-CpcState
    }
    Write-CpcLog 'Dedicated snapshot setting/group and policy assignment prepared. Wait for assignment propagation, then check prerequisites again. No license assigned.'
}

function Repair-CpcSnapshotAssignments {
    Assert-CpcContext
    Assert-CpcConfig
    if (-not $script:S.StatePath) { throw 'Save the plan before Graph repairs; an automatic journal is required.' }
    $rows = @($script:S.Rows)
    if (-not $rows.Count -or -not $script:S.GroupId -or -not $script:S.UserSettingId) {
        throw 'Use 4 Prepare snapshot provisioning for initial group/user-setting creation. Repair requires both plan-owned IDs already recorded.'
    }
    if (@($rows | Where-Object { $_.LicenseAssignedUtc -or $_.Phase -notin @('Mapped','IdentityPrepared','Staged','Imported','CaptureFailed') }).Count) {
        throw 'Repair applies to the entire batch and is restricted to known pre-provisioning phases. Reconcile in-flight/unknown operations or licensed users first.'
    }
    $groupId = Assert-CpcGuid $script:S.GroupId 'Migration group ID'
    $settingId = Assert-CpcGuid $script:S.UserSettingId 'Snapshot user setting ID'
    $existingGroup = [string](Get-Value $script:S.Config 'ExistingGroupId')
    if ($existingGroup) { $null = Assert-CpcSelectedGroup $script:S.Config $rows }
    $group = Invoke-CpcGraph -Path "/v1.0/groups/$groupId`?`$select=id,displayName,securityEnabled,groupTypes,onPremisesSyncEnabled,assignedLicenses"
    if ((-not $existingGroup -and (Get-Value $group 'displayName') -ne "CPCMigration-$($script:S.PlanId)") -or (Get-Value $group 'securityEnabled') -ne $true -or
        (Get-Value $group 'onPremisesSyncEnabled' $false) -eq $true -or 'DynamicMembership' -in @(Get-Value $group 'groupTypes' @())) {
        throw 'Migration group ownership/type changed. Repair will not modify an unrelated, synced or dynamic group.'
    }
    $parentGroups = @(Get-CpcGraphCollection "/v1.0/groups/$groupId/transitiveMemberOf/microsoft.graph.group?`$select=id,assignedLicenses")
    if (@(Get-Value $group 'assignedLicenses' @()).Count -or @($parentGroups | Where-Object { @(Get-Value $_ 'assignedLicenses' @()).Count }).Count) {
        throw 'Migration group or an ancestor group carries license assignments. Repair refuses membership changes that could trigger provisioning early.'
    }
    $settingPath = "$script:Endpoint/userSettings/$settingId"
    $setting = Invoke-CpcGraph -Path "$settingPath`?`$expand=assignments"
    if ((Get-Value $setting 'displayName') -ne "Snapshot-$($script:S.PlanId)") { throw 'Snapshot user setting ownership mismatch; no repair performed.' }
    $settingAssignments = @(Get-Value $setting 'assignments' @())
    if (@($settingAssignments | Where-Object { (Get-Value (Get-Value $_ 'target') 'groupId') -ne $groupId }).Count) {
        throw 'Snapshot setting has unrelated/unknown assignment targets. Review those manually; repair will not remove or affect them.'
    }
    $members = @(Get-CpcGraphCollection "/v1.0/groups/$groupId/members?`$select=id")
    $batchIds = @($rows | ForEach-Object { Assert-CpcGuid $_.UserId 'Mapped user ID' })
    if (@($members | Where-Object { (Get-Value $_ 'id') -notin $batchIds }).Count) { throw 'Migration group contains non-batch members; no repair performed.' }
    $policies = @(Get-CpcGraphCollection "$script:Endpoint/provisioningPolicies?`$expand=assignments")
    $chosen = @($policies | Where-Object { $_.id -eq $script:S.Config.PolicyId })
    if ($chosen.Count -ne 1 -or -not (Test-CpcPolicyTarget $chosen[0])) { throw 'Select an accessible Windows 365 dedicated desktop policy before repair.' }
    $settings = @(Get-CpcGraphCollection "$script:Endpoint/userSettings?`$expand=assignments")
    $pcs = @(Get-CpcGraphCollection "$script:Endpoint/cloudPCs")
    $skus = @(Get-CpcGraphCollection '/v1.0/subscribedSkus')
    $cloudSkuIds = @($skus | Where-Object {
        ((Get-Value $_ 'skuPartNumber' '') + ',' + ((@(Get-Value $_ 'servicePlans' @()) | ForEach-Object { Get-Value $_ 'servicePlanName' '' }) -join ',')) -match '(?i)CLOUDPC|WINDOWS[_ ]?365|CPC_'
    } | ForEach-Object { $_.skuId })
    # Complete all scope/identity checks before any Graph write. Do not auto-remove conflicts.
    foreach ($row in $rows) {
        $user = Invoke-CpcGraph -Path "/v1.0/users/$($row.UserId)?`$select=id,userPrincipalName,accountEnabled,assignedLicenses"
        if ((Get-Value $user 'id') -ne $row.UserId -or (Get-Value $user 'userPrincipalName') -ne $row.UserPrincipalName -or (Get-Value $user 'accountEnabled') -ne $true) { throw 'Target user identity/enablement changed; repair blocked.' }
        if (@($pcs | Where-Object { (Get-Value $_ 'userId') -eq $row.UserId -or (Get-Value $_ 'userPrincipalName') -eq $row.UserPrincipalName }).Count -or
            @(@(Get-Value $user 'assignedLicenses' @()) | Where-Object { $_.skuId -eq $script:S.Config.SkuId -or $_.skuId -in $cloudSkuIds }).Count) {
            throw 'Target user already has a Cloud PC or Windows 365 license; repair could trigger provisioning and is blocked.'
        }
        $groups = @(Get-CpcGraphCollection "/v1.0/users/$($row.UserId)/transitiveMemberOf/microsoft.graph.group?`$select=id" | ForEach-Object { $_.id }) + @($groupId)
        foreach ($object in @($policies | Where-Object { $_.id -ne $script:S.Config.PolicyId }) + @($settings | Where-Object { $_.id -ne $settingId })) {
            if (@(@(Get-Value $object 'assignments' @()) | Where-Object { (Get-Value (Get-Value $_ 'target') 'groupId') -in $groups }).Count) { throw 'Conflicting policy/user setting would apply to a batch user; resolve it in Intune before repair.' }
        }
    }
    $script:S.Preflight.Clear()
    $script:S.Checks.Clear()
    foreach ($row in $rows) { $row.Readiness = 'NotChecked'; $row.Attested = $false }
    Save-CpcState
    Assert-CpcContinue
    $null = Invoke-CpcGraph -Method PATCH -Path $settingPath -Body (New-CpcUserSettingSourceBody $setting 'snapshot')
    $target = @{ '@odata.type' = '#microsoft.graph.cloudPcManagementGroupAssignmentTarget'; groupId = $groupId }
    if ($existingGroup) { $null = Assert-CpcSelectedGroup $script:S.Config $rows }
    $null = Invoke-CpcGraph -Method POST -Path "$settingPath/assign" -Body @{ assignments = @(@{ target = $target }) }
    if ($existingGroup) {
        Add-CpcCheck 'Batch' 'Repair submitted; validation required' 'Manual' "Snapshot setting $settingId -> selected existing group $groupId. No group membership or policy assignments modified. Re-attest and validate after propagation."
        Save-CpcState
        return
    }
    $policyPath = "$script:Endpoint/provisioningPolicies/$($script:S.Config.PolicyId)"
    # Re-read immediately before a replace-collection API; exclusive admin window still required.
    $current = Invoke-CpcGraph -Path "$policyPath`?`$expand=assignments"
    $assignments = @(@(Get-Value $current 'assignments' @()) | ForEach-Object { @{ target = $_.target } })
    if (-not @($assignments | Where-Object { (Get-Value $_.target 'groupId') -eq $groupId }).Count) {
        $null = Invoke-CpcGraph -Method POST -Path "$policyPath/assign" -Body @{ assignments = @($assignments) + @(@{ target = $target }) }
    }
    foreach ($row in $rows) {
        Assert-CpcContinue
        if ($row.UserId -notin @($members | ForEach-Object { $_.id })) {
            $null = Invoke-CpcGraph -Method POST -Path "/v1.0/groups/$groupId/members/`$ref" -Body @{ '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$($row.UserId)" }
        }
    }
    Add-CpcCheck 'Batch' 'Repair submitted; validation required' 'Manual' "Snapshot setting $settingId -> group $groupId -> policy $($script:S.Config.PolicyId). Wait for Graph assignment propagation. Customer/admin must re-attest and click Validate prerequisites; this operation does NOT approve provisioning."
    Save-CpcState
    Write-CpcLog 'Graph snapshot configuration/assignment repair submitted. No import/license assigned. Customer attestation and explicit prerequisite validation are required again.'
}

function Assert-CpcOwnedSnapshot($Row) {
    $snap = Get-AzSnapshot -ResourceGroupName $script:S.Config.SnapshotResourceGroup -SnapshotName $Row.SnapshotName
    if ($snap.Tags['CpcMigrationPlan'] -ne $script:S.PlanId -or $snap.Tags['SourceVmId'] -ne $Row.VmId) {
        throw 'Snapshot ownership mismatch. Refusing to export or delete.'
    }
    if ([string]$snap.Id -ne $Row.SnapshotId -or [string]$snap.CreationData.SourceResourceId -ne $Row.SourceDiskId) { throw 'Snapshot source disk/resource identity mismatch.' }
    return $snap
}

function Start-CpcCapture($Rows) {
    Assert-CpcContext
    Assert-CpcPreflight $Rows 'Capture'
    Test-CpcRows $Rows
    if (@($Rows | Where-Object Readiness -NE 'Ready').Count) { throw 'Batch prerequisites changed before capture; no VM stopped.' }
    foreach ($row in $Rows) {
        Assert-CpcContinue
        if ($row.Phase -notin @('IdentityPrepared','CaptureFailed','Capturing')) { throw "$($row.VM): capture not permitted in phase $($row.Phase)." }
        # Recheck immediately before downtime; never trust cached UI readiness.
        Test-CpcRows @($row)
        if ($row.Readiness -ne 'Ready') { throw "$($row.VM) is not ready. Inspect prerequisite results." }
        $vm = Get-AzVM -ResourceGroupName $row.ResourceGroup -Name $row.VM
        $trusted = [string](Get-Value $vm.SecurityProfile 'SecurityType' '') -eq 'TrustedLaunch'
        if (-not $row.SnapshotName) {
            $row.SourceVmUniqueId = [string]$vm.VmId
            $row.SourceDiskId = [string]$vm.StorageProfile.OsDisk.ManagedDisk.Id
            if (-not $row.SourceVmUniqueId -or -not $row.SourceDiskId) { throw 'Source immutable VM ID / OS disk ID missing.' }
            $row.SnapshotName = 'cpcm-' + [guid]::NewGuid().ToString('N')
            $row.SnapshotId = "/subscriptions/$($script:S.SubscriptionId)/resourceGroups/$($script:S.Config.SnapshotResourceGroup)/providers/Microsoft.Compute/snapshots/$($row.SnapshotName)"
            $prefix = "$($script:S.PlanId)/$($row.UserId)/$($row.SnapshotName)"
            $row.VhdBlob = "$prefix/$($row.SnapshotName)-os.vhd"
            if ($trusted) { $row.VmgsBlob = "$prefix/$($row.SnapshotName)-gueststate.vhd" }
        }
        $row.Phase = 'Capturing'
        if (-not $row.CaptureStartedUtc) { $row.CaptureStartedUtc = [datetime]::UtcNow.ToString('o') }
        Save-CpcState
        try {
            Write-CpcLog "Deallocating $($row.VM). It remains stopped after capture; no automatic restart or source deletion."
            Stop-AzVM -ResourceGroupName $row.ResourceGroup -Name $row.VM -Force | Out-Null
            $status = Get-AzVM -ResourceGroupName $row.ResourceGroup -Name $row.VM -Status
            if (@($status.Statuses | Where-Object Code -EQ 'PowerState/deallocated').Count -ne 1) { throw 'VM is not deallocated. No snapshot will be created.' }
            Assert-CpcContinue
            $existing = @(Get-AzSnapshot -ResourceGroupName $script:S.Config.SnapshotResourceGroup | Where-Object Name -EQ $row.SnapshotName)
            if (-not $existing.Count) {
                $properties = @{ creationData = @{ createOption = 'Copy'; sourceResourceId = $vm.StorageProfile.OsDisk.ManagedDisk.Id }; hyperVGeneration = 'V2' }
                if ($trusted) { $properties.securityProfile = @{ securityType = 'TrustedLaunch' } }
                $payload = @{ location = $row.Location; sku = @{ name = 'Standard_LRS' }; tags = @{ CpcMigrationPlan = $script:S.PlanId; SourceVmId = $row.VmId }; properties = $properties }
                Write-CpcAudit 'CreateSnapshot' @{ SnapshotId = $row.SnapshotId; SourceVmId = $row.VmId; SourceDiskId = $row.SourceDiskId }
                $result = Invoke-AzRestMethod -Method PUT -Path "$($row.SnapshotId)?api-version=2024-03-02" -Payload ($payload | ConvertTo-Json -Depth 12)
                if ($result.StatusCode -notin @(200,201,202)) { throw "Snapshot creation rejected ($($result.StatusCode))." }
                $deadline = [datetime]::UtcNow.AddMinutes(20)
                do {
                    Assert-CpcContinue
                    $snap = Assert-CpcOwnedSnapshot $row
                    if ($snap.ProvisioningState -eq 'Failed') { throw 'Snapshot provisioning failed.' }
                    if ($snap.ProvisioningState -eq 'Succeeded') { break }
                    if ([datetime]::UtcNow -gt $deadline) { throw 'Snapshot creation timeout. The server may still be working; reconcile before retry.' }
                    Start-Sleep -Seconds 5
                } while ($true)
            }
            $snap = Assert-CpcOwnedSnapshot $row
            if ($snap.ProvisioningState -ne 'Succeeded') { throw 'Snapshot is not ready.' }
            $row.ExportExpiresUtc = [datetime]::UtcNow.AddHours(24).ToString('o')
            Save-CpcState
            $grant = @{ ResourceGroupName = $script:S.Config.SnapshotResourceGroup; SnapshotName = $row.SnapshotName; Access = 'Read'; DurationInSecond = 86400 }
            if ($trusted) { $grant.SecureVMGuestStateSAS = $true }
            Write-CpcAudit 'GrantSnapshotExport' @{ SnapshotId = $row.SnapshotId; ExpiresUtc = $row.ExportExpiresUtc; VMGS = $trusted }
            $access = Grant-AzSnapshotAccess @grant
            if (-not $access.AccessSAS) { throw 'No OS disk export SAS returned.' }
            if ($trusted -and -not $access.SecurityDataAccessSAS) { throw 'Trusted Launch requires VMGS. Azure returned no SecurityDataAccessSAS.' }
            $storage = Get-CpcStorage
            foreach ($part in @(@{ Blob = $row.VhdBlob; Url = $access.AccessSAS; Key = 'VhdCopyId' }, @{ Blob = $row.VmgsBlob; Url = (Get-Value $access 'SecurityDataAccessSAS'); Key = 'VmgsCopyId' })) {
                if (-not $part.Blob) { continue }
                Assert-CpcContinue
                if ($row[$part.Key]) { continue }
                # Unique names; never overwrite an unjournaled blob after an ambiguous request.
                $existingBlobs = @(Get-AzStorageBlob -Container $script:S.Config.Container -Prefix $part.Blob -Context $storage.Context | Where-Object Name -EQ $part.Blob)
                if ($existingBlobs.Count) { throw 'Unjournaled staging blob exists. Reconcile it before retrying; overwrite refused.' }
                Write-CpcAudit 'StartBlobCopy' @{ SnapshotId = $row.SnapshotId; Destination = $part.Blob }
                $null = Start-AzStorageBlobCopy -AbsoluteUri $part.Url -DestContainer $script:S.Config.Container -DestBlob $part.Blob -DestContext $storage.Context
                $copyState = Get-AzStorageBlobCopyState -Blob $part.Blob -Container $script:S.Config.Container -Context $storage.Context
                $row[$part.Key] = [string]$copyState.CopyId
                if (-not $row[$part.Key]) { throw 'Copy was submitted but returned no copy ID. Reconcile in Azure; do not resubmit blindly.' }
                Save-CpcState
            }
            $row.Phase = 'Copying'; $row.Readiness = 'NotChecked'; Save-CpcState
            Write-CpcLog "$($row.VM): server-side blob copies started. Use Refresh status; export SAS expires after 24 hours."
        } catch {
            $row.Phase = 'CaptureFailed'; $row.LastError = Protect-CpcText $_.Exception.Message
            Save-CpcState
            throw
        } finally { $access = $null }
    }
}

function Test-CpcVhdFooter([string]$SasUrl) {
    # Range-only check; never download a whole disk or write a SAS to disk.
    $head = Invoke-WebRequest -Uri $SasUrl -Method Head
    $length = [long]($head.Headers['Content-Length'] | Select-Object -First 1)
    if ($length -lt 512 -or ($length % 512) -ne 0) { throw 'Invalid VHD length.' }
    $response = Invoke-WebRequest -Uri $SasUrl -Headers @{ Range = "bytes=$($length - 512)-$($length - 1)" }
    if ($response.StatusCode -ne 206) { throw 'Storage did not honor the VHD footer range request.' }
    $bytes = $response.RawContentStream.ToArray()
    if ($bytes.Length -ne 512 -or [text.encoding]::ASCII.GetString($bytes,0,8) -ne 'conectix') { throw 'Invalid VHD footer cookie.' }
    $type = ([uint32]$bytes[60] -shl 24) -bor ([uint32]$bytes[61] -shl 16) -bor ([uint32]$bytes[62] -shl 8) -bor [uint32]$bytes[63]
    if ($type -ne 2) { throw 'Only fixed-format VHD (disk type 2) is supported.' }
    $stored = ([uint32]$bytes[64] -shl 24) -bor ([uint32]$bytes[65] -shl 16) -bor ([uint32]$bytes[66] -shl 8) -bor [uint32]$bytes[67]
    $sum = [uint32]0
    for ($i=0; $i -lt 512; $i++) { if ($i -lt 64 -or $i -gt 67) { $sum += $bytes[$i] } }
    if (([uint32]::MaxValue - $sum) -ne $stored) { throw 'VHD footer checksum mismatch.' }
    return $true
}

function New-CpcBlobSas($Context, [string]$Blob, [int]$Hours = 24) {
    New-AzStorageBlobSASToken -Container $script:S.Config.Container -Blob $Blob -Context $Context -Permission r -Protocol HttpsOnly -StartTime ([datetime]::UtcNow.AddMinutes(-5)) -ExpiryTime ([datetime]::UtcNow.AddHours($Hours)) -FullUri
}

function Start-CpcImport($Rows) {
    Assert-CpcContext
    Assert-CpcPreflight $Rows 'Import'
    Test-CpcRows $Rows
    if (@($Rows | Where-Object Readiness -NE 'Ready').Count) { throw 'Batch prerequisites changed before import; no import submitted.' }
    foreach ($row in $Rows) { Test-CpcStagedArtifacts $row }
    foreach ($row in $Rows) {
        Assert-CpcContinue
        if ($row.Phase -ne 'Staged') { throw "$($row.VM): import requires Staged, not $($row.Phase)." }
        Test-CpcRows @($row)
        if ($row.Readiness -ne 'Ready') { throw 'Prerequisites changed. Resolve failures before import.' }
        Test-CpcStagedArtifacts $row
        $status = Get-AzVM -ResourceGroupName $row.ResourceGroup -Name $row.VM -Status
        if (@($status.Statuses | Where-Object Code -EQ 'PowerState/deallocated').Count -ne 1) { throw 'Source VM was restarted. Refusing a stale-image cutover; start a new plan after reconciliation.' }
        $storage = Get-CpcStorage
        $vhd = Get-AzStorageBlob -Container $script:S.Config.Container -Blob $row.VhdBlob -Context $storage.Context
        if ([string]$vhd.BlobType -ne 'PageBlob') { throw 'OS VHD staging blob must be a PageBlob.' }
        $sas = New-CpcBlobSas $storage.Context $row.VhdBlob 48
        $vmgsSas = if ($row.VmgsBlob) { New-CpcBlobSas $storage.Context $row.VmgsBlob 48 } else { '' }
        try {
            $null = Test-CpcVhdFooter $sas
            $body = New-CpcImportBody $row.UserId $sas $vmgsSas
            $row.Phase = 'ImportSubmitting'; $row.ImportStartedUtc = [datetime]::UtcNow.ToString('o')
            $row.ImportSasExpiresUtc = [datetime]::UtcNow.AddHours(48).ToString('o')
            Save-CpcState
            $result = Invoke-CpcGraph -Method POST -Path "$script:Endpoint/snapshots/importSnapshot" -Body $body
            $row.ImportId = [string](Get-Value $result 'snapshotId' '')
            $row.ImportStatus = [string](Get-Value $result 'importStatus' '')
            $row.UsageStatus = [string](Get-Value $result 'usageStatus' '')
            if (-not $row.ImportId) {
                $row.Phase = 'ImportUnknown'
                throw 'Import may be accepted but returned no snapshotId. Reconcile the import ID using service results/support; do NOT repeat import.'
            }
            $row.Phase = 'Importing'
            $row.Readiness = 'NotChecked'
            Save-CpcState
            Write-CpcLog "$($row.VM): import accepted, snapshot $($row.ImportId). No license assigned yet."
        } catch {
            if ($row.Phase -eq 'ImportSubmitting') { $row.Phase = 'ImportUnknown' }
            $row.LastError = Protect-CpcText $_.Exception.Message
            Save-CpcState
            throw
        } finally { $sas = $null; $vmgsSas = $null; $body = $null }
    }
}

function Update-CpcStatus($Rows) {
    Assert-CpcContext
    $script:RefreshSucceededIds.Clear()
    $pcs = @(Get-CpcGraphCollection "$script:Endpoint/cloudPCs")
    foreach ($row in $Rows) {
        Assert-CpcContinue
        $priorPhase = $row.Phase
        $row.LastError = ''
        try {
            if ($row.Phase -eq 'Copying') {
                $storage = Get-CpcStorage
                if (-not $row.VhdBlob -or -not $row.VhdCopyId -or ([bool]$row.VmgsBlob -ne [bool]$row.VmgsCopyId)) { throw 'Missing staging artifact/copy IDs. Review the journal and Azure copy evidence; do not import or recapture blindly.' }
                $finished = $true
                $progress = [collections.generic.list[string]]::new()
                foreach ($blob in @($row.VhdBlob,$row.VmgsBlob) | Where-Object { $_ }) {
                    $copy = Get-AzStorageBlobCopyState -Container $script:S.Config.Container -Blob $blob -Context $storage.Context
                    $label = if ($blob -eq $row.VhdBlob) { 'OS VHD' } else { 'VMGS' }
                    $progress.Add("${label}: $($copy.Status) $($copy.BytesCopied)/$($copy.TotalBytes) bytes")
                    $row.Detail = ($progress -join ' | ') + '. Refresh until Staged; one successful artifact does not mean all copies are complete.'
                    if ([string]$copy.Status -in @('Failed','Aborted')) { $row.Phase = 'CopyFailed'; throw "Blob copy $($copy.Status). Revoke export and reconcile staging. No automatic overwrite." }
                    $expectedId = if ($blob -eq $row.VhdBlob) { $row.VhdCopyId } else { $row.VmgsCopyId }
                    if ([string]$copy.CopyId -ne $expectedId) { throw 'Staging copy ID differs from the journal. Refusing to use changed content.' }
                    if ([string]$copy.Status -ne 'Success') { $finished = $false }
                    elseif ([long]$copy.TotalBytes -le 0 -or [long]$copy.BytesCopied -ne [long]$copy.TotalBytes) { throw 'Copy reported Success with incomplete/unknown bytes. Staging remains blocked; review copy evidence.' }
                }
                if ($finished) {
                    $snapshot = Assert-CpcOwnedSnapshot $row
                    if ((Get-Value (Get-Value $snapshot 'SecurityProfile') 'SecurityType') -eq 'TrustedLaunch' -and -not $row.VmgsBlob) { throw 'Trusted Launch requires the matching VMGS copy. Staging cannot complete without it.' }
                    Revoke-AzSnapshotAccess -ResourceGroupName $script:S.Config.SnapshotResourceGroup -SnapshotName $row.SnapshotName | Out-Null
                    $row.Phase = 'Staged'; $row.Detail = 'All server-side copies succeeded; snapshot export access revoked.'
                }
            }
            if ($row.ImportId -and $row.Phase -notin @('Purged','Cleaned')) {
                try {
                    $r = Get-CpcImportResult $row.ImportId
                    if (-not (Test-CpcImportUserIdentity $r $row)) { throw 'Imported snapshot/user mismatch or missing user identity. Expected the journaled user UPN or its exact Entra object ID.' }
                    $row.ImportStatus = [string](Get-Value $r 'importStatus' '')
                    $row.UsageStatus = [string](Get-Value $r 'usageStatus' '')
                    $row.Detail = Protect-CpcText ([string](Get-Value $r 'additionalDetail' ''))
                    if ($row.Phase -in @('Importing','ImportUnknown')) {
                        if ($row.ImportStatus -eq 'succeeded' -and $row.UsageStatus -eq 'notUsed') { $row.Phase = 'Imported' }
                        elseif ($row.ImportStatus -eq 'failed') { $row.Phase = 'ImportFailed' }
                    }
                } catch {
                    # Imported artifacts can be cleaned up by the service after provisioning.
                    # Preserve historical success, but NEVER describe a failed read as success.
                    $row.LastError = 'Import lookup unavailable; historical result retained: ' + (Protect-CpcText $_.Exception.Message)
                    Write-CpcLog "$($row.VM): $($row.LastError)"
                }
            }
            $matchingPcs = @($pcs | Where-Object { (Get-Value $_ 'userId') -eq $row.UserId -or (Get-Value $_ 'userPrincipalName') -eq $row.UserPrincipalName })
            if ($matchingPcs.Count -eq 1) {
                $row.CloudPcId = $matchingPcs[0].id; $row.CloudPcStatus = $matchingPcs[0].status
                $row.CloudPcName = [string](Get-Value $matchingPcs[0] 'displayName' '')
                if ($row.LicenseAssignedUtc -and $row.CloudPcStatus -eq 'provisioned' -and $row.Phase -in @('Provisioning','Provisioned')) { $row.Phase = 'Provisioned' }
            } elseif ($matchingPcs.Count -gt 1) { $row.LastError = 'Multiple Cloud PCs found for target user. Manual correlation required.' }
            Update-CpcTimingWarning $row
            if ($row.Phase -ne $priorPhase) { $script:S.Preflight.Remove($row.VmId); $row.Readiness = 'NotChecked' }
            Save-CpcState
            if (-not $row.LastError) { $null = $script:RefreshSucceededIds.Add($row.VmId) }
        } catch { $row.LastError = Protect-CpcText $_.Exception.Message; Write-CpcLog "$($row.VM): $($row.LastError)"; Save-CpcState }
    }
}

function Update-CpcTimingWarning($Row) {
    for ($i = $script:S.Checks.Count - 1; $i -ge 0; $i--) {
        if ($script:S.Checks[$i].VM -eq $Row.VM -and $script:S.Checks[$i].Check -eq 'Elapsed time / SAS expiry') { $script:S.Checks.RemoveAt($i) }
    }
    $messages = [collections.generic.list[string]]::new()
    $start = ''; $expires = ''; $limit = 2
    switch ($Row.Phase) {
        { $_ -in @('Capturing','CaptureFailed','Copying','CopyFailed') } { $start = [string](Get-Value $Row 'CaptureStartedUtc'); $expires = [string](Get-Value $Row 'ExportExpiresUtc') }
        { $_ -in @('Importing','ImportUnknown') } { $start = [string](Get-Value $Row 'ImportStartedUtc'); $expires = [string](Get-Value $Row 'ImportSasExpiresUtc'); $limit = 6 }
        { $_ -in @('Provisioning','LicenseUnknown') } { $start = [string](Get-Value $Row 'LicenseStartedUtc' (Get-Value $Row 'LicenseAssignedUtc')); $limit = 2 }
    }
    $now = [datetimeoffset]::UtcNow
    if ($start) {
        $elapsed = ($now - [datetimeoffset]::Parse($start)).TotalHours
        if ($elapsed -ge $limit) { $messages.Add("$($Row.Phase) age $([math]::Round($elapsed,1))h exceeds the operator review threshold ($limit h), not a service SLA. Investigate; do not resubmit automatically.") }
    }
    if ($expires) {
        $remaining = ([datetimeoffset]::Parse($expires) - $now).TotalHours
        if ($remaining -le 2) { $messages.Add("Recorded SAS expiry: $expires ($([math]::Round($remaining,1))h remaining). Completion/renewal requires review; expiry alone is not proof of failure.") }
    }
    $Row.TimingWarning = $messages -join ' '
    if ($messages.Count) { Add-CpcCheck $Row.VM 'Elapsed time / SAS expiry' 'Manual' $Row.TimingWarning }
}

function Start-CpcLicense($Rows) {
    Assert-CpcContext
    if (@($Rows | Where-Object Phase -NE 'Imported').Count) { throw 'Assign license only from Imported. For LicenseUnknown use Reconcile license with reviewed audit evidence; no automatic assignment-time inference or repeat write.' }
    Assert-CpcPreflight $Rows 'License'
    Test-CpcRows $Rows
    if (@($Rows | Where-Object Readiness -NE 'Ready').Count) { throw 'Pre-license prerequisites changed; no license assigned.' }
    foreach ($row in $Rows) { Test-CpcStageEvidence $row 'License' }
    Update-CpcLicenseCatalog
    # Applies even to license reconciliation / loaded journals, not just the picker.
    $null = Assert-CpcLicenseTarget $script:S.Catalog.Skus $script:S.Config.SkuId 0 ([int]$script:S.Config.TargetDiskGiB)
    foreach ($row in $Rows) {
        Assert-CpcContinue
        if ($row.Phase -ne 'Imported') { throw 'Assign license only after import success.' }
        $r = Get-CpcImportResult $row.ImportId
        if (-not (Test-CpcImportUserIdentity $r $row)) { throw 'Import/user identity mismatch.' }
        $user = Invoke-CpcGraph -Path "/v1.0/users/$($row.UserId)?`$select=id,usageLocation,assignedLicenses,accountEnabled"
        if ($user.accountEnabled -ne $true) { throw 'Target account is disabled.' }
        $assigned = @($user.assignedLicenses | ForEach-Object { $_.skuId })
        $pcs = @(Get-CpcGraphCollection "$script:Endpoint/cloudPCs" | Where-Object { (Get-Value $_ 'userPrincipalName') -eq $row.UserPrincipalName -or (Get-Value $_ 'userId') -eq $row.UserId })
        if ($script:S.Config.SkuId -in $assigned) { throw 'Target license appeared outside this journal. Reconcile external assignment before continuing.' }
        if ($pcs.Count) { throw 'A Cloud PC already exists. Refusing to assign another license.' }
        if ((Get-Value $r 'importStatus') -ne 'succeeded' -or (Get-Value $r 'usageStatus') -ne 'notUsed') {
            throw 'Snapshot is not successfully imported and unused. Refresh and reconcile; no license change performed.'
        }
        if ($script:S.Config.SkuId -notin $assigned) {
            # Re-evaluate policy, group membership, license headroom, and user settings immediately before trigger.
            Test-CpcRows @($row)
            if ($row.Readiness -ne 'Ready') { throw 'Pre-license prerequisites changed; no license assigned.' }
            Test-CpcStageEvidence $row 'License'
            $row.Phase = 'LicenseSubmitting'; $row.LicenseStartedUtc = [datetime]::UtcNow.ToString('o'); Save-CpcState
            try {
                $null = Invoke-CpcGraph -Method POST -Path "/v1.0/users/$($row.UserId)/assignLicense" -Body @{ addLicenses = @(@{ skuId = $script:S.Config.SkuId; disabledPlans = @() }); removeLicenses = @() }
            } catch { $row.Phase = 'LicenseUnknown'; Save-CpcState; throw }
        }
        $row.LicenseAssignedUtc = [datetime]::UtcNow.ToString('o'); $row.Phase = 'Provisioning'; $row.Readiness = 'NotChecked'
        Save-CpcState
        Write-CpcLog "$($row.VM): license assigned. Provisioning is asynchronous; import success is NOT migration completion."
    }
}

function Repair-CpcLicenseOutcome($Rows, $Data) {
    # Explicit read-only recovery. Consumed import/artifacts may no longer exist.
    # Never infer assignment provenance merely from a present SKU.
    Assert-CpcContext
    Assert-CpcConfig
    $Rows = @($Rows)
    if (@($Rows).Count -ne 1 -or $Rows[0].Phase -ne 'LicenseUnknown') { throw 'Select exactly one LicenseUnknown row.' }
    $row = $Rows[0]
    $evidence = [string](Get-Value $Data 'Evidence')
    if ([string]::IsNullOrWhiteSpace($evidence) -or $evidence.Length -gt 2000) { throw 'Supply a reviewed Entra audit/request reference confirming this exact assignment (maximum 2000 characters).' }
    if ([string](Get-Value $Data 'AssignedUtc') -notmatch '(?:Z|[+-]\d{2}:\d{2})$') { throw 'Assignment timestamp needs an explicit timezone, preferably UTC Z.' }
    $assignedTime = [datetimeoffset]::Parse([string](Get-Value $Data 'AssignedUtc'))
    $importStart = [datetimeoffset]::Parse($row.ImportStartedUtc)
    if ($assignedTime -lt $importStart -or $assignedTime -gt [datetimeoffset]::UtcNow) { throw 'Assignment timestamp must be after this import attempt and not in the future.' }
    if ((Get-Value $row 'LicenseStartedUtc') -and $assignedTime -lt [datetimeoffset]::Parse($row.LicenseStartedUtc).AddSeconds(-5)) { throw 'Assignment predates this journaled license attempt.' }
    if ($row.ImportStatus -ne 'succeeded' -or -not $row.ImportId) { throw 'A recorded successful import is required; recover import evidence before license reconciliation.' }
    $user = Invoke-CpcGraph -Path "/v1.0/users/$($row.UserId)?`$select=id,userPrincipalName,accountEnabled,assignedLicenses,licenseAssignmentStates"
    if ((Get-Value $user 'id') -ne $row.UserId -or (Get-Value $user 'userPrincipalName') -ne $row.UserPrincipalName -or (Get-Value $user 'accountEnabled') -ne $true) { throw 'User identity or enabled state differs from the plan.' }
    if ($script:S.Config.SkuId -notin @((Get-Value $user 'assignedLicenses' @()) | ForEach-Object { $_.skuId })) { throw 'Exact license is not present. No assignment will be retried.' }
    $states = @((Get-Value $user 'licenseAssignmentStates' @()) | Where-Object { (Get-Value $_ 'skuId') -eq $script:S.Config.SkuId })
    if ($states.Count -ne 1 -or (Get-Value $states[0] 'assignedByGroup') -or (Get-Value $states[0] 'state') -ne 'Active' -or (Get-Value $states[0] 'error') -notin @($null,'','None')) { throw 'Require one active direct assignment with no licensing error; group/ambiguous assignments need manual reconciliation.' }
    $pcs = @(Get-CpcGraphCollection "$script:Endpoint/cloudPCs" | Where-Object { (Get-Value $_ 'userId') -eq $row.UserId -or (Get-Value $_ 'userPrincipalName') -eq $row.UserPrincipalName })
    if ($pcs.Count -ne 1) { throw 'Wait for exactly one attributable Cloud PC; no license write will be repeated.' }
    $pc = Invoke-CpcGraph -Path "$script:Endpoint/cloudPCs/$($pcs[0].id)"
    if ((Get-Value $pc 'userId') -ne $row.UserId -or (Get-Value $pc 'userPrincipalName') -ne $row.UserPrincipalName -or
        (Get-Value $pc 'provisioningPolicyId') -ne $script:S.Config.PolicyId -or ((Get-Value $row 'CloudPcId') -and $row.CloudPcId -ne $pc.id)) { throw 'Cloud PC user/policy/identity does not match this migration.' }
    $created = [datetimeoffset]::Parse([string](Get-Value $pc 'createdDateTime'))
    if ($created -lt $importStart -or $created -lt $assignedTime.AddSeconds(-5) -or $created -gt [datetimeoffset]::UtcNow) { throw 'Cloud PC creation time predates the reviewed assignment or is outside this migration attempt.' }
    $policy = Invoke-CpcGraph -Path "$script:Endpoint/provisioningPolicies/$($script:S.Config.PolicyId)"
    if (-not (Test-CpcPolicyTarget $policy)) { throw 'Cloud PC policy is not a compatible Windows 365 desktop policy.' }
    Write-CpcAudit 'LicenseReconciliation' @{ UserId = $row.UserId; SkuId = $script:S.Config.SkuId; CloudPcId = $pc.id; AssignedUtc = $assignedTime.ToUniversalTime().ToString('o'); Evidence = $evidence }
    $row.LicenseAssignedUtc = $assignedTime.ToUniversalTime().ToString('o')
    $row.LicenseReconciledUtc = [datetime]::UtcNow.ToString('o'); $row.LicenseReconciliationEvidence = Protect-CpcText $evidence
    $row.CloudPcId = $pc.id; $row.CloudPcStatus = $pc.status
    $row.Phase = if ($pc.status -eq 'provisioned') { 'Provisioned' } else { 'Provisioning' }
    $row.Readiness = 'NotChecked'; $row.LastError = ''; $script:S.Preflight.Remove($row.VmId)
    Save-CpcState
    Write-CpcLog 'License reconciled from live direct assignment, Cloud PC identity/policy/timestamps and operator-reviewed audit evidence. No Graph write or import lookup performed. Final cutover still requires independent data validation.'
}

function Remove-CpcImportedSnapshot($Rows) {
    Assert-CpcContext
    foreach ($row in $Rows) {
        Assert-CpcContinue
        if (-not $row.ImportId -or $row.LicenseAssignedUtc -or $row.Phase -notin @('Imported','ImportFailed')) { throw 'Purge is restricted to known terminal imports before license assignment. Unknown outcomes need manual reconciliation.' }
        $r = Get-CpcImportResult $row.ImportId
        if (-not (Test-CpcImportUserIdentity $r $row)) { throw 'Import user mismatch; purge blocked.' }
        if ((Get-Value $r 'usageStatus') -ne 'notUsed' -or (Get-Value $r 'importStatus') -notin @('failed','succeeded')) { throw 'Only terminal, unused imports can be purged.' }
        Assert-CpcNoProvisioning $row
        $row.Phase = 'PurgeSubmitting'; Save-CpcState
        try { $null = Invoke-CpcGraph -Method POST -Path "$script:Endpoint/snapshots/purgeImportedSnapshot" -Body @{ snapshotIds = @($row.ImportId) } }
        catch { $row.Phase = 'PurgeUnknown'; Save-CpcState; throw }
        $row.Phase = 'Purged'; Save-CpcState
    }
}

function Complete-CpcValidation($Rows) {
    Update-CpcStatus $Rows
    foreach ($row in $Rows) {
        if ($row.Phase -ne 'Provisioned' -or $row.ImportStatus -ne 'succeeded' -or -not $row.ImportId -or -not $row.LicenseAssignedUtc) {
            throw 'Completion requires provisioned Cloud PC plus recorded successful import and subsequent license assignment.'
        }
        $pc = Invoke-CpcGraph -Path "$script:Endpoint/cloudPCs/$($row.CloudPcId)"
        if ((Get-Value $pc 'status') -ne 'provisioned' -or (Get-Value $pc 'userPrincipalName') -ne $row.UserPrincipalName) { throw 'Current Cloud PC status/user does not match this migration.' }
        if ((Get-Value $pc 'provisioningPolicyId') -ne $script:S.Config.PolicyId) { throw 'Cloud PC provisioning policy does not match the migration plan.' }
        if ($row.UsageStatus -ne 'inUse') { Write-CpcLog "$($row.VM): snapshot consumption is NOT confirmed by current Graph usage status. Validation relies on the operator's independent source/data verification; the imported artifact may have been cleaned up." }
        $row.ValidatedUtc = [datetime]::UtcNow.ToString('o'); $row.Phase = 'Validated'; Save-CpcState
    }
    Write-CpcLog 'Operator confirmed user sign-in, correct restored data/apps/profile, and source/snapshot identity. Source VMs remain retained and stopped.'
}

function Assert-CpcNoProvisioning($Row) {
    $user = Invoke-CpcGraph -Path "/v1.0/users/$($Row.UserId)?`$select=id,userPrincipalName,assignedLicenses"
    if ((Get-Value $user 'id') -ne $Row.UserId -or (Get-Value $user 'userPrincipalName') -ne $Row.UserPrincipalName) { throw 'Target user identity changed; recovery blocked.' }
    $skus = @(Get-CpcGraphCollection '/v1.0/subscribedSkus')
    $ids = @($skus | Where-Object { ((Get-Value $_ 'skuPartNumber' '') + ',' + ((Get-Value $_ 'servicePlans' @() | ForEach-Object { Get-Value $_ 'servicePlanName' '' }) -join ',')) -match '(?i)CLOUDPC|WINDOWS[_ ]?365|CPC_' } | ForEach-Object { $_.skuId }) + @($script:S.Config.SkuId)
    if (@((Get-Value $user 'assignedLicenses' @()) | Where-Object { $_.skuId -in $ids }).Count -or
        @(Get-CpcGraphCollection "$script:Endpoint/cloudPCs" | Where-Object { (Get-Value $_ 'userId') -eq $Row.UserId -or (Get-Value $_ 'userPrincipalName') -eq $Row.UserPrincipalName }).Count) { throw 'A Cloud PC or Windows 365 license exists. Pre-license artifact removal is unsafe and blocked.' }
}

function Remove-CpcAttemptArtifacts($Row, [string]$PendingPhase) {
    # Two-pass, ownership-checked, restartable removal. Absence never hides a
    # permission/network failure: list calls must succeed, and writes are not retried.
    $snapshots = @(Get-AzSnapshot -ResourceGroupName $script:S.Config.SnapshotResourceGroup | Where-Object Name -EQ $Row.SnapshotName)
    if ($snapshots.Count -gt 1) { throw 'Ambiguous snapshot listing.' }
    if ($snapshots.Count) {
        $snap = Assert-CpcOwnedSnapshot $Row
        if ([string]$snap.ProvisioningState -notin @('Succeeded','Failed','Canceled')) { throw 'Snapshot is still provisioning. Wait before removing it.' }
    } elseif (-not (Get-Value $Row 'ArtifactRemovalApproved') -and $PendingPhase -eq 'CleanupPending') { throw 'Validated snapshot unexpectedly missing. Review ownership before cleanup.' }
    $storage = Get-CpcStorage
    $parts = @(@{ Blob = $Row.VhdBlob; CopyId = $Row.VhdCopyId }, @{ Blob = $Row.VmgsBlob; CopyId = $Row.VmgsCopyId })
    foreach ($part in $parts) {
        if (-not $part.Blob) { continue }
        $prefix = "$($script:S.PlanId)/$($Row.UserId)/$($Row.SnapshotName)/"
        if (-not $Row.SnapshotName -or -not $part.Blob.StartsWith($prefix, [StringComparison]::Ordinal)) { throw 'Staging path ownership mismatch.' }
        $found = @(Get-AzStorageBlob -Container $script:S.Config.Container -Prefix $part.Blob -Context $storage.Context | Where-Object Name -EQ $part.Blob)
        if ($found.Count) {
            if (-not $snapshots.Count -and -not (Get-Value $Row 'ArtifactRemovalApproved')) { throw 'Orphan blob has no verified snapshot. Manual reconciliation required.' }
            $copy = Get-AzStorageBlobCopyState -Container $script:S.Config.Container -Blob $part.Blob -Context $storage.Context
            if (-not $part.CopyId -or [string]$copy.CopyId -ne $part.CopyId) { throw 'Unjournaled/changed copy: deletion refused. Reconcile the copy identity in Azure first.' }
            if ([string]$copy.Status -notin @('Success','Failed','Aborted')) { throw 'A copy is still pending. Revoke export, wait for a terminal copy status and retry recovery; no pending copy is deleted.' }
        }
    }
    $Row.Phase = $PendingPhase; $Row.ArtifactRemovalApproved = $true
    $Row.Readiness = 'NotChecked'; $Row.Attested = $false; $script:S.Preflight.Remove($Row.VmId)
    Save-CpcState
    if ($snapshots.Count) {
        $null = Assert-CpcOwnedSnapshot $Row
        Write-CpcAudit 'RevokeSnapshotExport' @{ SnapshotId = $Row.SnapshotId }
        Revoke-AzSnapshotAccess -ResourceGroupName $script:S.Config.SnapshotResourceGroup -SnapshotName $Row.SnapshotName | Out-Null
    }
    foreach ($part in $parts) {
        if (-not $part.Blob) { continue }
        Assert-CpcContinue
        $found = @(Get-AzStorageBlob -Container $script:S.Config.Container -Prefix $part.Blob -Context $storage.Context | Where-Object Name -EQ $part.Blob)
        if ($found.Count) {
            $copy = Get-AzStorageBlobCopyState -Container $script:S.Config.Container -Blob $part.Blob -Context $storage.Context
            if ([string]$copy.CopyId -ne $part.CopyId -or [string]$copy.Status -notin @('Success','Failed','Aborted')) { throw 'Copy changed since recovery approval; removal stopped.' }
            Write-CpcAudit 'RemoveStagingBlob' @{ Blob = $part.Blob; CopyId = $part.CopyId }
            Remove-AzStorageBlob -Container $script:S.Config.Container -Blob $part.Blob -Context $storage.Context -Force | Out-Null
            Save-CpcState
        }
    }
    if ($snapshots.Count) {
        $null = Assert-CpcOwnedSnapshot $Row
        Write-CpcAudit 'RemoveSnapshot' @{ SnapshotId = $Row.SnapshotId }
        Remove-AzSnapshot -ResourceGroupName $script:S.Config.SnapshotResourceGroup -SnapshotName $Row.SnapshotName -Force | Out-Null
    }
}

function Reset-CpcCapture($Rows, [switch]$Abandon) {
    Assert-CpcContext
    Assert-CpcConfig
    foreach ($row in $Rows) {
        Assert-CpcContinue
        $allowed = @('Mapped','IdentityPrepared','Capturing','CaptureFailed','Copying','CopyFailed','Staged','Purged') + $(if ($Abandon) { @('Abandoning') } else { @('ResettingCapture') })
        if ($row.Phase -notin $allowed -or $row.LicenseAssignedUtc -or ($row.ImportId -and $row.Phase -notin @('Purged','ResettingCapture','Abandoning'))) { throw 'Reset/abandon requires a known pre-license phase and no live/unknown import. Purge a terminal unused import first. Resume an interrupted reset/abandon with the same action.' }
        if ($row.Phase -in @('ResettingCapture','Abandoning') -and -not (Get-Value $row 'ArtifactRemovalApproved')) { throw 'Interrupted recovery requires prior artifact-removal approval; live/unknown imports cannot bypass recovery validation.' }
        Assert-CpcNoProvisioning $row
        Remove-CpcAttemptArtifacts $row $(if ($Abandon) { 'Abandoning' } else { 'ResettingCapture' })
        $history = @{}; foreach ($key in @('SnapshotId','SnapshotName','VhdBlob','VmgsBlob','VhdCopyId','VmgsCopyId','ImportId','ImportStatus','CaptureStartedUtc','ImportStartedUtc')) { $history[$key] = Get-Value $row $key }
        $history.ClosedUtc = [datetime]::UtcNow.ToString('o')
        $row.AttemptHistory = @(Get-Value $row 'AttemptHistory' @()) + @($history)
        foreach ($key in @('SnapshotId','SnapshotName','VhdBlob','VmgsBlob','VhdCopyId','VmgsCopyId','SourceVmUniqueId','SourceDiskId','CaptureStartedUtc','ImportId','ImportStatus','UsageStatus','ImportStartedUtc','ExportExpiresUtc','ImportSasExpiresUtc')) { $row[$key] = '' }
        $row.ArtifactRemovalApproved = $false; $row.LastError = ''; $row.Readiness = 'NotChecked'; $row.Attested = $false
        $row.Phase = if ($Abandon) { 'Abandoned' } elseif ($script:S.GroupId -and $script:S.UserSettingId) { 'IdentityPrepared' } else { 'Mapped' }
        Save-CpcState
    }
    Write-CpcLog 'Owned terminal artifacts removed; attempt IDs retained in history. No source restart/deletion, license or policy change. For a retry, obtain fresh guest evidence as needed, attest and validate again. Abandoned users retain the group setting until the whole batch can use Revert to image.'
}

function Remove-CpcStaging($Rows) {
    Assert-CpcContext
    foreach ($row in $Rows) {
        if ($row.Phase -notin @('Validated','CleanupPending') -or -not $row.ValidatedUtc) { throw 'Staging cleanup requires validated migration. Source VMs are NEVER deleted.' }
        Remove-CpcAttemptArtifacts $row 'CleanupPending'
        $row.Phase = 'Cleaned'; Save-CpcState
    }
    Write-CpcLog 'Deleted only plan-owned staging blobs and managed snapshots. Licenses, Cloud PCs, source VMs, groups and policy assignments were retained.'
}

function Export-CpcReport([string]$Directory) {
    $null = [IO.Directory]::CreateDirectory($Directory)
    $rows = @($script:S.Rows | ForEach-Object { [pscustomobject]$_ })
    # Protect against spreadsheet formula injection; JSON preserves exact values.
    $csvRows = foreach ($r in $rows) {
        $safe = [ordered]@{}
        foreach ($p in $r.PSObject.Properties) {
            if ($p.Name -eq 'Guest') { continue }
            $v = [string]$p.Value
            if ($v -match '^[\s]*[=+@-]') { $v = "'$v" }
            $safe[$p.Name] = $v
        }
        [pscustomobject]$safe
    }
    $csvRows | Export-Csv (Join-Path $Directory 'migration-results.csv') -NoTypeInformation
    $script:S.Checks | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $Directory 'prerequisites.json') -Encoding utf8
    $script:S.GraphResults | ConvertTo-Json -Depth 15 | Set-Content (Join-Path $Directory 'graph-results.redacted.json') -Encoding utf8
    $script:S.Logs | Set-Content (Join-Path $Directory 'activity.log') -Encoding utf8
    $groups = $rows | Group-Object Phase
    $bars = foreach ($g in $groups) {
        $label = [net.webutility]::HtmlEncode($g.Name)
        "<div class='bar'><strong>$label ($($g.Count))</strong><meter min='0' max='$([math]::Max(1,$rows.Count))' value='$($g.Count)'></meter></div>"
    }
    $table = ($rows | Select-Object VM,UserPrincipalName,Phase,Readiness,ImportStatus,CloudPcStatus,LastError | ConvertTo-Html -Fragment) -join "`n"
    $checks = ($script:S.Checks | ConvertTo-Html -Fragment) -join "`n"
    $html = "<!doctype html><html><head><meta charset='utf-8'><title>Windows 365 migration</title><style>body{font:15px Segoe UI;background:#f4f7fb;color:#16243c;margin:32px}table{border-collapse:collapse;width:100%;background:white}td,th{border:1px solid #dde4ee;padding:9px;text-align:left}h1{color:#185abd}.bar{padding:8px}meter{width:50%;margin-left:20px}</style></head><body><h1>Windows 365 migration report</h1><p>UTC $([datetime]::UtcNow.ToString('o')) | Plan $($script:S.PlanId)</p><p>Import success is not proof of successful cutover. Validated means operator-confirmed. Contains tenant/user identifiers; handle as sensitive.</p>$($bars -join '')<h2>Migration state</h2>$table<h2>Prerequisites</h2>$checks</body></html>"
    [IO.File]::WriteAllText((Join-Path $Directory 'migration-report.html'), $html)
    Write-CpcLog "Exported redacted reports to $Directory."
}

function Invoke-CpcOperation {
    param([string]$Action, [hashtable]$Data = @{}, $Signals)
    if (-not $script:S) { Initialize-CpcState }
    $operationError = ''
    $script:Signals = $Signals
    try {
        $requiredTenant = [string](Get-Value $Data 'RequiredTenantId' '')
        if ($requiredTenant) {
            $requiredTenant = Assert-CpcGuid $requiredTenant 'Required tenant ID'
            if ($requiredTenant -eq [guid]::Empty.ToString()) { throw 'Required tenant cannot be the zero GUID.' }
            if ($script:RequiredTenantId -and $script:RequiredTenantId -ne $requiredTenant) { throw 'Startup tenant lock cannot be changed within this session.' }
            if ($script:S.TenantId -and $script:S.TenantId -ne $requiredTenant) { throw 'Active plan tenant differs from the requested startup tenant.' }
            $script:RequiredTenantId = $requiredTenant
        }
        if (($Action -in @('Prepare','RepairSnapshot','Capture','Import','License','Validate','Purge','Cleanup','RevokeExport','UseImage','ReconcileImport','ReconcileLicense','ResetCapture','Abandon') -or ($Action -eq 'Refresh' -and @($script:S.Rows | Where-Object Phase -EQ 'Copying').Count)) -and -not $script:S.StatePath) {
            throw 'Save the plan before mutations; an automatic operation journal is required.'
        }
        Write-CpcAudit 'OperationStart' @{ Action = $Action; VmIds = @(Get-Value $Data 'VmIds' @()) }
        switch ($Action) {
            'InitializeLogging' { Initialize-CpcLogging ([string](Get-Value $Data 'Directory' $PSScriptRoot)) }
            'LocalCheck' { Test-CpcLocal }
            'Install' {
                foreach ($m in $script:Modules) {
                    Assert-CpcContinue
                    Write-CpcLog "Installing/updating $m from PSGallery for CurrentUser. Restart the app after module updates."
                    Install-Module $m -Repository PSGallery -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
                }
                Test-CpcLocal
            }
            'Connect' { Connect-CpcServices $Data }
            'DetectSubscriptions' { Get-CpcSubscriptions $Data }
            'FindGroups' { Get-CpcGroupChoices $Data }
            'Discover' {
                try { Get-CpcInventory }
                catch {
                    # Never return a partly refreshed catalog or old resource scope.
                    foreach ($key in @('ResourceGroups','Vms','Storage','Policies','Skus','Groups')) { $script:S.Catalog[$key] = @() }
                    throw
                }
            }
            'RefreshLicenses' { Update-CpcLicenseCatalog }
            'Map' { Set-CpcMappings $Data }
            'Check' { Test-CpcPreflight (Get-CpcSelected $Data) }
            'Guest' { Invoke-CpcGuestAssessment (Get-CpcSelected $Data) }
            'Attest' {
                $rows = @(Get-CpcSelected $Data)
                foreach ($r in $rows) { $null = Get-CpcNextStage $r; if (-not $r.Guest) { throw 'Run guest assessment before attesting. If already captured, review recovery instead.' } }
                foreach ($r in $rows) {
                    $script:S.Preflight.Remove($r.VmId)
                    if (-not $r.Guest) { throw 'Run guest assessment before attesting.' }
                    $r.Attested = $true; $r.Readiness = 'NotChecked'
                }
                Save-CpcState
            }
            'Prepare' { Prepare-CpcIdentity (Get-CpcSelected $Data) }
            'RepairSnapshot' { Repair-CpcSnapshotAssignments }
            'Capture' { Start-CpcCapture (Get-CpcSelected $Data) }
            'Import' { Start-CpcImport (Get-CpcSelected $Data) }
            'Refresh' { Update-CpcStatus (Get-CpcSelected $Data) }
            'License' {
                try { Start-CpcLicense (Get-CpcSelected $Data) }
                finally {
                    try { Update-CpcLicenseCatalog }
                    catch { Write-CpcLog "License-count refresh failed; catalog cleared. $($_.Exception.Message)" }
                }
            }
            'Validate' { Complete-CpcValidation (Get-CpcSelected $Data) }
            'Purge' { Remove-CpcImportedSnapshot (Get-CpcSelected $Data) }
            'Cleanup' { Remove-CpcStaging (Get-CpcSelected $Data) }
            'RevokeExport' {
                Assert-CpcContext
                foreach ($r in (Get-CpcSelected $Data)) {
                    $null = Assert-CpcOwnedSnapshot $r
                    Revoke-AzSnapshotAccess -ResourceGroupName $script:S.Config.SnapshotResourceGroup -SnapshotName $r.SnapshotName | Out-Null
                    if ($r.Phase -in @('Copying','Capturing','CaptureFailed')) { $r.Phase = 'CopyFailed' }
                    Save-CpcState
                }
                Write-CpcLog 'Azure snapshot export SAS revoked. Incomplete copies may fail; no source/target resources deleted.'
            }
            'UseImage' {
                Assert-CpcContext
                if (Get-Value $script:S.Config 'ExistingGroupId') { $null = Assert-CpcSelectedGroup $script:S.Config @($script:S.Rows) }
                if (-not $script:S.UserSettingId -or @($script:S.Rows | Where-Object { $_.Phase -notin @('Validated','Cleaned','Abandoned') }).Count) {
                    throw 'All rows must be validated/cleaned or safely abandoned before reverting the dedicated setting to image provisioning.'
                }
                foreach ($r in @($script:S.Rows | Where-Object Phase -EQ 'Abandoned')) { Assert-CpcNoProvisioning $r }
                $setting = Invoke-CpcGraph -Path "$script:Endpoint/userSettings/$($script:S.UserSettingId)?`$expand=assignments"
                if ($setting.displayName -ne ('Snapshot-' + $script:S.PlanId)) { throw 'User setting ownership mismatch.' }
                $assignments = @(Get-Value $setting 'assignments' @())
                if ($assignments.Count -ne 1 -or -not (Test-CpcGroupTarget (Get-Value $assignments[0] 'target')) -or (Get-Value (Get-Value $assignments[0] 'target') 'groupId') -ne $script:S.GroupId) { throw 'Dedicated user setting assignments changed. Manual review required.' }
                $members = @(Get-CpcGraphCollection "/v1.0/groups/$($script:S.GroupId)/members?`$select=id")
                $batchUsers = @($script:S.Rows | ForEach-Object UserId)
                if (@($members | Where-Object { $_.id -notin $batchUsers }).Count) { throw 'Migration group contains non-batch members. Refusing to change their future provisioning behavior.' }
                if ((Get-Value $setting 'provisioningSourceType') -ne 'image') {
                    $body = New-CpcUserSettingSourceBody $setting 'image'
                    $null = Invoke-CpcGraph -Method PATCH -Path "$script:Endpoint/userSettings/$($script:S.UserSettingId)" -Body $body
                }
                # Confirm from a fresh read, not from a 204 or an assumed default.
                # A read failure never causes automatic replay of the PATCH.
                $verified = Invoke-CpcGraph -Path "$script:Endpoint/userSettings/$($script:S.UserSettingId)?`$expand=assignments"
                $targets = @(Get-Value $verified 'assignments' @())
                if ((Get-Value $verified 'id') -ne $script:S.UserSettingId -or
                    (Get-Value $verified 'displayName') -ne ('Snapshot-' + $script:S.PlanId) -or
                    (Get-Value $verified 'provisioningSourceType') -ne 'image' -or
                    $targets.Count -ne 1 -or -not (Test-CpcGroupTarget (Get-Value $targets[0] 'target')) -or
                    (Get-Value (Get-Value $targets[0] 'target') 'groupId') -ne $script:S.GroupId) {
                    throw 'Image provisioning switch not confirmed by read-back. Keep group membership unchanged; review the latest user-setting GET in Dashboard & Graph. No automatic PATCH retry.'
                }
                Write-CpcLog 'Dedicated user setting confirmed as image for FUTURE reprovisioning. Policy/group membership and existing Cloud PCs unchanged. Allow assignment propagation before changing membership.'
            }
            'ReconcileImport' {
                Assert-CpcContext
                $rows = @(Get-CpcSelected $Data)
                if ($rows.Count -ne 1 -or $rows[0].Phase -ne 'ImportUnknown') { throw 'Select one ImportUnknown row.' }
                $Data.ImportId = Assert-CpcGuid ([string](Get-Value $Data 'ImportId')) 'Known import snapshot ID'
                if ($Data.ImportId -eq [guid]::Empty.ToString()) { throw 'Known import snapshot ID must not be the zero GUID.' }
                $r = Get-CpcImportResult $Data.ImportId
                if (-not (Test-CpcImportUserIdentity $r $rows[0])) { throw 'Import belongs to another user.' }
                $filename = ($rows[0].VhdBlob -split '/')[-1]
                if ((Get-Value $r 'filename') -notin @($rows[0].VhdBlob, $filename, [IO.Path]::GetFileNameWithoutExtension($filename))) { throw 'Unique import filename mismatch. Escalate for manual correlation.' }
                if ([datetime](Get-Value $r 'startDateTime') -lt [datetime]$rows[0].ImportStartedUtc) { throw 'Import predates this attempt.' }
                $rows[0].ImportId = $Data.ImportId; $rows[0].Phase = 'Importing'; Save-CpcState
                Update-CpcStatus $rows
            }
            'ReconcileLicense' { Repair-CpcLicenseOutcome (Get-CpcSelected $Data) $Data }
            'ResetCapture' { Reset-CpcCapture (Get-CpcSelected $Data) }
            'Abandon' { Reset-CpcCapture (Get-CpcSelected $Data) -Abandon }
            'Save' {
                $candidate = $script:S.Clone()
                $candidate.StatePath = [IO.Path]::GetFullPath($Data.Path)
                Save-CpcState -State $candidate
                $script:S = $candidate
                Write-CpcLog 'Plan saved. This path is now the automatic operation journal.'
            }
            'Load' {
                Assert-CpcContext
                if ($script:S.Rows.Count) { throw 'Load into a fresh connected application instance.' }
                $lease = Open-CpcJournalLease $Data.Path
                try {
                $loaded = [IO.File]::ReadAllText($lease.Path) | ConvertFrom-Json -AsHashtable
                if ($loaded.SchemaVersion -ne 1 -or $loaded.TenantId -ne $script:S.TenantId -or $loaded.SubscriptionId -ne $script:S.SubscriptionId) { throw 'Plan schema/tenant/subscription mismatch.' }
                $null = Assert-CpcGuid $loaded.PlanId 'Plan ID'
                Assert-CpcTenantScope $loaded.TenantId
                Assert-CpcConfig $loaded.Config
                $candidate = $script:S.Clone()
                foreach ($k in @('PlanId','Config','GroupId','UserSettingId')) { $candidate[$k] = $loaded[$k] }
                foreach ($key in @('GroupId','UserSettingId')) { if ($candidate[$key]) { $null = Assert-CpcGuid $candidate[$key] $key } }
                $candidate.Preflight = @{}
                $candidate.Checks = [collections.generic.list[object]]::new()
                $candidate.Rows = [collections.generic.list[object]]::new()
                $vmIds = [collections.generic.hashset[string]]::new([StringComparer]::OrdinalIgnoreCase)
                $upns = [collections.generic.hashset[string]]::new([StringComparer]::OrdinalIgnoreCase)
                foreach ($r in $loaded.Rows) {
                    if ($r.VmId -notlike "/subscriptions/$($script:S.SubscriptionId)/resourceGroups/*/providers/Microsoft.Compute/virtualMachines/*") { throw 'Plan contains an out-of-scope VM.' }
                    if (-not $vmIds.Add($r.VmId) -or $r.UserPrincipalName -notmatch '^[^@\s]+@[^@\s]+$' -or -not $upns.Add($r.UserPrincipalName)) { throw 'Plan has duplicate mappings or invalid user identities.' }
                    if ($r.VmId -ne "/subscriptions/$($script:S.SubscriptionId)/resourceGroups/$($r.ResourceGroup)/providers/Microsoft.Compute/virtualMachines/$($r.VM)") { throw 'Journal VM name/resource group does not match its ARM ID.' }
                    foreach ($key in @('UserId','ImportId','CloudPcId')) { if (Get-Value $r $key) { $null = Assert-CpcGuid $r[$key] $key } }
                    if ($r.Phase -notin @('Mapped','IdentityPrepared','Capturing','CaptureFailed','Copying','CopyFailed','Staged','ImportSubmitting','ImportUnknown','Importing','Imported','ImportFailed','LicenseSubmitting','LicenseUnknown','Provisioning','Provisioned','Validated','CleanupPending','Cleaned','PurgeSubmitting','PurgeUnknown','Purged','ResettingCapture','Abandoning','Abandoned')) { throw 'Unknown journal phase; manual version/recovery review required.' }
                    if ($r.Phase -eq 'ImportSubmitting') { $r.Phase = 'ImportUnknown' }
                    if ($r.Phase -eq 'LicenseSubmitting') { $r.Phase = 'LicenseUnknown' }
                    if ($r.Phase -eq 'PurgeSubmitting') { $r.Phase = 'PurgeUnknown' }
                    $r.Readiness = 'NotChecked'; $r.Attested = $false
                    $candidate.Rows.Add($r)
                }
                $candidate.StatePath = $lease.Path
                Save-CpcState -State $candidate -Lease $lease
                $script:S = $candidate
                } finally { if ($lease -ne $script:JournalLease) { $lease.Stream.Dispose() } }
                Write-CpcLog 'Plan restored. Refresh server status FIRST. Then follow the current stage: re-attest/validate only where needed, never repeat completed capture/import/license steps. Guest reassessment is not required solely because a journal was loaded. Never load an untrusted/edited plan.'
            }
            'Export' { Export-CpcReport $Data.Directory }
            default { throw "Unknown operation $Action." }
        }
        Write-CpcAudit 'OperationEnd' @{ Action = $Action; Outcome = 'Returned'; Phases = @($script:S.Rows | ForEach-Object { @{ VmId = $_.VmId; Phase = $_.Phase } }) }
    } catch {
        $operationError = Protect-CpcText $_.Exception.Message
        try { Write-CpcLog ("ERROR: " + $operationError) } catch { $operationError += ' Audit logging unavailable; stop further mutations until journal access is restored.' }
        # Failed candidate operations must not save partial/old state over a journal.
        if ($Action -notin @('Map','Load','Save','InitializeLogging')) {
            try { Save-CpcState } catch { $operationError += ' Journal save failed. Reconcile server state before retrying any mutation.' }
        }
    }
    $output = [pscustomobject]@{
        Rows = @($script:S.Rows | ForEach-Object {
            $view = [pscustomobject]$_
            $view | Add-Member -NotePropertyName StatusRefreshSucceeded -NotePropertyValue ($Action -eq 'Refresh' -and $script:RefreshSucceededIds.Contains($_.VmId))
            $view
        }); Checks = @($script:S.Checks)
        Catalog = $script:S.Catalog; GraphResults = @($script:S.GraphResults); Config = $script:S.Config
        Connected = $script:S.Connected; GroupId = $script:S.GroupId; UserSettingId = $script:S.UserSettingId
        PlanId = $script:S.PlanId; StatePath = $script:S.StatePath
        TenantId = $script:S.TenantId; SubscriptionId = $script:S.SubscriptionId
        RequiredTenantId = $script:RequiredTenantId
        LogPath = $script:LogPath; LogLocationChanged = $script:LogLocationChanged
        Preflight = $script:S.Preflight
        OperationError = $operationError
    }
    try {
        # Persist every result listed in the UI: catalog, checks, rows, phase/status,
        # configuration, and errors. Approval receipts remain session-only.
        $listed = [ordered]@{ Action = $Action }
        foreach ($key in @('Rows','Checks','Catalog','GraphResults','Config','Connected','GroupId','UserSettingId','PlanId','StatePath','TenantId','SubscriptionId','RequiredTenantId','LogPath','OperationError')) { $listed[$key] = $output.$key }
        Write-CpcSessionRecord 'DisplayedResult' $listed
        if ($script:LogStream -and $Action -notin @('Map','Load','Save')) { Save-CpcState }
    } catch {
        $output.OperationError += ' Log/journal persistence failed: ' + (Protect-CpcText $_.Exception.Message) + ' Stop and restore write access before continuing.'
    }
    return $output
}

Export-ModuleMember -Function Invoke-CpcOperation,Protect-CpcText,New-CpcImportBody,Test-CpcPermission,Get-Value,ConvertTo-CpcLicenseCatalog