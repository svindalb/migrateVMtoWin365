#requires -Version 7.2
<#
Standalone logging regressions against the CURRENT, unmodified Core source.
No Pester, installs, authentication, or live cloud calls. Each case owns isolated
module instances and real temporary files. Documents is always redirected to the
fixture. Core's real per-plan LocalAppData locks are tracked and removed afterward.
Only this test suite is run; FAIL is a regression, never an expected/ignored defect.
#>
[CmdletBinding()]
param()
Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$corePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'CpcMigration.Core.psm1'
$coreSource = [IO.File]::ReadAllText($corePath)
$initialHash = (Get-FileHash $corePath -Algorithm SHA256).Hash
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($corePath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'Current Core must parse before logging tests can run.' }
$boundaries = @(@($ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true) |
    ForEach-Object { $_.GetCommandName() } |
    Where-Object { $_ -match '^(?:\w+)-(?:Az|Mg)' }) + @(
        'Install-Module', 'Install-Package', 'Install-PSResource', 'Update-Module',
        'Import-Module', 'Invoke-RestMethod', 'Invoke-WebRequest', 'Start-Process'
    ) | Sort-Object -Unique)
$script:Results = [collections.generic.list[object]]::new()
$script:Fixtures = [collections.generic.list[object]]::new()

function New-LoggingFixture {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('CpcLogging-' + [guid]::NewGuid().ToString('N'))
    $null = [IO.Directory]::CreateDirectory($root)
    # Dynamic modules execute the exact Core source, with separate script scopes,
    # including the real OnRemove handler. All initialization paths are explicit.
    $module = New-Module -Name ('CpcLoggingTest_' + [guid]::NewGuid().ToString('N')) -ScriptBlock ([scriptblock]::Create($coreSource))
    Import-Module $module -Force
    $fixture = @{ Root = $root; Module = $module; Removed = $false; PlanLock = ''; Violations = $null }
    $script:Fixtures.Add($fixture)
    $fixture.Violations = & $module {
        param($Root, $Boundaries)
        $script:PSModuleAutoLoadingPreference = 'None'
        $script:Temp = $Root
        $script:Documents = Join-Path $Root 'Documents'
        $script:DocumentsCalls = 0
        $script:Violations = [collections.generic.list[string]]::new()
        foreach ($name in $Boundaries) {
            Set-Item "function:script:$name" {
                $script:Violations.Add($MyInvocation.MyCommand.Name)
                throw "FORBIDDEN BOUNDARY: $($MyInvocation.MyCommand.Name)"
            }
        }
        function script:Get-CpcDocumentsDirectory { $script:DocumentsCalls++; return $script:Documents }
        function script:Assert-Logging([bool]$Condition, [string]$Message) {
            if (-not $Condition) { throw "ASSERT: $Message" }
        }
        function script:Read-Session {
            # FileShare.ReadWrite permits reading while Core retains its write handle.
            $stream = [IO.File]::Open($script:LogPath, 'Open', 'Read', 'ReadWrite')
            $reader = [IO.StreamReader]::new($stream)
            try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
        }
        function script:Read-Records {
            @((Read-Session) -split "`n" | Where-Object { $_.StartsWith('{') } |
                ForEach-Object { ConvertFrom-Json -InputObject $_ -AsHashtable })
        }
        function script:Assert-NoSecrets([string]$Text) {
            foreach ($secret in @('sas-fixture-secret', 'bearer-fixture-secret', 'access-fixture-secret',
                    'refresh-fixture-secret', 'client-fixture-secret', 'password-fixture-secret', 'receipt-must-not-persist')) {
                Assert-Logging (-not $Text.Contains($secret)) "Persisted secret: $secret"
            }
        }
        function script:Start-Logging([string]$Directory = (Join-Path $script:Temp 'preferred')) {
            $output = Invoke-CpcOperation -Action InitializeLogging -Data @{ Directory = $Directory }
            Assert-Logging (-not $output.OperationError) "Initialization failed: $($output.OperationError)"
            return $output
        }
        function script:Set-LoggingData {
            $script:S.Catalog.Vms = @(@{ Name = 'catalog-visible'; Url = 'https://example.invalid/catalog?sig=sas-fixture-secret' })
            $script:S.Rows.Add(@{ VM = 'row-visible'; VmId = 'offline-vm'; Phase = 'Mapped';
                LastError = 'row-error-visible Bearer bearer-fixture-secret'; Guest = @{ Detail = 'guest-visible' }; Attested = $false })
            $script:S.Checks.Add(@{ VM = 'row-visible'; Check = 'check-visible'; Status = 'Failed';
                Detail = 'https://example.invalid/check?sig=sas-fixture-secret' })
            $script:S.Config.Container = 'config-visible'
            $script:S.Preflight['offline-vm'] = @{ Nonce = 'receipt-must-not-persist'; Stage = 'Capture' }
        }
        function script:Set-LoadContext {
            $script:S.TenantId = '22222222-2222-2222-2222-222222222222'
            $script:S.SubscriptionId = '33333333-3333-3333-3333-333333333333'
            $script:S.Connected = $true
            $script:S.Config = @{ PolicyId = '44444444-4444-4444-4444-444444444444';
                SkuId = '55555555-5555-5555-5555-555555555555'; TargetDiskGiB = 128;
                StorageId = "/subscriptions/$($script:S.SubscriptionId)/resourceGroups/staging/providers/Microsoft.Storage/storageAccounts/offlinetest";
                Container = 'private'; SnapshotResourceGroup = 'snapshots' }
            # Only local context reads are allowed; sign-in and every mutation stay blocked.
            function script:Get-AzContext {
                @{ Tenant = @{ Id = $script:S.TenantId }; Subscription = @{ Id = $script:S.SubscriptionId }; Environment = @{ Name = 'AzureCloud' } }
            }
            function script:Get-MgContext { @{ TenantId = $script:S.TenantId; Environment = 'Global' } }
        }
        Initialize-CpcState
        return ,$script:Violations
    } $root $boundaries
    $fixture.PlanLock = & $module {
        Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) "CpcMigration/locks/$($script:S.PlanId).lock"
    }
    return $fixture
}

function Remove-LoggingFixtureModule($Fixture) {
    if (-not $Fixture.Removed) { Remove-Module $Fixture.Module -Force; $Fixture.Removed = $true }
}

function Test-LoggingCase([string]$Name, [scriptblock]$Body) {
    $script:Fixtures.Clear()
    $failures = [collections.generic.list[string]]::new()
    try { $fixture = New-LoggingFixture; & $Body $fixture | Out-Null }
    catch { $failures.Add($_.Exception.Message + ' [' + $_.ScriptStackTrace + ']') }
    finally {
        # Sessions can own files in another fixture after Load or shared-folder
        # initialization. Release ALL modules before inspecting/deleting any files.
        foreach ($fixture in $script:Fixtures) {
            try { Remove-LoggingFixtureModule $fixture }
            catch { $failures.Add('Module removal failed: ' + $_.Exception.Message) }
        }
        foreach ($fixture in $script:Fixtures) {
            if ($fixture.Violations -and $fixture.Violations.Count) {
                $failures.Add('Forbidden boundary calls: ' + ($fixture.Violations -join ', '))
            }
            try {
                Remove-LoggingFixtureModule $fixture
                # Verify release with exclusive opens BEFORE deletion (delete alone
                # does not prove a handle was released on every operating system).
                foreach ($file in @(Get-ChildItem $fixture.Root -File -Recurse)) {
                    $probe = [IO.File]::Open($file.FullName, 'Open', 'ReadWrite', 'None'); $probe.Dispose()
                }
                if ($fixture.PlanLock -and [IO.File]::Exists($fixture.PlanLock)) {
                    $probe = [IO.File]::Open($fixture.PlanLock, 'Open', 'ReadWrite', 'None'); $probe.Dispose()
                    [IO.File]::Delete($fixture.PlanLock)
                }
                Remove-Item $fixture.Root -Recurse -Force
            } catch { $failures.Add('Cleanup/lock release failed: ' + $_.Exception.Message) }
        }
    }
    $passed = $failures.Count -eq 0
    $script:Results.Add([pscustomobject]@{ Test = $Name; Passed = $passed; Error = $failures -join ' | ' })
    if ($passed) { Write-Host "PASS $Name" }
    else { Write-Host "FAIL $Name -- $($failures -join ' | ')" }
}

Test-LoggingCase 'Preferred folder creates matching log, journal and events automatically' {
    param($f)
    & $f.Module {
        $output = Start-Logging
        Assert-Logging ($script:DocumentsCalls -eq 0) 'Writable preferred folder must not consult Documents'
        Assert-Logging (-not $output.LogLocationChanged) 'Preferred location incorrectly marked changed'
        Assert-Logging ([IO.Path]::GetDirectoryName($output.LogPath) -eq (Join-Path $script:Temp 'preferred')) 'Wrong preferred folder'
        Assert-Logging ([IO.Path]::GetFileName($output.LogPath) -match '^migration-\d{8}-\d{6}-[0-9a-f]{32}\.log$') 'Session filename lacks timestamp/GUID'
        Assert-Logging ([IO.Path]::ChangeExtension($output.LogPath, '.json') -eq $output.StatePath) 'Log/journal basenames differ'
        foreach ($path in @($output.LogPath, $output.StatePath, ($output.StatePath + '.events.jsonl'))) {
            Assert-Logging ([IO.File]::Exists($path) -and ([IO.FileInfo]$path).Length -gt 0) "Missing/empty automatic file: $path"
        }
        $journal = [IO.File]::ReadAllText($output.StatePath) | ConvertFrom-Json -AsHashtable
        Assert-Logging ($journal.PlanId -eq $output.PlanId) 'Automatic journal has wrong plan'
        $events = @(Get-Content ($output.StatePath + '.events.jsonl') | ForEach-Object { $_ | ConvertFrom-Json -AsHashtable })
        Assert-Logging (@($events | Where-Object Event -EQ OperationEnd).Count -eq 1) 'Missing completed initialization event'
    }
}

Test-LoggingCase 'Direct Initialize is idempotent and retains stream and leases' {
    param($f)
    & $f.Module {
        Initialize-CpcLogging (Join-Path $script:Temp 'preferred')
        $stream = $script:LogStream; $lease = $script:JournalLease; $planLease = $script:PlanLease
        $path = $script:S.StatePath; $text = Read-Session
        Initialize-CpcLogging (Join-Path $script:Temp 'must-not-create')
        Assert-Logging ([object]::ReferenceEquals($stream, $script:LogStream)) 'Repeated init replaced log stream'
        Assert-Logging ([object]::ReferenceEquals($lease, $script:JournalLease)) 'Repeated init replaced journal lease'
        Assert-Logging ([object]::ReferenceEquals($planLease, $script:PlanLease)) 'Repeated init replaced plan lease'
        Assert-Logging ($path -eq $script:S.StatePath -and $text -eq (Read-Session)) 'Repeated direct init changed paths/content'
        Assert-Logging (-not [IO.Directory]::Exists((Join-Path $script:Temp 'must-not-create'))) 'Repeated init created another directory'
        Assert-Logging (@(Get-ChildItem $script:Temp -Filter '*.log' -Recurse).Count -eq 1) 'Repeated init created another log'
    }
}

Test-LoggingCase 'Write-CpcLog is immediately readable and redacted in log, events and queue' {
    param($f)
    & $f.Module {
        $null = Start-Logging
        $script:Signals = @{ Queue = [collections.concurrent.ConcurrentQueue[string]]::new(); Cancel = $false }
        Write-CpcLog 'flush-marker https://example.invalid/disk?sig=sas-fixture-secret Bearer bearer-fixture-secret'
        $text = Read-Session
        Assert-Logging ($text.Contains('flush-marker') -and $text.Contains('[REDACTED]')) 'Activity not flushed immediately'
        $audit = [IO.File]::ReadAllText($script:S.StatePath + '.events.jsonl')
        Assert-Logging ($audit.Contains('flush-marker')) 'Activity audit not immediately readable'
        Assert-Logging ($script:Signals.Queue.Count -eq 1) 'Activity not queued for display'
        Assert-NoSecrets ($text + $audit + ($script:Signals.Queue.ToArray() -join '') + ($script:S.Logs -join ''))
    }
}

Test-LoggingCase 'Write-CpcSessionRecord writes parseable immediate structured evidence' {
    param($f)
    & $f.Module {
        $null = Start-Logging
        Write-CpcSessionRecord 'FixtureEvidence' @{ Marker = 'record-visible'; access_token = 'access-fixture-secret';
            refresh_token = 'refresh-fixture-secret'; client_secret = 'client-fixture-secret'; password = 'password-fixture-secret';
            Url = 'https://example.invalid/disk?sv=1&sig=sas-fixture-secret' }
        $record = @(Read-Records | Where-Object Kind -EQ FixtureEvidence)
        Assert-Logging ($record.Count -eq 1 -and $record[0].Details.Marker -eq 'record-visible') 'Structured record missing/unparseable'
        # ConvertFrom-Json may deserialize ISO timestamps as DateTime (depending
        # on PowerShell version); validate the actual wire-format UTC suffix.
        Assert-Logging ($record[0].PlanId -eq $script:S.PlanId -and (Read-Session) -match '"Utc":"[^"\r\n]+Z"') 'Record missing plan/UTC metadata'
        Assert-Logging ($record[0].Details.access_token -eq '[REDACTED]') 'Structured token not redacted'
        Assert-NoSecrets (Read-Session)
    }
}

Test-LoggingCase 'Operation results save rows and checks before any manual Save' {
    param($f)
    & $f.Module {
        $null = Start-Logging
        Set-LoggingData
        # Repeat the local-only operation to exercise the real final persistence path.
        $output = Invoke-CpcOperation -Action InitializeLogging
        Assert-Logging (-not $output.OperationError) "Operation failed: $($output.OperationError)"
        $text = [IO.File]::ReadAllText($output.StatePath)
        $journal = $text | ConvertFrom-Json -AsHashtable
        Assert-Logging ($journal.Rows.Count -eq 1 -and $journal.Rows[0].VM -eq 'row-visible') 'Rows were not saved automatically'
        Assert-Logging ($journal.Checks.Count -eq 1 -and $journal.Checks[0].Check -eq 'check-visible') 'Checks were not saved automatically'
        Assert-Logging ($journal.Config.Container -eq 'config-visible') 'Configuration was not saved automatically'
        Assert-Logging (-not $journal.ContainsKey('Preflight')) 'Journal persisted approval receipts'
        Assert-NoSecrets $text
    }
}

Test-LoggingCase 'Displayed diagnostics contain only allowlisted counts, not catalog or journal snapshots' {
    param($f)
    & $f.Module {
        $null = Start-Logging; Set-LoggingData
        $output = Invoke-CpcOperation -Action InitializeLogging
        Assert-Logging (-not $output.OperationError) "Operation failed: $($output.OperationError)"
        $displayed = @(Read-Records | Where-Object Kind -EQ DisplayedResult)[-1].Details
        Assert-Logging ($displayed.RowCount -eq 1 -and $displayed.CheckCount -eq 1 -and -not $displayed.HasError) 'Summary counts incorrect'
        foreach ($key in @('Catalog','Rows','Checks','Config','GraphResults')) { Assert-Logging (-not $displayed.ContainsKey($key)) "Repeated sensitive snapshot: $key" }
        foreach ($marker in @('catalog-visible','guest-visible','row-visible','config-visible')) { Assert-Logging (-not (Read-Session).Contains($marker)) "Sensitive snapshot in diagnostic log: $marker" }
        Assert-Logging (-not $displayed.ContainsKey('Preflight')) 'DisplayedResult persisted Preflight'
        Assert-Logging ($output.Preflight.Count -eq 1) 'Logging should not destroy session-only approval receipts'
        Assert-NoSecrets ((Read-Session) + [IO.File]::ReadAllText($output.StatePath) + [IO.File]::ReadAllText($output.StatePath + '.events.jsonl'))
    }
}

Test-LoggingCase 'Operation errors are displayed and durably logged with secrets removed' {
    param($f)
    & $f.Module {
        $null = Start-Logging
        $output = Invoke-CpcOperation -Action 'error-visible https://example.invalid/error?sig=sas-fixture-secret Bearer bearer-fixture-secret'
        Assert-Logging ($output.OperationError.Contains('Unknown operation error-visible')) 'Expected blocking operation error missing'
        $displayed = @(Read-Records | Where-Object Kind -EQ DisplayedResult)[-1].Details
        Assert-Logging ($displayed.HasError -and -not $displayed.ContainsKey('OperationError')) 'Summary should flag, not repeat, operation error'
        Assert-Logging ((Read-Session).Contains('ERROR: Unknown operation error-visible')) 'Immediate activity error omitted'
        Assert-NoSecrets ((Read-Session) + [IO.File]::ReadAllText($output.StatePath + '.events.jsonl') + $output.OperationError)
    }
}

Test-LoggingCase 'Real Graph wrapper returns live response but stores summary only' {
    param($f)
    & $f.Module {
        $null = Start-Logging
        $script:GraphFixtureCalls = 0
        function script:Invoke-MgGraphRequest {
            param($Method, $Uri, $OutputType, $ErrorAction, $Headers)
            if ($Method -ne 'GET' -or $Uri -ne 'https://graph.microsoft.com/v1.0/logging-fixture') {
                $script:Violations.Add("Graph $Method $Uri"); throw 'Unexpected Graph request'
            }
            $script:GraphFixtureCalls++
            @{ id = 'graph-visible'; access_token = 'access-fixture-secret'; refresh_token = 'refresh-fixture-secret';
                sourceFiles = @(@{ sasUrl = 'https://example.invalid/disk?sig=sas-fixture-secret' });
                authorization = 'Bearer bearer-fixture-secret' }
        }
        $result = Invoke-CpcGraph -Method GET -Path '/v1.0/logging-fixture'
        Assert-Logging ($result.access_token -eq 'access-fixture-secret') 'Logging changed the live in-memory response'
        Assert-Logging ($script:GraphFixtureCalls -eq 1) 'Expected exactly one mocked GET'
        $record = @(Read-Records | Where-Object Kind -EQ GraphResult)
        Assert-Logging ($record.Count -eq 1 -and $record[0].Details.Outcome -eq 'Returned') 'Graph summary missing'
        Assert-Logging (-not $record[0].Details.ContainsKey('Result') -and -not (Read-Session).Contains('graph-visible')) 'Raw Graph result persisted'
        Assert-NoSecrets (Read-Session)
        $output = Invoke-CpcOperation -Action InitializeLogging
        Assert-Logging (-not $output.OperationError) "Graph display persistence failed: $($output.OperationError)"
        Assert-NoSecrets ((Read-Session) + [IO.File]::ReadAllText($output.StatePath) + [IO.File]::ReadAllText($output.StatePath + '.events.jsonl'))
        $displayed = @(Read-Records | Where-Object Kind -EQ DisplayedResult)[-1].Details
        Assert-Logging (-not $displayed.ContainsKey('GraphResults') -and -not $output.GraphResults[0].Result.Contains('graph-visible')) 'Graph history contains raw response'
        Assert-NoSecrets ((Read-Session) + [IO.File]::ReadAllText($output.StatePath) + [IO.File]::ReadAllText($output.StatePath + '.events.jsonl'))
    }
}

Test-LoggingCase 'Graph PATCH service error reaches UI evidence and logs redacted without retry' {
    param($f)
    & $f.Module {
        $null = Start-Logging
        $script:GraphFixtureCalls = 0
        function script:Invoke-MgGraphRequest {
            param($Method, $Uri, $OutputType, $ErrorAction, $Headers, $Body, $ContentType)
            if ($Method -ne 'PATCH' -or $Uri -ne 'https://graph.microsoft.com/beta/logging-fixture') {
                $script:Violations.Add("Graph $Method $Uri"); throw 'Unexpected Graph request'
            }
            $script:GraphFixtureCalls++
            $exception = [System.Net.Http.HttpRequestException]::new('Bad Request', $null, [System.Net.HttpStatusCode]::BadRequest)
            $record = [System.Management.Automation.ErrorRecord]::new($exception, 'FixtureGraphError', 'InvalidOperation', $null)
            $record.ErrorDetails = [System.Management.Automation.ErrorDetails]::new('{"error":{"code":"BadRequest","message":"fixture-validation-reason https://example.invalid/disk?sig=sas-fixture-secret Bearer bearer-fixture-secret","innerError":{"request-id":"fixture-server-id"}},"access_token":"access-fixture-secret"}')
            throw $record
        }
        $caught = ''
        try { $null = Invoke-CpcGraph -Method PATCH -Path '/beta/logging-fixture' -Body @{ provisioningSourceType = 'image' } }
        catch { $caught = $_.Exception.Message }
        Assert-Logging ($caught.Contains('fixture-validation-reason') -and $caught.Contains('fixture-server-id')) 'Detailed service error/correlation missing'
        Assert-Logging ($script:GraphFixtureCalls -eq 1) 'Failed mutation must never be automatically retried'
        $record = @(Read-Records | Where-Object Kind -EQ GraphFailure)
        Assert-Logging ($record.Count -eq 1 -and $record[0].Details.StatusCode -eq 400) 'Structured failure/status missing'
        Assert-Logging ($script:S.GraphResults.Count -eq 1 -and $script:S.GraphResults[0].Result.Contains('fixture-validation-reason')) 'Dashboard failure missing'
        Assert-NoSecrets ($caught + (Read-Session) + [IO.File]::ReadAllText($script:S.StatePath + '.events.jsonl') + $script:S.GraphResults[0].Result)
    }
}

Test-LoggingCase 'Graph service error falls back to response content and bounds redacted output' {
    param($f)
    & $f.Module {
        $exception = [System.Exception]::new('generic')
        $exception | Add-Member -NotePropertyName ResponseContent -NotePropertyValue ('https://example.invalid/disk?sig=sas-fixture-secret ' + ('x' * 13000))
        $record = [System.Management.Automation.ErrorRecord]::new($exception, 'Fixture', 'InvalidOperation', $null)
        $detail = Get-CpcGraphFailureDetail $record
        Assert-Logging ($detail.Length -lt 12100 -and $detail.EndsWith(' [truncated]')) 'Failure evidence must be bounded'
        Assert-NoSecrets $detail
    }
}

Test-LoggingCase 'Graph error HttpResponseMessage fallback preserves body without exposing secrets' {
    param($f)
    & $f.Module {
        $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::BadRequest)
        $response.Content = [System.Net.Http.StringContent]::new('fixture-http-content Bearer bearer-fixture-secret')
        try {
            $exception = [System.Exception]::new('generic')
            $exception | Add-Member -NotePropertyName Response -NotePropertyValue $response
            $record = [System.Management.Automation.ErrorRecord]::new($exception, 'Fixture', 'InvalidOperation', $null)
            $detail = Get-CpcGraphFailureDetail $record
            Assert-Logging ($detail.Contains('fixture-http-content')) 'HTTP response content missing'
            Assert-NoSecrets $detail
        } finally { $response.Dispose() }
        Assert-Logging ([string]::IsNullOrEmpty((Get-CpcGraphFailureDetail $record))) 'Disposed response must not hide original error'
    }
}

Test-LoggingCase 'Graph exception without service body remains reportable' {
    param($f)
    & $f.Module {
        $record = [System.Management.Automation.ErrorRecord]::new([System.Exception]::new('generic'), 'Fixture', 'InvalidOperation', $null)
        Assert-Logging ([string]::IsNullOrEmpty((Get-CpcGraphFailureDetail $record))) 'Missing service body should be empty, not a new exception'
    }
}

Test-LoggingCase 'Default private directory creates protected ACLs without consulting Documents' {
    param($f)
    & $f.Module {
        $actual = Get-CpcDataDirectory
        Assert-Logging ($actual -eq (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CpcMigration/data')) 'Production default is not per-user local app data'
        function script:Get-CpcDataDirectory { Join-Path $script:Temp 'private-default' }
        $output = Start-Logging ''
        Assert-Logging ([IO.Path]::GetDirectoryName($output.StatePath) -eq (Get-CpcDataDirectory) -and $script:DocumentsCalls -eq 0) 'Private default not used'
        $acl = [IO.FileSystemAclExtensions]::GetAccessControl([IO.DirectoryInfo]::new((Get-CpcDataDirectory)))
        Assert-Logging ($acl.AreAccessRulesProtected) 'New private directory inherits permissions'
        foreach ($path in @($output.StatePath, $output.LogPath, ($output.StatePath + '.events.jsonl'))) { $null = Assert-CpcPrivatePath $path }
    }
}

Test-LoggingCase 'Unavailable explicit destination fails closed without Documents fallback' {
    param($f)
    & $f.Module {
        $blocked = Join-Path $script:Temp 'preferred-file'
        [IO.File]::WriteAllText($blocked, 'preferred-blocker')
        $null = [IO.Directory]::CreateDirectory($script:Documents)
        $fallback = Join-Path $script:Documents 'MigrateLog'
        [IO.File]::WriteAllText($fallback, 'fallback-blocker')
        $output = Invoke-CpcOperation -Action InitializeLogging -Data @{ Directory = $blocked }
        Assert-Logging ($output.OperationError -like '*Cannot initialize private log/journal*No migration started*') 'Private startup error not surfaced'
        Assert-Logging ($script:DocumentsCalls -eq 0) 'An insecure fallback was attempted'
        Assert-Logging (-not $output.StatePath -and -not $output.LogPath -and -not $output.Connected) 'Failure left an active path/connection'
        Assert-Logging ($null -eq $script:LogStream -and $null -eq $script:JournalLease -and $null -eq $script:PlanLease) 'Failure leaked an active stream/lease'
        Assert-Logging ($script:Violations.Count -eq 0) 'Initialization attempted cloud/auth/install boundary'
        Assert-Logging ([IO.File]::ReadAllText($blocked) -eq 'preferred-blocker' -and [IO.File]::ReadAllText($fallback) -eq 'fallback-blocker') 'Blockers modified'
        Assert-Logging (@(Get-ChildItem $script:Temp -Recurse -File).Count -eq 2) 'Failed initialization left unexpected session files'
    }
}

Test-LoggingCase 'Concurrent isolated sessions use unique paths and retain independent locks' {
    param($f)
    $second = New-LoggingFixture
    $shared = Join-Path $f.Root 'shared'
    $one = & $f.Module { param($path) Start-Logging $path } $shared
    $two = & $second.Module { param($path) Start-Logging $path } $shared
    & $f.Module {
        param($one, $two)
        Assert-Logging ($one.LogPath -ne $two.LogPath -and $one.StatePath -ne $two.StatePath -and $one.PlanId -ne $two.PlanId) 'Concurrent sessions collided'
        Assert-Logging (@(Get-ChildItem ([IO.Path]::GetDirectoryName($one.LogPath)) -Filter '*.log').Count -eq 2) 'Concurrent logs not both present'
        foreach ($path in @($one.LogPath, $two.LogPath, ($one.StatePath + '.lock'), ($two.StatePath + '.lock'))) {
            $blocked = $false
            try { $probe = [IO.File]::Open($path, 'Open', 'ReadWrite', 'None'); $probe.Dispose() }
            catch [IO.IOException] { $blocked = $true }
            Assert-Logging $blocked "Active session did not retain exclusive ownership: $path"
        }
    } $one $two
    # The second session writes in the first fixture; remove it before cleanup.
    Remove-LoggingFixtureModule $second
}

Test-LoggingCase 'Module removal releases log, journal and plan identity locks' {
    param($f)
    $output = & $f.Module { Start-Logging }
    & $f.Module {
        param($planLock)
        foreach ($path in @($script:LogPath, ($script:S.StatePath + '.lock'), $planLock)) {
            $blocked = $false
            try { $probe = [IO.File]::Open($path, 'Open', 'ReadWrite', 'None'); $probe.Dispose() }
            catch [IO.IOException] { $blocked = $true }
            Assert-Logging $blocked "Expected held lock: $path"
        }
    } $f.PlanLock
    Remove-LoggingFixtureModule $f
    foreach ($path in @($output.LogPath, $output.StatePath, ($output.StatePath + '.lock'), $f.PlanLock)) {
        $probe = [IO.File]::Open($path, 'Open', 'ReadWrite', 'None'); $probe.Dispose()
    }
}

Test-LoggingCase 'Save As keeps original session log and changes active journal and audit destination' {
    param($f)
    & $f.Module {
        $initial = Start-Logging
        $oldJournal = [IO.File]::ReadAllText($initial.StatePath)
        Set-LoggingData
        $newPath = Join-Path $script:Temp 'save-as/renamed.json'
        $output = Invoke-CpcOperation -Action Save -Data @{ Path = $newPath }
        Assert-Logging (-not $output.OperationError) "Save As failed: $($output.OperationError)"
        Assert-Logging ($output.LogPath -eq $initial.LogPath -and $output.StatePath -eq $newPath) 'Save As changed session log or retained wrong journal'
        Assert-Logging ($script:JournalLease.Path -eq $newPath) 'Save As lease not switched'
        $newJournal = [IO.File]::ReadAllText($newPath) | ConvertFrom-Json -AsHashtable
        Assert-Logging ($newJournal.Rows[0].VM -eq 'row-visible') 'Save As lost row state'
        Assert-Logging ([IO.File]::ReadAllText($initial.StatePath) -eq $oldJournal) 'Save As changed original journal'
        $oldEvents = [IO.File]::ReadAllText($initial.StatePath + '.events.jsonl')
        Write-CpcLog 'after-save-as-marker'
        Assert-Logging ([IO.File]::ReadAllText($initial.StatePath + '.events.jsonl') -eq $oldEvents) 'Later log appended to old audit'
        Assert-Logging ([IO.File]::ReadAllText($newPath + '.events.jsonl').Contains('after-save-as-marker')) 'Later log missing from new audit'
        Assert-Logging ((Read-Session).Contains('after-save-as-marker')) 'Original session log stopped receiving messages'
        $displayed = @(Read-Records | Where-Object Kind -EQ DisplayedResult)[-1].Details
        Assert-Logging (-not $displayed.ContainsKey('StatePath') -and $displayed.Action -eq 'Save') 'Save summary leaked path'
        $probe = [IO.File]::Open($initial.StatePath + '.lock', 'Open', 'ReadWrite', 'None'); $probe.Dispose()
        Assert-NoSecrets ((Read-Session) + [IO.File]::ReadAllText($newPath) + [IO.File]::ReadAllText($newPath + '.events.jsonl'))
    }
}

Test-LoggingCase 'Load retains receiving session log and switches active journal using only fixture context reads' {
    param($f)
    $source = & $f.Module {
        Set-LoadContext
        $initial = Start-Logging
        $script:S.Rows.Add(@{ VM = 'source'; ResourceGroup = 'source-rg';
            VmId = "/subscriptions/$($script:S.SubscriptionId)/resourceGroups/source-rg/providers/Microsoft.Compute/virtualMachines/source";
            UserPrincipalName = 'offline@example.invalid'; Phase = 'Mapped'; Readiness = 'Ready'; Attested = $true })
        $output = Invoke-CpcOperation -Action InitializeLogging
        Assert-Logging (-not $output.OperationError) "Source automatic save failed: $($output.OperationError)"
        return $initial
    }
    Remove-LoggingFixtureModule $f
    $receiver = New-LoggingFixture
    & $receiver.Module {
        param($source)
        Set-LoadContext
        $initial = Start-Logging
        $oldJournal = [IO.File]::ReadAllText($initial.StatePath)
        $script:S.Preflight['stale'] = @{ Nonce = 'receipt-must-not-persist' }
        $output = Invoke-CpcOperation -Action Load -Data @{ Path = $source.StatePath }
        Assert-Logging (-not $output.OperationError) "Load failed: $($output.OperationError)"
        Assert-Logging ($output.LogPath -eq $initial.LogPath -and $output.StatePath -eq $source.StatePath) 'Load moved session log or retained wrong journal'
        Assert-Logging ($output.PlanId -eq $source.PlanId -and $script:JournalLease.Path -eq $source.StatePath) 'Load has wrong plan/journal lease'
        Assert-Logging ($output.Rows.Count -eq 1 -and $output.Rows[0].VM -eq 'source') 'Loaded row missing'
        Assert-Logging ($output.Preflight.Count -eq 0 -and -not $output.Rows[0].Attested) 'Load retained stale approval/attestation'
        Assert-Logging ([IO.File]::ReadAllText($initial.StatePath) -eq $oldJournal) 'Load overwrote receiving automatic journal'
        Write-CpcLog 'after-load-marker'
        Assert-Logging ((Read-Session).Contains('after-load-marker')) 'Receiver session log stopped after Load'
        Assert-Logging ([IO.File]::ReadAllText($source.StatePath + '.events.jsonl').Contains('after-load-marker')) 'Loaded journal not receiving audit events'
        Assert-Logging (-not [IO.File]::ReadAllText($initial.StatePath + '.events.jsonl').Contains('after-load-marker')) 'Audit still targets pre-load journal'
        $displayed = @(Read-Records | Where-Object Kind -EQ DisplayedResult)[-1].Details
        Assert-Logging (-not $displayed.ContainsKey('StatePath') -and $displayed.Action -eq 'Load') 'Load summary leaked path'
        Assert-NoSecrets ((Read-Session) + [IO.File]::ReadAllText($source.StatePath))
        $probe = [IO.File]::Open($initial.StatePath + '.lock', 'Open', 'ReadWrite', 'None'); $probe.Dispose()
    } $source
    # Receiver owns the source journal and source plan lock until removal.
    Remove-LoggingFixtureModule $receiver
}

Test-LoggingCase 'Unsafe ACLs and reparse/network destinations are rejected without permission repair' {
    param($f)
    & $f.Module {
        $null = Start-Logging
        $shared = Join-Path $script:Temp 'shared'; $null = [IO.Directory]::CreateDirectory($shared)
        $info = [IO.DirectoryInfo]::new($shared)
        $acl = [IO.FileSystemAclExtensions]::GetAccessControl($info)
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-1-0'), 'ReadAndExecute', 'ContainerInherit, ObjectInherit', 'None', 'Allow'))
        [IO.FileSystemAclExtensions]::SetAccessControl($info, $acl)
        $before = [IO.FileSystemAclExtensions]::GetAccessControl($info).GetSecurityDescriptorSddlForm('Access, Owner, Group')
        foreach ($action in @('Save','Export')) {
            $result = Invoke-CpcOperation $action @{ Path = (Join-Path $shared 'unsafe.json'); Directory = $shared }
            Assert-Logging ($result.OperationError -like '*other principals*') "$action accepted insecure destination"
        }
        Assert-Logging ([IO.FileSystemAclExtensions]::GetAccessControl($info).GetSecurityDescriptorSddlForm('Access, Owner, Group') -eq $before) 'Existing shared ACL modified'
        Assert-Logging (@([IO.Directory]::EnumerateFileSystemEntries($shared)).Count -eq 0) 'Sensitive files created in shared folder'
        foreach ($path in @('\\server\share\journal.json', ($script:Temp + '\file.json:stream'))) {
            $caught = ''; try { Assert-CpcPrivatePath $path | Out-Null } catch { $caught = $_.Exception.Message }
            Assert-Logging ([bool]$caught) 'Network/alternate stream accepted'
        }
        $link = Join-Path $script:Temp 'junction'
        $null = New-Item -ItemType Junction -Path $link -Target $shared
        try {
            $caught = ''; try { Assert-CpcPrivatePath (Join-Path $link 'secret.json') | Out-Null } catch { $caught = $_.Exception.Message }
            Assert-Logging ($caught -like '*reparse*') 'Junction accepted'
        } finally { [IO.Directory]::Delete($link) }
    }
}

Test-LoggingCase 'File-level broad ACL blocks loading a journal without changing its bytes or permissions' {
    param($f)
    & $f.Module {
        Set-LoadContext
        $null = Start-Logging
        $path = Join-Path $script:Temp 'unsafe-load.json'
        [IO.File]::WriteAllText($path, 'sensitive-fixture-not-a-valid-journal')
        $info = [IO.FileInfo]::new($path)
        $acl = [IO.FileSystemAclExtensions]::GetAccessControl($info)
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-1-0'), 'Read', 'Allow'))
        [IO.FileSystemAclExtensions]::SetAccessControl($info, $acl)
        $before = [IO.FileSystemAclExtensions]::GetAccessControl($info).GetSecurityDescriptorSddlForm('Access, Owner, Group')
        $active = $script:S.StatePath
        $r = Invoke-CpcOperation Load @{ Path = $path }
        Assert-Logging ($r.OperationError -like '*other principals*' -and $r.StatePath -eq $active) 'Load parsed/accepted insecure file or changed active journal'
        Assert-Logging ([IO.File]::ReadAllText($path) -eq 'sensitive-fixture-not-a-valid-journal' -and -not [IO.File]::Exists("$path.lock")) 'Rejected load modified evidence'
        Assert-Logging ([IO.FileSystemAclExtensions]::GetAccessControl($info).GetSecurityDescriptorSddlForm('Access, Owner, Group') -eq $before) 'Load repaired ACL without consent'
    }
}

Test-LoggingCase 'Audit or log failures latch, block mutations, and require explicit durable restoration' {
    param($f)
    & $f.Module {
        $null = Start-Logging
        $blocker = [IO.File]::Open($script:S.StatePath + '.events.jsonl', 'Open', 'Read', 'Read')
        try {
            $failed = Invoke-CpcOperation InitializeLogging
            Assert-Logging ([bool]$failed.PersistenceFault) 'Audit failure did not latch'
            $restore = Invoke-CpcOperation RestorePersistence
            Assert-Logging ([bool]$restore.PersistenceFault) 'Failed restore cleared fault'
        } finally { $blocker.Dispose() }
        $restored = Invoke-CpcOperation RestorePersistence
        Assert-Logging (-not $restored.PersistenceFault -and -not $restored.OperationError) 'Durable audit restoration failed'
        $script:LogStream.Dispose()
        $failed = Invoke-CpcOperation InitializeLogging
        Assert-Logging ([bool]$failed.PersistenceFault) 'Closed log did not latch'
        $blocked = Invoke-CpcOperation RevokeExport
        Assert-Logging ([bool]$blocked.PersistenceFault -and $script:Violations.Count -eq 0) 'Fault allowed mutation'
        $before = [IO.File]::ReadAllText($script:LogPath)
        $script:S.Preflight['stale'] = @{ Stage = 'Capture' }
        $restored = Invoke-CpcOperation RestorePersistence
        Assert-Logging (-not $restored.OperationError -and -not $restored.PersistenceFault -and $restored.Preflight.Count -eq 0) 'Explicit recovery did not reopen closed log/clear approvals'
        Assert-Logging ((Read-Session).StartsWith($before, [StringComparison]::Ordinal)) 'Reopening log lost previous evidence'
        Assert-Logging ($script:Violations.Count -eq 0) 'Local restoration reached a cloud boundary'
    }
}

Test-LoggingCase 'Session rotation and oversize omission bound bytes without touching other evidence' {
    param($f)
    & $f.Module {
        $null = Start-Logging
        $other = Join-Path $script:Temp 'historical.log'; [IO.File]::WriteAllText($other, 'retain-me')
        $script:SessionLogLimit = 128KB
        foreach ($i in 1..30) { Write-CpcSessionRecord 'BoundedFixture' @{ Detail = 'x' * 30000 } }
        Write-CpcSessionRecord 'OversizedFixture' @{ Detail = 'secret-not-stored' * 10000 }
        $records = @(Read-Records | Where-Object Kind -EQ OversizedFixture)
        Assert-Logging ($records.Count -eq 1 -and $records[0].Details.Omitted) 'Oversize record not replaced with omission marker'
        $segments = @(Get-ChildItem ([IO.Path]::GetDirectoryName($script:LogPath)) -Filter '*.log*')
        Assert-Logging ($segments.Count -eq 4 -and @($segments | Where-Object Length -GT 128KB).Count -eq 0) 'Rotation exceeded size/count bound'
        Assert-Logging ([IO.File]::ReadAllText($other) -eq 'retain-me') 'Rotation modified historical evidence'
    }
}

Test-LoggingCase 'Scoped Cloud PC query encodes OData literals, follows pages and rejects unrelated data' {
    param($f)
    & $f.Module {
        $null = Start-Logging; $script:ScopedCalls = [collections.generic.list[string]]::new()
        $script:ScopedUpn = "o'connor+privacy@example.invalid"; $script:UnexpectedPc = $false
        $script:DirectoryCalls = 0
        function script:Invoke-MgGraphRequest {
            param($Uri)
            if ($Uri -like 'https://graph.microsoft.com/v1.0/users/*') {
                $script:DirectoryCalls++
                $key = if ($script:DirectoryCalls % 2 -eq 1) { [uri]::EscapeDataString($script:ScopedUpn) } else { '11111111-1111-1111-1111-111111111111' }
                Assert-Logging ($Uri -eq "https://graph.microsoft.com/v1.0/users/${key}?`$select=id,userPrincipalName") 'Directory lookup escaped UPN/immutable-ID scope'
                return @{ id = '11111111-1111-1111-1111-111111111111'; userPrincipalName = $script:ScopedUpn }
            }
            $script:ScopedCalls.Add($Uri)
            if ($Uri -notlike '*skiptoken=fixture') {
                Assert-Logging ([uri]::UnescapeDataString(([uri]$Uri).Query) -eq "?`$filter=userPrincipalName eq 'o''connor+privacy@example.invalid'") 'OData/URL encoding incorrect'
                return @{ value = @(); '@odata.nextLink' = 'https://graph.microsoft.com/beta/deviceManagement/virtualEndpoint/cloudPCs?skiptoken=fixture' }
            }
            @{ value = @(@{ id = 'fixture-pc'; userPrincipalName = $(if ($script:UnexpectedPc) { 'unrelated@example.invalid' } else { $script:ScopedUpn }); displayName = 'sensitive-device-name' }) }
        }
        $rows = @(@{ UserPrincipalName = $script:ScopedUpn })
        $pcs = @(Get-CpcCloudPcs $rows)
        Assert-Logging ($pcs.Count -eq 1 -and $script:ScopedCalls.Count -eq 2 -and $script:DirectoryCalls -eq 2) 'Scoped pagination lost device or skipped identity recheck'
        $script:UnexpectedPc = $true; $caught = ''
        try { Get-CpcCloudPcs $rows | Out-Null } catch { $caught = $_.Exception.Message }
        Assert-Logging ($caught -like '*unrelated*' -and $script:ScopedCalls.Count -eq 4) 'Unrelated result accepted or broad fallback occurred'
        Assert-Logging (-not (Read-Session).Contains('sensitive-device-name') -and -not (Read-Session).Contains('privacy@example')) 'Scoped response/query leaked to disk'
    }
}

foreach ($scenario in @('valid','empty','renamed','reused','missing-id','zero-return','missing-upn','404','403','500','post-rename','post-id','reject-filter','invalid-id','zero-id')) {
    Test-LoggingCase "Directory-bound UPN Cloud PC lookup: $scenario" {
        param($f)
        & $f.Module {
            param($Scenario)
            $null = Start-Logging
            $script:LookupScenario = $Scenario
            $script:DirectoryCalls = 0; $script:PcCalls = 0
            function script:Invoke-MgGraphRequest {
                param($Uri, $Method)
                Assert-Logging ($Method -eq 'GET') 'Lookup attempted a write'
                if ($Uri -like 'https://graph.microsoft.com/v1.0/users/*') {
                    $script:DirectoryCalls++
                    Assert-Logging ($Uri -eq 'https://graph.microsoft.com/v1.0/users/11111111-1111-1111-1111-111111111111?$select=id,userPrincipalName') 'Directory lookup not bound to recorded ID'
                    if ($script:LookupScenario -in @('404','403','500')) {
                        $ex = [InvalidOperationException]::new("Directory failure $script:LookupScenario")
                        $ex | Add-Member -NotePropertyName ResponseStatusCode -NotePropertyValue ([int]$script:LookupScenario)
                        throw $ex
                    }
                    $user = @{ id = '11111111-1111-1111-1111-111111111111'; userPrincipalName = 'old@example.invalid' }
                    switch ($script:LookupScenario) {
                        renamed { $user.userPrincipalName = 'new@example.invalid' }
                        reused { $user.id = '99999999-9999-9999-9999-999999999999' }
                        'missing-id' { $user.Remove('id') }
                        'zero-return' { $user.id = [guid]::Empty.ToString() }
                        'missing-upn' { $user.Remove('userPrincipalName') }
                        'post-rename' { if ($script:DirectoryCalls -gt 1) { $user.userPrincipalName = 'new@example.invalid' } }
                        'post-id' { if ($script:DirectoryCalls -gt 1) { $user.id = '99999999-9999-9999-9999-999999999999' } }
                    }
                    return $user
                }
                $script:PcCalls++
                Assert-Logging ($Uri.StartsWith('https://graph.microsoft.com/beta/deviceManagement/virtualEndpoint/cloudPCs?') -and
                    [uri]::UnescapeDataString(([uri]$Uri).Query) -eq "?`$filter=userPrincipalName eq 'old@example.invalid'") 'Invalid filter or tenant-wide fallback'
                if ($script:LookupScenario -eq 'reject-filter') {
                    $ex = [InvalidOperationException]::new('Unsupported UPN filter fixture')
                    $ex | Add-Member -NotePropertyName ResponseStatusCode -NotePropertyValue 400
                    throw $ex
                }
                if ($script:LookupScenario -eq 'empty') { return @{ value = @() } }
                @{ value = @(@{ id = 'fixture-pc'; userPrincipalName = 'old@example.invalid'; displayName = 'sensitive-device-name' }) }
            }
            $row = @{ UserId = '11111111-1111-1111-1111-111111111111'; UserPrincipalName = 'old@example.invalid' }
            if ($Scenario -eq 'invalid-id') { $row.UserId = 'invalid' }
            if ($Scenario -eq 'zero-id') { $row.UserId = [guid]::Empty.ToString() }
            $before = $row | ConvertTo-Json -Compress
            $emitted = [collections.generic.list[object]]::new(); $caught = ''
            try { Get-CpcCloudPcs @($row) | ForEach-Object { $emitted.Add($_) } } catch { $caught = $_.Exception.Message }
            if ($Scenario -in @('valid','empty')) {
                $expected = if ($Scenario -eq 'valid') { 1 } else { 0 }
                Assert-Logging (-not $caught -and $emitted.Count -eq $expected -and $script:DirectoryCalls -eq 2 -and $script:PcCalls -eq 1) 'Valid result failed or identity recheck skipped'
                if ($emitted.Count) { Assert-Logging (-not $emitted[0].ContainsKey('userId')) 'Synthesized a fictional Cloud PC API property' }
            } else {
                Assert-Logging ([bool]$caught -and $emitted.Count -eq 0) 'Failure emitted trusted partial results'
                $expectedPcCalls = if ($Scenario -in @('post-rename','post-id','reject-filter')) { 1 } else { 0 }
                $expectedDirectoryCalls = if ($Scenario -in @('invalid-id','zero-id')) { 0 } elseif ($Scenario -in @('post-rename','post-id')) { 2 } else { 1 }
                Assert-Logging ($script:PcCalls -eq $expectedPcCalls -and $script:DirectoryCalls -eq $expectedDirectoryCalls) 'Failure retried, fell back, or skipped expected verification'
                if ($Scenario -eq 'reject-filter') { Assert-Logging ($caught -like '*Unsupported UPN filter fixture*') 'Wrong filter failure' }
            }
            Assert-Logging (($row | ConvertTo-Json -Compress) -eq $before) 'Lookup silently rebound journal identity'
            Assert-Logging (-not (Read-Session).Contains('sensitive-device-name') -and -not (Read-Session).Contains('old@example.invalid') -and -not (Read-Session).Contains('new@example.invalid')) 'Directory/scoped response leaked'
        } $scenario
    }
}

if ((Get-FileHash $corePath -Algorithm SHA256).Hash -ne $initialHash) {
    $script:Results.Add([pscustomobject]@{ Test = 'Core remains unmodified'; Passed = $false; Error = 'Core hash changed during testing' })
}
$passed = @($script:Results | Where-Object Passed).Count
$failed = $script:Results.Count - $passed
Write-Host "Logging tests: $($script:Results.Count) total; $passed passed; $failed failed."
if ($failed) { exit 1 }
exit 0