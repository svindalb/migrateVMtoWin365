#requires -Version 7.2
<#
Standalone, dependency-free recovery regressions against the CURRENT Core module.
Run: pwsh -NoProfile -File tests/Test-Recovery.ps1
Every case imports a fresh module and removes it in finally. All Az/Mg commands
found in Core are fail-closed stubs; explicitly permitted reads/deletes use fixtures.
Only journal cases use real files: unique temporary directories and generated
PlanId locks in Core's per-user local lock directory (removed after each case). No auth,
dependency installation, source VM mutation, or live Azure/Graph access is allowed.
FAIL denotes an independently executed regression, not a skipped/pending test.
#>
[CmdletBinding()]
param()
Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$corePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'CpcMigration.Core.psm1'
$script:Results = [collections.generic.list[object]]::new()
$initialHash = (Get-FileHash $corePath -Algorithm SHA256).Hash
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'CpcMigration.Workflow.psm1') -Force

$setup = {
    param([bool]$Journal, [string[]]$CloudCommands)
    $script:PSModuleAutoLoadingPreference = 'None'
    $script:OriginalGraph = (Get-Command Invoke-CpcGraph).ScriptBlock
    $script:BoundaryViolations = [collections.generic.list[string]]::new()
    foreach ($command in $CloudCommands) {
        Set-Item "function:script:$command" {
            $script:BoundaryViolations.Add($MyInvocation.MyCommand.Name)
            throw "UNMOCKED BOUNDARY: $($MyInvocation.MyCommand.Name)"
        }
    }
    function script:Import-Module {
        $script:BoundaryViolations.Add('Import-Module'); throw 'UNMOCKED BOUNDARY: Import-Module'
    }
    function script:Check([bool]$Condition, [string]$Message) {
        if (-not $Condition) { throw "ASSERT: $Message" }
    }
    function script:ExpectFailure([scriptblock]$Body, [string]$Pattern) {
        $message = ''
        try { & $Body | Out-Null } catch { $message = $_.Exception.Message }
        Check ([bool]$message) 'Expected rejection, but operation returned successfully'
        Check ($message -match $Pattern) "Wrong rejection: $message (expected $Pattern)"
    }
    function script:StateFingerprint {
        # Logs may legitimately acquire a failure entry; transactional plan data may not.
        @{ PlanId = $script:S.PlanId; Config = $script:S.Config; Rows = @($script:S.Rows)
           Preflight = $script:S.Preflight; Checks = @($script:S.Checks)
           GroupId = $script:S.GroupId; UserSettingId = $script:S.UserSettingId
           StatePath = $script:S.StatePath } | ConvertTo-Json -Depth 30 -Compress
    }
    Initialize-CpcState
    $script:TestPlanIds = [collections.generic.list[string]]::new()
    $script:TestPlanIds.Add($script:S.PlanId)
    function script:CheckLeaseHeld([string]$Path) {
        $blocked = $false
        try { $probe = [IO.File]::Open($Path, 'OpenOrCreate', 'ReadWrite', 'None'); $probe.Dispose() }
        catch [IO.IOException] { $blocked = $true }
        Check $blocked "Lease was not held: $Path"
    }
    function script:CheckLeaseFree([string]$Path) {
        $probe = [IO.File]::Open($Path, 'OpenOrCreate', 'ReadWrite', 'None'); $probe.Dispose()
    }
    $script:Signals = $null
    $script:S.TenantId = '22222222-2222-2222-2222-222222222222'
    $script:S.SubscriptionId = '33333333-3333-3333-3333-333333333333'
    $script:S.Connected = $true
    $script:S.Config = @{
        PolicyId = '44444444-4444-4444-4444-444444444444'
        SkuId = '55555555-5555-5555-5555-555555555555'; TargetDiskGiB = 128
        StorageId = "/subscriptions/$($script:S.SubscriptionId)/resourceGroups/staging/providers/Microsoft.Storage/storageAccounts/offlinetest"
        Container = 'private'; SnapshotResourceGroup = 'snapshots'
    }
    $script:S.StatePath = ''
    $script:Audit = [collections.generic.list[object]]::new()
    $script:Saves = [collections.generic.list[object]]::new()
    if (-not $Journal) {
        function script:Write-CpcAudit($EventName, $Details) { $script:Audit.Add(@{ Event = $EventName; Details = $Details }) }
        function script:Save-CpcState($State = $script:S, $Lease = $null) {
            $script:Saves.Add(($State | ConvertTo-Json -Depth 30 -Compress))
        }
    }
    function script:Get-AzContext {
        @{ Tenant = @{ Id = $script:S.TenantId }; Subscription = @{ Id = $script:S.SubscriptionId }; Environment = @{ Name = 'AzureCloud' } }
    }
    function script:Get-MgContext { @{ TenantId = $script:S.TenantId; Environment = 'Global' } }
    function script:Get-CpcStorage { @{ Context = 'OFFLINE-NO-CREDENTIAL'; Account = @{} } }
    $script:Row = @{
        Selected = $true; VmId = "/subscriptions/$($script:S.SubscriptionId)/resourceGroups/source-rg/providers/Microsoft.Compute/virtualMachines/source"
        VM = 'source'; ResourceGroup = 'source-rg'; Location = 'eastus'
        UserId = '11111111-1111-1111-1111-111111111111'; UserPrincipalName = 'test@example.invalid'
        Phase = 'Mapped'; Readiness = 'Ready'; Attested = $true; Guest = @{ Evidence = 'old assessment' }
        Detail = ''; CheckedUtc = ''; LastError = 'old error'; SnapshotName = 'cpcm-offline'
        SnapshotId = "/subscriptions/$($script:S.SubscriptionId)/resourceGroups/snapshots/providers/Microsoft.Compute/snapshots/cpcm-offline"
        SourceDiskId = "/subscriptions/$($script:S.SubscriptionId)/resourceGroups/source-rg/providers/Microsoft.Compute/disks/os"
        SourceVmUniqueId = 'source-immutable-id'; VhdCopyId = 'copy-os'; VmgsCopyId = 'copy-vmgs'
        CaptureStartedUtc = [datetimeoffset]::UtcNow.AddHours(-4).ToString('o')
        ImportStartedUtc = [datetimeoffset]::UtcNow.AddHours(-3).ToString('o')
        ImportId = ''; ImportStatus = ''; UsageStatus = ''; LicenseAssignedUtc = ''; ValidatedUtc = ''
        CloudPcId = ''; CloudPcStatus = ''; ArtifactRemovalApproved = $false
    }
    $script:Row.VhdBlob = "$($script:S.PlanId)/$($script:Row.UserId)/$($script:Row.SnapshotName)/os.vhd"
    $script:Row.VmgsBlob = "$($script:S.PlanId)/$($script:Row.UserId)/$($script:Row.SnapshotName)/vmgs.vhd"
    $script:S.Rows.Add($script:Row)
    $script:S.Preflight[$script:Row.VmId] = @{ Stage = 'old approval'; Nonce = 'must survive rejected candidate' }
    $script:Temp = ''
    if ($Journal) {
        $script:Temp = Join-Path ([IO.Path]::GetTempPath()) ('CpcRecovery-' + [guid]::NewGuid().ToString('N'))
        $null = [IO.Directory]::CreateDirectory($script:Temp)
    }

    function script:PrepareMap {
        $script:S.Config.ExistingGroupId = '66666666-6666-6666-6666-666666666666'
        $script:S.Catalog.Vms = @(@{ Id = $script:Row.VmId; Name = 'source'; ResourceGroup = 'source-rg'; Location = 'eastus' })
        function script:Update-CpcLicenseCatalog { }
        function script:Assert-CpcSelectedGroup { param($Config, $Rows) @{ displayName = 'offline group' } }
        function script:Assert-CpcLicenseTarget { param($Catalog, $SkuId, $Count) @{ StorageGB = 128; DisplayName = 'offline SKU'; Available = 10 } }
        $script:MapData = @{ Config = $script:S.Config.Clone(); Mappings = @(@{ VmId = $script:Row.VmId; UserPrincipalName = $script:Row.UserPrincipalName }) }
    }

    function script:PrepareLicense {
        $script:Row.Phase = 'LicenseUnknown'
        $script:Row.ImportId = '77777777-7777-7777-7777-777777777777'; $script:Row.ImportStatus = 'succeeded'
        $script:Row.LicenseStartedUtc = [datetimeoffset]::UtcNow.AddHours(-2).ToString('o')
        $script:LicenseData = @{ Evidence = 'Reviewed Entra audit request offline-123'; AssignedUtc = [datetimeoffset]::UtcNow.AddHours(-1).ToString('o') }
        $script:User = @{ id = $script:Row.UserId; userPrincipalName = $script:Row.UserPrincipalName; accountEnabled = $true
            assignedLicenses = @(@{ skuId = $script:S.Config.SkuId })
            licenseAssignmentStates = @(@{ skuId = $script:S.Config.SkuId; state = 'Active'; assignedByGroup = $null; error = 'None' }) }
        # No fictional cloudPC.userId. The optional creation field below exists
        # only to exercise legacy recovery chronology, NOT public API coverage.
        $script:PC = @{ id = '88888888-8888-8888-8888-888888888888'
            userPrincipalName = $script:Row.UserPrincipalName; provisioningPolicyId = $script:S.Config.PolicyId
            createdDateTime = [datetimeoffset]::UtcNow.AddMinutes(-30).ToString('o'); status = 'provisioned' }
        $script:PCs = @($script:PC)
        $script:PcDetail = $script:PC
        $script:Policy = @{ id = $script:S.Config.PolicyId; provisioningType = 'dedicated'; managedBy = 'windows365'; userExperienceType = 'cloudPc' }
        $script:Reads = [collections.generic.list[string]]::new()
        function script:Get-CpcImportResult {
            $script:BoundaryViolations.Add('Get-CpcImportResult')
            throw 'Import gone: this read must NEVER be attempted by license reconciliation'
        }
        function script:Invoke-CpcGraph {
            param([string]$Method = 'GET', [string]$Path, $Body)
            if ($Method -ne 'GET') { $script:BoundaryViolations.Add("Graph $Method"); throw 'Graph mutation forbidden' }
            $script:Reads.Add($Path)
            if ($Path -like "/v1.0/users/$($script:Row.UserId)?*") { return $script:User }
            if ($Path -eq "$script:Endpoint/cloudPCs/$($script:PCs[0].id)") { return $script:PcDetail }
            if ($Path -eq "$script:Endpoint/provisioningPolicies/$($script:S.Config.PolicyId)") { return $script:Policy }
            $script:BoundaryViolations.Add($Path); throw "Unexpected Graph read: $Path"
        }
        function script:Get-CpcGraphCollection {
            param([string]$Path)
            $script:Reads.Add($Path)
            if ($Path.StartsWith("$script:Endpoint/cloudPCs?`$filter=")) { return $script:PCs }
            $script:BoundaryViolations.Add($Path); throw "Unexpected Graph collection: $Path"
        }
    }

    function script:PrepareCloudPcObservation {
        PrepareLicense
        $script:Row.Phase = 'Mapped'
        foreach ($key in @('SnapshotName','SnapshotId','SourceDiskId','SourceVmUniqueId','VhdBlob','VmgsBlob','VhdCopyId','VmgsCopyId',
            'CaptureStartedUtc','ImportStartedUtc','ImportId','ImportStatus','UsageStatus','LicenseStartedUtc','LicenseAssignedUtc','ValidatedUtc')) {
            $script:Row[$key] = ''
        }
        $script:Row.CloudPcName = ''; $script:Row.LastError = ''
        $script:User.assignedLicenses = @(); $script:User.licenseAssignmentStates = @()
        $script:PC.Remove('createdDateTime')
        $script:PC.status = 'deprovisioning'; $script:PC.displayName = 'old-pc'
        function script:Get-CpcImportResult {
            @{ assignedUserPrincipalName = $script:Row.UserPrincipalName; importStatus = 'succeeded'; usageStatus = 'notUsed' }
        }
    }

    function script:PrepareArtifacts {
        $script:Row.Phase = 'CopyFailed'
        $script:Snapshot = @{ Name = $script:Row.SnapshotName; Id = $script:Row.SnapshotId; ProvisioningState = 'Succeeded'
            Tags = @{ CpcMigrationPlan = $script:S.PlanId; SourceVmId = $script:Row.VmId }
            CreationData = @{ SourceResourceId = $script:Row.SourceDiskId } }
        $script:SnapshotPresent = $true
        $script:Blobs = @{
            ($script:Row.VhdBlob) = @{ CopyId = $script:Row.VhdCopyId; Status = 'Failed' }
            ($script:Row.VmgsBlob) = @{ CopyId = $script:Row.VmgsCopyId; Status = 'Success' }
        }
        $script:Deletes = [collections.generic.list[string]]::new()
        $script:Revokes = 0; $script:CopyReads = @{}; $script:ChangeCopyOnReplay = $false
        $script:RecoveryUser = @{ id = $script:Row.UserId; userPrincipalName = $script:Row.UserPrincipalName; assignedLicenses = @() }
        $script:RecoveryPCs = @(); $script:RecoverySkus = @()
        function script:Invoke-CpcGraph {
            param([string]$Method = 'GET', [string]$Path, $Body)
            if ($Method -eq 'GET' -and $Path -like "/v1.0/users/$($script:Row.UserId)?*") { return $script:RecoveryUser }
            $script:BoundaryViolations.Add("Graph $Method $Path"); throw 'Unexpected Graph boundary'
        }
        function script:Get-CpcGraphCollection {
            param([string]$Path)
            if ($Path.StartsWith("$script:Endpoint/cloudPCs?`$filter=")) { return $script:RecoveryPCs }
            if ($Path -eq '/v1.0/subscribedSkus') { return $script:RecoverySkus }
            $script:BoundaryViolations.Add($Path); throw 'Unexpected Graph collection'
        }
        function script:Get-CpcImportResult { $script:BoundaryViolations.Add('Get-CpcImportResult'); throw 'No import lookup expected in artifact removal' }
        function script:Get-AzSnapshot {
            param($ResourceGroupName, $SnapshotName)
            Check ($ResourceGroupName -eq $script:S.Config.SnapshotResourceGroup) 'Snapshot read escaped configured RG'
            if ($SnapshotName) { Check ($SnapshotName -eq $script:Row.SnapshotName) 'Snapshot read escaped journal name' }
            if ($script:SnapshotPresent) { return $script:Snapshot }
        }
        function script:Get-AzStorageBlob {
            param($Container, $Prefix, $Context)
            Check ($Container -eq $script:S.Config.Container -and $Context -eq 'OFFLINE-NO-CREDENTIAL') 'Wrong storage read scope'
            foreach ($name in @($script:Blobs.Keys)) { if ($name.StartsWith($Prefix, [StringComparison]::Ordinal)) { @{ Name = $name } } }
        }
        function script:Get-AzStorageBlobCopyState {
            param($Container, $Blob, $Context)
            Check ($Container -eq $script:S.Config.Container -and $script:Blobs.ContainsKey($Blob)) 'Wrong copy scope'
            if (-not $script:CopyReads.ContainsKey($Blob)) { $script:CopyReads[$Blob] = 0 }
            $script:CopyReads[$Blob]++
            if ($script:ChangeCopyOnReplay -and $script:CopyReads[$Blob] -gt 1) { return @{ CopyId = 'external-replacement'; Status = 'Success' } }
            return $script:Blobs[$Blob]
        }
        function script:Revoke-AzSnapshotAccess {
            param($ResourceGroupName, $SnapshotName)
            Check ($ResourceGroupName -eq $script:S.Config.SnapshotResourceGroup -and $SnapshotName -eq $script:Row.SnapshotName) 'Revoke escaped snapshot scope'
            $script:Revokes++
        }
        function script:Remove-AzStorageBlob {
            param($Container, $Blob, $Context, [switch]$Force)
            Check ($Container -eq $script:S.Config.Container -and $Context -eq 'OFFLINE-NO-CREDENTIAL' -and $Force) 'Wrong blob delete scope'
            Check ($script:Blobs.ContainsKey($Blob)) 'Deleted absent blob'
            $script:Deletes.Add("blob:$Blob"); $script:Blobs.Remove($Blob)
        }
        function script:Remove-AzSnapshot {
            param($ResourceGroupName, $SnapshotName, [switch]$Force)
            Check ($ResourceGroupName -eq $script:S.Config.SnapshotResourceGroup -and $SnapshotName -eq $script:Row.SnapshotName -and $Force) 'Snapshot delete escaped scope'
            $script:Deletes.Add("snapshot:$SnapshotName"); $script:SnapshotPresent = $false
        }
    }
}

function Invoke-RecoveryTest {
    param([string]$Name, [scriptblock]$Body, [object[]]$Arguments = @(), [switch]$Journal, [switch]$Peer)
    $module = $null; $peerModule = $null; $temp = ''; $peerTemp = ''; $failure = ''
    try {
        # Re-scan each import: another agent may be editing Core during development.
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($corePath, [ref]$tokens, [ref]$errors)
        if ($errors.Count) { throw ('Core parse errors: ' + ($errors.Message -join '; ')) }
        $cloud = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true) |
            ForEach-Object { $_.GetCommandName() } | Where-Object { $_ -match '^[^-]+-(Az|Mg)' } | Sort-Object -Unique)
        $cloud += @('Install-Module', 'Invoke-RestMethod', 'Invoke-WebRequest', 'Start-Sleep')
        $module = Import-Module $corePath -Force -PassThru
        & $module $setup ([bool]$Journal) $cloud
        $temp = & $module { $script:Temp }
        if ($Peer) {
            # A separately registered dynamic module gives independent script state
            # and OnRemove without Import-Module -Force unloading the first instance.
            $peerModule = New-Module -Name ('CpcRecoveryPeer-' + [guid]::NewGuid().ToString('N')) -ScriptBlock ([scriptblock]::Create([IO.File]::ReadAllText($corePath))) |
                Import-Module -PassThru
            & $peerModule $setup $true $cloud
            $peerTemp = & $peerModule { $script:Temp }
            & $module { param($Other) $script:Peer = $Other } $peerModule
        }
        & $module $Body @Arguments | Out-Null
        & $module { Check ($script:BoundaryViolations.Count -eq 0) ('Forbidden/unmocked calls: ' + ($script:BoundaryViolations -join ', ')) }
    } catch {
        $failure = $_.Exception.Message + ' | ' + $_.ScriptStackTrace
    } finally {
        foreach ($instance in @($peerModule, $module)) {
            if (-not $instance) { continue }
            $violations = @(& $instance { if (Get-Variable BoundaryViolations -Scope Script -ErrorAction SilentlyContinue) { $script:BoundaryViolations.ToArray() } })
            if ($violations.Count) { $failure += ' | BOUNDARY VIOLATIONS: ' + ($violations -join ', ') }
            $lockPaths = @(& $instance {
                foreach ($id in $script:TestPlanIds) { Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) "CpcMigration/locks/$id.lock" }
            })
            Remove-Module $instance -Force -ErrorAction SilentlyContinue
            foreach ($path in $lockPaths) {
                # The other instance may still own a shared PlanId until removed.
                try { if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) } } catch [IO.IOException] { }
            }
        }
        if ($temp -and [IO.Directory]::Exists($temp)) { [IO.Directory]::Delete($temp, $true) }
        if ($peerTemp -and [IO.Directory]::Exists($peerTemp)) { [IO.Directory]::Delete($peerTemp, $true) }
    }
    $status = if ($failure) { 'FAIL' } else { 'PASS' }
    $script:Results.Add([pscustomobject]@{ Status = $status; Name = $Name; Detail = $failure })
    Write-Host ("{0}: {1}" -f $status, $Name)
    if ($failure) { Write-Host $failure }
}

# User-setting PATCH contract: preserve settings, never resend the GET envelope.
foreach ($source in @('image','snapshot')) {
    Invoke-RecoveryTest "User setting source body: $source preserves live writable fields" {
        param($Source)
        $setting = @{
            id = 'server-id'; displayName = 'owned-name'; localAdminEnabled = $true; resetEnabled = $false
            provisioningSourceType = 'snapshot'; createdDateTime = 'server-time'; lastModifiedDateTime = 'server-time'
            '@odata.context' = 'server-metadata'; assignments = @(@{ id = 'assignment' })
            selfServiceEnabled = $true; notificationSetting = @{ restartPromptsDisabled = $true }
            restorePointSetting = @{ frequencyType = 'twelveHours'; frequencyInHours = 12; userRestoreEnabled = $true }
            crossRegionDisasterRecoverySetting = @{ crossRegionDisasterRecoveryEnabled = $false; disasterRecoveryType = 'notConfigured'; disasterRecoveryNetworkSetting = $null; maintainCrossRegionRestorePointEnabled = $true; userInitiatedDisasterRecoveryAllowed = $false }
        }
        $before = $setting | ConvertTo-Json -Depth 20 -Compress
        $body = New-CpcUserSettingSourceBody $setting $Source
        Check ($body.provisioningSourceType -eq $Source -and $body.displayName -eq $setting.displayName) 'Source/name incorrect'
        Check ($body.localAdminEnabled -eq $true -and $body.resetEnabled -eq $false) 'Existing booleans changed'
        Check ($body['@odata.type'] -eq '#microsoft.graph.cloudPcUserSetting') 'Entity type missing'
        foreach ($field in @('restorePointSetting','crossRegionDisasterRecoverySetting')) {
            Check (($body[$field] | ConvertTo-Json -Compress) -eq ($setting[$field] | ConvertTo-Json -Compress)) "Changed $field"
        }
        foreach ($field in @('id','assignments','createdDateTime','lastModifiedDateTime','@odata.context','selfServiceEnabled','notificationSetting')) {
            Check (-not $body.ContainsKey($field)) "Read-only/relationship/deprecated field leaked: $field"
        }
        $body.restorePointSetting.userRestoreEnabled = $false
        Check (($setting | ConvertTo-Json -Depth 20 -Compress) -eq $before) 'Body aliases/mutates GET result'
    } -Arguments @($source)
}
foreach ($field in @('displayName','localAdminEnabled','resetEnabled')) {
    Invoke-RecoveryTest "User setting missing $field fails closed" {
        param($Field)
        $setting = @{ displayName = 'owned'; localAdminEnabled = $false; resetEnabled = $false }
        $setting.Remove($Field)
        ExpectFailure { New-CpcUserSettingSourceBody $setting 'image' } 'Refusing to guess'
    } -Arguments @($field)
}
Invoke-RecoveryTest 'User setting source body accepts false booleans and absent optional settings' {
    $body = New-CpcUserSettingSourceBody ([pscustomobject]@{ displayName = 'owned'; localAdminEnabled = $false; resetEnabled = $false }) 'image'
    Check ($body.Count -eq 5 -and $body.localAdminEnabled -eq $false -and $body.resetEnabled -eq $false) 'False values were treated as absent'
    ExpectFailure { New-CpcUserSettingSourceBody @{ displayName = 'owned'; localAdminEnabled = 'false'; resetEnabled = $false } 'image' } 'Refusing to guess'
}

foreach ($scenario in @('Success','AlreadyImage','MissingRequired','PatchRejected','StaleReadback','ReadbackFailed','ChangedAssignments','ExpandedGroup','UnfinishedRow')) {
    Invoke-RecoveryTest "UseImage real request serialization and guards: $scenario" {
        param($Scenario)
        $script:S.StatePath = 'OFFLINE'
        $script:S.GroupId = '66666666-6666-6666-6666-666666666666'
        $script:S.Config.ExistingGroupId = $script:S.GroupId
        $script:S.UserSettingId = '99999999-9999-9999-9999-999999999999'
        $script:Row.Phase = 'Cleaned'
        $script:Row.CloudPcId = '88888888-8888-8888-8888-888888888888'
        $script:Scenario = $Scenario
        $script:Writes = [collections.generic.list[object]]::new()
        $script:SettingReads = 0
        $script:Setting = @{
            id = $script:S.UserSettingId; displayName = "Snapshot-$($script:S.PlanId)"
            provisioningSourceType = 'snapshot'; localAdminEnabled = $false; resetEnabled = $false
            restorePointSetting = @{ frequencyType = 'twelveHours'; frequencyInHours = 12; userRestoreEnabled = $false }
            assignments = @(@{ target = @{ '@odata.type' = '#microsoft.graph.cloudPcManagementGroupAssignmentTarget'; groupId = $script:S.GroupId } })
        }
        if ($Scenario -eq 'AlreadyImage') { $script:Setting.provisioningSourceType = 'image' }
        if ($Scenario -eq 'MissingRequired') { $script:Setting.Remove('resetEnabled') }
        if ($Scenario -eq 'UnfinishedRow') { $script:Row.Phase = 'Provisioning' }
        # Group selection has independent integration coverage. The direct member
        # guard and all Graph serialization below remain real and fail closed.
        function script:Assert-CpcSelectedGroup { }
        function script:Invoke-MgGraphRequest {
            param($Method, $Uri, $Headers, $OutputType, $ErrorAction, $Body, $ContentType)
            $settingUri = "https://graph.microsoft.com$script:Endpoint/userSettings/$($script:S.UserSettingId)"
            if ($Method -eq 'PATCH' -and $Uri -eq $settingUri) {
                $payload = $Body | ConvertFrom-Json -AsHashtable
                $script:Writes.Add($payload)
                Check ($ContentType -eq 'application/json') 'Wrong content type'
                Check ($payload.ContainsKey('displayName') -and $payload.ContainsKey('localAdminEnabled') -and $payload.ContainsKey('resetEnabled')) 'requiredFieldsNotProvided regression'
                Check ($payload.displayName -eq $script:Setting.displayName -and $payload.localAdminEnabled -eq $false -and $payload.resetEnabled -eq $false) 'PATCH alters existing configuration'
                Check ($payload.provisioningSourceType -eq 'image' -and -not $payload.ContainsKey('assignments')) 'Wrong source or assignment write'
                Check ($payload.restorePointSetting.frequencyInHours -eq 12) 'Restore settings lost'
                if ($script:Scenario -eq 'PatchRejected') { throw 'requiredFieldsNotProvided fixture' }
                if ($script:Scenario -ne 'StaleReadback') { $script:Setting.provisioningSourceType = 'image' }
                return
            }
            if ($Method -eq 'GET' -and $Uri -eq "$settingUri`?`$expand=assignments") {
                $script:SettingReads++
                if ($script:SettingReads -gt 1 -and $script:Scenario -eq 'ReadbackFailed') { throw 'Readback fixture unavailable' }
                if ($script:SettingReads -gt 1 -and $script:Scenario -eq 'ChangedAssignments') { $script:Setting.assignments = @() }
                return $script:Setting
            }
            if ($Method -eq 'GET' -and $Uri -eq "https://graph.microsoft.com/v1.0/groups/$($script:S.GroupId)/members?`$select=id") {
                $members = @(@{ id = $script:Row.UserId })
                if ($script:Scenario -eq 'ExpandedGroup') { $members += @{ id = 'foreign-user' } }
                return @{ value = $members }
            }
            $script:BoundaryViolations.Add("$Method $Uri"); throw 'Unexpected Graph call (no assignment/license/group writes permitted)'
        }
        $before = StateFingerprint
        $result = Invoke-CpcOperation 'UseImage'
        Check ((StateFingerprint) -eq $before) 'UseImage changed row phase, IDs or plan configuration'
        if ($Scenario -in @('Success','AlreadyImage')) {
            Check (-not $result.OperationError) "UseImage unexpectedly failed: $($result.OperationError)"
            Check (@($script:S.Logs | Where-Object { $_ -match 'confirmed as image' }).Count -eq 1) 'No read-back-confirmed success message'
            Check ($script:SettingReads -eq 2) 'No fresh verification read'
        } else {
            Check ([bool]$result.OperationError) 'Expected blocking error'
            Check (@($script:S.Logs | Where-Object { $_ -match 'confirmed as image' }).Count -eq 0) 'False success after failure'
        }
        $expectedWrites = if ($Scenario -in @('AlreadyImage','MissingRequired','ExpandedGroup','UnfinishedRow')) { 0 } else { 1 }
        Check ($script:Writes.Count -eq $expectedWrites) 'Unexpected/duplicate PATCH; no automatic mutation retries allowed'
    } -Arguments @($scenario)
}

# Request-level Graph regressions: leave Invoke-CpcGraph and collection paging real.
foreach ($cast in @('memberOf', 'transitiveMemberOf')) {
    Invoke-RecoveryTest "Graph $cast cast: advanced headers/count on first AND nextLink page" {
        param($Cast)
        $script:Requests = [collections.generic.list[object]]::new()
        $script:CastPath = "/v1.0/users/$($script:Row.UserId)/$Cast/microsoft.graph.group"
        function script:Invoke-MgGraphRequest {
            param($Method, $Uri, $Headers, $OutputType, $ErrorAction)
            $script:Requests.Add(@{ Method = $Method; Uri = $Uri; Headers = $Headers.Clone() })
            if ($script:Requests.Count -eq 1) { return @{ value = @(@{ id = 'page-one' }); '@odata.nextLink' = "https://graph.microsoft.com$script:CastPath`?`$skiptoken=opaque%2Btoken" } }
            @{ value = @(@{ id = 'page-two' }) }
        }
        $items = @(Get-CpcGraphCollection "$script:CastPath`?`$select=id")
        Check ($items.Count -eq 2 -and $script:Requests.Count -eq 2) 'Pagination did not consume exactly two pages'
        foreach ($request in $script:Requests) {
            Check ($request.Headers.ConsistencyLevel -eq 'eventual') 'Missing eventual consistency'
            Check ([regex]::Matches($request.Uri, '\$count=true').Count -eq 1) 'Missing/duplicate $count=true'
            Check ($request.Headers.Prefer -eq 'include-unknown-enum-members') 'Existing Prefer header lost'
        }
        Check ($script:Requests[1].Uri.Contains('$skiptoken=opaque%2Btoken')) 'Opaque nextLink token changed'
    } -Arguments @($cast)
}
foreach ($query in @('', '?$count=true', '?%24count=true&$select=id')) {
    Invoke-RecoveryTest "Graph cast count normalization: '$query'" {
        param($Query)
        function script:Invoke-MgGraphRequest { param($Method,$Uri,$Headers,$OutputType,$ErrorAction) $script:RequestUri = $Uri; @{ value = @() } }
        $null = Invoke-CpcGraph -Path ("/v1.0/groups/id/transitiveMemberOf/microsoft.graph.group" + $Query)
        Check ([regex]::Matches($script:RequestUri, '(?:\$|%24)count=true').Count -eq 1) 'Count missing/duplicated'
    } -Arguments @($query)
}
Invoke-RecoveryTest 'Graph cast rejects explicit $count=false before outgoing request' {
    ExpectFailure { Invoke-CpcGraph -Path '/v1.0/users/id/memberOf/microsoft.graph.group?$count=false' } 'Membership queries require'
}
foreach ($request in @(
    @{ Method = 'GET'; Path = '/v1.0/users/id?$select=id' },
    @{ Method = 'GET'; Path = '/v1.0/groups/id/members?$select=id' },
    @{ Method = 'GET'; Path = '/beta/deviceManagement/virtualEndpoint/cloudPCs' },
    @{ Method = 'POST'; Path = '/v1.0/users/id/memberOf/microsoft.graph.group' }
)) {
    Invoke-RecoveryTest "Graph regular $($request.Method) $($request.Path): no advanced query leakage" {
        param($Request)
        function script:Invoke-MgGraphRequest {
            param($Method,$Uri,$Headers,$OutputType,$ErrorAction)
            Check (-not $Headers.ContainsKey('ConsistencyLevel')) 'Unexpected ConsistencyLevel'
            Check ($Uri -notmatch '(?:\$|%24)count=') 'Unexpected $count'
            @{ value = @() }
        }
        $null = Invoke-CpcGraph @Request
    } -Arguments @($request)
}

foreach ($case in @(
    @{ Label = 'explicit Windows365 desktop'; Policy = @{ provisioningType = 'dedicated'; managedBy = 'windows365'; userExperienceType = 'cloudPc' }; Expected = $true },
    @{ Label = 'omitted legacy owner/experience'; Policy = @{ provisioningType = 'dedicated' }; Expected = $true },
    @{ Label = 'devBox owner'; Policy = @{ provisioningType = 'dedicated'; managedBy = 'devBox' }; Expected = $false },
    @{ Label = 'unknown explicit owner'; Policy = @{ provisioningType = 'dedicated'; managedBy = 'unknownFutureValue' }; Expected = $false },
    @{ Label = 'empty explicit owner'; Policy = @{ provisioningType = 'dedicated'; managedBy = '' }; Expected = $false },
    @{ Label = 'null explicit owner'; Policy = @{ provisioningType = 'dedicated'; managedBy = $null }; Expected = $false },
    @{ Label = 'cloudApp experience'; Policy = @{ provisioningType = 'dedicated'; userExperienceType = 'cloudApp' }; Expected = $false },
    @{ Label = 'unknown explicit experience'; Policy = @{ provisioningType = 'dedicated'; userExperienceType = 'unknownFutureValue' }; Expected = $false },
    @{ Label = 'shared provisioning'; Policy = @{ provisioningType = 'shared' }; Expected = $false }
)) {
    Invoke-RecoveryTest "Policy target: $($case.Label)" { param($Case) Check ((Test-CpcPolicyTarget $Case.Policy) -eq $Case.Expected) 'Unexpected policy acceptance' } -Arguments @($case)
}

# Transactional candidate operations; real files are confined to journal cases.
Invoke-RecoveryTest 'Map invalid config preserves Config/Rows/preflight and makes no save' {
    PrepareMap
    $before = StateFingerprint; $config = $script:S.Config; $rows = $script:S.Rows
    $script:MapData.Config.Container = 'invalid/container'
    $result = Invoke-CpcOperation Map $script:MapData
    Check ($result.OperationError -match 'container') "Unexpected failure: $($result.OperationError)"
    Check ((StateFingerprint) -eq $before) 'Invalid Map mutated active plan'
    Check ([object]::ReferenceEquals($config, $script:S.Config) -and [object]::ReferenceEquals($rows, $script:S.Rows)) 'Map replaced original objects'
    Check ($script:Saves.Count -eq 0) 'Invalid Map attempted journal save'
}
Invoke-RecoveryTest 'Journal: invalid Map leaves saved file byte-for-byte intact' -Journal {
    PrepareMap
    $script:S.StatePath = Join-Path $script:Temp 'plan.json'; Save-CpcState
    $before = [IO.File]::ReadAllText($script:S.StatePath); $state = StateFingerprint
    $script:MapData.Config.PolicyId = 'invalid'
    $result = Invoke-CpcOperation Map $script:MapData
    Check ($result.OperationError -match 'Policy ID') 'Did not reject invalid policy'
    Check ((StateFingerprint) -eq $state) 'Map mutated state'
    Check ([IO.File]::ReadAllText($script:S.StatePath) -ceq $before) 'Invalid Map overwrote journal'
}
Invoke-RecoveryTest 'Journal: Load late invalid row preserves state, prior journal, and input file' -Journal {
    $first = $script:Row.Clone(); $second = $script:Row.Clone()
    $second.VmId = $second.VmId + '-second'; $second.VM = 'source-second'; $second.UserPrincipalName = 'second@example.invalid'; $second.Phase = 'ImpossiblePhase'
    $loaded = @{ SchemaVersion = 1; PlanId = [guid]::NewGuid().ToString(); TenantId = $script:S.TenantId; SubscriptionId = $script:S.SubscriptionId
        Config = $script:S.Config.Clone(); GroupId = ''; UserSettingId = ''; Rows = @($first, $second); Checks = @() }
    $loaded.Config.Container = 'different-valid'
    $inputPath = Join-Path $script:Temp 'late-invalid.json'
    [IO.File]::WriteAllText($inputPath, ($loaded | ConvertTo-Json -Depth 30))
    $inputBefore = [IO.File]::ReadAllText($inputPath)
    $script:S.Rows.Clear(); $script:S.Checks.Add(@{ Check = 'retained' })
    $script:S.StatePath = Join-Path $script:Temp 'active.json'; Save-CpcState
    $activeBefore = [IO.File]::ReadAllText($script:S.StatePath); $before = StateFingerprint
    $result = Invoke-CpcOperation Load @{ Path = $inputPath }
    Check ($result.OperationError -match 'Unknown journal phase') "Not a late-row validation failure: $($result.OperationError)"
    Check ((StateFingerprint) -eq $before) 'Load committed a partial candidate'
    Check ([IO.File]::ReadAllText($inputPath) -ceq $inputBefore) 'Rejected input journal changed'
    Check ([IO.File]::ReadAllText($script:S.StatePath) -ceq $activeBefore) 'Old active journal changed'
    $released = [IO.File]::Open("$inputPath.lock", 'Open', 'ReadWrite', 'None'); $released.Dispose()
}
Invoke-RecoveryTest 'Journal: Save write failure preserves active StatePath/file/lease' -Journal {
    $script:S.StatePath = Join-Path $script:Temp 'active.json'; Save-CpcState
    $before = StateFingerprint; $activeBefore = [IO.File]::ReadAllText($script:S.StatePath)
    $newPath = Join-Path $script:Temp 'candidate.json'
    # A directory at the temporary output path deterministically prevents writing,
    # without relying on machine-specific permissions or elevated accounts.
    $null = [IO.Directory]::CreateDirectory("$newPath.tmp")
    $result = Invoke-CpcOperation Save @{ Path = $newPath }
    Check ([bool]$result.OperationError) 'Expected an actual filesystem write failure'
    Check ((StateFingerprint) -eq $before) 'Failed Save switched active StatePath'
    Check ([IO.File]::ReadAllText($script:S.StatePath) -ceq $activeBefore) 'Failed Save changed active file'
    Check ($script:JournalLease.Path -eq $script:S.StatePath) 'Old active lease lost'
    $released = [IO.File]::Open("$newPath.lock", 'Open', 'ReadWrite', 'None'); $released.Dispose()
    Write-CpcAudit 'StillWritable' @{ Result = 'old journal remains active' }
}
Invoke-RecoveryTest 'Journal: exclusive .lock prevents second FileStream; same owner can resave' -Journal {
    $script:S.StatePath = Join-Path $script:Temp 'plan.json'; Save-CpcState
    $lease = $script:JournalLease
    $blocked = $false
    try { $other = [IO.File]::Open("$($script:S.StatePath).lock", 'Open', 'ReadWrite', 'None'); $other.Dispose() }
    catch [IO.IOException] { $blocked = $true }
    Check $blocked 'Second FileStream acquired an exclusively leased journal'
    Save-CpcState
    Check ([object]::ReferenceEquals($lease, $script:JournalLease)) 'Same owner did not reuse lease'
}
Invoke-RecoveryTest 'Journal: external lock blocks Save and Load without switching active state' -Journal {
    $script:S.Rows.Clear(); $before = StateFingerprint
    $path = Join-Path $script:Temp 'locked.json'
    $other = [IO.File]::Open("$path.lock", 'OpenOrCreate', 'ReadWrite', 'None')
    try {
        foreach ($action in @('Save', 'Load')) {
            $result = Invoke-CpcOperation $action @{ Path = $path }
            Check ($result.OperationError -match 'locked|persistence is faulted') "$action did not report lock conflict or prior failure latch"
            Check ((StateFingerprint) -eq $before) "$action switched state on lock conflict"
        }
        Check (-not [IO.File]::Exists($path)) 'Blocked operation created plan file'
    } finally { $other.Dispose() }
}
Invoke-RecoveryTest 'Journal: file collision with another PlanId is blocked and releases candidate lease' -Journal {
    $script:S.StatePath = Join-Path $script:Temp 'active.json'; Save-CpcState
    $path = Join-Path $script:Temp 'foreign.json'
    $foreign = @{ PlanId = [guid]::NewGuid().ToString(); Marker = 'must not overwrite' } | ConvertTo-Json
    [IO.File]::WriteAllText($path, $foreign)
    $before = StateFingerprint
    $result = Invoke-CpcOperation Save @{ Path = $path }
    Check ($result.OperationError -match 'different migration plan') 'Different plan collision not rejected'
    Check ((StateFingerprint) -eq $before) 'Collision changed active state'
    Check ([IO.File]::ReadAllText($path) -ceq $foreign) 'Foreign journal overwritten'
    $released = [IO.File]::Open("$path.lock", 'Open', 'ReadWrite', 'None'); $released.Dispose()
}
Invoke-RecoveryTest 'Journal: durable events redact secrets and survive independent read' -Journal {
    $script:S.StatePath = Join-Path $script:Temp 'plan.json'; Save-CpcState
    Write-CpcAudit 'RedactionProbe' @{ Text = 'https://offline.blob.core.windows.net/c/b?sv=SECRET_QUERY&sig=SECRET_SIG Bearer SECRET.BEARER.VALUE access_token=SECRET_ACCESS refresh_token=SECRET_REFRESH client_secret=SECRET_CLIENT' }
    $text = [IO.File]::ReadAllText($script:S.StatePath + '.events.jsonl')
    Check ($text -notmatch 'SECRET_') 'Durable event leaked query/key secret'
    Check ($text -notmatch 'SECRET\.BEARER\.VALUE') 'Durable event leaked bearer'
    $eventRecord = $text | ConvertFrom-Json -AsHashtable
    Check ($eventRecord.Event -eq 'RedactionProbe' -and $eventRecord.PlanId -eq $script:S.PlanId -and [bool]$eventRecord.Utc) 'Persisted event identity missing'
    Check ($eventRecord.Details.Text.Contains('[REDACTED]')) 'Redaction marker missing'
}
Invoke-RecoveryTest 'Journal: durable event rotation bounded to active plus one backup' -Journal {
    $script:S.StatePath = Join-Path $script:Temp 'plan.json'; Save-CpcState
    $payload = 'x' * 60KB
    for ($i = 0; $i -lt 180; $i++) { Write-CpcAudit 'RotationProbe' @{ Sequence = $i; Payload = $payload } }
    $path = $script:S.StatePath + '.events.jsonl'
    Check ([IO.File]::Exists($path) -and [IO.File]::Exists("$path.1")) 'Active/backup events missing'
    Check (-not [IO.File]::Exists("$path.2")) 'Unbounded backup generations'
    Check (([IO.FileInfo]$path).Length -lt 6MB -and ([IO.FileInfo]"$path.1").Length -lt 6MB) 'Rotation exceeded threshold plus one bounded event'
    $last = [IO.File]::ReadAllLines($path)[-1] | ConvertFrom-Json -AsHashtable
    Check ($last.Details.Sequence -eq 179) 'Latest durable event lost during rotation'
    Write-CpcAudit 'Oversized' @{ Payload = 'x' * 1MB }
    $last = [IO.File]::ReadAllLines($path)[-1] | ConvertFrom-Json -AsHashtable
    Check ([bool]$last.Details.Omitted -and -not $last.Details.ContainsKey('Payload')) 'Oversized audit payload persisted'
}

# Explicit license reconciliation: the import lookup is forbidden even if gone.
foreach ($status in @('provisioned', 'provisioning')) {
    Invoke-RecoveryTest "License recovery succeeds with exact direct license/PC ($status), no import reads or Graph writes" {
        param($Status)
        PrepareLicense; $script:PC.status = $Status
        Repair-CpcLicenseOutcome @($script:Row) $script:LicenseData
        $phase = if ($Status -eq 'provisioned') { 'Provisioned' } else { 'Provisioning' }
        Check ($script:Row.Phase -eq $phase -and $script:Row.CloudPcId -eq $script:PC.id) 'Reconciliation did not commit correlated PC'
        Check ([datetimeoffset]::Parse($script:Row.LicenseAssignedUtc) -eq [datetimeoffset]::Parse($script:LicenseData.AssignedUtc)) 'Historical assignment timestamp replaced with now'
        Check ($script:Row.ImportStatus -eq 'succeeded' -and [bool]$script:Row.ImportId) 'Historical import evidence lost'
        Check ($script:Row.Readiness -eq 'NotChecked' -and -not $script:S.Preflight.ContainsKey($script:Row.VmId)) 'Old preflight survived reconciliation'
        Check ($script:Saves.Count -eq 1 -and @($script:Audit | Where-Object Event -EQ 'LicenseReconciliation').Count -eq 1) 'Reconciliation not saved/audited exactly once'
        Check ($script:Reads.Count -eq 7 -and @($script:Reads | Where-Object { $_ -eq "/v1.0/users/$($script:Row.UserId)?`$select=id,userPrincipalName" }).Count -eq 3) 'Expected license user, scoped PC collection/detail, policy and three directory binding reads'
    } -Arguments @($status)
}
Invoke-RecoveryTest 'License recovery is available through explicit ReconcileLicense dispatcher action' {
    PrepareLicense
    $script:S.StatePath = 'OFFLINE-MOCKED-JOURNAL'
    $result = Invoke-CpcOperation ReconcileLicense @{ VmIds = @($script:Row.VmId); Evidence = $script:LicenseData.Evidence; AssignedUtc = $script:LicenseData.AssignedUtc }
    Check (-not $result.OperationError -and $script:Row.Phase -eq 'Provisioned') "Dispatcher failed: $($result.OperationError)"
}
Invoke-RecoveryTest 'License recovery redacts saved operator evidence' {
    PrepareLicense
    $script:LicenseData.Evidence = 'Audit https://example.invalid/request?access_token=SECRET_AUDIT'
    Repair-CpcLicenseOutcome @($script:Row) $script:LicenseData
    Check ($script:Row.LicenseReconciliationEvidence -notmatch 'SECRET_AUDIT') 'Operator evidence leaked into row'
    Check (($script:Saves -join '') -notmatch 'SECRET_AUDIT') 'Operator evidence leaked into saved state'
}
$licenseNegatives = @(
    @{ Name = 'empty selection'; Change = { $script:Selection = @() }; Error = 'exactly one LicenseUnknown' },
    @{ Name = 'multiple selected rows'; Change = { $script:Selection = @($script:Row, $script:Row.Clone()) }; Error = 'exactly one LicenseUnknown' },
    @{ Name = 'wrong phase'; Change = { $script:Row.Phase = 'Imported' }; Error = 'exactly one LicenseUnknown' },
    @{ Name = 'missing evidence'; Change = { $script:LicenseData.Remove('Evidence') }; Error = 'audit/request reference' },
    @{ Name = 'whitespace evidence'; Change = { $script:LicenseData.Evidence = '  ' }; Error = 'audit/request reference' },
    @{ Name = 'oversized evidence'; Change = { $script:LicenseData.Evidence = 'x' * 2001 }; Error = 'maximum 2000' },
    @{ Name = 'missing AssignedUtc'; Change = { $script:LicenseData.Remove('AssignedUtc') }; Error = 'explicit timezone' },
    @{ Name = 'malformed AssignedUtc'; Change = { $script:LicenseData.AssignedUtc = 'not a date' }; Error = 'explicit timezone' },
    @{ Name = 'timezone-less AssignedUtc'; Change = { $script:LicenseData.AssignedUtc = '2026-09-17T10:00:00' }; Error = 'explicit timezone' },
    @{ Name = 'assignment before import'; Change = { $script:LicenseData.AssignedUtc = [datetimeoffset]::UtcNow.AddHours(-5).ToString('o') }; Error = 'after this import' },
    @{ Name = 'assignment in future'; Change = { $script:LicenseData.AssignedUtc = [datetimeoffset]::UtcNow.AddDays(1).ToString('o') }; Error = 'future' },
    @{ Name = 'assignment before license attempt'; Change = { $script:LicenseData.AssignedUtc = [datetimeoffset]::UtcNow.AddMinutes(-150).ToString('o') }; Error = 'predates.*license attempt' },
    @{ Name = 'no successful import'; Change = { $script:Row.ImportStatus = 'inProgress' }; Error = 'recorded successful import' },
    @{ Name = 'no historical import ID'; Change = { $script:Row.ImportId = '' }; Error = 'recorded successful import' },
    @{ Name = 'user ID mismatch'; Change = { $script:User.id = [guid]::NewGuid().ToString() }; Error = 'User identity' },
    @{ Name = 'user UPN mismatch'; Change = { $script:User.userPrincipalName = 'other@example.invalid' }; Error = 'User identity' },
    @{ Name = 'disabled account'; Change = { $script:User.accountEnabled = $false }; Error = 'enabled state' },
    @{ Name = 'accountEnabled absent'; Change = { $script:User.Remove('accountEnabled') }; Error = 'enabled state' },
    @{ Name = 'license absent'; Change = { $script:User.assignedLicenses = @() }; Error = 'Exact license is not present' },
    @{ Name = 'wrong license'; Change = { $script:User.assignedLicenses = @(@{ skuId = [guid]::NewGuid().ToString() }) }; Error = 'Exact license is not present' },
    @{ Name = 'assignment states absent'; Change = { $script:User.Remove('licenseAssignmentStates') }; Error = 'active direct assignment' },
    @{ Name = 'group assigned license'; Change = { $script:User.licenseAssignmentStates[0].assignedByGroup = '66666666-6666-6666-6666-666666666666' }; Error = 'active direct assignment' },
    @{ Name = 'inactive assignment'; Change = { $script:User.licenseAssignmentStates[0].state = 'Disabled' }; Error = 'active direct assignment' },
    @{ Name = 'active with error'; Change = { $script:User.licenseAssignmentStates[0].state = 'ActiveWithError' }; Error = 'active direct assignment' },
    @{ Name = 'licensing error'; Change = { $script:User.licenseAssignmentStates[0].error = 'CountViolation' }; Error = 'active direct assignment' },
    @{ Name = 'multiple assignment states'; Change = { $script:User.licenseAssignmentStates += $script:User.licenseAssignmentStates[0].Clone() }; Error = 'active direct assignment' },
    @{ Name = 'no Cloud PC'; Change = { $script:PCs = @() }; Error = 'exactly one attributable Cloud PC' },
    @{ Name = 'multiple Cloud PCs'; Change = { $other = $script:PC.Clone(); $other.id = [guid]::NewGuid().ToString(); $script:PCs += $other }; Error = 'exactly one attributable Cloud PC' },
    @{ Name = 'Cloud PC missing UPN'; Change = { $script:PC.Remove('userPrincipalName') }; Error = 'unrelated or unidentified' },
    @{ Name = 'Cloud PC UPN mismatch'; Change = { $script:PC.userPrincipalName = 'other@example.invalid' }; Error = 'unrelated or unidentified' },
    @{ Name = 'Cloud PC policy mismatch'; Change = { $script:PC.provisioningPolicyId = [guid]::NewGuid().ToString() }; Error = 'user/policy/identity' },
    @{ Name = 'detail Cloud PC ID differs from list'; Change = { $script:PcDetail = $script:PC.Clone(); $script:PcDetail.id = [guid]::NewGuid().ToString() }; Error = 'user/policy/identity' },
    @{ Name = 'journaled Cloud PC ID mismatch'; Change = { $script:Row.CloudPcId = [guid]::NewGuid().ToString() }; Error = 'user/policy/identity' },
    @{ Name = 'Cloud PC predates import'; Change = { $script:PC.createdDateTime = [datetimeoffset]::UtcNow.AddDays(-1).ToString('o') }; Error = 'creation time' },
    @{ Name = 'Cloud PC future creation'; Change = { $script:PC.createdDateTime = [datetimeoffset]::UtcNow.AddDays(1).ToString('o') }; Error = 'creation time' },
    @{ Name = 'missing Cloud PC creation'; Change = { $script:PC.Remove('createdDateTime') }; Error = 'creation evidence is unavailable' },
    @{ Name = 'provisioning time is not creation evidence'; Change = { $script:PC.Remove('createdDateTime'); $script:PC.provisionedDateTime = [datetimeoffset]::UtcNow.ToString('o') }; Error = 'creation evidence is unavailable' },
    @{ Name = 'shared policy'; Change = { $script:Policy.provisioningType = 'shared' }; Error = 'compatible Windows 365' },
    @{ Name = 'devBox policy'; Change = { $script:Policy.managedBy = 'devBox' }; Error = 'compatible Windows 365' },
    @{ Name = 'cloudApp policy'; Change = { $script:Policy.userExperienceType = 'cloudApp' }; Error = 'compatible Windows 365' }
)
foreach ($case in $licenseNegatives) {
    Invoke-RecoveryTest "License recovery rejects $($case.Name) without commit" {
        param($Case)
        PrepareLicense; $script:Selection = @($script:Row)
        # Nested data-driven scriptblocks retain their original session state;
        # explicitly bind them to this case's isolated module, like the test body.
        & $ExecutionContext.SessionState.Module $Case.Change
        $before = StateFingerprint
        ExpectFailure { Repair-CpcLicenseOutcome $script:Selection $script:LicenseData } $Case.Error
        Check ((StateFingerprint) -eq $before) 'Rejected license recovery changed plan/evidence'
        Check ($script:Saves.Count -eq 0) 'Rejected license recovery saved state'
    } -Arguments @($case)
}

# Capture recovery keeps the real ownership validator and the two-pass algorithm.
foreach ($status in @('Success', 'Failed', 'Aborted')) {
    Invoke-RecoveryTest "Capture reset removes only owned terminal artifacts ($status) and archives attempt" {
        param($Status)
        PrepareArtifacts
        $script:S.Checks.Add(@{ VM = $script:Row.VM; Check = 'stale prerequisite'; Status = 'Fail'; Detail = 'must not appear as the reset result' })
        $script:S.GroupId = '66666666-6666-6666-6666-666666666666'; $script:S.UserSettingId = '99999999-9999-9999-9999-999999999999'
        $old = $script:Row.Clone()
        foreach ($copy in $script:Blobs.Values) { $copy.Status = $Status }
        Reset-CpcCapture @($script:Row)
        Check ($script:Row.Phase -eq 'IdentityPrepared') 'Reset did not return to prepared identity'
        Check ($script:Deletes.Count -eq 3 -and $script:Revokes -eq 1) 'Wrong artifact delete/revoke count'
        Check ($script:Deletes[2] -like 'snapshot:*') 'Snapshot removed before blobs'
        Check ($script:Row.AttemptHistory.Count -eq 1 -and $script:Row.AttemptHistory[0].SnapshotId -eq $old.SnapshotId -and $script:Row.AttemptHistory[0].VhdCopyId -eq $old.VhdCopyId) 'Attempt ownership evidence not archived'
        Check (-not $script:Row.SnapshotId -and -not $script:Row.VhdBlob -and -not $script:Row.SourceDiskId) 'Active attempt evidence not cleared'
        Check (-not $script:Row.Attested -and $script:Row.Readiness -eq 'NotChecked' -and -not $script:S.Preflight.ContainsKey($old.VmId)) 'Stale approvals survived reset'
        Check ($script:S.Checks.Count -eq 0) 'Stale prerequisite evidence survived successful reset'
        Check ($script:Row.VmId -eq $old.VmId -and $script:S.GroupId -eq '66666666-6666-6666-6666-666666666666') 'Source/group identity changed'
    } -Arguments @($status)
}
foreach ($phase in @('Mapped','IdentityPrepared','Capturing','CaptureFailed','Copying','CopyFailed','Staged','Purged')) {
    Invoke-RecoveryTest "Capture reset accepts known pre-license phase $phase" {
        param($Phase)
        PrepareArtifacts; $script:Row.Phase = $Phase
        if ($Phase -eq 'Purged') { $script:Row.ImportId = '77777777-7777-7777-7777-777777777777'; $script:Row.ImportStatus = 'failed' }
        $oldImport = $script:Row.ImportId
        Reset-CpcCapture @($script:Row)
        Check ($script:Row.Phase -eq 'Mapped' -and -not $script:Row.ImportId) 'Reset did not clear active attempt'
        Check ($script:Row.AttemptHistory[0].ImportId -eq $oldImport) 'Purged import history lost'
    } -Arguments @($phase)
}
Invoke-RecoveryTest 'Artifact-free unprepared abandoned draft can reopen without artifact mutation' {
    PrepareArtifacts
    $script:Row.Phase = 'Abandoned'
    $script:Row.AttemptHistory = @(@{ SnapshotName = $script:Row.SnapshotName; SnapshotId = ''; VhdBlob = ''; VmgsBlob = ''; VhdCopyId = ''; VmgsCopyId = ''; ImportId = ''; ImportStartedUtc = '' })
    foreach ($key in @('SnapshotId','SnapshotName','VhdBlob','VmgsBlob','VhdCopyId','VmgsCopyId','SourceVmUniqueId','SourceDiskId','CaptureStartedUtc','ImportId','ImportStatus','ImportStartedUtc','ExportExpiresUtc','ImportSasExpiresUtc','LicenseAssignedUtc','CloudPcId')) { $script:Row[$key] = '' }
    $script:S.Preflight[$script:Row.VmId] = @{ Stage = 'stale' }
    $script:S.Checks.Add(@{ Check = 'stale conflict'; Status = 'Fail' })
    Reset-CpcCapture @($script:Row)
    Check ($script:Row.Phase -eq 'Mapped') 'Artifact-free abandoned draft did not reopen to Mapped'
    Check ($script:Deletes.Count -eq 0 -and $script:Revokes -eq 0) 'Draft reopen attempted artifact mutation'
    Check ($script:Row.AttemptHistory.Count -eq 1) 'Draft reopen fabricated or removed attempt history'
    Check (-not $script:S.Preflight.ContainsKey($script:Row.VmId) -and $script:S.Checks.Count -eq 0) 'Draft reopen retained stale approval/check evidence'
}
foreach ($phase in @('ImportSubmitting','ImportUnknown','Importing','Imported','ImportFailed','LicenseSubmitting','LicenseUnknown','Provisioning','Provisioned','Validated','CleanupPending','Cleaned','PurgeSubmitting','PurgeUnknown','Abandoned')) {
    Invoke-RecoveryTest "Capture reset rejects unsafe phase $phase before deletes" {
        param($Phase)
        PrepareArtifacts; $script:Row.Phase = $Phase; $before = StateFingerprint
        $expected = if ($Phase -eq 'Abandoned') { 'never owned a group/user setting.*no current or historical artifact evidence' } else { 'known pre-license phase' }
        ExpectFailure { Reset-CpcCapture @($script:Row) } $expected
        Check ($script:Deletes.Count -eq 0 -and $script:Revokes -eq 0 -and (StateFingerprint) -eq $before) 'Unsafe phase caused mutation'
    } -Arguments @($phase)
}
$artifactNegatives = @(
    @{ Name = 'license timestamp present'; Change = { $script:Row.LicenseAssignedUtc = [datetimeoffset]::UtcNow.ToString('o') }; Error = 'known pre-license' },
    @{ Name = 'live import ID on CopyFailed'; Change = { $script:Row.ImportId = '77777777-7777-7777-7777-777777777777' }; Error = 'known pre-license' },
    @{ Name = 'target user mismatch'; Change = { $script:RecoveryUser.id = [guid]::NewGuid().ToString() }; Error = 'user identity changed' },
    @{ Name = 'target UPN mismatch'; Change = { $script:RecoveryUser.userPrincipalName = 'other@example.invalid' }; Error = 'user identity changed' },
    @{ Name = 'target Windows365 license'; Change = { $script:RecoveryUser.assignedLicenses = @(@{ skuId = $script:S.Config.SkuId }) }; Error = 'Cloud PC or Windows 365 license exists' },
    @{ Name = 'another Windows365 SKU'; Change = { $id = [guid]::NewGuid().ToString(); $script:RecoveryUser.assignedLicenses = @(@{ skuId = $id }); $script:RecoverySkus = @(@{ skuId = $id; skuPartNumber = 'CPC_E_4C_16GB_256GB' }) }; Error = 'Cloud PC or Windows 365 license exists' },
    @{ Name = 'Cloud PC missing assigned UPN'; Change = { $script:RecoveryPCs = @(@{ id = 'existing' }) }; Error = 'unrelated or unidentified' },
    @{ Name = 'existing Cloud PC by UPN'; Change = { $script:RecoveryPCs = @(@{ id = 'existing'; userPrincipalName = $script:Row.UserPrincipalName }) }; Error = 'Cloud PC or Windows 365 license exists' },
    @{ Name = 'snapshot plan tag mismatch'; Change = { $script:Snapshot.Tags.CpcMigrationPlan = 'other-plan' }; Error = 'ownership mismatch' },
    @{ Name = 'snapshot source VM tag mismatch'; Change = { $script:Snapshot.Tags.SourceVmId = 'other-vm' }; Error = 'ownership mismatch' },
    @{ Name = 'snapshot ARM ID mismatch'; Change = { $script:Snapshot.Id = 'other-snapshot' }; Error = 'resource identity mismatch' },
    @{ Name = 'snapshot source disk mismatch'; Change = { $script:Snapshot.CreationData.SourceResourceId = 'other-disk' }; Error = 'resource identity mismatch' },
    @{ Name = 'snapshot still provisioning'; Change = { $script:Snapshot.ProvisioningState = 'Creating' }; Error = 'still provisioning' },
    @{ Name = 'VHD path ownership mismatch'; Change = { $script:Row.VhdBlob = 'other-plan/user/snapshot/os.vhd' }; Error = 'path ownership mismatch' },
    @{ Name = 'VMGS path ownership mismatch'; Change = { $script:Row.VmgsBlob = 'other-plan/user/snapshot/vmgs.vhd' }; Error = 'path ownership mismatch' },
    @{ Name = 'VHD copy ID mismatch'; Change = { $script:Blobs[$script:Row.VhdBlob].CopyId = 'different' }; Error = 'changed copy' },
    @{ Name = 'VMGS copy ID mismatch'; Change = { $script:Blobs[$script:Row.VmgsBlob].CopyId = 'different' }; Error = 'changed copy' },
    @{ Name = 'unjournaled VHD copy'; Change = { $script:Row.VhdCopyId = '' }; Error = 'changed copy' },
    @{ Name = 'pending VHD copy'; Change = { $script:Blobs[$script:Row.VhdBlob].Status = 'Pending' }; Error = 'copy is still pending' },
    @{ Name = 'pending VMGS copy'; Change = { $script:Blobs[$script:Row.VmgsBlob].Status = 'Pending' }; Error = 'copy is still pending' },
    @{ Name = 'unknown copy status'; Change = { $script:Blobs[$script:Row.VhdBlob].Status = 'Unknown' }; Error = 'copy is still pending' },
    @{ Name = 'orphan blob without approved removal'; Change = { $script:SnapshotPresent = $false }; Error = 'Orphan blob' }
)
foreach ($case in $artifactNegatives) {
    Invoke-RecoveryTest "Capture reset rejects $($case.Name) before any artifact mutation" {
        param($Case)
        PrepareArtifacts
        & $ExecutionContext.SessionState.Module $Case.Change
        $before = StateFingerprint
        ExpectFailure { Reset-CpcCapture @($script:Row) } $Case.Error
        Check ($script:Deletes.Count -eq 0 -and $script:Revokes -eq 0) 'Invalid ownership/state caused delete or revoke'
        Check ((StateFingerprint) -eq $before -and $script:Saves.Count -eq 0) 'Rejected removal changed plan/approval'
    } -Arguments @($case)
}
Invoke-RecoveryTest 'Capture recovery rechecks copy ID immediately before delete' {
    PrepareArtifacts; $script:ChangeCopyOnReplay = $true
    ExpectFailure { Reset-CpcCapture @($script:Row) } 'Copy changed since recovery approval'
    Check ($script:Deletes.Count -eq 0) 'Changed copy deleted in second pass'
    Check ($script:Row.Phase -eq 'ResettingCapture' -and $script:Row.ArtifactRemovalApproved) 'Interrupted removal not replayable'
}
foreach ($action in @('Reset', 'Abandon', 'Cleanup')) {
    foreach ($remaining in @('none', 'one-blob', 'snapshot-only')) {
        Invoke-RecoveryTest "Artifact replay $action with $remaining remaining is idempotent" {
            param($Action, $Remaining)
            PrepareArtifacts
            $script:Row.ArtifactRemovalApproved = $true
            $script:Row.Phase = switch ($Action) { 'Reset' { 'ResettingCapture' } 'Abandon' { 'Abandoning' } 'Cleanup' { 'CleanupPending' } }
            $script:Row.ValidatedUtc = [datetimeoffset]::UtcNow.AddMinutes(-5).ToString('o')
            $script:SnapshotPresent = $Remaining -eq 'snapshot-only'
            if ($Remaining -eq 'one-blob') { $script:Blobs.Remove($script:Row.VmgsBlob) } else { $script:Blobs.Clear() }
            $old = $script:Row.Clone()
            switch ($Action) {
                'Reset' { Reset-CpcCapture @($script:Row) }
                'Abandon' { Reset-CpcCapture @($script:Row) -Abandon }
                'Cleanup' { Remove-CpcStaging @($script:Row) }
            }
            $expected = switch ($Action) { 'Reset' { 'Mapped' } 'Abandon' { 'Abandoned' } 'Cleanup' { 'Cleaned' } }
            Check ($script:Row.Phase -eq $expected) 'Replay did not finish'
            $deleteCount = if ($Remaining -eq 'none') { 0 } else { 1 }
            Check ($script:Deletes.Count -eq $deleteCount) 'Replay deleted absent/unrelated artifacts'
            if ($Action -ne 'Cleanup') { Check ($script:Row.AttemptHistory.Count -eq 1 -and $script:Row.AttemptHistory[0].SnapshotId -eq $old.SnapshotId) 'Replay lost attempt history' }
        } -Arguments @($action, $remaining)
    }
}
Invoke-RecoveryTest 'Cleanup refuses unexpectedly absent unapproved validated snapshot' {
    PrepareArtifacts; $script:Row.Phase = 'Validated'; $script:Row.ValidatedUtc = [datetimeoffset]::UtcNow.ToString('o'); $script:SnapshotPresent = $false
    ExpectFailure { Remove-CpcStaging @($script:Row) } 'snapshot unexpectedly missing'
    Check ($script:Deletes.Count -eq 0) 'Cleanup deleted unapproved orphan artifacts'
}
Invoke-RecoveryTest 'Capture reset appends history rather than overwriting older attempts' {
    PrepareArtifacts; $script:Row.AttemptHistory = @(@{ SnapshotId = 'older-attempt'; ClosedUtc = 'historical' })
    Reset-CpcCapture @($script:Row)
    Check ($script:Row.AttemptHistory.Count -eq 2 -and $script:Row.AttemptHistory[0].SnapshotId -eq 'older-attempt') 'Prior history overwritten'
}
foreach ($phase in @('ResettingCapture', 'Abandoning')) {
    Invoke-RecoveryTest "Recovery $phase must not bypass live import guard without prior removal approval" {
        param($Phase)
        PrepareArtifacts; $script:Row.Phase = $Phase
        $script:Row.ImportId = '77777777-7777-7777-7777-777777777777'; $script:Row.ImportStatus = 'inProgress'
        $before = StateFingerprint
        ExpectFailure { Reset-CpcCapture @($script:Row) -Abandon:($Phase -eq 'Abandoning') } 'pre-license|import|approval|recovery'
        Check ($script:Deletes.Count -eq 0 -and (StateFingerprint) -eq $before) 'Live import artifacts removed via unapproved replay phase'
    } -Arguments @($phase)
}

# Plan identity is independent of the journal path, including copies and Save As.
foreach ($mode in @('copied', 'SaveAs')) {
    Invoke-RecoveryTest "Plan lease: $mode journal blocked in isolated module; old leases survive" -Journal -Peer {
        param($Mode)
        $script:S.StatePath = Join-Path $script:Temp 'original.json'; Save-CpcState
        $original = $script:S.StatePath; $planLease = $script:PlanLease
        $copy = Join-Path $script:Temp 'copy.json'
        if ($Mode -eq 'copied') { [IO.File]::Copy($original, $copy) }
        else {
            $result = Invoke-CpcOperation Save @{ Path = $copy }
            Check (-not $result.OperationError) "Owner Save As failed: $($result.OperationError)"
            Check ([object]::ReferenceEquals($planLease, $script:PlanLease)) 'Save As replaced/released identity lease'
            CheckLeaseFree "$original.lock"
            # The old path is unlocked, but still contains the SAME PlanId.
            $copy = $original
        }
        $bytes = [IO.File]::ReadAllText($copy)
        & $script:Peer {
            param($Copy, $PlanId)
            $script:S.Rows.Clear()
            $script:S.StatePath = Join-Path $script:Temp 'peer-active.json'; Save-CpcState
            $before = StateFingerprint; $journalLease = $script:JournalLease; $identityLease = $script:PlanLease
            $script:TestPlanIds.Add($PlanId)
            $result = Invoke-CpcOperation Load @{ Path = $Copy }
            Check ($result.OperationError -match 'plan identity.*another instance') "Copy was not identity-locked: $($result.OperationError)"
            Check ((StateFingerprint) -eq $before) 'Rejected copy Load changed peer state'
            Check ([object]::ReferenceEquals($journalLease, $script:JournalLease) -and [object]::ReferenceEquals($identityLease, $script:PlanLease)) 'Failed Load replaced old leases'
            CheckLeaseHeld $journalLease.Stream.Name; CheckLeaseHeld $identityLease.Stream.Name
            CheckLeaseFree "$Copy.lock"
            # Direct candidate Save to a completely different path must also lock PlanId.
            $candidate = $script:S.Clone(); $candidate.PlanId = $PlanId
            $candidate.StatePath = Join-Path $script:Temp 'peer-save-as.json'
            ExpectFailure { Save-CpcState $candidate } 'plan identity.*another instance'
            Check (-not [IO.File]::Exists($candidate.StatePath)) 'Blocked Save created a duplicate journal'
            CheckLeaseFree "$($candidate.StatePath).lock"
            CheckLeaseHeld $journalLease.Stream.Name; CheckLeaseHeld $identityLease.Stream.Name
            Write-CpcAudit 'OldPeerStillWritable' @{}
        } $copy $script:S.PlanId
        Check ([IO.File]::ReadAllText($copy) -ceq $bytes) 'Rejected peer operation changed owner journal'
        CheckLeaseHeld $planLease.Stream.Name
        Save-CpcState
    } -Arguments @($mode)
}
Invoke-RecoveryTest 'Module removal releases journal AND identity leases, then another instance can Load' -Journal -Peer {
    $owned = & $script:Peer {
        $script:S.StatePath = Join-Path $script:Temp 'owned.json'; Save-CpcState
        @{ Path = $script:S.StatePath; Id = $script:S.PlanId; Journal = $script:JournalLease; Identity = $script:PlanLease }
    }
    $script:TestPlanIds.Add($owned.Id)
    CheckLeaseHeld $owned.Journal.Stream.Name; CheckLeaseHeld $owned.Identity.Stream.Name
    $journalLock = $owned.Journal.Stream.Name; $planLock = $owned.Identity.Stream.Name
    Remove-Module $script:Peer -Force
    Check (-not $owned.Journal.Stream.CanRead -and -not $owned.Identity.Stream.CanRead) 'OnRemove left a lease stream open'
    CheckLeaseFree $journalLock; CheckLeaseFree $planLock
    $script:S.Rows.Clear()
    $result = Invoke-CpcOperation Load @{ Path = $owned.Path }
    Check (-not $result.OperationError -and $script:S.PlanId -eq $owned.Id) "Load after removal failed: $($result.OperationError)"
    CheckLeaseHeld $journalLock; CheckLeaseHeld $planLock
}
foreach ($failureMode in @('write', 'invalid-plan-id', 'collision')) {
    Invoke-RecoveryTest "Plan lease: failed $failureMode candidate preserves both old leases and releases new locks" -Journal {
        param($FailureMode)
        $script:S.StatePath = Join-Path $script:Temp 'active.json'; Save-CpcState
        $before = StateFingerprint; $bytes = [IO.File]::ReadAllText($script:S.StatePath)
        $journal = $script:JournalLease; $identity = $script:PlanLease
        $candidate = $script:S.Clone(); $candidate.StatePath = Join-Path $script:Temp 'candidate.json'
        $candidate.PlanId = [guid]::NewGuid().ToString(); $script:TestPlanIds.Add($candidate.PlanId)
        $candidateLock = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) "CpcMigration/locks/$($candidate.PlanId).lock"
        switch ($FailureMode) {
            'write' { $null = [IO.Directory]::CreateDirectory("$($candidate.StatePath).tmp"); $pattern = 'denied|access|directory' }
            'invalid-plan-id' { $candidate.PlanId = 'invalid'; $pattern = 'Plan ID must be a GUID' }
            'collision' { [IO.File]::WriteAllText($candidate.StatePath, (@{ PlanId = [guid]::NewGuid().ToString() } | ConvertTo-Json)); $pattern = 'different migration plan' }
        }
        ExpectFailure { Save-CpcState $candidate } $pattern
        Check ((StateFingerprint) -eq $before -and [IO.File]::ReadAllText($script:S.StatePath) -ceq $bytes) 'Failed candidate changed active state/file'
        Check ([object]::ReferenceEquals($journal, $script:JournalLease) -and [object]::ReferenceEquals($identity, $script:PlanLease)) 'Failed candidate replaced old leases'
        CheckLeaseHeld $journal.Stream.Name; CheckLeaseHeld $identity.Stream.Name
        CheckLeaseFree "$($candidate.StatePath).lock"; CheckLeaseFree $candidateLock
        Save-CpcState; Write-CpcAudit 'StillOwned' @{}
    } -Arguments @($failureMode)
}

# Tenant lock is set by the central dispatcher, not by a UI or auth mock.
foreach ($action in @('DetectSubscriptions', 'Connect')) {
    foreach ($bypass in @('omitted', 'empty', 'null', 'replacement', 'same')) {
        Invoke-RecoveryTest "Tenant dispatch: $action rejects foreign tenant with $bypass requiredTenantId before auth" {
            param($Action, $Bypass)
            $tenant = $script:S.TenantId; $foreign = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
            $script:S.Rows.Clear(); $script:S.Preflight.Clear()
            function script:Test-CpcLocal { }
            $seed = Invoke-CpcOperation LocalCheck @{ requiredTenantId = $tenant }
            Check (-not $seed.OperationError -and $seed.RequiredTenantId -eq $tenant) 'Central dispatch did not establish tenant lock'
            $data = @{ TenantId = $foreign; SubscriptionId = $script:S.SubscriptionId }
            switch ($Bypass) {
                'empty' { $data.RequiredTenantId = '' }
                'null' { $data.RequiredTenantId = $null }
                'replacement' { $data.RequiredTenantId = $foreign }
                'same' { $data.RequiredTenantId = $tenant }
            }
            $result = Invoke-CpcOperation $Action $data
            Check ($result.OperationError -match 'locked to startup tenant|lock cannot be changed') "Wrong rejection: $($result.OperationError)"
            Check ($result.RequiredTenantId -eq $tenant -and $script:S.TenantId -eq $tenant) 'Rejected request changed tenant lock/state'
            Check ($script:BoundaryViolations.Count -eq 0) 'Auth/module load happened before scope rejection'
            $again = Invoke-CpcOperation LocalCheck @{}
            Check (-not $again.OperationError -and $again.RequiredTenantId -eq $tenant) 'Omitted tenant erased session lock'
        } -Arguments @($action, $bypass)
    }
}
foreach ($required in @('not-a-guid', '00000000-0000-0000-0000-000000000000', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa')) {
    Invoke-RecoveryTest "Tenant dispatch rejects invalid/conflicting initial lock $required" {
        param($Required)
        function script:Test-CpcLocal { throw 'Must reject before dispatch' }
        $result = Invoke-CpcOperation LocalCheck @{ requiredTenantId = $Required }
        Check ($result.OperationError -match 'must be a GUID|zero GUID|Active plan tenant differs') "Wrong lock rejection: $($result.OperationError)"
        Check (-not $result.RequiredTenantId) 'Invalid initial request persisted a lock'
    } -Arguments @($required)
}
Invoke-RecoveryTest 'Tenant dispatch: matching Detect then Connect retain startup lock when later calls omit it' {
    $tenant = $script:S.TenantId; $subscription = $script:S.SubscriptionId
    $script:S.Rows.Clear(); $script:S.TenantId = ''; $script:S.Connected = $false
    $script:AuthCalls = [collections.generic.list[string]]::new()
    $script:AuthTenant = $tenant; $script:AuthSubscription = $subscription
    function script:Import-Module { param($Name, $ErrorAction) Check ($Name -in $script:Modules) 'Unexpected module'; $script:AuthCalls.Add("module:$Name") }
    function script:Disable-AzContextAutosave { param($Scope) Check ($Scope -eq 'Process') 'Autosave scope' }
    function script:Update-AzConfig {
        param($LoginExperienceV2, $Scope, $ErrorAction)
        Check ($LoginExperienceV2 -eq 'Off' -and $Scope -eq 'Process' -and $ErrorAction -eq 'Stop') 'Console selector configuration escaped process scope'
        $script:AuthCalls.Add('NoConsoleSelector')
    }
    function script:Connect-AzAccount {
        param($Tenant, $Subscription, $Environment, $Scope)
        Check ($script:AuthCalls[-1] -eq 'NoConsoleSelector') 'Console selector not disabled before Azure login'
        Check ($Tenant -eq $script:AuthTenant -and $Environment -eq 'AzureCloud' -and $Scope -eq 'Process') 'Azure auth escaped tenant'
        if ($Subscription) { Check ($Subscription -eq $script:AuthSubscription) 'Azure auth escaped subscription' }
        $script:AuthCalls.Add('Azure')
    }
    function script:Get-AzSubscription { param($TenantId) Check ($TenantId -eq $script:AuthTenant) 'Wrong discovery tenant'; @{ Id = $script:AuthSubscription; TenantId = $TenantId; State = 'Enabled'; Name = 'Offline' } }
    function script:Set-AzContext { param($Tenant, $Subscription, $Scope) Check ($Tenant -eq $script:AuthTenant -and $Subscription -eq $script:AuthSubscription -and $Scope -eq 'Process') 'Wrong selected context' }
    function script:Connect-MgGraph { param($TenantId, $Environment, $ContextScope, [switch]$NoWelcome, $Scopes) Check ($TenantId -eq $script:AuthTenant -and $Environment -eq 'Global' -and $ContextScope -eq 'Process') 'Graph auth escaped tenant'; $script:AuthCalls.Add('Graph') }
    function script:Set-MgRequestContext { param($MaxRetry, $ClientTimeout) Check ($MaxRetry -eq 0) 'Mutation retry enabled' }
    $detect = Invoke-CpcOperation DetectSubscriptions @{ TenantId = $tenant; requiredTenantId = $tenant }
    Check (-not $detect.OperationError -and $detect.RequiredTenantId -eq $tenant) "Detect failed: $($detect.OperationError)"
    Check (-not $detect.Connected -and -not $detect.SubscriptionId -and $script:AuthCalls -notcontains 'Graph') 'Detect signed Graph in/selected a subscription'
    $connect = Invoke-CpcOperation Connect @{ TenantId = $tenant; SubscriptionId = $subscription }
    Check (-not $connect.OperationError -and $connect.Connected -and $connect.RequiredTenantId -eq $tenant) "Connect failed: $($connect.OperationError)"
    Check (@($script:AuthCalls | Where-Object { $_ -eq 'Azure' }).Count -eq 2 -and @($script:AuthCalls | Where-Object { $_ -eq 'Graph' }).Count -eq 1) 'Wrong mocked auth count'
    Assert-CpcContext
}
foreach ($contextCase in @('matching', 'disconnected', 'startup-tenant', 'azure-tenant', 'graph-tenant', 'subscription', 'azure-cloud', 'graph-cloud')) {
    Invoke-RecoveryTest "Assert-CpcContext enforces $contextCase" {
        param($Case)
        function script:Test-CpcLocal { }
        $null = Invoke-CpcOperation LocalCheck @{ RequiredTenantId = $script:S.TenantId }
        $script:AzContext = @{ Tenant = @{ Id = $script:S.TenantId }; Subscription = @{ Id = $script:S.SubscriptionId }; Environment = @{ Name = 'AzureCloud' } }
        $script:MgContext = @{ TenantId = $script:S.TenantId; Environment = 'Global' }
        $script:ContextReads = 0
        function script:Get-AzContext { $script:ContextReads++; $script:AzContext }
        function script:Get-MgContext { $script:ContextReads++; $script:MgContext }
        switch ($Case) {
            'disconnected' { $script:S.Connected = $false; $pattern = 'Connect to Azure' }
            'startup-tenant' { $script:S.TenantId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'; $pattern = 'locked to startup tenant' }
            'azure-tenant' { $script:AzContext.Tenant.Id = 'other'; $pattern = 'Tenant mismatch' }
            'graph-tenant' { $script:MgContext.TenantId = 'other'; $pattern = 'Tenant mismatch' }
            'subscription' { $script:AzContext.Subscription.Id = 'other'; $pattern = 'subscription context changed' }
            'azure-cloud' { $script:AzContext.Environment.Name = 'AzureUSGovernment'; $pattern = 'Commercial cloud only' }
            'graph-cloud' { $script:MgContext.Environment = 'USGov'; $pattern = 'Commercial cloud only' }
        }
        if ($Case -eq 'matching') { Assert-CpcContext; Check ($script:ContextReads -eq 2) 'Did not validate both contexts' }
        else { ExpectFailure { Assert-CpcContext } $pattern }
        if ($Case -in @('disconnected', 'startup-tenant')) { Check ($script:ContextReads -eq 0) 'Read contexts before local rejection' }
    } -Arguments @($contextCase)
}

foreach ($offset in @(-6, -5, 0, 10)) {
    Invoke-RecoveryTest "License recovery creation relative to reviewed assignment: $offset seconds" {
        param($Offset)
        PrepareLicense
        $script:PC.createdDateTime = [datetimeoffset]::Parse($script:LicenseData.AssignedUtc).AddSeconds($Offset).ToString('o')
        $before = StateFingerprint
        if ($Offset -lt -5) {
            ExpectFailure { Repair-CpcLicenseOutcome @($script:Row) $script:LicenseData } 'creation time.*predates'
            Check ((StateFingerprint) -eq $before -and $script:Saves.Count -eq 0) 'Pre-assignment PC committed'
        } else {
            Repair-CpcLicenseOutcome @($script:Row) $script:LicenseData
            Check ($script:Row.Phase -eq 'Provisioned') 'Valid creation timestamp rejected'
        }
    } -Arguments @($offset)
}
foreach ($count in @(0, 2)) {
    Invoke-RecoveryTest "License reconciliation dispatcher rejects $count selected rows without reads/writes" {
        param($Count)
        PrepareLicense; $script:S.StatePath = 'OFFLINE-MOCKED-JOURNAL'
        $ids = @()
        if ($Count -eq 2) {
            $other = $script:Row.Clone(); $other.VmId += '-second'; $other.VM += '-second'
            $script:S.Rows.Add($other); $ids = @($script:Row.VmId, $other.VmId)
        }
        $before = StateFingerprint
        $result = Invoke-CpcOperation ReconcileLicense @{ VmIds = $ids; Evidence = $script:LicenseData.Evidence; AssignedUtc = $script:LicenseData.AssignedUtc }
        Check ($result.OperationError -match 'Select one or more|exactly one LicenseUnknown') "Wrong dispatcher rejection: $($result.OperationError)"
        Check ((StateFingerprint) -eq $before -and $script:Reads.Count -eq 0) 'Non-singleton dispatched license reads or committed state'
    } -Arguments @($count)
}
Invoke-RecoveryTest 'License reconciliation dispatcher: absent exact license cannot POST or advance phase' {
    PrepareLicense; $script:S.StatePath = 'OFFLINE-MOCKED-JOURNAL'
    $script:User.assignedLicenses = @(); $before = StateFingerprint
    $result = Invoke-CpcOperation ReconcileLicense @{ VmIds = @($script:Row.VmId); Evidence = $script:LicenseData.Evidence; AssignedUtc = $script:LicenseData.AssignedUtc }
    Check ($result.OperationError -match 'Exact license is not present.*No assignment will be retried') "Wrong failure: $($result.OperationError)"
    Check ((StateFingerprint) -eq $before -and $script:Reads.Count -eq 1) 'Missing license advanced state or performed extra reads'
    Check (@($script:Audit | Where-Object Event -EQ 'LicenseReconciliation').Count -eq 0) 'Missing license recorded successful reconciliation'
    # PrepareLicense treats ANY non-GET as a boundary violation, even if caught.
    Check ($script:BoundaryViolations.Count -eq 0) 'Missing license triggered Graph mutation'
}
Invoke-RecoveryTest 'Import reconciliation dispatcher handles singleton selected row without scalar indexing failure' {
    $script:Row.Phase = 'ImportUnknown'; $script:S.StatePath = 'OFFLINE-MOCKED-JOURNAL'
    $script:ImportReads = 0; $script:Refreshes = 0
    function script:Get-CpcImportResult {
        param($Id)
        Check ($Id -eq '77777777-7777-7777-7777-777777777777') 'Wrong reconciliation import ID'
        $script:ImportReads++
        @{ assignedUserPrincipalName = $script:Row.UserPrincipalName; filename = 'os.vhd'; startDateTime = [datetimeoffset]::Parse($script:Row.ImportStartedUtc).AddMinutes(1).ToString('o') }
    }
    function script:Update-CpcStatus { param($Rows) Check (@($Rows).Count -eq 1 -and $Rows[0].Phase -eq 'Importing') 'Dispatcher lost singleton row'; $script:Refreshes++ }
    $result = Invoke-CpcOperation ReconcileImport @{ VmIds = @($script:Row.VmId); ImportId = '77777777-7777-7777-7777-777777777777' }
    Check (-not $result.OperationError -and $script:Row.Phase -eq 'Importing') "Singleton failed: $($result.OperationError)"
    Check ($script:ImportReads -eq 1 -and $script:Refreshes -eq 1) 'Unexpected reconciliation dispatch count'
}

foreach ($phase in @('Capturing','CaptureFailed','Copying','CopyFailed','Importing','ImportUnknown','Provisioning','LicenseUnknown')) {
    Invoke-RecoveryTest "Timing warnings: aged $phase is advisory; expired SAS never changes phase" {
        param($Phase)
        $script:Row.Phase = $Phase; $now = [datetimeoffset]::UtcNow
        foreach ($key in @('CaptureStartedUtc','ImportStartedUtc','LicenseStartedUtc')) { $script:Row[$key] = $now.AddHours(-8).ToOffset([timespan]::FromHours(5.5)).ToString('o') }
        foreach ($key in @('ExportExpiresUtc','ImportSasExpiresUtc')) { $script:Row[$key] = $now.AddHours(-1).ToOffset([timespan]::FromHours(-7)).ToString('o') }
        $before = $script:Row.Clone()
        Update-CpcTimingWarning $script:Row
        Check ($script:Row.TimingWarning -match 'age.*operator review threshold.*not a service SLA.*do not resubmit automatically') 'Age warning missing/advice changed'
        if ($Phase -notin @('Provisioning','LicenseUnknown')) { Check ($script:Row.TimingWarning -match 'SAS expiry.*expiry alone is not proof of failure') 'Expiry warning missing' }
        foreach ($key in $before.Keys) {
            Check (($script:Row[$key] | ConvertTo-Json -Depth 30 -Compress) -ceq ($before[$key] | ConvertTo-Json -Depth 30 -Compress)) "Warning mutated operational field $key"
        }
        Check ($script:S.Checks.Count -eq 1 -and $script:S.Checks[0].Status -eq 'Manual') 'Warning is not a Manual advisory'
        Check ($script:Saves.Count -eq 0 -and $script:Audit.Count -eq 0) 'Timing warning submitted/saved an operation'
    } -Arguments @($phase)
}
foreach ($hours in @(1, 3)) {
    Invoke-RecoveryTest "Timing warning: fresh copy with SAS expiring in $hours hours" {
        param($Hours)
        $script:Row.Phase = 'Copying'; $script:Row.CaptureStartedUtc = [datetimeoffset]::UtcNow.AddMinutes(-10).ToString('o')
        $script:Row.ExportExpiresUtc = [datetimeoffset]::UtcNow.AddHours($Hours).ToString('o')
        $script:Row.TimingWarning = 'stale warning'
        Update-CpcTimingWarning $script:Row
        if ($Hours -eq 1) { Check ($script:Row.TimingWarning -match 'SAS expiry' -and $script:Row.TimingWarning -notmatch 'age .*exceeds') 'Expected expiry-only warning' }
        else { Check (-not $script:Row.TimingWarning -and $script:S.Checks.Count -eq 0) 'Healthy timing did not clear stale warning' }
        Check ($script:Row.Phase -eq 'Copying' -and $script:Saves.Count -eq 0) 'Timing check changed phase/saved'
    } -Arguments @($hours)
}
Invoke-RecoveryTest 'Timing warning: terminal/untracked phase clears stale warning without transitioning' {
    $script:Row.Phase = 'Validated'; $script:Row.TimingWarning = 'stale warning'
    $script:Row.ExportExpiresUtc = [datetimeoffset]::UtcNow.AddDays(-1).ToString('o')
    Update-CpcTimingWarning $script:Row
    Check (-not $script:Row.TimingWarning -and $script:Row.Phase -eq 'Validated' -and $script:S.Checks.Count -eq 0) 'Terminal row gained an operational warning/transition'
}

foreach ($initialPhase in @('Imported', 'ImportFailed')) {
    Invoke-RecoveryTest "Purge ambiguous $initialPhase outcome: persist PurgeUnknown and forbid retry POST" {
        param($InitialPhase)
        PrepareArtifacts; $script:Row.Phase = $InitialPhase; $script:S.StatePath = 'OFFLINE-MOCKED-JOURNAL'
        $script:Row.ImportId = '77777777-7777-7777-7777-777777777777'
        $script:Row.ImportStatus = if ($InitialPhase -eq 'Imported') { 'succeeded' } else { 'failed' }
        $script:PurgePosts = 0; $script:PurgeReads = 0
        function script:Get-CpcImportResult {
            param($Id)
            Check ($Id -eq $script:Row.ImportId) 'Purge escaped import scope'; $script:PurgeReads++
            @{ assignedUserPrincipalName = $script:Row.UserPrincipalName; importStatus = $script:Row.ImportStatus; usageStatus = 'notUsed' }
        }
        # Keep Invoke-CpcGraph REAL, including its no-mutation-retry policy.
        Remove-Item function:script:Invoke-CpcGraph
        # Restore the original module implementation, not an HTTP-level retry mock.
        Set-Item function:script:Invoke-CpcGraph $script:OriginalGraph
        function script:Invoke-MgGraphRequest {
            param($Method, $Uri, $Headers, $OutputType, $Body, $ContentType, $ErrorAction)
            if ($Method -eq 'GET' -and $Uri -like "https://graph.microsoft.com/v1.0/users/$($script:Row.UserId)?*") { return $script:RecoveryUser }
            Check ($Method -eq 'POST' -and $Uri -eq "https://graph.microsoft.com$script:Endpoint/snapshots/purgeImportedSnapshot") 'Unexpected purge HTTP request'
            $payload = $Body | ConvertFrom-Json -AsHashtable
            Check (@($payload.snapshotIds).Count -eq 1 -and $payload.snapshotIds[0] -eq $script:Row.ImportId) 'Wrong purge payload'
            Check ($script:Row.Phase -eq 'PurgeSubmitting') 'POST preceded durable intent'
            $last = $script:Saves[-1] | ConvertFrom-Json -AsHashtable
            Check ($last.Rows[0].Phase -eq 'PurgeSubmitting') 'Purge intent was not saved before POST'
            $script:PurgePosts++
            $mockException = [Exception]::new('Mock ambiguous acceptance; HTTP 503')
            $mockException | Add-Member NoteProperty ResponseStatusCode 503
            throw $mockException
        }
        $first = Invoke-CpcOperation Purge @{ VmIds = @($script:Row.VmId) }
        Check ($first.OperationError -match 'Mock ambiguous acceptance' -and $script:Row.Phase -eq 'PurgeUnknown') "Ambiguity lost: $($first.OperationError)"
        Check ($script:PurgePosts -eq 1) 'Ambiguous mutation was retried'
        $saved = $script:Saves[-1] | ConvertFrom-Json -AsHashtable
        Check ($saved.Rows[0].Phase -eq 'PurgeUnknown') 'Ambiguous outcome was not persisted'
        $second = Invoke-CpcOperation Purge @{ VmIds = @($script:Row.VmId) }
        Check ($second.OperationError -match 'Unknown outcomes need manual reconciliation') 'PurgeUnknown retry not blocked'
        Check ($script:PurgePosts -eq 1 -and $script:PurgeReads -eq 1 -and $script:Row.Phase -eq 'PurgeUnknown') 'Retry re-read or re-submitted ambiguous purge'
    } -Arguments @($initialPhase)
}
Invoke-RecoveryTest 'Journal: interrupted PurgeSubmitting reloads as PurgeUnknown, never Purged or retryable' -Journal {
    $script:Row.Phase = 'PurgeSubmitting'; $script:Row.ImportId = '77777777-7777-7777-7777-777777777777'
    $script:S.StatePath = Join-Path $script:Temp 'interrupted.json'; Save-CpcState
    $path = $script:S.StatePath; $script:S.Rows.Clear()
    $result = Invoke-CpcOperation Load @{ Path = $path }
    Check (-not $result.OperationError -and $script:S.Rows[0].Phase -eq 'PurgeUnknown') "Interrupted purge recovery failed: $($result.OperationError)"
    $saved = [IO.File]::ReadAllText($path) | ConvertFrom-Json -AsHashtable
    Check ($saved.Rows[0].Phase -eq 'PurgeUnknown') 'Normalized ambiguity not saved'
    $retry = Invoke-CpcOperation Purge @{ VmIds = @($script:S.Rows[0].VmId) }
    Check ($retry.OperationError -match 'Unknown outcomes need manual reconciliation') 'Loaded ambiguity was retryable'
}

foreach ($phase in @('Copying','Importing','Imported','LicenseUnknown','Provisioning','Provisioned','Cleaned','Abandoned')) {
    Invoke-RecoveryTest "Stage audit: guest Run Command blocked in $phase before any cloud call" {
        param($Phase)
        $script:Row.Phase = $Phase
        ExpectFailure { Invoke-CpcGuestAssessment @($script:Row) } 'frozen|cannot be assessed'
        Check ($script:BoundaryViolations.Count -eq 0) 'Wrong-stage guest assessment reached Azure'
    } -Arguments @($phase)
}
Invoke-RecoveryTest 'Stage audit: frozen source identity blocks guest even without snapshot ID' {
    $script:Row.Phase = 'CaptureFailed'; $script:Row.SnapshotId = ''
    ExpectFailure { Invoke-CpcGuestAssessment @($script:Row) } 'frozen'
    Check ($script:BoundaryViolations.Count -eq 0) 'Frozen identity guest read reached Azure'
}
Invoke-RecoveryTest 'Stage audit: mixed attestation rejected before partially changing selected rows' {
    $script:Row.Phase = 'Mapped'; $script:Row.Attested = $false
    $other = $script:Row.Clone(); $other.VmId += '2'; $other.Phase = 'Copying'; $script:S.Rows.Add($other)
    $result = Invoke-CpcOperation Attest @{ VmIds = @($script:Row.VmId,$other.VmId) }
    Check ($result.OperationError -match 'no new migration action' -and -not $script:Row.Attested -and -not $other.Attested) 'Wrong-stage attestation partially mutated batch'
}
Invoke-RecoveryTest 'Stage audit: LicenseUnknown cannot use old automatic reconciliation shortcut' {
    PrepareLicense
    ExpectFailure { Start-CpcLicense @($script:Row) } 'Reconcile license'
    ExpectFailure { Get-CpcNextStage $script:Row } 'Reconcile license'
    Check ($script:Row.Phase -eq 'LicenseUnknown' -and -not $script:Row.LicenseAssignedUtc -and $script:Reads.Count -eq 0) 'Unknown outcome inferred assignment time or reached Graph'
}
Invoke-RecoveryTest 'Stage audit: copy summary includes pending OS and successful VMGS; all completion consumes stale readiness' {
    PrepareArtifacts; $script:Row.Phase = 'Copying'; $script:S.StatePath = 'OFFLINE-MOCKED-JOURNAL'
    $script:Blobs[$script:Row.VhdBlob].Status = 'Pending'; $script:Blobs[$script:Row.VhdBlob].BytesCopied = 10; $script:Blobs[$script:Row.VhdBlob].TotalBytes = 100
    $script:Blobs[$script:Row.VmgsBlob].BytesCopied = 4; $script:Blobs[$script:Row.VmgsBlob].TotalBytes = 4
    $first = Invoke-CpcOperation Refresh @{ VmIds = @($script:Row.VmId) }
    Check ($script:Row.Phase -eq 'Copying' -and $script:Row.Detail -match 'OS VHD: Pending 10/100' -and $script:Row.Detail -match 'VMGS: Success 4/4' -and $script:Revokes -eq 0) 'Small successful VMGS hid pending VHD or revoked too soon'
    Check ($first.Rows[0].StatusRefreshSucceeded -and -not $script:Row.Contains('StatusRefreshSucceeded')) 'Refresh success should be output only, not journaled row data'
    $script:Blobs[$script:Row.VhdBlob].Status = 'Success'; $script:Blobs[$script:Row.VhdBlob].BytesCopied = 100
    Update-CpcStatus @($script:Row)
    Check ($script:Row.Phase -eq 'Staged' -and $script:Revokes -eq 1 -and $script:Row.Readiness -eq 'NotChecked' -and -not $script:S.Preflight.ContainsKey($script:Row.VmId)) 'Completion failed to invalidate old capture approval/readiness'
    Check (-not $script:Row.LastError -and $script:RefreshSucceededIds.Contains($script:Row.VmId)) 'Successful refresh retained stale error or lost success flag'
}
foreach ($fault in @('missing-vhd','missing-vmgs-id','wrong-copy-id','incomplete-bytes','trusted-missing-vmgs','revoke-fails')) {
    Invoke-RecoveryTest "Stage audit: copying $fault cannot become Staged or release resume gate" {
        param($Fault)
        PrepareArtifacts; $script:Row.Phase = 'Copying'
        foreach ($copy in $script:Blobs.Values) { $copy.Status = 'Success'; $copy.BytesCopied = 4; $copy.TotalBytes = 4 }
        switch ($Fault) {
            'missing-vhd' { $script:Row.VhdBlob = '' }
            'missing-vmgs-id' { $script:Row.VmgsCopyId = '' }
            'wrong-copy-id' { $script:Blobs[$script:Row.VhdBlob].CopyId = 'replacement' }
            'incomplete-bytes' { $script:Blobs[$script:Row.VhdBlob].BytesCopied = 2 }
            'trusted-missing-vmgs' { $script:Row.VmgsBlob = ''; $script:Row.VmgsCopyId = ''; $script:Snapshot.SecurityProfile = @{ SecurityType = 'TrustedLaunch' } }
            'revoke-fails' { function script:Revoke-AzSnapshotAccess { throw 'offline revoke failure' } }
        }
        Update-CpcStatus @($script:Row)
        Check ($script:Row.Phase -eq 'Copying' -and $script:Row.LastError -and -not $script:RefreshSucceededIds.Contains($script:Row.VmId) -and $script:Revokes -eq 0) 'Invalid copy/failing revoke advanced stage or marked refresh successful'
    } -Arguments @($fault)
}

foreach ($identity in @('upn','object-id','other-upn','other-id','missing','zero')) {
    Invoke-RecoveryTest "Import identity: $identity response matches only the journal user" {
        param($Identity)
        $value = switch ($Identity) {
            'upn' { $script:Row.UserPrincipalName.ToUpperInvariant() }
            'object-id' { $script:Row.UserId }
            'other-upn' { 'other@example.invalid' }
            'other-id' { '99999999-9999-9999-9999-999999999999' }
            'missing' { '' }
            'zero' { [guid]::Empty.ToString() }
        }
        $expected = $Identity -in @('upn','object-id')
        Check ((Test-CpcImportUserIdentity @{ assignedUserPrincipalName = $value } $script:Row) -eq $expected) 'Identity matching relaxed or rejected supported response'
        if ($Identity -eq 'object-id') {
            $script:Row.UserId = ''
            Check (-not (Test-CpcImportUserIdentity @{ assignedUserPrincipalName = $value } $script:Row)) 'Missing journal object ID must not accept arbitrary GUID'
        }
    } -Arguments @($identity)
}
foreach ($validUser in @($true,$false)) {
    Invoke-RecoveryTest "Import status: succeeded object-ID response advances only matching user ($validUser)" {
        param($ValidUser)
        PrepareArtifacts
        $script:Row.Phase = 'Importing'; $script:Row.ImportStatus = 'inProgress'; $script:Row.ImportId = '80995780-6047-47b0-ac6f-728d90ff6b60'
        $script:ReturnedImportUser = if ($ValidUser) { $script:Row.UserId } else { '99999999-9999-9999-9999-999999999999' }
        function script:Get-CpcGraphCollection { param($Path) Check ($Path.StartsWith("$script:Endpoint/cloudPCs?`$filter=")) 'Unexpected read'; @() }
        function script:Get-CpcImportResult {
            param($Id)
            Check ($Id -eq $script:Row.ImportId) 'Lookup changed the known import ID'
            @{ snapshotId = $Id; assignedUserPrincipalName = $script:ReturnedImportUser; filename = $Id; importStatus = 'succeeded'; usageStatus = 'notUsed'; additionalDetail = $null }
        }
        Update-CpcStatus @($script:Row)
        if ($ValidUser) {
            Check ($script:Row.Phase -eq 'Imported' -and $script:Row.ImportStatus -eq 'succeeded' -and -not $script:Row.LastError) 'Object-ID result remained stuck or retained mismatch error'
            Check ($script:Row.Readiness -eq 'NotChecked' -and -not $script:Row.LicenseAssignedUtc -and $script:RefreshSucceededIds.Contains($script:Row.VmId)) 'Status refresh bypassed next-stage validation or licensing'
            function script:Test-CpcStagedArtifacts { param($Row) }
            Test-CpcStageEvidence $script:Row 'License'
            Check (@($script:S.Checks | Where-Object { $_.Check -eq 'Live import identity / completion' -and $_.Status -eq 'Pass' }).Count -eq 1) 'License preflight did not accept exact user object ID'
        } else {
            Check ($script:Row.Phase -eq 'Importing' -and $script:Row.LastError -match 'user mismatch' -and -not $script:RefreshSucceededIds.Contains($script:Row.VmId)) 'Foreign user result advanced or released resume gate'
        }
        Check ($script:BoundaryViolations.Count -eq 0) 'Refresh reached a cloud write'
    } -Arguments @($validUser)
}

Invoke-RecoveryTest 'Persistence fault: real replacement failure blocks repeated revocation until explicit local recovery' -Journal {
    PrepareArtifacts
    $script:S.StatePath = Join-Path $script:Temp 'fault.json'
    Save-CpcState
    $blocker = [IO.File]::Open($script:S.StatePath, 'Open', 'Read', 'Read')
    try {
        foreach ($attempt in 1..2) {
            $r = Invoke-CpcOperation RevokeExport @{ VmIds = @($script:Row.VmId) }
            Check ([bool]$r.OperationError -and [bool]$r.PersistenceFault -and $script:Revokes -eq 0) 'Mutation escaped failed durability checkpoint'
        }
    } finally { $blocker.Dispose() }
    $r = Invoke-CpcOperation RevokeExport @{ VmIds = @($script:Row.VmId) }
    Check ($script:Revokes -eq 0 -and [bool]$r.PersistenceFault) 'Successful incidental save cleared fault without review'
    $r = Invoke-CpcOperation RestorePersistence
    Check (-not $r.OperationError -and -not $r.PersistenceFault -and $script:Revokes -eq 0) 'Local restoration replayed mutation or failed'
    $r = Invoke-CpcOperation RevokeExport @{ VmIds = @($script:Row.VmId) }
    Check (-not $r.OperationError -and $script:Revokes -eq 1) 'Reviewed operation unavailable after restored durability'
}

Invoke-RecoveryTest 'Refresh: transient durable-write failure blocks automatic revocation and later rows even after incidental save succeeds' -Journal {
    PrepareArtifacts
    $script:Row.Phase = 'Copying'
    foreach ($blob in $script:Blobs.Values) { $blob.Status = 'Success'; $blob.BytesCopied = 512; $blob.TotalBytes = 512 }
    $second = $script:Row.Clone(); $second.VmId += '-second'; $second.VM = 'second'
    $script:S.Rows.Add($second)
    $script:S.StatePath = Join-Path $script:Temp 'refresh-fault.json'
    Save-CpcState
    $script:RealSave = (Get-Command Save-CpcState).ScriptBlock
    $script:FailOnce = $true
    function script:Save-CpcState($State = $script:S, $Lease = $null) {
        if ($script:FailOnce) {
            $script:FailOnce = $false
            $hold = [IO.File]::Open($script:S.StatePath, 'Open', 'Read', 'Read')
            try { & $script:RealSave -State $State -Lease $Lease } finally { $hold.Dispose() }
        } else { & $script:RealSave -State $State -Lease $Lease }
    }
    $r = Invoke-CpcOperation Refresh @{ VmIds = @($script:Row.VmId, $second.VmId) }
    Check ([bool]$r.OperationError -and [bool]$r.PersistenceFault -and $script:Revokes -eq 0) 'Refresh revoked despite failed checkpoint'
    Check ($script:CopyReads[$script:Row.VhdBlob] -eq 1 -and $second.Phase -eq 'Copying') 'Refresh continued to later row after fault'
    Check ($script:RefreshSucceededIds.Count -eq 0) 'Failed refresh released resume gate'
    $r = Invoke-CpcOperation RestorePersistence
    Check (-not $r.OperationError -and -not $r.PersistenceFault -and $script:Revokes -eq 0) 'Restoration replayed automatic revocation'
}

Invoke-RecoveryTest 'Faulted license operation skips its finally-block remote catalog refresh' {
    $script:S.StatePath = 'fixture'
    function script:Start-CpcLicense { Set-CpcPersistenceFault 'Simulated durable write failure'; throw 'Stopped before assignment' }
    function script:Update-CpcLicenseCatalog { $script:BoundaryViolations.Add('Faulted catalog read'); throw 'Catalog must not be read' }
    $r = Invoke-CpcOperation License @{ VmIds = @($script:Row.VmId) }
    Check ([bool]$r.PersistenceFault -and $r.OperationError -like '*Stopped before assignment*') 'Faulted license outcome lost'
}

Invoke-RecoveryTest 'Pre-license observation: existing PC blocks without binding the new migration; empty refresh clears display' {
    PrepareCloudPcObservation
    $guestBefore = $script:Row.Guest | ConvertTo-Json -Compress
    Update-CpcStatus @($script:Row)
    Check (-not $script:Row.CloudPcId) 'Mapped draft adopted the previous Cloud PC as this migration result'
    Check ($script:Row.ObservedCloudPcId -eq $script:PC.id -and $script:Row.CloudPcStatus -eq 'deprovisioning') 'Existing PC observation not shown'
    Check ($script:Row.Readiness -eq 'Blocked' -and $script:Row.LastError -match 'Existing Cloud PC' -and -not $script:RefreshSucceededIds.Contains($script:Row.VmId)) 'Existing PC released the migration gate'
    $script:PCs = @()
    Update-CpcStatus @($script:Row)
    Check (-not $script:Row.CloudPcId -and -not $script:Row.ObservedCloudPcId -and -not $script:Row.CloudPcStatus -and -not $script:Row.CloudPcName) 'Empty scoped result retained the previous PC display'
    Check ($script:Row.Phase -eq 'Mapped' -and $script:Row.Readiness -eq 'NotChecked' -and -not $script:Row.LastError -and $script:RefreshSucceededIds.Contains($script:Row.VmId)) 'Empty refresh advanced a stage or did not require validation'
    Check ($script:Row.Attested -and ($script:Row.Guest | ConvertTo-Json -Compress) -eq $guestBefore -and -not $script:S.Preflight.ContainsKey($script:Row.VmId)) 'Observation refresh changed guest evidence or retained approval'
}

Invoke-RecoveryTest 'Pre-license observation: loaded legacy draft clears stale ID only after successful empty refresh' -Journal {
    PrepareCloudPcObservation
    $script:Row.CloudPcId = $script:PC.id; $script:Row.CloudPcStatus = 'deprovisioning'; $script:Row.CloudPcName = 'old-pc'
    $script:S.StatePath = Join-Path $script:Temp 'old-pc-draft.json'
    Save-CpcState
    $script:S.Rows.Clear() # Load is allowed only in a fresh/empty application state.
    $loaded = Invoke-CpcOperation Load @{ Path = $script:S.StatePath }
    Check (-not $loaded.OperationError -and $script:S.Rows[0].CloudPcId -eq $script:PC.id) "Load failed or altered the recorded PC before a live lookup: $($loaded.OperationError)"
    $script:Row = $script:S.Rows[0]
    $script:PCs = @()
    $refreshed = Invoke-CpcOperation Refresh @{ VmIds = @($script:Row.VmId) }
    Check (-not $refreshed.OperationError -and $refreshed.Rows[0].StatusRefreshSucceeded -and -not $script:Row.CloudPcId -and -not $script:Row.CloudPcStatus) 'Loaded draft did not clear obsolete observation'
    $saved = [IO.File]::ReadAllText($script:S.StatePath) | ConvertFrom-Json -AsHashtable
    Check (-not $saved.Rows[0].CloudPcId -and $saved.Rows[0].Phase -eq 'Mapped' -and $saved.Rows[0].Readiness -eq 'NotChecked') 'Corrected draft state was not durable'
    $events = @([IO.File]::ReadAllLines("$($script:S.StatePath).events.jsonl") | ForEach-Object { $_ | ConvertFrom-Json -AsHashtable })
    $cleared = @($events | Where-Object Event -EQ 'PreLicenseCloudPcObservationCleared')
    Check ($cleared.Count -eq 1 -and $cleared[0].Details.RecordedCloudPcId -eq $script:PC.id) 'Previous PC identity was not retained in the audit'
}

foreach ($scenario in @('403','500','partial-list','directory-id','directory-upn','late-directory-upn')) {
    Invoke-RecoveryTest "Pre-license observation: $scenario never clears the legacy binding or releases resume" {
        param($Scenario)
        PrepareCloudPcObservation
        $script:Row.CloudPcId = $script:PC.id; $script:Row.CloudPcStatus = 'deprovisioning'; $script:Row.CloudPcName = 'old-pc'
        $script:PCs = @(); $script:ObservationFault = $Scenario
        switch ($Scenario) {
            'directory-id' { $script:User.id = '99999999-9999-9999-9999-999999999999' }
            'directory-upn' { $script:User.userPrincipalName = 'renamed@example.invalid' }
            default {
                function script:Get-CpcGraphCollection {
                    param($Path)
                    Check ($Path.StartsWith("$script:Endpoint/cloudPCs?`$filter=")) 'Unexpected collection read'
                    if ($script:ObservationFault -eq 'late-directory-upn') { $script:User.userPrincipalName = 'renamed@example.invalid'; return @() }
                    if ($script:ObservationFault -eq 'partial-list') { $script:PC }
                    throw "Offline lookup failure: $script:ObservationFault"
                }
            }
        }
        foreach ($attempt in 1..2) {
            $r = Invoke-CpcOperation Refresh @{ VmIds = @($script:Row.VmId) }
            Check (-not $r.Rows[0].StatusRefreshSucceeded -and $script:Row.LastError) 'Failed lookup released resume'
            Check ($script:Row.CloudPcId -eq $script:PC.id -and $script:Row.CloudPcStatus -eq 'deprovisioning' -and $script:Row.CloudPcName -eq 'old-pc') 'Failed/partial lookup erased recorded evidence'
        }
        Check (@($script:Audit | Where-Object Event -EQ 'PreLicenseCloudPcObservationCleared').Count -eq 0) 'Failed lookup audited a false absence'
    } -Arguments @($scenario)
}

foreach ($phase in @('Mapped','IdentityPrepared','Capturing','CaptureFailed','Copying','CopyFailed','Staged','ImportSubmitting','ImportUnknown','Importing','Imported','ImportFailed','PurgeSubmitting','PurgeUnknown','Purged','ResettingCapture','Abandoning','Abandoned')) {
    Invoke-RecoveryTest "Pre-license observation: verified absence can clear $phase without touching stage/artifacts" {
        param($Phase)
        PrepareCloudPcObservation
        $script:Row.Phase = $Phase; $script:Row.CloudPcId = $script:PC.id; $script:Row.CloudPcStatus = 'deprovisioning'
        $script:Row.ImportId = '77777777-7777-7777-7777-777777777777'; $script:Row.SnapshotId = 'retained-artifact'
        # Test the shared helper without executing phase-specific copy/import work.
        Update-CpcPreLicenseCloudPcObservation $script:Row @()
        Check (-not $script:Row.CloudPcId -and -not $script:Row.CloudPcStatus -and $script:Row.Phase -eq $Phase) 'Observation cleanup remapped/advanced a stage'
        Check ($script:Row.ImportId -eq '77777777-7777-7777-7777-777777777777' -and $script:Row.SnapshotId -eq 'retained-artifact') 'Observation cleanup erased migration artifacts'
        Check ($script:Row.Readiness -eq 'NotChecked' -and -not $script:S.Preflight.ContainsKey($script:Row.VmId)) 'Observation cleanup retained approval'
        Update-CpcPreLicenseCloudPcObservation $script:Row @()
        Check (@($script:Audit | Where-Object Event -EQ 'PreLicenseCloudPcObservationCleared').Count -eq 1) 'Repeated absence duplicated clearing audit'
    } -Arguments @($phase)
}

foreach ($phase in @('LicenseSubmitting','LicenseUnknown','Provisioning','Provisioned','Validated','CleanupPending','Cleaned','unknown-future-phase')) {
    Invoke-RecoveryTest "Post-license identity: $phase retains recorded PC even with empty lookup and missing timestamps" {
        param($Phase)
        PrepareCloudPcObservation
        $script:Row.Phase = $Phase; $script:Row.CloudPcId = $script:PC.id; $script:Row.CloudPcStatus = 'provisioned'; $script:Row.CloudPcName = 'migration-pc'
        $script:PCs = @()
        Update-CpcStatus @($script:Row)
        Check ($script:Row.CloudPcId -eq $script:PC.id -and $script:Row.CloudPcStatus -eq 'provisioned' -and $script:Row.CloudPcName -eq 'migration-pc') 'Absence erased post-license identity'
        Check (@($script:Audit | Where-Object Event -EQ 'PreLicenseCloudPcObservationCleared').Count -eq 0) 'Post-license identity treated as a draft observation'
    } -Arguments @($phase)
}

foreach ($marker in @('LicenseStartedUtc','LicenseAssignedUtc','LicenseReconciledUtc','LicenseReconciliationEvidence','ValidatedUtc','UsageStatus')) {
    Invoke-RecoveryTest "Pre-license phase with $marker evidence must preserve recorded identity" {
        param($Marker)
        PrepareCloudPcObservation
        $script:Row.CloudPcId = $script:PC.id; $script:Row.CloudPcStatus = 'provisioned'
        $script:Row[$Marker] = if ($Marker -eq 'UsageStatus') { 'inUse' } else { 'recorded-evidence' }
        $script:PCs = @()
        Update-CpcStatus @($script:Row)
        Check ($script:Row.CloudPcId -eq $script:PC.id -and $script:Row.CloudPcStatus -eq 'provisioned') 'Evidence was ignored based only on phase'
    } -Arguments @($marker)
}

foreach ($usage in @('notUsed','','missing')) {
    Invoke-RecoveryTest "Recorded consumption: live import usage '$usage' cannot erase protection on repeated refresh" {
        param($Usage)
        PrepareCloudPcObservation
        $script:Row.Phase = 'Imported'; $script:Row.ImportId = '77777777-7777-7777-7777-777777777777'
        $script:Row.ImportStatus = 'succeeded'; $script:Row.UsageStatus = 'inUse'
        $script:Row.CloudPcId = $script:PC.id; $script:Row.CloudPcStatus = 'provisioned'; $script:PCs = @()
        $script:ReturnedUsage = $Usage
        function script:Get-CpcImportResult {
            $result = @{ assignedUserPrincipalName = $script:Row.UserPrincipalName; importStatus = 'succeeded' }
            if ($script:ReturnedUsage -ne 'missing') { $result.usageStatus = $script:ReturnedUsage }
            return $result
        }
        foreach ($attempt in 1..2) {
            Update-CpcStatus @($script:Row)
            Check ($script:Row.CloudPcId -eq $script:PC.id -and $script:Row.UsageStatus -eq 'inUse' -and $script:Row.ImportStatus -eq 'succeeded') 'Regressed/missing import usage discarded recorded identity or consumption'
            Check ($script:Row.LastError -match 'usage evidence regressed' -and -not $script:RefreshSucceededIds.Contains($script:Row.VmId)) 'Regressed evidence released resume'
        }
        Check (@($script:Audit | Where-Object Event -EQ 'PreLicenseCloudPcObservationCleared').Count -eq 0) 'Regressed evidence was treated as safe pre-license absence'
    } -Arguments @($usage)
}

foreach ($scenario in @('other-policy','multiple','different-id')) {
    Invoke-RecoveryTest "Pre-license observation: $scenario blocks without adopting/replacing an identity" {
        param($Scenario)
        PrepareCloudPcObservation
        $script:Row.CloudPcId = $script:PC.id
        switch ($Scenario) {
            'other-policy' { $script:PC.provisioningPolicyId = '99999999-9999-9999-9999-999999999999' }
            'multiple' { $other = $script:PC.Clone(); $other.id = '99999999-9999-9999-9999-999999999999'; $script:PCs += $other }
            'different-id' { $script:PC.id = '99999999-9999-9999-9999-999999999999' }
        }
        Update-CpcStatus @($script:Row)
        Check ($script:Row.Readiness -eq 'Blocked' -and $script:Row.LastError -match 'Existing Cloud PC' -and -not $script:RefreshSucceededIds.Contains($script:Row.VmId)) 'Conflict was ignored'
        Check ($script:Row.CloudPcId -eq '88888888-8888-8888-8888-888888888888') 'Conflict replaced legacy recorded identity before absence'
    } -Arguments @($scenario)
}

Invoke-RecoveryTest 'Pre-license observation: cleared old PC does not poison later provisioning; new ID remains protected' {
    PrepareCloudPcObservation
    $script:Row.CloudPcId = $script:PC.id; $script:Row.CloudPcStatus = 'deprovisioning'; $script:PCs = @()
    Update-CpcStatus @($script:Row)
    Check (-not $script:Row.CloudPcId) 'Old identity remained before the new licensing attempt'
    # Simulate already-recorded successful import/license; do NOT execute a write.
    $script:Row.Phase = 'Provisioning'; $script:Row.LicenseStartedUtc = [datetimeoffset]::UtcNow.AddMinutes(-2).ToString('o')
    $script:Row.LicenseAssignedUtc = [datetimeoffset]::UtcNow.AddMinutes(-1).ToString('o')
    $script:Row.ImportId = '77777777-7777-7777-7777-777777777777'; $script:Row.ImportStatus = 'succeeded'
    $script:PC.id = '99999999-9999-9999-9999-999999999999'; $script:PC.status = 'provisioning'; $script:PCs = @($script:PC)
    Update-CpcStatus @($script:Row)
    Check ($script:Row.CloudPcId -eq $script:PC.id -and -not $script:Row.LastError) 'New migration PC could not bind after clearing previous observation'
    $script:PC.status = 'provisioned'
    Update-CpcStatus @($script:Row)
    Check ($script:Row.Phase -eq 'Provisioned' -and -not $script:Row.LastError) 'Current migration did not reach Provisioned'
    $script:PC.id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    foreach ($attempt in 1..2) {
        Update-CpcStatus @($script:Row)
        Check ($script:Row.CloudPcId -eq '99999999-9999-9999-9999-999999999999' -and $script:Row.LastError -match 'identity/policy differs' -and -not $script:RefreshSucceededIds.Contains($script:Row.VmId)) 'Repeated refresh replaced the current migration identity'
    }
}

Invoke-RecoveryTest 'Pre-license observation: audit failure preserves the old binding and blocks resume' {
    PrepareCloudPcObservation
    $script:Row.CloudPcId = $script:PC.id; $script:Row.CloudPcStatus = 'deprovisioning'; $script:PCs = @()
    $script:ObservationAudit = (Get-Command Write-CpcAudit).ScriptBlock
    function script:Write-CpcAudit($EventName, $Details) {
        if ($EventName -eq 'PreLicenseCloudPcObservationCleared') { Set-CpcPersistenceFault 'Offline audit unavailable'; throw 'Offline audit unavailable' }
        & $script:ObservationAudit $EventName $Details
    }
    $r = Invoke-CpcOperation Refresh @{ VmIds = @($script:Row.VmId) }
    Check ($r.PersistenceFault -and -not $r.Rows[0].StatusRefreshSucceeded -and $script:Row.CloudPcId -eq $script:PC.id) 'Audit failure discarded identity or released resume'
}

Invoke-RecoveryTest 'Pre-license observation: failed durable save never releases resume after clearing' -Journal {
    PrepareCloudPcObservation
    $script:Row.CloudPcId = $script:PC.id; $script:Row.CloudPcStatus = 'deprovisioning'; $script:PCs = @()
    $script:S.StatePath = Join-Path $script:Temp 'sharing-failure.json'; Save-CpcState
    $hold = [IO.File]::Open($script:S.StatePath, 'Open', 'Read', 'Read')
    try { $r = Invoke-CpcOperation Refresh @{ VmIds = @($script:Row.VmId) } }
    finally { $hold.Dispose() }
    Check ($r.PersistenceFault -and -not $r.Rows[0].StatusRefreshSucceeded) 'Save failure released resume'
    $saved = [IO.File]::ReadAllText($script:S.StatePath) | ConvertFrom-Json -AsHashtable
    Check ($saved.Rows[0].CloudPcId -eq $script:PC.id) 'Failed replacement corrupted original journal'
}

foreach ($case in @(
    @{ Phase = 'LicenseUnknown'; Status = 404; PolicyMatches = $true; Expected = $true },
    @{ Phase = 'Provisioned'; Status = 404; PolicyMatches = $true; Expected = $true },
    @{ Phase = 'Validated'; Status = 404; PolicyMatches = $true; Expected = $true },
    @{ Phase = 'CleanupPending'; Status = 404; PolicyMatches = $true; Expected = $true },
    @{ Phase = 'Imported'; Status = 404; PolicyMatches = $true; Expected = $false },
    @{ Phase = 'LicenseUnknown'; Status = 403; PolicyMatches = $true; Expected = $false },
    @{ Phase = 'LicenseUnknown'; Status = 500; PolicyMatches = $true; Expected = $false },
    @{ Phase = 'LicenseUnknown'; Status = 404; PolicyMatches = $false; Expected = $false }
)) {
    Invoke-RecoveryTest "Historical import resume: $($case.Phase)/$($case.Status)/policy=$($case.PolicyMatches)" {
        param($Case)
        PrepareLicense
        $script:PC.Remove('createdDateTime') # Public Cloud PC shape; absence is not a missing identity.
        $script:Row.Phase = $Case.Phase
        $script:Row.LicenseAssignedUtc = if ($Case.Phase -in @('Provisioned','Validated','CleanupPending')) { $script:LicenseData.AssignedUtc } else { '' }
        $script:Row.ValidatedUtc = if ($Case.Phase -in @('Validated','CleanupPending')) { [datetimeoffset]::UtcNow.ToString('o') } else { '' }
        if (-not $Case.PolicyMatches) { $script:PC.provisioningPolicyId = 'foreign-policy' }
        $script:ImportHttpStatus = $Case.Status
        function script:Get-CpcImportResult { $ex = [InvalidOperationException]::new('Fixture import lookup failed'); $ex.Data['CpcHttpStatus'] = $script:ImportHttpStatus; throw $ex }
        $r = Invoke-CpcOperation Refresh @{ VmIds = @($script:Row.VmId) }
        Check ($r.Rows[0].StatusRefreshSucceeded -eq $Case.Expected) 'Incorrect resume-refresh decision'
        # Reproduce the launcher's pending-set behavior with the real UI rules.
        $r.StatePath = 'offline-fixture'; $r.UserSettingId = 'owned-setting'
        $r | Add-Member -NotePropertyName ResumePendingVmIds -NotePropertyValue $(if ($r.Rows[0].StatusRefreshSucceeded) { @() } else { @($script:Row.VmId) })
        $actions = switch ($Case.Phase) {
            LicenseUnknown { @('ReconcileLicense') }
            Provisioned { @('Validate') }
            Validated { @('Cleanup','UseImage') }
            CleanupPending { @('Cleanup') }
            default { @() }
        }
        foreach ($action in $actions) { Check ((Get-CpcActionAvailability $action $r $r.Rows).Allowed -eq $Case.Expected) "Post-load UI incorrectly gated $action" }
        Check ([bool]$script:Row.ImportLookupWarning -eq $Case.Expected) 'Historical warning classification wrong'
        Check ($script:Row.ImportStatus -eq 'succeeded') 'Historical evidence was erased'
        if ($Case.Expected -and $Case.Phase -eq 'LicenseUnknown') {
            ExpectFailure { Repair-CpcLicenseOutcome @($script:Row) $script:LicenseData } 'creation evidence is unavailable'
            Check ($script:Row.Phase -eq 'LicenseUnknown') 'Missing creation evidence was inferred from historical import or provisioning status'
        }
    } -Arguments @($case)
}

foreach ($mismatch in @('id','directoryId','directoryUpn','userPrincipalName','provisioningPolicyId','multiple')) {
    Invoke-RecoveryTest "Historical 404: repeated Refresh cannot adopt mismatched Cloud PC ($mismatch)" {
        param($Mismatch)
        PrepareLicense
        $script:Row.CloudPcId = $script:PC.id
        if ($Mismatch -eq 'multiple') {
            $other = $script:PC.Clone(); $other.id = '99999999-9999-9999-9999-999999999999'; $script:PCs += $other
        } elseif ($Mismatch -eq 'directoryId') { $script:User.id = '99999999-9999-9999-9999-999999999999'
        } elseif ($Mismatch -eq 'directoryUpn') { $script:User.userPrincipalName = 'renamed@example.invalid'
        } else { $script:PC[$Mismatch] = 'foreign' }
        function script:Get-CpcImportResult { $ex = [InvalidOperationException]::new('Consumed fixture'); $ex.Data['CpcHttpStatus'] = 404; throw $ex }
        foreach ($attempt in 1..2) {
            $r = Invoke-CpcOperation Refresh @{ VmIds = @($script:Row.VmId) }
            Check (-not $r.Rows[0].StatusRefreshSucceeded -and [bool]$script:Row.LastError -and -not $script:Row.ImportLookupWarning) 'Mismatch released post-load gate'
            Check ($script:Row.CloudPcId -eq '88888888-8888-8888-8888-888888888888') 'Repeated refresh silently adopted replacement PC'
        }
    } -Arguments @($mismatch)
}

foreach ($scenario in @('normal','historical404','detail-id','detail-upn','detail-policy','late-directory-change','directory404')) {
    Invoke-RecoveryTest "Cutover verification with documented Cloud PC fields: $scenario" {
        param($Scenario)
        PrepareLicense
        $script:PC.Remove('createdDateTime')
        $script:Row.Phase = 'Provisioned'; $script:Row.CloudPcId = $script:PC.id
        $script:Row.LicenseAssignedUtc = $script:LicenseData.AssignedUtc
        $script:AcceptanceScenario = $Scenario
        function script:Get-CpcImportResult {
            if ($script:AcceptanceScenario -eq 'historical404') { $ex = [InvalidOperationException]::new('Consumed fixture'); $ex.Data['CpcHttpStatus'] = 404; throw $ex }
            @{ assignedUserPrincipalName = $script:Row.UserPrincipalName; importStatus = 'succeeded'; usageStatus = 'inUse' }
        }
        $script:PcDetail = $script:PC.Clone()
        switch ($Scenario) {
            'detail-id' { $script:PcDetail.id = '99999999-9999-9999-9999-999999999999' }
            'detail-upn' { $script:PcDetail.userPrincipalName = 'other@example.invalid' }
            'detail-policy' { $script:PcDetail.provisioningPolicyId = 'foreign' }
        }
        $script:ValidationGraph = (Get-Command Invoke-CpcGraph).ScriptBlock
        function script:Invoke-CpcGraph {
            param([string]$Method = 'GET', [string]$Path, $Body)
            if ($script:AcceptanceScenario -eq 'directory404' -and $Path.StartsWith('/v1.0/users/')) { throw 'Directory not found fixture' }
            $result = & $script:ValidationGraph @PSBoundParameters
            if ($script:AcceptanceScenario -eq 'late-directory-change' -and $Path -eq "$script:Endpoint/cloudPCs/$($script:PC.id)") { $script:User.userPrincipalName = 'renamed@example.invalid' }
            return $result
        }
        if ($Scenario -in @('normal','historical404')) {
            Complete-CpcValidation @($script:Row)
            Check ($script:Row.Phase -eq 'Validated' -and [bool]$script:Row.ValidatedUtc) 'Supported Cloud PC shape could not complete cutover'
            Check ([bool]$script:Row.ImportLookupWarning -eq ($Scenario -eq 'historical404')) 'Historical import warning lost'
        } else {
            ExpectFailure { Complete-CpcValidation @($script:Row) } 'status/user|policy does not match|directory user identity|Directory not found'
            Check ($script:Row.Phase -eq 'Provisioned' -and -not $script:Row.ValidatedUtc -and $script:Row.CloudPcId -eq $script:PC.id) 'Failed verification accepted cutover or remapped PC'
        }
        Check (-not $script:PC.ContainsKey('userId') -and -not $script:PC.ContainsKey('createdDateTime')) 'Fixture accidentally required undocumented fields'
    } -Arguments @($scenario)
}

foreach ($cultureName in @('en-US','en-GB','ro-RO')) {
    foreach ($shape in @('Json','DateTime','DateTimeOffset')) {
        Invoke-RecoveryTest "UTC journal reconciliation and timing: $cultureName/$shape" {
            param($CultureName, $Shape)
            $oldCulture = [cultureinfo]::CurrentCulture
            try {
                [cultureinfo]::CurrentCulture = [cultureinfo]::GetCultureInfo($CultureName)
                PrepareLicense
                $expected = ConvertTo-CpcUtcInstant $script:Row.ImportStartedUtc
                foreach ($entry in @(@{ Object = $script:Row; Key = 'ImportStartedUtc' }, @{ Object = $script:Row; Key = 'LicenseStartedUtc' }, @{ Object = $script:PC; Key = 'createdDateTime' })) {
                    $instant = ConvertTo-CpcUtcInstant $entry.Object[$entry.Key]
                    $entry.Object[$entry.Key] = switch ($Shape) {
                        Json { (ConvertFrom-Json -AsHashtable -InputObject (@{ time = $instant.UtcDateTime.ToString('o') } | ConvertTo-Json)).time }
                        DateTime { $instant.UtcDateTime }
                        DateTimeOffset { $instant.ToOffset([timespan]::FromHours(-4)) }
                    }
                }
                Check ((ConvertTo-CpcUtcInstant $script:Row.ImportStartedUtc) -eq $expected) 'UTC instant changed'
                Check ((ConvertTo-CpcUtcInstant $expected.LocalDateTime) -eq $expected) 'Local DateTime kind failed to preserve instant'
                Update-CpcTimingWarning $script:Row
                Repair-CpcLicenseOutcome @($script:Row) $script:LicenseData
                Check ($script:Row.Phase -eq 'Provisioned') 'Valid typed chronology rejected'
                $script:Row.Phase = 'LicenseUnknown'
                $script:LicenseData.AssignedUtc = $expected.AddMinutes(-1).ToString('o')
                ExpectFailure { Repair-CpcLicenseOutcome @($script:Row) $script:LicenseData } 'after this import'
                ExpectFailure { ConvertTo-CpcUtcInstant ([datetime]::SpecifyKind($expected.UtcDateTime, [DateTimeKind]::Unspecified)) } 'explicit timezone'
            } finally { [cultureinfo]::CurrentCulture = $oldCulture }
        } -Arguments @($cultureName, $shape)
    }
}

foreach ($change in @('none','vm','disk')) {
    Invoke-RecoveryTest "Assessment identity before/after Run Command: $change" {
        param($Change)
        $script:Row.Phase = 'Mapped'; $script:Row.SnapshotId = ''; $script:Row.SourceVmUniqueId = ''
        $script:AssessmentReads = 0; $script:AssessmentChange = $Change
        function script:Get-AzVM {
            param($ResourceGroupName, $Name, [switch]$Status)
            if ($Status) { return @{ Statuses = @(@{ Code = 'PowerState/running' }); VMAgent = @{ Statuses = @(@{ Code = 'ProvisioningState/succeeded' }) } } }
            $script:AssessmentReads++
            @{ VmId = $(if ($script:AssessmentChange -eq 'vm' -and $script:AssessmentReads -gt 1) { 'replaced' } else { 'original' }); StorageProfile = @{ OsDisk = @{ ManagedDisk = @{ Id = $script:Row.SourceDiskId } } } }
        }
        function script:Get-AzDisk { @{ UniqueId = $(if ($script:AssessmentChange -eq 'disk' -and $script:AssessmentReads -gt 1) { 'replacement-disk' } else { 'original-disk' }) } }
        function script:Invoke-AzVMRunCommand { @{ Value = @(@{ Message = 'CPC_GUEST_BEGIN{"Caption":"fixture","AgentCandidates":[]}CPC_GUEST_END' }) } }
        if ($Change -eq 'none') {
            Invoke-CpcGuestAssessment @($script:Row)
            Check ($script:Row.Guest.SourceVmUniqueId -eq 'original' -and $script:Row.Guest.SourceDiskUniqueId -eq 'original-disk') 'Missing assessment binding'
        } else {
            ExpectFailure { Invoke-CpcGuestAssessment @($script:Row) } 'changed during guest assessment'
            Check ($null -eq $script:Row.Guest -and -not $script:Row.Attested) 'Failed assessment retained stale evidence'
        }
    } -Arguments @($change)
}

foreach ($scenario in @('valid','wrong-upn','zero-id','licensed','cloud-pc','artifact','existing-id')) {
    Invoke-RecoveryTest "Unresolved draft abandonment: $scenario" {
        param($Scenario)
        PrepareArtifacts
        foreach ($key in @('SnapshotId','SnapshotName','SourceVmUniqueId','SourceDiskId','VhdBlob','VmgsBlob','VhdCopyId','VmgsCopyId','CaptureStartedUtc','ImportStartedUtc')) { $script:Row[$key] = '' }
        $script:Row.Phase = 'Mapped'; $script:Row.UserId = ''; $script:Row.UserPrincipalName = "o'connor+draft@example.invalid"
        $script:RecoveryUser.userPrincipalName = $script:Row.UserPrincipalName
        $script:ExpectedLookup = [uri]::EscapeDataString($script:Row.UserPrincipalName)
        function script:Invoke-CpcGraph {
            param($Path)
            Check ($Path -eq "/v1.0/users/$($script:ExpectedLookup)?`$select=id,userPrincipalName,assignedLicenses" -or
                $Path -eq "/v1.0/users/$($script:RecoveryUser.id)?`$select=id,userPrincipalName") 'Draft lookup not correctly encoded or directory read escaped resolved ID'
            $script:RecoveryUser
        }
        switch ($Scenario) {
            'wrong-upn' { $script:RecoveryUser.userPrincipalName = 'other@example.invalid' }
            'zero-id' { $script:RecoveryUser.id = [guid]::Empty.ToString() }
            'licensed' { $script:RecoveryUser.assignedLicenses = @(@{ skuId = $script:S.Config.SkuId }) }
            'cloud-pc' { $script:RecoveryPCs = @(@{ id = 'existing'; userPrincipalName = $script:Row.UserPrincipalName }) }
            'artifact' { $script:Row.SnapshotId = 'must-not-delete' }
            'existing-id' { $script:Row.UserId = '99999999-9999-9999-9999-999999999999'; $script:ExpectedLookup = $script:Row.UserId }
        }
        if ($Scenario -eq 'valid') {
            Reset-CpcCapture @($script:Row) -Abandon
            Check ($script:Row.Phase -eq 'Abandoned' -and $script:Row.UserId -eq $script:RecoveryUser.id) 'Draft did not resolve and abandon'
            Check ($script:Saves.Count -ge 2) 'Resolved identity not persisted before completion'
        } else {
            ExpectFailure { Reset-CpcCapture @($script:Row) -Abandon } 'identity|license exists'
            Check ($script:Row.Phase -eq 'Mapped') 'Rejected draft changed phase'
        }
        Check ($script:Deletes.Count -eq 0 -and $script:Revokes -eq 0) 'Draft attempted artifact changes'
    } -Arguments @($scenario)
}

Invoke-RecoveryTest 'Capture boundary rejects replacement disk instance and preserves legacy frozen semantics' {
    $script:Row.Guest = @{ SourceVmUniqueId = 'original'; SourceDiskId = 'disk'; SourceDiskUniqueId = 'original-disk' }
    $script:CaptureIdentity = @{ SourceVmUniqueId = 'original'; SourceDiskId = 'disk'; SourceDiskUniqueId = 'replacement' }
    function script:Get-CpcAssessmentSource { $script:CaptureIdentity }
    ExpectFailure { Assert-CpcCaptureSource $script:Row } 'Source identity changed'
    $script:CaptureIdentity.SourceDiskUniqueId = 'original-disk'
    $null = Assert-CpcCaptureSource $script:Row
    $script:Row.Guest = @{ CheckedUtc = [datetime]::UtcNow }; $script:Row.SourceVmUniqueId = 'original'; $script:Row.SourceDiskId = 'disk'
    $null = Assert-CpcCaptureSource $script:Row
    Check (-not $script:Row.Guest.ContainsKey('SourceVmUniqueId')) 'Legacy evidence was retroactively bound'
}

$finalHash = (Get-FileHash $corePath -Algorithm SHA256).Hash
$passed = @($script:Results | Where-Object Status -EQ 'PASS').Count
$failed = @($script:Results | Where-Object Status -EQ 'FAIL').Count
Write-Host "RECOVERY CORE SHA256 START=$initialHash END=$finalHash"
Write-Host "RECOVERY SUMMARY: TOTAL=$($script:Results.Count) PASS=$passed FAIL=$failed SKIP=0 LIVE_CALLS=0"
if ($initialHash -ne $finalHash) {
    Write-Host 'RECOVERY STATUS: INCONCLUSIVE (Core changed during execution; rerun against a stable version)'
    exit 2
}
if ($failed) { Write-Host 'RECOVERY STATUS: FAIL'; exit 1 }
Write-Host 'RECOVERY STATUS: PASS'
exit 0