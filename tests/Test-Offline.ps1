#requires -Version 7.2
<#! Offline regression tests. No Azure login, tenant reads, module installation or cloud mutations. !#>
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
$root = Split-Path $PSScriptRoot -Parent
$module = Import-Module (Join-Path $root 'CpcMigration.Core.psm1') -Force -PassThru
Import-Module (Join-Path $root 'CpcMigration.Confirmation.psm1') -Force
$script:Passed = 0
function Assert-Test([bool]$Condition,[string]$Name) {
    if (-not $Condition) { throw "FAIL: $Name" }
    $script:Passed++
    Write-Host "PASS: $Name"
}
function Assert-Throws([scriptblock]$Code,[string]$Name) {
    $threw = $false
    try { & $Code | Out-Null } catch { $threw = $true }
    Assert-Test $threw $Name
}

foreach ($file in Get-ChildItem $root -Recurse -File | Where-Object Extension -In @('.ps1','.psm1')) {
    $tokens = $null; $errors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
    Assert-Test ($errors.Count -eq 0) "PowerShell syntax: $($file.Name)"
}
$user = '11111111-1111-1111-1111-111111111111'
$sas = 'https://example.blob.core.windows.net/private/os.vhd?sv=fake&sp=r&sig=TEST_ONLY'
$vmgs = 'https://example.blob.core.windows.net/private/vmgs.vhd?sv=fake&sp=r&sig=TEST_ONLY'
$body = New-CpcImportBody $user $sas ''
Assert-Test ($body.assignedUserId -eq $user -and $body.sourceFiles.Count -eq 1) 'Standard Gen2 import body uses one file and assignedUserId'
Assert-Test ($body.sourceFiles[0].sourceType -eq 'sasUrl' -and $body.sourceFiles[0].fileType -eq 'dataFile') 'Public Graph source/file enums'
Assert-Test (-not $body.ContainsKey('snapshotLocation') -and -not $body.ContainsKey('policyId')) 'No invented overview-only API parameters'
$body = New-CpcImportBody $user $sas $vmgs
Assert-Test ($body.sourceFiles.Count -eq 2 -and $body.sourceFiles[1].fileType -eq 'virtualMachineGuestState') 'Trusted Launch adds matching VMGS'
Assert-Throws { New-CpcImportBody 'bad-user' $sas '' } 'Reject invalid user ID'
Assert-Throws { New-CpcImportBody $user '' '' } 'Reject missing VHD'
Assert-Throws { New-CpcImportBody $user 'http://example.blob.core.windows.net/x?sig=abc' '' } 'Reject HTTP SAS'
Assert-Throws { New-CpcImportBody $user 'https://evil.example/x?sig=abc' '' } 'Reject non-Azure blob host'
$redacted = Protect-CpcText ('SAS ' + $sas + ' Bearer TEST.TOKEN.VALUE')
Assert-Test ($redacted -notmatch 'TEST_ONLY|TEST.TOKEN.VALUE|sv=fake') 'Redact full SAS and bearer token'
$jsonRedacted = Protect-CpcText (@{ additionalDetail = "Failure at $sas" } | ConvertTo-Json)
Assert-Test ($jsonRedacted -notmatch 'TEST_ONLY') 'Redact SAS in JSON response text'
Assert-Test ((Get-Value @{ a = 4 } 'a') -eq 4 -and (Get-Value $null 'x' 'fallback') -eq 'fallback') 'Nullable data accessor'
$perms = @(@{ actions = @('Microsoft.Compute/*'); notActions = @('Microsoft.Compute/snapshots/delete') })
Assert-Test (Test-CpcPermission $perms 'Microsoft.Compute/snapshots/write') 'RBAC wildcard grant'
Assert-Test (-not (Test-CpcPermission $perms 'Microsoft.Compute/snapshots/delete')) 'RBAC NotActions subtracts from its own grant'
$perms += @{ actions = @('Microsoft.Compute/snapshots/delete'); notActions = @() }
Assert-Test (Test-CpcPermission $perms 'Microsoft.Compute/snapshots/delete') 'NotActions is not a global deny'
Assert-Test (-not (Test-CpcPermission $perms 'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/write' -DataAction)) 'Management wildcard does not imply storage data permissions'

foreach ($check in @('Entra joined to this tenant','No encrypted guest volumes','Client Windows 10+ (not Server/multi-session)','Guest assessment captured','Guest evidence fresh (24h before capture)','Agent ready during guest assessment')) {
    $hint = Get-CpcCheckRemediation $check
    Assert-Test ($hint -match '1 Assess guest' -and $hint -match '2 Attest prerequisites' -and $hint -match '3 Validate prerequisites' -and $hint -match 'After capture') "Guest remediation explains refresh sequence and captured-source safety: $check"
}
Assert-Test ((Get-CpcCheckRemediation 'Assessment boundaries') -match 'not an automated failure') 'Manual boundaries guidance does not claim an automated failure'
$guestDetails = & $module {
    $savedState = $script:S
    $script:S = @{ TenantId = 'test-tenant' }
    $r = @{ SourceVmUniqueId = ''; Guest = @{ CheckedUtc = [datetime]::new(2026,9,17,12,18,34,[DateTimeKind]::Utc); AzureAdJoined = $false; TenantId = ''; BitLockerKnown = $true; EncryptedVolumes = 1 } }
    $culture = [cultureinfo]::CurrentCulture
    try {
        [cultureinfo]::CurrentCulture = [cultureinfo]::GetCultureInfo('ro-RO')
        $join = Get-CpcGuestCheckDetail $r 'Entra joined to this tenant'
        $bitlocker = Get-CpcGuestCheckDetail $r 'No encrypted guest volumes'
        $r.SourceVmUniqueId = 'captured'
        $frozen = Get-CpcGuestCheckDetail $r 'No encrypted guest volumes'
        $r.SourceVmUniqueId = ''; $r.Guest = $null
        $missing = Get-CpcGuestCheckDetail $r 'Guest assessment captured'
        @{ Join = $join; BitLocker = $bitlocker; Frozen = $frozen; Missing = $missing; Other = Get-CpcGuestCheckDetail $r 'Target disk capacity' }
    } finally { [cultureinfo]::CurrentCulture = $culture; $script:S = $savedState }
}
Assert-Test ($guestDetails.Join -match '2026-09-17T12:18:34.0000000Z' -and $guestDetails.Join -match "AzureAdJoined=False; TenantId=''; required tenant='test-tenant'") 'Join evidence includes actual values and culture-independent collection timestamp'
Assert-Test ($guestDetails.BitLocker -match 'FullyDecrypted=1' -and $guestDetails.BitLocker -match 'suspended protection' -and $guestDetails.BitLocker -match 'does not reread Windows') 'BitLocker evidence explains cached values and full decryption requirement'
Assert-Test ($guestDetails.Frozen -match 'frozen' -and $guestDetails.Frozen -notmatch 'repeat 1 Assess guest') 'Captured evidence does not instruct refreshing the source'
Assert-Test ($guestDetails.Missing -match 'No saved guest assessment' -and $guestDetails.Missing -match 'repeat 1 Assess guest') 'Missing assessment provides complete next steps'
Assert-Test ($null -eq $guestDetails.Other) 'Non-guest checks retain independent evidence'

function New-TestSku([string]$Name, [string[]]$Children = @(), [long]$Enabled = 10, [long]$Consumed = 3, [string]$Status = 'Enabled') {
    @{ skuId = [guid]::NewGuid().ToString(); skuPartNumber = $Name; capabilityStatus = $Status
       prepaidUnits = @{ enabled = $Enabled; warning = 200; suspended = 300 }; consumedUnits = $Consumed
       servicePlans = @($Children | ForEach-Object { @{ servicePlanName = $_ } }) }
}
$standard = New-TestSku 'CPC_E_2C_4GB_128GB'
$leveled = New-TestSku 'CPC_LVL_3' @('CPC_E_4C_16GB_256GB')
$lite = New-TestSku 'CloudPC_AddOn' @('CloudPC_Lite','CPC_E_2C_4GB_128GB') 12 5
$litePlanId = '6b97ad6a-be15-4cbe-afbb-4eb74ecb0243'
$standardPlanId = [guid]::NewGuid().ToString()
$planFixture = @(
    @{ id = $litePlanId; displayName = 'CloudPC_Lite'; type = 'enterprise'; vCpuCount = 2; ramInGB = 4; storageInGB = 128 },
    @{ id = $standardPlanId; displayName = 'Windows 365 Enterprise 2 vCPU / 4 GB / 128 GB'; type = 'enterprise'; vCpuCount = 2; ramInGB = 4; storageInGB = 128 }
)
$licenses = @(ConvertTo-CpcLicenseCatalog @($standard,$leveled,$lite) $planFixture)
Assert-Test ($licenses.Count -eq 3) 'License catalog keeps standard Enterprise, leveling SKU and Lite'
$resolvedLite = @($licenses | Where-Object IsLite)[0]
$resolvedStandard = @($licenses | Where-Object SkuId -EQ $standard.skuId)[0]
Assert-Test ($resolvedLite.ServicePlanId -eq $litePlanId -and $resolvedLite.StorageGB -eq 128 -and $resolvedLite.Available -eq 7) 'Lite explicit mapping and available seat count'
Assert-Test ($resolvedStandard.ServicePlanId -eq $standardPlanId -and -not $resolvedStandard.IsLite) 'Lite does not collide with ordinary Enterprise having identical specs'
Assert-Test (@($licenses | Where-Object SkuId -EQ $leveled.skuId)[0].StorageGB -eq 256) 'Leveling SKU derives configuration from child provisioning plan'
Assert-Test ($resolvedStandard.Available -eq 7 -and $resolvedStandard.SelectionLabel -match 'Available: 7') 'Picker count is enabled minus consumed, not warning/suspended units'
foreach ($excludedSku in @(
    (New-TestSku 'Windows_365_Flex' @('CPC_E_2C_8GB_128GB')),
    (New-TestSku 'Windows_365_Frontline' @('CPC_E_2C_8GB_128GB')),
    (New-TestSku 'CPC_S_2C_8GB_128GB' @('CPC_E_2C_8GB_128GB')),
    (New-TestSku 'CPC_E_4C_16GB_256GB_GPU'),
    (New-TestSku 'CPC_E_2C_8GB_128GB' @('GPU_Standard')),
    (New-TestSku 'CloudPC_Lite_GPU'),
    (New-TestSku 'CPC_B_2C_8GB_128GB'),
    (New-TestSku 'CPC_E_2C_8GB_128GB' @('Windows_365_Frontline')),
    (New-TestSku 'Windows_365_Reserve' @('CPC_E_2C_8GB_128GB')),
    (New-TestSku 'Windows_365_CrossRegion_DisasterRecovery' @('CPC_E_2C_8GB_128GB')),
    (New-TestSku 'O365_E3'),
    (New-TestSku 'CPC_LVL_UNKNOWN'),
    (New-TestSku 'CPC_LVL_AMBIGUOUS' @('CPC_E_2C_8GB_128GB','CPC_E_4C_16GB_256GB'))
)) {
    Assert-Test (@(ConvertTo-CpcLicenseCatalog @($excludedSku) $planFixture).Count -eq 0) "Excluded license: $($excludedSku.skuPartNumber) / $(($excludedSku.servicePlans | ForEach-Object servicePlanName) -join ',')"
}
$exhausted = @(ConvertTo-CpcLicenseCatalog @((New-TestSku 'CPC_E_2C_8GB_128GB' @() 2 9)))[0]
Assert-Test ($exhausted.Available -eq 0 -and -not $exhausted.CanSelect) 'Overconsumption clamps available seats to zero and disables selection'
$suspended = @(ConvertTo-CpcLicenseCatalog @((New-TestSku 'CPC_E_2C_8GB_128GB' @() 20 1 'Suspended')))[0]
Assert-Test ($suspended.Available -eq 0 -and -not $suspended.CanSelect) 'Suspended SKU cannot be selected despite prepaid seats'
$missing = New-TestSku 'CPC_E_2C_8GB_128GB'; $missing.Remove('consumedUnits')
$unknownCount = @(ConvertTo-CpcLicenseCatalog @($missing))[0]
Assert-Test (-not $unknownCount.CountsKnown -and -not $unknownCount.CanSelect) 'Missing seat data fails closed'
$linkedGpuId = [guid]::NewGuid().ToString()
$linkedGpu = New-TestSku 'CPC_E_2C_8GB_128GB'; $linkedGpu.servicePlans = @(@{ servicePlanId = $linkedGpuId; servicePlanName = 'UNLABELED' })
Assert-Test (@(ConvertTo-CpcLicenseCatalog @($linkedGpu) @(@{ id = $linkedGpuId; displayName = 'Windows 365 Enterprise GPU'; type = 'enterprise' })).Count -eq 0) 'Excluded service plan ID blocks an innocuously named SKU'
Assert-Throws { & $module { param($catalog) Assert-CpcLicenseTarget $catalog '00000000-0000-0000-0000-000000000000' } $licenses } 'Backend rejects non-allowlisted SKU IDs'
Assert-Throws { & $module { param($catalog,$id) Assert-CpcLicenseTarget $catalog $id 8 } $licenses $standard.skuId } 'Backend rejects batch larger than available seats'
Assert-Throws { & $module { param($catalog,$id) Assert-CpcLicenseTarget $catalog $id 1 512 } $licenses $standard.skuId } 'Backend rejects mismatched saved disk capacity'

$review = Get-CpcConfirmationText 'Import' @{ TenantId = 'TENANT'; PolicyName = 'POLICY'; PolicyId = 'POLICY-ID'; StorageId = 'STORAGE-ID' } @(@{ VM = 'VM-NAME'; VmId = 'VM-ID'; UserPrincipalName = 'UPN'; UserId = 'USER-ID'; SnapshotId = 'SNAPSHOT-ID'; VhdBlob = 'BLOB-PATH'; VhdCopyId = 'COPY-ID'; ImportId = 'IMPORT-ID'; CloudPcId = 'PC-ID' })
foreach ($value in @('TENANT','POLICY-ID','STORAGE-ID','VM-NAME','VM-ID','UPN','USER-ID','SNAPSHOT-ID','BLOB-PATH','COPY-ID','IMPORT-ID','PC-ID','48-hour')) {
    Assert-Test ($review.Contains($value)) "Confirmation includes $value"
}

# Invoke internal functions with every cloud boundary mocked in the module's scope.
$results = & $module {
    Initialize-CpcState
    $script:Signals = $null
    $script:S.TenantId = '22222222-2222-2222-2222-222222222222'
    $script:S.SubscriptionId = '33333333-3333-3333-3333-333333333333'
    $script:S.Connected = $true
    $script:S.Config = @{ PolicyId = '44444444-4444-4444-4444-444444444444'; SkuId = '55555555-5555-5555-5555-555555555555'; TargetDiskGiB = 128; StorageId = '/subscriptions/33333333-3333-3333-3333-333333333333/resourceGroups/rg/providers/Microsoft.Storage/storageAccounts/example'; Container = 'private'; SnapshotResourceGroup = 'snapshots' }
    $vmId = '/subscriptions/33333333-3333-3333-3333-333333333333/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/source'
    $script:S.Catalog.Vms = @([pscustomobject]@{ Id = $vmId; Name = 'source'; ResourceGroup = 'rg'; Location = 'eastus' })
    function script:Assert-CpcContext { }
    function script:Get-CpcStorage {
        @{ Context = 'MOCK-NOT-A-CREDENTIAL'; Account = [pscustomobject]@{ Kind = $script:MockStorageKind; PublicNetworkAccess = 'Enabled'; NetworkRuleSet = [pscustomobject]@{ DefaultAction = 'Allow' } } }
    }
    function script:Get-AzStorageContainer { [pscustomobject]@{ PublicAccess = 'Off' } }
    function script:Get-CpcPermissions { @{ actions = @('*'); notActions = @(); dataActions = @('*'); notDataActions = @() } }
    function script:Get-AzVM {
        param($ResourceGroupName,$Name,[switch]$Status)
        if ($Status) { return [pscustomobject]@{ Statuses = @([pscustomobject]@{ Code = $script:MockPower }); VMAgent = [pscustomobject]@{ Statuses = @([pscustomobject]@{ Code = $script:MockAgentStatus }) } } }
        [pscustomobject]@{ VmId = 'vm-immutable-id'; SecurityProfile = $null; StorageProfile = [pscustomobject]@{ DataDisks = $script:MockDataDisks; OsDisk = [pscustomobject]@{ OsType = 'Windows'; DiffDiskSettings = $null; ManagedDisk = [pscustomobject]@{ Id = '/subscriptions/33333333-3333-3333-3333-333333333333/resourceGroups/rg/providers/Microsoft.Compute/disks/os' } } } }
    }
    function script:Get-AzDisk {
        [pscustomobject]@{ UniqueId = 'disk-immutable-id'; HyperVGeneration = $script:MockGeneration; DiskSizeGB = 128; DataAccessAuthMode = 'None'; NetworkAccessPolicy = 'AllowAll'; Encryption = $null; EncryptionSettingsCollection = $null }
    }
    # Workflow tests isolate stage gating; artifact validator has separate mocked tests below.
    function script:Test-CpcStagedArtifacts { }
    $script:MockPower = 'PowerState/running'
    $script:MockAgentStatus = 'ProvisioningState/succeeded'; $script:MockGeneration = 'V2'; $script:MockDataDisks = @()
    $script:MockExistingPc = $false
    $script:MockUserId = '11111111-1111-1111-1111-111111111111'
    $script:MockImportState = 'inProgress'
    $script:MockUsageState = 'notUsed'
    $script:MockCloudWrites = 0
    $script:MockSkuPart = 'CPC_E_2C_8GB_128GB'
    $script:MockConsumed = 0
    $script:MockPolicyAssigned = $true
    $script:MockStorageKind = 'StorageV2'
    $script:MockUserLicenses = @()
    $script:MockPolicyGroup = '66666666-6666-6666-6666-666666666666'
    $script:MockSettingSource = 'snapshot'
    $script:MockSettingAssigned = $true
    $script:MockMigrationMember = $true
    $script:MockConflictingSetting = $false
    function script:Get-CpcGraphCollection {
        param([string]$Path)
        if ($Path -match 'provisioningPolicies') {
            return @{ id = $script:S.Config.PolicyId; provisioningType = 'dedicated'; domainJoinConfigurations = @(@{ domainJoinType = 'azureADJoin'; regionName = 'eastus' }); assignments = $(if ($script:MockPolicyAssigned) { @(@{ target = @{ groupId = $script:MockPolicyGroup } }) } else { @() }) }
        }
        if ($Path -match 'userSettings' -and $script:MockConflictingSetting) { return @{ id = '77777777-7777-7777-7777-777777777777'; displayName = 'Snapshot-88888888-8888-8888-8888-888888888888'; provisioningSourceType = 'image'; localAdminEnabled = $false; resetEnabled = $false; assignments = @(@{ target = @{ '@odata.type' = '#microsoft.graph.cloudPcManagementGroupAssignmentTarget'; groupId = $script:MockPolicyGroup } }) } }
        if ($Path -match 'userSettings' -and $script:S.UserSettingId) { return @{ id = $script:S.UserSettingId; provisioningSourceType = $script:MockSettingSource; assignments = $(if ($script:MockSettingAssigned) { @(@{ target = @{ groupId = $script:S.GroupId } }) } else { @() }) } }
        if ($Path -match 'subscribedSkus') { return @{ skuId = $script:S.Config.SkuId; skuPartNumber = $script:MockSkuPart; prepaidUnits = @{ enabled = 5 }; consumedUnits = $script:MockConsumed; capabilityStatus = 'Enabled'; servicePlans = @(@{ servicePlanName = 'CPC_E_2C_8GB_128GB' }) } }
        if ($Path -match 'cloudPCs' -and $script:MockExistingPc) { return @{ id = 'existing'; userPrincipalName = 'test@example.invalid'; status = 'provisioned' } }
        if ($Path -match 'transitiveMemberOf') {
            if ($script:MockMigrationMember) { @{ id = '66666666-6666-6666-6666-666666666666' } }
            @{ id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' }
        }
    }
    function script:Invoke-CpcGraph {
        param([string]$Method = 'GET',[string]$Path,$Body)
        if ($Method -ne 'GET') { $script:MockCloudWrites++; throw 'Unexpected mutation during offline prerequisites' }
        if ($Path -match '/users/') { return @{ id = $script:MockUserId; userPrincipalName = 'test@example.invalid'; accountEnabled = $true; usageLocation = 'US'; assignedLicenses = $script:MockUserLicenses } }
        if ($Path -match 'retrieveSnapshotImportResult') { return @{ snapshotId = '77777777-7777-7777-7777-777777777777'; assignedUserPrincipalName = 'test@example.invalid'; importStatus = $script:MockImportState; usageStatus = $script:MockUsageState } }
        throw "Unexpected mocked Graph path: $Path"
    }
    # Group selector has isolated live-boundary tests below. Keep legacy workflow fixtures.
    function script:Assert-CpcSelectedGroup { param($Config,$Rows) @{ id = $script:MockPolicyGroup; displayName = 'offline-group' } }
    $script:S.Config.ExistingGroupId = '66666666-6666-6666-6666-666666666666'
    Set-CpcMappings @{ Mappings = @(@{ VmId = $vmId; UserPrincipalName = 'test@example.invalid' }); Config = $script:S.Config }
    $script:S.Config.Remove('ExistingGroupId'); $script:S.Config.Remove('ExistingGroupName')
    $row = $script:S.Rows[0]
    Test-CpcRows @($row)
    $noGuest = $row.Readiness -eq 'Blocked'
    $row.Guest = @{ ProductType = 1; Build = 26100; Edition = 'Enterprise'; AzureAdJoined = $true; TenantId = $script:S.TenantId; AgentReady = $true; BitLockerKnown = $true; EncryptedVolumes = 0; CheckedUtc = [datetime]::UtcNow.ToString('o') }
    $row.Guest.SourceVmUniqueId = 'vm-immutable-id'; $row.Guest.SourceDiskId = '/subscriptions/33333333-3333-3333-3333-333333333333/resourceGroups/rg/providers/Microsoft.Compute/disks/os'; $row.Guest.SourceDiskUniqueId = 'disk-immutable-id'
    $row.Attested = $true
    Test-CpcRows @($row)
    $ready = $row.Readiness -eq 'Ready'
    if (-not $ready) { throw ($script:S.Checks | Where-Object Status -EQ 'Fail' | ConvertTo-Json -Depth 6) }
    # Exercise the actual validation caller, not only Refresh: an old build may
    # have recorded a previous CPC before this attempt ever reached licensing.
    $row.CloudPcId = '88888888-8888-8888-8888-888888888888'; $row.CloudPcStatus = 'deprovisioning'; $row.CloudPcName = 'old-pc'
    Test-CpcRows @($row)
    if ($row.CloudPcId -or $row.CloudPcStatus -or $row.CloudPcName -or $row.Readiness -ne 'Ready') { throw 'Successful prerequisite lookup retained the old PC binding or skipped valid checks.' }
    $script:MockExistingPc = $true
    Test-CpcRows @($row)
    if ($row.CloudPcId -or $row.ObservedCloudPcId -ne 'existing' -or $row.Readiness -ne 'Blocked') { throw 'Prerequisites adopted or ignored an existing PC.' }
    $script:MockExistingPc = $false
    Test-CpcRows @($row)
    if ($row.CloudPcId -or $row.ObservedCloudPcId -or $row.CloudPcStatus -or $row.LastError -or $row.Readiness -ne 'Ready') { throw 'Fresh prerequisites failed to clear an obsolete existing-PC conflict.' }
    $row.Guest.SourceVmUniqueId = 'different-assessed-vm'
    $row.Remove('ObservedSourceVmUniqueId'); $row.Remove('ObservedSourceDiskId')
    Test-CpcRows @($row) -Preparing
    if ($row.Readiness -ne 'Blocked') { throw 'First validation accepted guest evidence from a different VM.' }
    $row.Guest.SourceVmUniqueId = 'vm-immutable-id'; $row.Guest.SourceDiskUniqueId = 'replaced-disk-same-arm-id'
    Test-CpcRows @($row) -Preparing
    if ($row.Readiness -ne 'Blocked') { throw 'Recreated OS disk reused guest evidence.' }
    $row.Guest.Remove('SourceDiskUniqueId')
    Test-CpcRows @($row) -Preparing
    if ($row.Readiness -ne 'Blocked') { throw 'Unbound legacy pre-capture evidence accepted.' }
    $row.Guest.SourceDiskUniqueId = 'disk-immutable-id'
    Test-CpcRows @($row) -Preparing
    if ($row.Readiness -ne 'Ready') { throw 'Matching guest identity failed control.' }
    $script:MockConflictingSetting = $true
    Test-CpcRows @($row)
    $conflict = @($script:S.Checks | Where-Object { $_.Check -eq 'No conflicting user setting' -and $_.Status -eq 'Fail' })
    if ($conflict.Count -ne 1 -or $conflict[0].Detail -notmatch 'Snapshot-88888888-8888-8888-8888-888888888888 \[77777777-7777-7777-7777-777777777777; source: image\]' -or $conflict[0].Detail -notmatch 'Use images succeeded' -or $row.Readiness -ne 'Blocked') { throw 'Conflicting image setting must remain blocked and explain that its assignment remains after Use images.' }
    $script:S.Config.ExistingGroupId = $script:MockPolicyGroup
    Test-CpcRows @($row) -Preparing
    $reuse = @($script:S.Checks | Where-Object { $_.Check -eq 'Reusable group user setting' -and $_.Status -eq 'Manual' })
    if ($row.Readiness -ne 'Ready' -or $reuse.Count -ne 1 -or $script:S.Config.ReusableUserSettingId -ne '77777777-7777-7777-7777-777777777777') {
        $failed = @($script:S.Checks | Where-Object Status -EQ 'Fail' | Select-Object VM,Check,Detail)
        throw "Prepare preflight did not identify the single direct tool-created setting as reusable. Reuse=$($reuse.Count); ID='$($script:S.Config.ReusableUserSettingId)'; failed=$($failed | ConvertTo-Json -Depth 6 -Compress)"
    }
    $script:S.Config.Remove('ExistingGroupId')
    $script:MockConflictingSetting = $false
    $row.Guest.AzureAdJoined = $false; $row.Guest.EncryptedVolumes = 1
    $recordedStamp = $row.Guest.CheckedUtc
    Test-CpcRows @($row)
    foreach ($name in @('Entra joined to this tenant','No encrypted guest volumes')) {
        $failure = @($script:S.Checks | Where-Object { $_.Check -eq $name -and $_.Status -eq 'Fail' })
        if ($failure.Count -ne 1 -or $failure[0].Detail -notmatch 'Guest assessment collected:' -or $failure[0].Detail -notmatch 'repeat 1 Assess guest') { throw "Missing cached evidence/remediation for $name" }
    }
    if ($row.Guest.CheckedUtc -ne $recordedStamp -or $row.Readiness -ne 'Blocked') { throw 'Explanatory guest evidence must not refresh observations or bypass blocking checks.' }
    $row.Guest.AzureAdJoined = $true; $row.Guest.EncryptedVolumes = 0
    $savedCulture = [cultureinfo]::CurrentCulture
    try {
        foreach ($culture in @('ro-RO','en-GB','en-US')) {
            [cultureinfo]::CurrentCulture = [cultureinfo]::GetCultureInfo($culture)
            # Reproduce real guest/journal JSON decoding, not a string-only mock.
            $row.Guest = $row.Guest | ConvertTo-Json | ConvertFrom-Json -AsHashtable
            Test-CpcRows @($row)
            if ($row.Readiness -ne 'Ready') { throw "Decoded guest timestamp failed under $culture" }
            foreach ($stamp in @([datetime]::UtcNow.AddMinutes(-1), [datetime]::Now.AddMinutes(-1), [datetimeoffset]::UtcNow.AddMinutes(-1), [datetimeoffset]::UtcNow.AddMinutes(-1).ToOffset([timespan]::FromHours(3)).ToString('o'))) {
                if (-not (Test-CpcGuestEvidenceFresh $stamp)) { throw "Fresh timestamp rejected under $culture" }
            }
            foreach ($stamp in @($null, '', '09/17/2026 12:01:48', '2026-09-17T12:01:48', [datetime]::SpecifyKind([datetime]::UtcNow,[DateTimeKind]::Unspecified), [datetime]::UtcNow.AddDays(-2), [datetime]::UtcNow.AddHours(1))) {
                if (Test-CpcGuestEvidenceFresh $stamp) { throw "Invalid, expired, or future timestamp accepted under $culture" }
            }
        }
    } finally { [cultureinfo]::CurrentCulture = $savedCulture }
    $script:MockAgentStatus = 'ProvisioningState/failed'
    Test-CpcRows @($row)
    $liveAgentBlocked = $row.Readiness -eq 'Blocked' -and @($script:S.Checks | Where-Object { $_.Check -eq 'Live Azure VM agent ready before capture' -and $_.Status -eq 'Fail' }).Count -eq 1
    $script:MockAgentStatus = 'ProvisioningState/succeeded'; $script:MockGeneration = 'V1'
    Test-CpcRows @($row)
    $gen1Blocked = $row.Readiness -eq 'Blocked'
    $script:MockGeneration = 'V2'; $script:MockDataDisks = @(@{ Name = 'data' })
    Test-CpcRows @($row)
    $dataDiskBlocked = $row.Readiness -eq 'Blocked'
    $script:MockDataDisks = @(); $row.Guest.Build = 9600
    Test-CpcRows @($row)
    $oldWindowsBlocked = $row.Readiness -eq 'Blocked'
    $row.Guest.Build = 26100; $row.Guest.ProductType = 3
    Test-CpcRows @($row)
    $serverBlocked = $row.Readiness -eq 'Blocked'
    $row.Guest.ProductType = 1
    Test-CpcRows @($row)
    $automaticNotApproval = $script:S.Preflight.Count -eq 0
    $unvalidatedPrepareBlocked = $false
    try { Prepare-CpcIdentity @($row) } catch { $unvalidatedPrepareBlocked = $_.Exception.Message -match 'Validate prerequisites first' }
    Test-CpcPreflight @($row)
    $explicitPrepare = $script:S.Preflight[$row.VmId].Stage -eq 'Prepare'
    $wrongStageBlocked = $false
    try { Start-CpcCapture @($row) } catch { $wrongStageBlocked = $_.Exception.Message -match 'Validate prerequisites first' }
    $script:S.Preflight[$row.VmId].ExpiresUtc = [datetime]::UtcNow.AddSeconds(-1).ToString('o')
    $expiredBlocked = $false
    try { Assert-CpcPreflight @($row) 'Prepare' } catch { $expiredBlocked = $true }
    Test-CpcPreflight @($row)
    $row.Attested = $false
    $changedEvidenceBlocked = $false
    try { Assert-CpcPreflight @($row) 'Prepare' } catch { $changedEvidenceBlocked = $true }
    $row.Attested = $true
    Test-CpcPreflight @($row)
    Assert-CpcPreflight @($row) 'Prepare'
    $singleUseBlocked = $false
    try { Assert-CpcPreflight @($row) 'Prepare' } catch { $singleUseBlocked = $true }
    $script:MockExistingPc = $true
    Test-CpcRows @($row)
    $existingBlocked = $row.Readiness -eq 'Blocked'
    $script:MockExistingPc = $false
    $script:MockUserId = '88888888-8888-8888-8888-888888888888'
    Test-CpcRows @($row)
    $recreatedUserBlocked = $row.Readiness -eq 'Blocked' -and $row.UserId -eq '11111111-1111-1111-1111-111111111111'
    $script:MockUserId = $row.UserId
    $row.SourceVmUniqueId = 'vm-immutable-id'; $row.SourceDiskId = '/subscriptions/33333333-3333-3333-3333-333333333333/resourceGroups/rg/providers/Microsoft.Compute/disks/os'
    Test-CpcRows @($row)
    $restartedSourceBlocked = $row.Readiness -eq 'Blocked'
    $script:MockPower = 'PowerState/deallocated'
    $row.Guest.CheckedUtc = [datetime]::UtcNow.AddDays(-2).ToString('o')
    Test-CpcRows @($row)
    $frozenCaptureNotStale = $row.Readiness -eq 'Ready'
    $row.Phase = 'IdentityPrepared'
    Test-CpcRows @($row)
    $missingIdentityBlocked = $row.Readiness -eq 'Blocked'
    $script:S.GroupId = '66666666-6666-6666-6666-666666666666'
    $script:S.UserSettingId = '99999999-9999-9999-9999-999999999999'
    Test-CpcPreflight @($row)
    $captureApproval = $script:S.Preflight[$row.VmId].Stage -eq 'Capture'
    $script:MockPolicyAssigned = $false
    $missingPolicyBlocked = $false
    try { Start-CpcCapture @($row) } catch { $missingPolicyBlocked = $_.Exception.Message -match 'Batch prerequisites changed' }
    $script:MockPolicyAssigned = $true
    $row.Phase = 'Staged'
    $unvalidatedImport = $false
    try { Start-CpcImport @($row) } catch { $unvalidatedImport = $_.Exception.Message -match 'Validate prerequisites first' }
    Test-CpcPreflight @($row)
    $importApproval = $script:S.Preflight[$row.VmId].Stage -eq 'Import'
    $script:MockStorageKind = 'BlockBlobStorage'
    $storageChangedBlocked = $false
    try { Start-CpcImport @($row) } catch { $storageChangedBlocked = $_.Exception.Message -match 'Batch prerequisites changed before import' }
    $script:MockStorageKind = 'StorageV2'
    $script:MockPolicyGroup = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    Test-CpcPreflight @($row)
    $wrongPolicyGroupBlocked = $row.Readiness -eq 'Blocked' -and -not $script:S.Preflight.ContainsKey($row.VmId) -and
        @($script:S.Checks | Where-Object { $_.Check -eq 'Selected provisioning policy assigned' -and $_.Status -eq 'Pass' }).Count -eq 1 -and
        @($script:S.Checks | Where-Object { $_.Check -eq 'Selected policy assigned to migration group' -and $_.Status -eq 'Fail' }).Count -eq 1
    $script:MockPolicyGroup = $script:S.GroupId
    $script:MockSettingSource = 'image'
    Test-CpcPreflight @($row)
    $imageSettingBlocked = $row.Readiness -eq 'Blocked' -and -not $script:S.Preflight.ContainsKey($row.VmId)
    $script:MockSettingSource = 'snapshot'; $script:MockSettingAssigned = $false
    Test-CpcPreflight @($row)
    $unassignedSettingBlocked = $row.Readiness -eq 'Blocked' -and -not $script:S.Preflight.ContainsKey($row.VmId)
    $script:MockSettingAssigned = $true; $script:MockMigrationMember = $false
    Test-CpcPreflight @($row)
    $missingMemberBlocked = $row.Readiness -eq 'Blocked' -and -not $script:S.Preflight.ContainsKey($row.VmId)
    $script:MockMigrationMember = $true
    $row.Phase = 'Importing'; $row.ImportId = '77777777-7777-7777-7777-777777777777'
    Update-CpcStatus @($row)
    $pendingNotImported = $row.Phase -eq 'Importing'
    $script:MockImportState = 'succeeded'
    Update-CpcStatus @($row)
    $importedNotProvisioned = $row.Phase -eq 'Imported' -and -not $row.LicenseAssignedUtc
    $script:MockImportState = 'inProgress'
    $blockedLicense = $false
    try { Start-CpcLicense @($row) } catch { $blockedLicense = $true }
    $script:MockImportState = 'succeeded'
    Test-CpcPreflight @($row)
    $licenseApproval = $script:S.Preflight[$row.VmId].Stage -eq 'License'
    $script:MockConsumed = 5
    $depletedBlocked = $false
    try { Start-CpcLicense @($row) } catch { $depletedBlocked = $_.Exception.Message -match 'Pre-license prerequisites changed' }
    $depletedBlocked = $depletedBlocked -and @($script:S.Checks | Where-Object { $_.Status -eq 'Fail' -and $_.Detail -match 'available 0' }).Count -gt 0
    $script:MockConsumed = 0
    Test-CpcPreflight @($row)
    $script:MockSkuPart = 'Windows_365_Flex'
    $forbiddenBlocked = $false
    try { Start-CpcLicense @($row) } catch { $forbiddenBlocked = $_.Exception.Message -match 'Pre-license prerequisites changed' }
    $script:MockSkuPart = 'CPC_E_2C_8GB_128GB'
    $row.Phase = 'LicenseUnknown'
    $script:MockConsumed = 5
    $script:MockUserLicenses = @(@{ skuId = $script:S.Config.SkuId })
    $unknownCheckBlocked = $false; $unknownLicenseBlocked = $false
    try { Test-CpcPreflight @($row) } catch { $unknownCheckBlocked = $_.Exception.Message -match 'Reconcile license' }
    try { Start-CpcLicense @($row) } catch { $unknownLicenseBlocked = $_.Exception.Message -match 'Reconcile license' }
    $reconciledWithoutWrite = $unknownCheckBlocked -and $unknownLicenseBlocked -and $row.Phase -eq 'LicenseUnknown' -and -not $row.LicenseAssignedUtc -and $script:MockCloudWrites -eq 0
    $jsonPath = Join-Path ([IO.Path]::GetTempPath()) ('cpcm-test-' + [guid]::NewGuid() + '.json')
    $script:S.StatePath = $jsonPath
    $row.Detail = 'https://example.blob.core.windows.net/private/file?sig=DO_NOT_PERSIST'
    Save-CpcState
    $saved = [IO.File]::ReadAllText($jsonPath)
    Remove-Item $jsonPath
    $script:S.StatePath = ''
    [pscustomobject]@{
        NoGuestBlocks = $noGuest; NullableAzureModels = $ready; ExistingPcBlocks = $existingBlocked
        LiveAgentFailureBlocks = $liveAgentBlocked; SourceGen1Blocks = $gen1Blocked; SourceDataDisksBlock = $dataDiskBlocked; PreWindows10Blocks = $oldWindowsBlocked; WindowsServerBlocks = $serverBlocked
        RecreatedUserBlocks = $recreatedUserBlocked; RestartedSourceBlocks = $restartedSourceBlocked
        FrozenCaptureEvidence = $frozenCaptureNotStale; PendingNotImported = $pendingNotImported
        ImportedNotProvisioned = $importedNotProvisioned; LicenseGated = $blockedLicense
        FreshlyDepletedLicenseBlocks = $depletedBlocked; ForbiddenSkuBlocksAssignment = $forbiddenBlocked
        AutomaticCheckCannotApprove = $automaticNotApproval; UnvalidatedPrepareBlocks = $unvalidatedPrepareBlocked
        ExplicitPrepareApproval = $explicitPrepare; ExpiredApprovalBlocks = $expiredBlocked; ChangedEvidenceBlocks = $changedEvidenceBlocked
        SingleUseApproval = $singleUseBlocked; MissingIdentityBlocks = $missingIdentityBlocked; ExplicitCaptureApproval = $captureApproval
        RemovedPolicyBlocksCapture = $missingPolicyBlocked; ExplicitLicenseApproval = $licenseApproval
        WrongStageBlocks = $wrongStageBlocked; UnvalidatedImportBlocks = $unvalidatedImport; ExplicitImportApproval = $importApproval
        StorageChangedBlocksImport = $storageChangedBlocked; UnknownLicenseRequiresExplicitAuditReconciliation = $reconciledWithoutWrite
        ApprovalNotPersisted = $saved -notmatch 'Preflight|Fingerprint|ExpiresUtc'
        SameMigrationGroupRequiredForPolicy = $wrongPolicyGroupBlocked; ImageProvisioningSettingBlocksImport = $imageSettingBlocked
        UnassignedSnapshotSettingBlocksImport = $unassignedSettingBlocked; MissingMigrationGroupMemberBlocksImport = $missingMemberBlocked
        NoCloudWrites = $script:MockCloudWrites -eq 0; JournalRedacted = $saved -notmatch 'DO_NOT_PERSIST'
    }
}
foreach ($p in $results.PSObject.Properties) { Assert-Test ([bool]$p.Value) "Mocked workflow: $($p.Name)" }
Remove-Module CpcMigration.Core
$module = Import-Module (Join-Path $root 'CpcMigration.Core.psm1') -Force -PassThru
$footerResults = & $module {
    Initialize-CpcState
    $script:FooterBytes = [byte[]]::new(512)
    [text.encoding]::ASCII.GetBytes('conectix').CopyTo($script:FooterBytes,0)
    $script:FooterBytes[63] = 2
    $sum = [uint32]0
    foreach ($b in $script:FooterBytes) { $sum += $b }
    $checksum = [uint32]::MaxValue - $sum
    for ($i = 0; $i -lt 4; $i++) { $script:FooterBytes[64 + $i] = [byte](($checksum -shr (24 - 8 * $i)) -band 255) }
    function script:Invoke-WebRequest {
        param($Uri,$Method,$Headers)
        if ($Method -eq 'Head') { return [pscustomobject]@{ Headers = @{ 'Content-Length' = @('1024') } } }
        [pscustomobject]@{ StatusCode = 206; RawContentStream = [IO.MemoryStream]::new($script:FooterBytes) }
    }
    $fixedValid = Test-CpcVhdFooter 'https://example.invalid/OFFLINE'
    $script:FooterBytes[63] = 3
    $dynamicRejected = $false
    try { $null = Test-CpcVhdFooter 'https://example.invalid/OFFLINE' } catch { $dynamicRejected = $true }
    $script:FooterBytes[63] = 2; $script:FooterBytes[80] = 1
    $checksumRejected = $false
    try { $null = Test-CpcVhdFooter 'https://example.invalid/OFFLINE' } catch { $checksumRejected = $true }
    # Confirm mutation gate is enforced in the engine, not just by the UI.
    $signals = [hashtable]::Synchronized(@{ Cancel = $false; Queue = [collections.concurrent.concurrentqueue[string]]::new() })
    $null = Invoke-CpcOperation -Action Capture -Data @{ VmIds = @('OFFLINE') } -Signals $signals
    $journalGate = ($script:S.Logs -join ' ') -match 'journal is required'
    [pscustomobject]@{ FixedFooter = $fixedValid; DynamicRejected = $dynamicRejected; ChecksumRejected = $checksumRejected; EngineJournalGate = $journalGate }
}
foreach ($p in $footerResults.PSObject.Properties) { Assert-Test ([bool]$p.Value) "Offline integrity: $($p.Name)" }
Remove-Module CpcMigration.Core
$module = Import-Module (Join-Path $root 'CpcMigration.Core.psm1') -Force -PassThru
$artifactResults = & $module {
    Initialize-CpcState
    $script:S.Config.TargetDiskGiB = 128
    $script:S.Config.Container = 'private'
    $r = @{ VM = 'source'; VmId = 'vm-id'; UserId = 'user-id'; SnapshotName = 'snap'; SnapshotId = 'snapshot-id'; SourceDiskId = 'disk-id'; VhdBlob = "$($script:S.PlanId)/user-id/snap/os.vhd"; VmgsBlob = ''; VhdCopyId = 'copy-id'; VmgsCopyId = '' }
    $script:MockSnapshot = @{ Id = 'snapshot-id'; Tags = @{ CpcMigrationPlan = $script:S.PlanId; SourceVmId = 'vm-id' }; CreationData = @{ SourceResourceId = 'disk-id' }; ProvisioningState = 'Succeeded'; HyperVGeneration = 'V2'; DiskSizeGB = 128; SecurityProfile = @{ SecurityType = 'Standard' } }
    $script:MockCopy = @{ CopyId = 'copy-id'; Status = 'Success'; BytesCopied = 1024L; TotalBytes = 1024L }
    $script:MockBlobType = 'PageBlob'
    $script:FooterValid = $true
    function script:Get-AzSnapshot { $script:MockSnapshot }
    function script:Get-CpcStorage { @{ Context = 'OFFLINE' } }
    function script:Get-AzStorageBlobCopyState { $script:MockCopy }
    function script:Get-AzStorageBlob { @{ BlobType = $script:MockBlobType } }
    function script:New-CpcBlobSas { 'https://example.invalid/os.vhd?sig=OFFLINE_ONLY' }
    function script:Test-CpcVhdFooter { if (-not $script:FooterValid) { throw 'Invalid VHD footer' }; $true }
    function Test-Rejected([scriptblock]$Call) { try { & $Call; return $false } catch { return $true } }
    Test-CpcStagedArtifacts $r
    $passed = $script:S.Checks[-1].Status -eq 'Pass'
    $script:MockSnapshot.Tags.CpcMigrationPlan = 'someone-else'
    $ownership = Test-Rejected { Test-CpcStagedArtifacts $r }
    $script:MockSnapshot.Tags.CpcMigrationPlan = $script:S.PlanId
    $script:MockSnapshot.HyperVGeneration = 'V1'
    $gen = Test-Rejected { Test-CpcStagedArtifacts $r }
    $script:MockSnapshot.HyperVGeneration = 'V2'
    $script:MockSnapshot.DiskSizeGB = 256
    $capacity = Test-Rejected { Test-CpcStagedArtifacts $r }
    $script:MockSnapshot.DiskSizeGB = 128
    $script:MockCopy.CopyId = 'replaced-copy'
    $copyId = Test-Rejected { Test-CpcStagedArtifacts $r }
    $script:MockCopy.CopyId = 'copy-id'; $script:MockCopy.BytesCopied = 512L
    $partial = Test-Rejected { Test-CpcStagedArtifacts $r }
    $script:MockCopy.BytesCopied = 1024L; $script:MockCopy.Status = 'Pending'
    $pending = Test-Rejected { Test-CpcStagedArtifacts $r }
    $script:MockCopy.Status = 'Success'; $script:MockBlobType = 'BlockBlob'
    $type = Test-Rejected { Test-CpcStagedArtifacts $r }
    $script:MockBlobType = 'PageBlob'; $script:FooterValid = $false
    $footer = Test-Rejected { Test-CpcStagedArtifacts $r }
    $script:FooterValid = $true; $script:MockSnapshot.SecurityProfile.SecurityType = 'TrustedLaunch'
    $missingVmgs = Test-Rejected { Test-CpcStagedArtifacts $r }
    [pscustomobject]@{ ValidStaging = $passed; ForeignSnapshotBlocks = $ownership; Gen1SnapshotBlocks = $gen; OversizedSnapshotBlocks = $capacity
        ReplacedCopyBlocks = $copyId; IncompleteCopyBlocks = $partial; PendingCopyBlocks = $pending; BlockBlobBlocks = $type; InvalidFooterBlocks = $footer; MissingVmgsBlocks = $missingVmgs }
}
foreach ($p in $artifactResults.PSObject.Properties) { Assert-Test ([bool]$p.Value) "Stage evidence: $($p.Name)" }
Remove-Module CpcMigration.Core
$module = Import-Module (Join-Path $root 'CpcMigration.Core.psm1') -Force -PassThru
$repairResults = & $module {
    Initialize-CpcState
    $script:S.Connected = $true; $script:S.StatePath = 'OFFLINE-JOURNAL'
    $script:S.SubscriptionId = '33333333-3333-3333-3333-333333333333'
    $script:S.GroupId = '66666666-6666-6666-6666-666666666666'; $script:S.UserSettingId = '99999999-9999-9999-9999-999999999999'
    $script:S.Config = @{ PolicyId = '44444444-4444-4444-4444-444444444444'; SkuId = '55555555-5555-5555-5555-555555555555'; TargetDiskGiB = 128; StorageId = '/subscriptions/33333333-3333-3333-3333-333333333333/resourceGroups/rg/providers/Microsoft.Storage/storageAccounts/example'; Container = 'private'; SnapshotResourceGroup = 'snapshots' }
    $r = @{ VmId = 'vm'; UserId = '11111111-1111-1111-1111-111111111111'; UserPrincipalName = 'test@example.invalid'; Phase = 'Imported'; LicenseAssignedUtc = ''; Readiness = 'Ready'; Attested = $true }
    $script:S.Rows.Add($r); $script:S.Preflight.vm = @{ Stage = 'License' }
    $script:RepairWrites = [collections.generic.list[object]]::new()
    $script:RepairMembers = @(); $script:RepairLicensed = $false
    $script:RepairGroupLicenses = @()
    $script:RepairSettingName = "Snapshot-$($script:S.PlanId)"
    $script:RepairSettingAssignments = @()
    $script:RepairPolicy = @{ id = $script:S.Config.PolicyId; provisioningType = 'dedicated'; assignments = @(@{ target = @{ groupId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' } }) }
    function script:Assert-CpcContext { }
    function script:Save-CpcState { } # No disk writes, no actual credentials.
    function script:Write-CpcAudit { } # Durable audit is tested with real temp journals in Test-Recovery.
    function script:Get-CpcGraphCollection {
        param($Path)
        if ($Path -match 'provisioningPolicies') { return $script:RepairPolicy }
        if ($Path -match '/members\?') { return $script:RepairMembers }
    }
    function script:Invoke-CpcGraph {
        param($Method = 'GET',$Path,$Body)
        if ($Method -ne 'GET') { $script:RepairWrites.Add(@{ Method = $Method; Path = $Path; Body = $Body }); return }
        if ($Path -match '/groups/') { return @{ id = $script:S.GroupId; displayName = "CPCMigration-$($script:S.PlanId)"; securityEnabled = $true; groupTypes = @(); assignedLicenses = $script:RepairGroupLicenses } }
        if ($Path -match '/userSettings/') { return @{ id = $script:S.UserSettingId; displayName = $script:RepairSettingName; localAdminEnabled = $false; resetEnabled = $false; provisioningSourceType = 'image'; assignments = $script:RepairSettingAssignments } }
        if ($Path -match '/provisioningPolicies/') { return $script:RepairPolicy }
        if ($Path -match '/users/') { return @{ id = $script:S.Rows[0].UserId; userPrincipalName = 'test@example.invalid'; accountEnabled = $true; assignedLicenses = $(if ($script:RepairLicensed) { @(@{ skuId = $script:S.Config.SkuId }) } else { @() }) } }
        throw "Unexpected mock Graph path $Path"
    }
    Repair-CpcSnapshotAssignments
    $patch = @($script:RepairWrites | Where-Object Method -EQ 'PATCH')
    $settingAssign = @($script:RepairWrites | Where-Object { $_.Path -match '/userSettings/.+/assign$' })
    $policyAssign = @($script:RepairWrites | Where-Object { $_.Path -match '/provisioningPolicies/.+/assign$' })
    $checks = [ordered]@{
        PatchesSnapshotMode = $patch.Count -eq 1 -and $patch[0].Body.provisioningSourceType -eq 'snapshot'
        AssignsSettingToMigrationGroup = $settingAssign.Count -eq 1 -and $settingAssign[0].Body.assignments[0].target.groupId -eq $script:S.GroupId
        PreservesExistingPolicyTarget = $policyAssign.Count -eq 1 -and $policyAssign[0].Body.assignments.Count -eq 2 -and $policyAssign[0].Body.assignments[0].target.groupId -eq 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        RestoresUserMembership = @($script:RepairWrites | Where-Object { $_.Path -match '/members/\$ref$' }).Count -eq 1
        NoImportOrLicenseWrite = @($script:RepairWrites | Where-Object { $_.Path -match 'importSnapshot|assignLicense' }).Count -eq 0
        RequiresCustomerReattestation = -not $r.Attested -and $r.Readiness -eq 'NotChecked' -and $script:S.Preflight.Count -eq 0 -and $r.Phase -eq 'Imported'
    }
    function Test-RepairBlocked {
        $count = $script:RepairWrites.Count
        try { Repair-CpcSnapshotAssignments; return $false } catch { return $script:RepairWrites.Count -eq $count }
    }
    $script:RepairSettingName = 'Unrelated setting'
    $checks['RefusesUnownedSetting'] = Test-RepairBlocked
    $script:RepairSettingName = "Snapshot-$($script:S.PlanId)"
    $script:RepairMembers = @(@{ id = 'non-batch-user' })
    $checks['RefusesNonBatchMembers'] = Test-RepairBlocked
    $script:RepairMembers = @(); $script:RepairLicensed = $true
    $checks['RefusesAlreadyLicensedUser'] = Test-RepairBlocked
    $script:RepairLicensed = $false; $r.Phase = 'Provisioning'
    $checks['RefusesProvisioningBatch'] = Test-RepairBlocked
    $r.Phase = 'Imported'; $script:RepairSettingAssignments = @(@{ target = @{ groupId = 'unrelated-group' } })
    $checks['RefusesUnrelatedSettingAssignments'] = Test-RepairBlocked
    $script:RepairSettingAssignments = @(); $script:RepairGroupLicenses = @(@{ skuId = $script:S.Config.SkuId })
    $checks['RefusesLicenseBearingGroup'] = Test-RepairBlocked
    [pscustomobject]$checks
}
foreach ($p in $repairResults.PSObject.Properties) { Assert-Test ([bool]$p.Value) "Admin Graph repair: $($p.Name)" }
Remove-Module CpcMigration.Core
Assert-Test ((Get-CpcCheckRemediation 'Snapshot user setting assigned') -match 'Repair snapshot setting') 'Failed snapshot assignment points admin to the repair button'
Assert-Test ((Get-CpcCheckRemediation 'Operator attestation recorded') -match 'Customer/admin.*Attest prerequisites') 'Missing customer attestation gives explicit corrective action'
$module = Import-Module (Join-Path $root 'CpcMigration.Core.psm1') -Force -PassThru
$scopeResults = & $module {
    Initialize-CpcState
    $tenant = '22222222-2222-2222-2222-222222222222'
    $subA = '33333333-3333-3333-3333-333333333333'
    $subB = '77777777-7777-7777-7777-777777777777'
    $script:AuthCalls = 0; $script:GraphAuthCalls = 0; $script:ContextCalls = 0
    $script:FailAuth = $false; $script:FailGraph = $false; $script:WrongContext = $false; $script:FailInventory = $false
    $script:ScopeSubscriptions = @(
        [pscustomobject]@{ Name = 'Same name'; Id = $subA; TenantId = $tenant; State = 'Enabled' },
        [pscustomobject]@{ Name = 'Same name'; Id = $subB; TenantId = $tenant; State = 'Enabled' },
        [pscustomobject]@{ Name = 'Disabled'; Id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'; TenantId = $tenant; State = 'Disabled' },
        [pscustomobject]@{ Name = 'Foreign tenant'; Id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'; TenantId = 'cccccccc-cccc-cccc-cccc-cccccccccccc'; State = 'Enabled' }
    )
    # Mock every authentication and service boundary; no installed Az modules needed.
    function script:Import-Module { param($Name,$ErrorAction) }
    function script:Disable-AzContextAutosave { param($Scope) }
    $script:LoginConfigCalls = 0
    function script:Update-AzConfig {
        param($LoginExperienceV2,$Scope,$ErrorAction)
        if ($LoginExperienceV2 -ne 'Off' -or $Scope -ne 'Process' -or $ErrorAction -ne 'Stop') { throw 'Console login selector must be disabled in this process only.' }
        $script:LoginConfigCalls++
    }
    function script:Connect-AzAccount {
        param($Tenant,$Subscription,$Environment,$Scope)
        $script:AuthCalls++
        if ($script:LoginConfigCalls -ne $script:AuthCalls) { throw 'Console selector was not disabled before this login.' }
        if ($script:FailAuth) { throw 'OFFLINE auth failure' }
        $script:AzTenant = $Tenant; $script:AzSub = $Subscription
    }
    function script:Get-AzSubscription { param($TenantId) $script:ScopeSubscriptions }
    function script:Set-AzContext { param($Tenant,$Subscription,$Scope) $script:ContextCalls++; $script:AzTenant = $Tenant; $script:AzSub = $Subscription }
    function script:Get-AzContext {
        @{ Tenant = @{ Id = $script:AzTenant }; Subscription = @{ Id = $(if ($script:WrongContext) { 'wrong' } else { $script:AzSub }) }; Environment = @{ Name = 'AzureCloud' } }
    }
    function script:Connect-MgGraph {
        param($TenantId,$Environment,$ContextScope,[switch]$NoWelcome,$Scopes)
        $script:GraphAuthCalls++
        if ($script:FailGraph) { throw 'OFFLINE Graph auth failure' }
        $script:MgTenant = $TenantId
    }
    function script:Get-MgContext { @{ TenantId = $script:MgTenant; Environment = 'Global' } }
    function script:Set-MgRequestContext { param($MaxRetry,$ClientTimeout) }
    function script:Get-AzResourceGroup {
        [pscustomobject]@{ ResourceGroupName = 'source'; ResourceId = "/subscriptions/$($script:AzSub)/resourceGroups/source"; Location = 'eastus' }
        [pscustomobject]@{ ResourceGroupName = 'empty'; ResourceId = "/subscriptions/$($script:AzSub)/resourceGroups/empty"; Location = 'westus' }
    }
    function script:Get-AzVM {
        if ($script:FailInventory) { throw 'OFFLINE inventory failure' }
        [pscustomobject]@{ Name = 'source-vm'; ResourceGroupName = 'source'; Location = 'eastus'; Id = "/subscriptions/$($script:AzSub)/resourceGroups/source/providers/Microsoft.Compute/virtualMachines/source-vm"; HardwareProfile = @{ VmSize = 'Standard_D2s_v5' }; StorageProfile = @{ OsDisk = @{ OsType = 'Windows' } } }
    }
    function script:Get-AzStorageAccount { [pscustomobject]@{ StorageAccountName = 'storage'; Id = "/subscriptions/$($script:AzSub)/resourceGroups/source/providers/Microsoft.Storage/storageAccounts/storage"; Location = 'eastus' } }
    function script:Get-CpcGraphCollection { param($Path) }
    function script:Update-CpcLicenseCatalog { $script:S.Catalog.Skus = @() }
    $checks = [ordered]@{}
    $discovered = Invoke-CpcOperation 'DetectSubscriptions' @{ TenantId = $tenant }
    $checks.EnabledTenantSubscriptionsOnly = $discovered.Catalog.Subscriptions.Count -eq 2 -and -not $discovered.OperationError
    $checks.DiscoveryDisablesConsoleSelector = $script:LoginConfigCalls -eq 1
    $checks.NoImplicitSubscriptionOrGraphLogin = -not $discovered.Connected -and -not $discovered.SubscriptionId -and $script:GraphAuthCalls -eq 0 -and $script:ContextCalls -eq 0
    $checks.DuplicateNamesHaveDistinctIds = $discovered.Catalog.Subscriptions[0].DisplayName -ne $discovered.Catalog.Subscriptions[1].DisplayName
    foreach ($id in @('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb','dddddddd-dddd-dddd-dddd-dddddddddddd')) {
        $before = $script:AuthCalls
        $rejected = Invoke-CpcOperation 'Connect' @{ TenantId = $tenant; SubscriptionId = $id }
        $checks["RejectUndiscovered_$id"] = [bool]$rejected.OperationError -and $script:AuthCalls -eq $before
    }
    $connected = Invoke-CpcOperation 'Connect' @{ TenantId = $tenant; SubscriptionId = $subA }
    $checks.ExplicitSelectedContext = $connected.Connected -and $connected.SubscriptionId -eq $subA -and $script:ContextCalls -eq 1 -and -not $connected.OperationError
    $checks.ConnectDisablesConsoleSelector = $script:LoginConfigCalls -eq 2
    $inventory = Invoke-CpcOperation 'Discover'
    $checks.GroupsIncludeEmptyGroups = $inventory.Catalog.ResourceGroups.Count -eq 2 -and $inventory.Catalog.Vms.Count -eq 1 -and -not $inventory.OperationError
    $checks.InventoryBoundToSubscription = $inventory.Catalog.ResourceGroups[0].Id -like "/subscriptions/$subA/*" -and $inventory.Catalog.Vms[0].Id -like "/subscriptions/$subA/*" -and $inventory.Catalog.Storage[0].Id -like "/subscriptions/$subA/*"
    $script:S.Config.PolicyId = 'old-policy'; $script:S.Preflight.old = @{ Stage = 'Prepare' }
    $switched = Invoke-CpcOperation 'Connect' @{ TenantId = $tenant; SubscriptionId = $subB }
    $checks.PreplanSwitchClearsOldScope = $switched.Connected -and $switched.SubscriptionId -eq $subB -and $switched.Catalog.Vms.Count -eq 0 -and $switched.Catalog.ResourceGroups.Count -eq 0 -and $switched.Catalog.Storage.Count -eq 0 -and -not $switched.Config.PolicyId -and $switched.Preflight.Count -eq 0
    $inventory = Invoke-CpcOperation 'Discover'
    $checks.SwitchRediscoversCorrectScope = $inventory.Catalog.Vms[0].Id -like "/subscriptions/$subB/*"
    $script:S.Rows.Add(@{ VmId = $inventory.Catalog.Vms[0].Id; Phase = 'Mapped' })
    $before = $script:AuthCalls; $contextBefore = $script:ContextCalls
    $locked = Invoke-CpcOperation 'Connect' @{ TenantId = $tenant; SubscriptionId = $subA }
    $checks.PlanBlocksSwitchBeforeAuthentication = [bool]$locked.OperationError -and $script:AuthCalls -eq $before -and $script:ContextCalls -eq $contextBefore -and $locked.SubscriptionId -eq $subB -and $locked.Rows.Count -eq 1 -and $locked.Catalog.Vms.Count -eq 1
    $locked = Invoke-CpcOperation 'DetectSubscriptions' @{ TenantId = $tenant }
    $checks.PlanBlocksDiscoveryBeforeAuthentication = [bool]$locked.OperationError -and $script:AuthCalls -eq $before -and $locked.SubscriptionId -eq $subB
    $same = Invoke-CpcOperation 'Connect' @{ TenantId = $tenant; SubscriptionId = $subB }
    $checks.PlanAllowsSameScopeReconnect = $same.Connected -and -not $same.OperationError -and $same.Rows.Count -eq 1
    $script:S.Rows.Clear()
    $script:S.GroupId = 'owned-group'
    $locked = Invoke-CpcOperation 'Connect' @{ TenantId = $tenant; SubscriptionId = $subA }
    $checks.OwnedGroupLocksScopeEvenWithoutRows = [bool]$locked.OperationError -and $locked.SubscriptionId -eq $subB
    $script:S.GroupId = ''
    $script:WrongContext = $true
    $wrong = Invoke-CpcOperation 'Connect' @{ TenantId = $tenant; SubscriptionId = $subB }
    $checks.ContextMismatchFailsClosed = [bool]$wrong.OperationError -and -not $wrong.Connected
    $script:WrongContext = $false; $script:FailGraph = $true
    $failed = Invoke-CpcOperation 'Connect' @{ TenantId = $tenant; SubscriptionId = $subA }
    $checks.GraphFailureFailsClosed = [bool]$failed.OperationError -and -not $failed.Connected -and $failed.Catalog.Vms.Count -eq 0
    $script:FailGraph = $false
    $null = Invoke-CpcOperation 'Connect' @{ TenantId = $tenant; SubscriptionId = $subB }
    $script:FailInventory = $true
    $failed = Invoke-CpcOperation 'Discover'
    $checks.FailedDiscoveryDiscardsPartialInventory = [bool]$failed.OperationError -and $failed.Catalog.ResourceGroups.Count -eq 0 -and $failed.Catalog.Vms.Count -eq 0 -and $failed.Catalog.Storage.Count -eq 0
    $script:FailAuth = $true
    $failed = Invoke-CpcOperation 'DetectSubscriptions' @{ TenantId = $tenant }
    $checks.FailedAuthenticationClearsScope = [bool]$failed.OperationError -and -not $failed.Connected -and -not $failed.SubscriptionId -and $failed.Catalog.Subscriptions.Count -eq 0
    $script:FailAuth = $false; $script:ScopeSubscriptions = @()
    $empty = Invoke-CpcOperation 'DetectSubscriptions' @{ TenantId = $tenant }
    $checks.EmptySubscriptionListHasActionableError = $empty.OperationError -match 'No enabled accessible subscriptions' -and -not $empty.Connected
    [pscustomobject]$checks
}
foreach ($p in $scopeResults.PSObject.Properties) { Assert-Test ([bool]$p.Value) "Subscription / resource-group selection: $($p.Name)" }
Remove-Module CpcMigration.Core
$module = Import-Module (Join-Path $root 'CpcMigration.Core.psm1') -Force -PassThru
$groupResults = & $module {
    Initialize-CpcState
    $script:S.SubscriptionId = '33333333-3333-3333-3333-333333333333'
    $script:S.StatePath = 'OFFLINE'; $script:S.Connected = $true
    $g1 = '66666666-6666-6666-6666-666666666666'; $g2 = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    $uid = '11111111-1111-1111-1111-111111111111'
    $script:S.Config = @{ PolicyId = '44444444-4444-4444-4444-444444444444'; SkuId = '55555555-5555-5555-5555-555555555555'; TargetDiskGiB = 128; StorageId = '/subscriptions/33333333-3333-3333-3333-333333333333/resourceGroups/rg/providers/Microsoft.Storage/storageAccounts/example'; Container = 'private'; SnapshotResourceGroup = 'snapshots'; ExistingGroupId = $g1 }
    $script:ChosenGroup = @{ id = $g1; displayName = 'Admin selected group'; securityEnabled = $true; groupTypes = @(); assignedLicenses = @(); onPremisesSyncEnabled = $false }
    $script:GroupMembers = @(@{ id = $uid; '@odata.type' = '#microsoft.graph.user' })
    $script:GroupParents = @()
    $script:GroupPolicy = @{ id = $script:S.Config.PolicyId; displayName = 'Enterprise policy'; provisioningType = 'dedicated'; assignments = @(
        @{ target = @{ '@odata.type' = '#microsoft.graph.cloudPcManagementGroupAssignmentTarget'; groupId = $g1 } },
        @{ target = @{ '@odata.type' = '#microsoft.graph.cloudPcManagementGroupAssignmentTarget'; groupId = $g2 } }
    ) }
    $script:UserGroups = @(@{ id = $g1 },@{ id = $g2 })
    $script:GroupWrites = [collections.generic.list[object]]::new()
    $script:SettingTargets = @()
    $script:ReusableSetting = $null
    $row = @{ VmId = 'vm'; VM = 'source'; UserId = $uid; UserPrincipalName = 'test@example.invalid'; Phase = 'Mapped'; Readiness = 'Ready'; Attested = $true; LicenseAssignedUtc = '' }
    $script:S.Rows.Add($row)
    function script:Assert-CpcContext { }
    function script:Save-CpcState { }
    function script:Write-CpcAudit { }
    function script:Assert-CpcPreflight { param($Rows,$Action) } # Stage receipts covered independently above.
    function script:Test-CpcRows { param($Rows,[switch]$Preparing) foreach ($r in $Rows) { $r.Readiness = 'Ready' } }
    function script:Get-CpcGraphCollection {
        param($Path)
        if ($Path -match '/users/.+/memberOf/|/users/.+/transitiveMemberOf/') { return $script:UserGroups }
        if ($Path -match '/groups/.+/transitiveMemberOf/') { return $script:GroupParents }
        if ($Path -match '/groups/.+/members\?') { return $script:GroupMembers }
        if ($Path -match 'provisioningPolicies') { return $script:GroupPolicy }
        if ($Path -match 'userSettings' -and $script:ReusableSetting) { return $script:ReusableSetting }
        if ($Path -match 'userSettings' -and $script:S.UserSettingId) { return @{ id = $script:S.UserSettingId; displayName = "Snapshot-$($script:S.PlanId)"; assignments = $script:SettingTargets } }
        if ($Path -match 'userSettings|cloudPCs|subscribedSkus') { return }
        throw "Unexpected group collection: $Path"
    }
    function script:Invoke-CpcGraph {
        param($Method = 'GET',$Path,$Body)
        if ($Method -ne 'GET') {
            $script:GroupWrites.Add(@{ Method = $Method; Path = $Path; Body = $Body })
            if ($Path -match '/userSettings$') { return @{ id = '99999999-9999-9999-9999-999999999999' } }
            if ($Path -match '/userSettings/.+/assign$') { $script:SettingTargets = $Body.assignments; return }
            if ($Path -match '/userSettings/' -and $Method -eq 'PATCH') { if ($script:ReusableSetting) { $script:ReusableSetting.provisioningSourceType = $Body.provisioningSourceType }; return }
            throw "Unexpected external group/policy mutation: $Path"
        }
        if ($Path -match '/groups/aaaaaaaa') { return @{ id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'; displayName = 'Second group'; securityEnabled = $true; groupTypes = @(); assignedLicenses = @() } }
        if ($Path -match '/groups/') { return $script:ChosenGroup }
        if ($Path -match '/users/') { return @{ id = $script:S.Rows[0].UserId; userPrincipalName = 'test@example.invalid'; accountEnabled = $true; assignedLicenses = @() } }
        if ($Path -match '/provisioningPolicies/') { return $script:GroupPolicy }
        if ($Path -match '/userSettings/' -and $script:ReusableSetting) { return $script:ReusableSetting }
        if ($Path -match '/userSettings/') { return @{ id = $script:S.UserSettingId; displayName = "Snapshot-$($script:S.PlanId)"; localAdminEnabled = $false; resetEnabled = $false; assignments = $script:SettingTargets; provisioningSourceType = 'snapshot' } }
        throw "Unexpected group Graph read: $Path"
    }
    $data = @{ PolicyId = $script:S.Config.PolicyId; Mappings = @(@{ UserPrincipalName = $row.UserPrincipalName }) }
    Get-CpcGroupChoices $data
    $checks = [ordered]@{
        MultipleGroupsPresented = $script:S.Catalog.Groups.Count -eq 2 -and $script:S.Catalog.Groups[0].DisplayName -match $g1
        DiscoveryDoesNotAssignGroup = -not $script:S.GroupId -and $script:GroupWrites.Count -eq 0
    }
    $script:UserGroups = @(@{ id = $g1 })
    Get-CpcGroupChoices $data
    $checks.OnlyCommonPolicyGroups = $script:S.Catalog.Groups.Count -eq 1 -and $script:S.Catalog.Groups[0].Id -eq $g1
    $script:GroupPolicy.provisioningType = 'shared'
    try { Get-CpcGroupChoices $data; $checks.NonEnterpriseDiscoveryBlocked = $false } catch { $checks.NonEnterpriseDiscoveryBlocked = $script:S.Catalog.Groups.Count -eq 0 }
    $script:GroupPolicy.provisioningType = 'dedicated'
    $null = Assert-CpcSelectedGroup $script:S.Config @($row)
    $checks.ExactExistingGroupAccepted = $true
    function Test-GroupBlocked {
        try { $null = Assert-CpcSelectedGroup $script:S.Config @($script:S.Rows); return $false } catch { return $true }
    }
    $script:GroupMembers += @{ id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'; '@odata.type' = '#microsoft.graph.user' }
    $checks.ExtraGroupUserBlocked = Test-GroupBlocked
    $before = $script:GroupWrites.Count
    try { Prepare-CpcIdentity @($row); $checks.UnsafePrepareNoWrites = $false } catch { $checks.UnsafePrepareNoWrites = $script:GroupWrites.Count -eq $before }
    $script:GroupMembers = @()
    $checks.MissingUserBlocked = Test-GroupBlocked
    $script:GroupMembers = @(@{ id = $uid; '@odata.type' = '#microsoft.graph.group' })
    $checks.NestedGroupBlocked = Test-GroupBlocked
    $script:GroupMembers[0]['@odata.type'] = '#microsoft.graph.user'
    $script:ChosenGroup.groupTypes = @('DynamicMembership')
    $checks.DynamicGroupBlocked = Test-GroupBlocked
    $script:ChosenGroup.groupTypes = @(); $script:ChosenGroup.onPremisesSyncEnabled = $true
    $checks.SyncedGroupBlocked = Test-GroupBlocked
    $script:ChosenGroup.onPremisesSyncEnabled = $false; $script:ChosenGroup.assignedLicenses = @(@{ skuId = 'any' })
    $checks.LicenseBearingGroupBlocked = Test-GroupBlocked
    $script:ChosenGroup.assignedLicenses = @(); $script:GroupParents = @(@{ assignedLicenses = @(@{ skuId = 'any' }) })
    $checks.LicenseBearingAncestorBlocked = Test-GroupBlocked
    $script:GroupParents = @(); $script:GroupPolicy.assignments[0].target.groupId = $g2
    $checks.UnassignedGroupBlocked = Test-GroupBlocked
    $script:GroupPolicy.assignments[0].target.groupId = $g1
    $script:GroupPolicy.assignments[0].target['@odata.type'] = '#microsoft.graph.exclusionGroupAssignmentTarget'
    $checks.ExclusionTargetBlocked = Test-GroupBlocked
    $script:GroupPolicy.assignments[0].target['@odata.type'] = '#microsoft.graph.cloudPcManagementGroupAssignmentTarget'
    $script:GroupPolicy.assignments[0].target.deviceAndAppManagementAssignmentFilterId = 'filter'
    $checks.FilteredAssignmentBlocked = Test-GroupBlocked
    $script:GroupPolicy.assignments[0].target.Remove('deviceAndAppManagementAssignmentFilterId')
    $script:GroupPolicy.provisioningType = 'shared'
    $checks.NonEnterpriseValidationBlocked = Test-GroupBlocked
    $script:GroupPolicy.provisioningType = 'dedicated'
    $script:S.Rows.Add(@{ UserPrincipalName = 'other@example.invalid' })
    try { Prepare-CpcIdentity @($row); $checks.PartialPrepareBlocked = $false } catch { $checks.PartialPrepareBlocked = $_.Exception.Message -match 'every row' }
    $script:S.Rows.RemoveAt(1)
    Prepare-CpcIdentity @($row)
    $assign = @($script:GroupWrites | Where-Object { $_.Path -match '/userSettings/.+/assign$' })
    $checks.PrepareUsesSelectedExistingGroup = $script:S.GroupId -eq $g1 -and $row.Phase -eq 'IdentityPrepared' -and $assign.Count -eq 1 -and $assign[0].Body.assignments[0].target.groupId -eq $g1
    $checks.PrepareCreatesSnapshotSetting = @($script:GroupWrites | Where-Object { $_.Path -match '/userSettings$' -and $_.Body.provisioningSourceType -eq 'snapshot' }).Count -eq 1
    $script:GroupWrites.Clear()
    $attestedBefore = $row.Attested; $readinessBefore = $row.Readiness
    Repair-CpcSnapshotAssignments
    $checks.RepairHealthyStateHasNoWrites = $script:GroupWrites.Count -eq 0
    $checks.RepairHealthyStateReported = @($script:S.Checks | Where-Object { $_.Check -eq 'Snapshot setting repair' -and $_.Status -eq 'Pass' -and $_.Detail -match 'No repair required.*No Graph write' }).Count -eq 1
    $checks.RepairHealthyStatePreservesEvidence = $row.Attested -eq $attestedBefore -and $row.Readiness -eq $readinessBefore
    $script:GroupMembers += @{ id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'; '@odata.type' = '#microsoft.graph.user' }
    $before = $script:GroupWrites.Count
    try { Repair-CpcSnapshotAssignments; $checks.RepairRejectsExpandedGroup = $false } catch { $checks.RepairRejectsExpandedGroup = $before -eq $script:GroupWrites.Count }
    $row.Phase = 'Validated'
    $out = Invoke-CpcOperation 'UseImage'
    $checks.FutureImageRejectsExpandedGroup = [bool]$out.OperationError -and $before -eq $script:GroupWrites.Count
    $script:GroupMembers = @(@{ id = $uid; '@odata.type' = '#microsoft.graph.user' })
    $row.Phase = 'Mapped'; $row.Readiness = 'Ready'; $row.Attested = $true
    $script:S.GroupId = ''; $script:S.UserSettingId = ''; $script:S.Config.Remove('UserSettingName')
    $script:ReusableSetting = @{ id = '77777777-7777-7777-7777-777777777777'; displayName = 'Snapshot-88888888-8888-8888-8888-888888888888'; provisioningSourceType = 'image'; localAdminEnabled = $false; resetEnabled = $false; assignments = @(@{ target = @{ '@odata.type' = '#microsoft.graph.cloudPcManagementGroupAssignmentTarget'; groupId = $g1 } }) }
    $script:S.Config.ReusableUserSettingId = $script:ReusableSetting.id
    $script:S.Config.ReusableUserSettingName = $script:ReusableSetting.displayName
    $script:S.Config.ReusableUserSettingSource = 'image'
    $script:GroupWrites.Clear()
    Prepare-CpcIdentity @($row)
    $checks.PrepareReusesImageSetting = $script:S.UserSettingId -eq $script:ReusableSetting.id -and $script:S.Config.UserSettingName -eq $script:ReusableSetting.displayName -and $script:ReusableSetting.provisioningSourceType -eq 'snapshot' -and @($script:GroupWrites | Where-Object Method -EQ 'PATCH').Count -eq 1 -and @($script:GroupWrites | Where-Object { $_.Path -match '/userSettings$|/assign$' }).Count -eq 0
    $row.Phase = 'Mapped'; $row.Readiness = 'Ready'; $row.Attested = $true
    $script:S.GroupId = ''; $script:S.UserSettingId = ''; $script:S.Config.Remove('UserSettingName')
    $script:S.Config.ReusableUserSettingSource = 'snapshot'
    $script:GroupWrites.Clear()
    Prepare-CpcIdentity @($row)
    $checks.PrepareReusesSnapshotSettingWithoutWrite = $script:S.UserSettingId -eq $script:ReusableSetting.id -and $row.Phase -eq 'IdentityPrepared' -and $script:GroupWrites.Count -eq 0
    [pscustomobject]$checks
}
foreach ($p in $groupResults.PSObject.Properties) { Assert-Test ([bool]$p.Value) "Existing user group: $($p.Name)" }
Remove-Module CpcMigration.Core
$predecessorTemp = Join-Path ([IO.Path]::GetTempPath()) ('cpcm-predecessor-' + [guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($predecessorTemp)
try {
    $predecessorPath = Join-Path $predecessorTemp 'completed.json'
    $predecessorPlanId = [guid]::NewGuid().ToString()
    $vmId = '/subscriptions/33333333-3333-3333-3333-333333333333/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/source'
    $prior = @{ SchemaVersion = 1; PlanId = $predecessorPlanId; TenantId = '22222222-2222-2222-2222-222222222222'; SubscriptionId = '33333333-3333-3333-3333-333333333333'; Rows = @(@{ VM = 'source'; VmId = $vmId; Phase = 'Cleaned' }) }
    [IO.File]::WriteAllText($predecessorPath, ($prior | ConvertTo-Json -Depth 8))
    $fingerprint = (Get-FileHash $predecessorPath -Algorithm SHA256).Hash
    $module = Import-Module (Join-Path $root 'CpcMigration.Core.psm1') -Force -PassThru
    $predecessorResults = & $module {
        param($Path,$PlanId,$VmId,$Fingerprint)
        Initialize-CpcState
        $script:S.Connected = $true; $script:S.TenantId = '22222222-2222-2222-2222-222222222222'; $script:S.SubscriptionId = '33333333-3333-3333-3333-333333333333'
        $script:S.Catalog.Vms = @(@{ Id = $VmId; Name = 'source'; ResourceGroup = 'rg'; Location = 'region' })
        $script:Saved = $null; $script:SaveCount = 0
        function script:Assert-CpcContext { }
        function script:Update-CpcLicenseCatalog { }
        function script:Assert-CpcSelectedGroup { return @{ displayName = 'Migration group' } }
        function script:Assert-CpcLicenseTarget { return @{ DisplayName = 'W365'; Available = 1; StorageGB = 128 } }
        function script:Assert-CpcConfig { }
        function script:Save-CpcState($State) { $script:Saved = $State; $script:SaveCount++ }
        function New-Data($Hash) {
            @{ Mappings = @(@{ VmId = $VmId; UserPrincipalName = 'user@example.invalid' }); Config = @{ ExistingGroupId = '66666666-6666-6666-6666-666666666666'; PolicyId = '44444444-4444-4444-4444-444444444444'; SkuId = '55555555-5555-5555-5555-555555555555'; StorageId = 'storage'; Container = 'private'; SnapshotResourceGroup = 'snapshots' }; Predecessors = @(@{ PlanId = $PlanId; JournalPath = $Path; JournalFingerprint = $Hash; LastSavedUtc = [datetime]::UtcNow.ToString('o') }) }
        }
        $before = (Get-FileHash $Path).Hash
        Set-CpcMappings (New-Data $Fingerprint)
        $checks = [ordered]@{
            TerminalPredecessorRecorded = $script:Saved.Predecessors.Count -eq 1 -and $script:Saved.Predecessors[0].PlanId -eq $PlanId -and $script:Saved.Predecessors[0].Summary -match 'Cleaned'
            PriorJournalUnchanged = (Get-FileHash $Path).Hash -eq $before
        }
        [IO.File]::AppendAllText($Path, ' ')
        $count = $script:SaveCount
        try { Set-CpcMappings (New-Data $Fingerprint); $checks.ChangedPredecessorRejected = $false } catch { $checks.ChangedPredecessorRejected = $script:SaveCount -eq $count }
        $prior = [IO.File]::ReadAllText($Path).Trim() | ConvertFrom-Json -AsHashtable
        $prior.Rows[0].Phase = 'Provisioning'; [IO.File]::WriteAllText($Path, ($prior | ConvertTo-Json -Depth 8))
        $current = (Get-FileHash $Path -Algorithm SHA256).Hash
        try { Set-CpcMappings (New-Data $current); $checks.NonterminalPredecessorRejected = $false } catch { $checks.NonterminalPredecessorRejected = $script:SaveCount -eq $count }
        $prior.Rows[0].Phase = 'Cleaned'; $prior.TenantId = '99999999-9999-9999-9999-999999999999'; [IO.File]::WriteAllText($Path, ($prior | ConvertTo-Json -Depth 8))
        $current = (Get-FileHash $Path -Algorithm SHA256).Hash
        try { Set-CpcMappings (New-Data $current); $checks.WrongScopePredecessorRejected = $false } catch { $checks.WrongScopePredecessorRejected = $script:SaveCount -eq $count }
        $prior.TenantId = '22222222-2222-2222-2222-222222222222'; $prior.Rows[0].VmId = '/subscriptions/33333333-3333-3333-3333-333333333333/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/other'; [IO.File]::WriteAllText($Path, ($prior | ConvertTo-Json -Depth 8))
        $current = (Get-FileHash $Path -Algorithm SHA256).Hash
        try { Set-CpcMappings (New-Data $current); $checks.MissingSourceOverlapRejected = $false } catch { $checks.MissingSourceOverlapRejected = $script:SaveCount -eq $count }
        [pscustomobject]$checks
    } $predecessorPath $predecessorPlanId $vmId $fingerprint
    foreach ($p in $predecessorResults.PSObject.Properties) { Assert-Test ([bool]$p.Value) "New migration cycle: $($p.Name)" }
    Remove-Module CpcMigration.Core
} finally { [IO.Directory]::Delete($predecessorTemp,$true) }
Write-Host "`n$script:Passed offline checks passed. No live migration was attempted."