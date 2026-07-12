[CmdletBinding()]
param(
  [Parameter(Mandatory)] [ValidateSet('Validate', 'Request', 'Destroy', 'Extend', 'SyncExpiry', 'Reconcile')] [string] $Operation
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$controller = Join-Path $root 'controller/src/cli.ts'
. (Join-Path $PSScriptRoot 'GitHubAppAuthentication.ps1')
Initialize-GitHubAppAuthentication

function Invoke-Controller {
  param([Parameter(Mandatory)] [string[]] $Arguments)
  $result = & node --experimental-strip-types $controller @Arguments
  if ($LASTEXITCODE -ne 0) { throw "Lifecycle controller command failed: $($Arguments[0])" }
  return ($result | Out-String).Trim()
}

function Write-LabSummary {
  param([string[]] $Lines)
  if (-not $env:GITHUB_STEP_SUMMARY) { return }
  $Lines -join "`n" | Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Encoding utf8
}

function Enter-EnvironmentLease {
  param([Parameter(Mandatory)] [string] $EnvironmentId)
  if (-not $env:TF_STATE_STORAGE_ACCOUNT) { throw 'TF_STATE_STORAGE_ACCOUNT is required for the environment lease.' }
  $container = if ($env:TF_LOCK_CONTAINER) { $env:TF_LOCK_CONTAINER } else { 'locks' }
  $blob = "$EnvironmentId.lease"
  $emptyFile = Join-Path ([System.IO.Path]::GetTempPath()) "lease-$([guid]::NewGuid().ToString('N'))"
  try {
    New-Item -ItemType File -Path $emptyFile | Out-Null
    & az storage blob upload --auth-mode login --account-name $env:TF_STATE_STORAGE_ACCOUNT --container-name $container --name $blob --file $emptyFile --overwrite false --output none 2>$null
    if ($LASTEXITCODE -ne 0) {
      & az storage blob show --auth-mode login --account-name $env:TF_STATE_STORAGE_ACCOUNT --container-name $container --name $blob --output none
      if ($LASTEXITCODE -ne 0) { throw "Could not create or verify environment lock blob $container/$blob." }
    }
  }
  finally { Remove-Item -LiteralPath $emptyFile -Force -ErrorAction SilentlyContinue }
  $leaseId = & az storage blob lease acquire --auth-mode login --account-name $env:TF_STATE_STORAGE_ACCOUNT --container-name $container --blob-name $blob --lease-duration 60 --query leaseId --output tsv
  if ($LASTEXITCODE -ne 0 -or -not $leaseId) { throw "Environment $EnvironmentId is already locked by another controller generation." }
  $env:PLATFORM_LEASE_ID = [string]$leaseId
  $env:PLATFORM_LEASE_BLOB = $blob
  $env:PLATFORM_LEASE_CONTAINER = $container
  $env:PLATFORM_LEASE_ENVIRONMENT_ID = $EnvironmentId
  $renewalJob = Start-ThreadJob -ArgumentList @($env:TF_STATE_STORAGE_ACCOUNT, $container, $blob, [string]$leaseId) -ScriptBlock {
    param($AccountName, $ContainerName, $BlobName, $LeaseId)
    $ErrorActionPreference = 'Continue'
    while ($true) {
      Start-Sleep -Seconds 25
      $renewed = $false
      for ($attempt = 1; $attempt -le 3; $attempt++) {
        & az storage blob lease renew --auth-mode login --account-name $AccountName --container-name $ContainerName --blob-name $BlobName --lease-id $LeaseId --output none 2>$null
        if ($LASTEXITCODE -eq 0) { $renewed = $true; break }
        Start-Sleep -Seconds 5
      }
      if (-not $renewed) { throw "Blob lease renewal failed for $ContainerName/$BlobName." }
    }
  }
  return [pscustomobject]@{ LeaseId = [string]$leaseId; RenewalJob = $renewalJob; FencingGeneration = $null }
}

function Set-EnvironmentLeaseFence {
  param(
    [Parameter(Mandatory)] $LeaseHandle,
    [Parameter(Mandatory)] $Record
  )
  $LeaseHandle.FencingGeneration = [int64]$Record.fencingGeneration
  $env:PLATFORM_FENCING_GENERATION = [string]$Record.fencingGeneration
}

function Assert-EnvironmentLease {
  param(
    [Parameter(Mandatory)] [string] $EnvironmentId,
    [Parameter(Mandatory)] $LeaseHandle,
    [Parameter(Mandatory)] [string] $Before
  )
  if (-not $LeaseHandle.RenewalJob -or $LeaseHandle.RenewalJob.State -ne 'Running') {
    $detail = if ($LeaseHandle.RenewalJob) { (Receive-Job -Job $LeaseHandle.RenewalJob -ErrorAction SilentlyContinue | Out-String).Trim() } else { 'renewal job is missing' }
    throw "Environment lease is no longer renewable before ${Before}; refusing side effects. $detail"
  }
  $renew = & az storage blob lease renew --auth-mode login --account-name $env:TF_STATE_STORAGE_ACCOUNT --container-name $env:PLATFORM_LEASE_CONTAINER --blob-name $env:PLATFORM_LEASE_BLOB --lease-id $LeaseHandle.LeaseId --output none 2>&1
  if ($LASTEXITCODE -ne 0) { throw "Could not synchronously prove the Azure Blob lease before ${Before}; refusing side effects. $($renew | Out-String)" }
  if ($null -eq $LeaseHandle.FencingGeneration) { throw "No inventory fencing generation is bound before ${Before}." }
  $current = Invoke-Controller @('get', '--environment-id', $EnvironmentId) | ConvertFrom-Json
  if ([int64]$current.fencingGeneration -ne [int64]$LeaseHandle.FencingGeneration) {
    throw "Inventory fencing generation changed before ${Before}; refusing stale side effects."
  }
}

function Exit-EnvironmentLease {
  param([Parameter(Mandatory)] [string] $EnvironmentId, [Parameter(Mandatory)] $LeaseHandle)
  $container = if ($env:TF_LOCK_CONTAINER) { $env:TF_LOCK_CONTAINER } else { 'locks' }
  if ($LeaseHandle.RenewalJob) {
    Stop-Job -Job $LeaseHandle.RenewalJob -ErrorAction SilentlyContinue
    Receive-Job -Job $LeaseHandle.RenewalJob -ErrorAction SilentlyContinue | Out-Null
    Remove-Job -Job $LeaseHandle.RenewalJob -Force -ErrorAction SilentlyContinue
  }
  & az storage blob lease release --auth-mode login --account-name $env:TF_STATE_STORAGE_ACCOUNT --container-name $container --blob-name "$EnvironmentId.lease" --lease-id $LeaseHandle.LeaseId --output none
  if ($LASTEXITCODE -ne 0) { Write-Warning "Could not release lease for $EnvironmentId; its 60-second duration will expire automatically." }
  Remove-Item Env:PLATFORM_LEASE_ID, Env:PLATFORM_LEASE_BLOB, Env:PLATFORM_LEASE_CONTAINER, Env:PLATFORM_LEASE_ENVIRONMENT_ID, Env:PLATFORM_FENCING_GENERATION -ErrorAction SilentlyContinue
}

function Publish-LifecycleEvidence {
  param(
    [Parameter(Mandatory)] [string] $EnvironmentId,
    [Parameter(Mandatory)] [ValidatePattern('^[a-z0-9-]+$')] [string] $Category,
    [Parameter(Mandatory)] [string] $File,
    [string] $BlobName,
    [ValidatePattern('^[0-9a-f]{64}$')] [string] $EvidenceSha256,
    [switch] $PassThru
  )
  if (-not $env:TF_STATE_STORAGE_ACCOUNT) { throw 'TF_STATE_STORAGE_ACCOUNT is required to retain lifecycle evidence.' }
  $container = if ($env:EVIDENCE_CONTAINER) { $env:EVIDENCE_CONTAINER } else { 'evidence' }
  if (-not $BlobName) {
    $stamp = [DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
    $BlobName = "$EnvironmentId/$Category/$stamp-$([guid]::NewGuid().ToString('N')).json"
  }
  $requiredPrefix = "$EnvironmentId/$Category/"
  if (-not $BlobName.StartsWith($requiredPrefix, [StringComparison]::Ordinal)) {
    throw "Evidence blob path must remain under $requiredPrefix."
  }
  $uploadArguments = @(
    'storage', 'blob', 'upload', '--auth-mode', 'login',
    '--account-name', $env:TF_STATE_STORAGE_ACCOUNT,
    '--container-name', $container,
    '--name', $BlobName,
    '--file', $File,
    '--overwrite', 'false',
    '--output', 'none'
  )
  if ($EvidenceSha256) { $uploadArguments += @('--metadata', "evidenceSha256=$EvidenceSha256") }
  $upload = & az @uploadArguments 2>&1
  if ($LASTEXITCODE -ne 0) {
    $alreadyRetained = $false
    if ($EvidenceSha256) {
      $existingHash = & az storage blob show --auth-mode login --account-name $env:TF_STATE_STORAGE_ACCOUNT --container-name $container --name $BlobName --query 'metadata.evidenceSha256' --output tsv 2>$null
      $alreadyRetained = $LASTEXITCODE -eq 0 -and [string]$existingHash -ceq $EvidenceSha256
    }
    if (-not $alreadyRetained) { throw "Could not retain sanitized lifecycle evidence $BlobName`: $($upload | Out-String)" }
  }
  Write-Host "Retained sanitized lifecycle evidence: $container/$BlobName"
  if ($PassThru) { Write-Output $BlobName }
}

function Save-DeletedTombstone {
  param(
    [Parameter(Mandatory)] $Record,
    [Parameter(Mandatory)] $LeaseHandle
  )
  if ($Record.phase -ne 'DELETED') { throw 'Final tombstone retention requires the DELETED checkpoint.' }
  if ($Record.tombstoneRetainedAt -and $Record.tombstoneBlobName -and $Record.tombstoneEvidenceHash) { return $Record }

  $tombstoneFile = Join-Path ([System.IO.Path]::GetTempPath()) "tombstone-$($Record.environmentId)-$([guid]::NewGuid().ToString('N')).json"
  $blobName = "$($Record.environmentId)/tombstone/final.json"
  try {
    # Keep the payload stable across a failed post-upload inventory checkpoint,
    # so the deterministic blob can be verified and adopted on retry.
    $payload = [ordered]@{
      schemaVersion = 1
      environmentId = $Record.environmentId
      phase = $Record.phase
      desiredState = $Record.desiredState
      owner = $Record.owner
      goldenPath = $Record.goldenPath
      pathVersion = $Record.pathVersion
      createdAt = $Record.createdAt
      expiresAt = $Record.expiresAt
      stateKey = $Record.stateKey
      repository = $Record.repository
      resourceGroupNames = @($Record.resourceGroupNames)
      resourceIds = @($Record.resourceIds)
      imageRepository = $Record.imageRepository
      sharedAcrId = $Record.sharedAcrId
      azureAbsence = $Record.azureAbsence
      evidenceHash = $Record.evidenceHash
      repositoryObservedAbsentAt = $Record.repositoryObservedAbsentAt
      repositoryDeleteIssuedAt = $Record.repositoryDeleteIssuedAt
    }
    $payload | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $tombstoneFile -Encoding utf8NoBOM
    $hash = (Get-FileHash -LiteralPath $tombstoneFile -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-EnvironmentLease -EnvironmentId $Record.environmentId -LeaseHandle $LeaseHandle -Before 'retaining final tombstone evidence'
    $retainedBlob = Publish-LifecycleEvidence -EnvironmentId $Record.environmentId -Category 'tombstone' -File $tombstoneFile -BlobName $blobName -EvidenceSha256 $hash -PassThru
    if ([string]$retainedBlob -cne $blobName) { throw 'Final tombstone evidence upload returned an unexpected blob identity.' }
    Assert-EnvironmentLease -EnvironmentId $Record.environmentId -LeaseHandle $LeaseHandle -Before 'checkpointing final tombstone retention'
    $env:TOMBSTONE_BLOB_NAME = $blobName
    $env:TOMBSTONE_EVIDENCE_HASH = $hash
    $updated = Invoke-Controller @('complete-tombstone-retention', '--environment-id', $Record.environmentId) | ConvertFrom-Json
    Set-EnvironmentLeaseFence -LeaseHandle $LeaseHandle -Record $updated
    return $updated
  }
  finally {
    Remove-Item Env:TOMBSTONE_BLOB_NAME, Env:TOMBSTONE_EVIDENCE_HASH -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tombstoneFile -Force -ErrorAction SilentlyContinue
  }
}

function Assert-TrackedRegistryIdentity {
  param([Parameter(Mandatory)] $Record)
  if (-not $Record.sharedAcrId -or -not $env:SHARED_ACR_ID) { throw 'Both inventoried sharedAcrId and configured SHARED_ACR_ID are required for image cleanup.' }
  if ($Record.sharedAcrId.TrimEnd('/').ToLowerInvariant() -ne $env:SHARED_ACR_ID.TrimEnd('/').ToLowerInvariant()) {
    throw 'Configured shared ACR ID differs from authoritative environment inventory; image cleanup fails closed.'
  }
  $acrName = ($Record.sharedAcrId -split '/')[-1]
  $acrGroup = ($Record.sharedAcrId -split '/resourceGroups/')[1].Split('/')[0]
  $actualId = & az acr show --name $acrName --resource-group $acrGroup --query id --output tsv 2>&1
  if ($LASTEXITCODE -ne 0 -or -not $actualId -or $actualId.TrimEnd('/').ToLowerInvariant() -ne $Record.sharedAcrId.TrimEnd('/').ToLowerInvariant()) {
    throw "The exact inventoried shared registry could not be proven before image cleanup: $($actualId | Out-String)"
  }
  return $acrName
}

function Save-LifecycleFailure {
  param(
    [Parameter(Mandatory)] [string] $EnvironmentId,
    [Parameter(Mandatory)] $ErrorRecord,
    [string] $CodeOverride
  )
  $summary = [string]$ErrorRecord.Exception.Message
  $code = if ($CodeOverride) { $CodeOverride }
    elseif ($summary -match 'AMBIGUOUS_REPOSITORY_CREATION') { 'AMBIGUOUS_REPOSITORY_CREATION' }
    elseif ($summary -match '(?i)\b429\b|rate.?limit') { 'GITHUB_OR_AZURE_429' }
    elseif ($summary -match '(?i)\b5\d\d\b|temporar|timeout') { 'TRANSIENT_REMOTE_FAILURE' }
    elseif ($summary -match '(?i)lease|fencing') { 'LEASE_OR_FENCE_LOST' }
    elseif ($summary -match '(?i)terraform') { 'TERRAFORM_FAILURE' }
    elseif ($summary -match '(?i)repository') { 'GITHUB_REPOSITORY_FAILURE' }
    else { 'LIFECYCLE_FAILURE' }
  try {
    $failed = Invoke-Controller @('record-failure', '--environment-id', $EnvironmentId, '--code', $code, '--summary', $summary.Substring(0, [Math]::Min(900, $summary.Length))) | ConvertFrom-Json
    & (Join-Path $PSScriptRoot 'Write-PlatformLifecycleLog.ps1') -Operation 'lifecycle-failure' -Outcome 'failure' -EnvironmentId $EnvironmentId -Phase $failed.phase -FencingGeneration $failed.fencingGeneration -Message $summary -BestEffort
    return $failed
  }
  catch {
    Write-Warning "Could not persist failure/backoff for ${EnvironmentId}: $($_.Exception.Message)"
    return $null
  }
}

if ($Operation -eq 'Validate') {
  Invoke-Controller @('validate') | Write-Output
  return
}

if ($Operation -eq 'Extend') {
  if ($env:ADDITIONAL_HOURS -notin @('4', '8', '24')) { throw 'ADDITIONAL_HOURS must be 4, 8, or 24.' }
  $record = Invoke-Controller @('get', '--environment-id', $env:ENVIRONMENT_ID) | ConvertFrom-Json
  $leaseId = Enter-EnvironmentLease -EnvironmentId $env:ENVIRONMENT_ID
  Set-EnvironmentLeaseFence -LeaseHandle $leaseId -Record $record
  try {
    Assert-EnvironmentLease -EnvironmentId $record.environmentId -LeaseHandle $leaseId -Before 'extending expiry'
    $record = Invoke-Controller @('extend', '--environment-id', $env:ENVIRONMENT_ID, '--hours', $env:ADDITIONAL_HOURS) | ConvertFrom-Json
    Set-EnvironmentLeaseFence -LeaseHandle $leaseId -Record $record
    Assert-EnvironmentLease -EnvironmentId $record.environmentId -LeaseHandle $leaseId -Before 'refreshing Azure expiry tags'
    $recordJson = $record | ConvertTo-Json -Depth 20 -Compress
    & (Join-Path $PSScriptRoot 'Update-AzureExpiryTags.ps1') -RecordJson $recordJson | Write-Host
    Assert-EnvironmentLease -EnvironmentId $record.environmentId -LeaseHandle $leaseId -Before 'updating generated-repository expiry metadata'
    Update-GitHubAppInstallationToken
    & (Join-Path $PSScriptRoot 'Update-GeneratedRepositoryExpiry.ps1') -RecordJson $recordJson
    Assert-EnvironmentLease -EnvironmentId $record.environmentId -LeaseHandle $leaseId -Before 'confirming expiry synchronization'
    $record = Invoke-Controller @('complete-expiry-sync', '--environment-id', $record.environmentId) | ConvertFrom-Json
    Set-EnvironmentLeaseFence -LeaseHandle $leaseId -Record $record
    Write-LabSummary @('# Environment extended', '', "- ID: ``$($record.environmentId)``", "- New expiry: ``$($record.expiresAt)``")
  }
  catch {
    $originalErrorRecord = $_
    $failed = Save-LifecycleFailure -EnvironmentId $record.environmentId -ErrorRecord $originalErrorRecord
    if ($failed) { Set-EnvironmentLeaseFence -LeaseHandle $leaseId -Record $failed }
    throw $originalErrorRecord
  }
  finally { Exit-EnvironmentLease -EnvironmentId $env:ENVIRONMENT_ID -LeaseHandle $leaseId }
  return
}

if ($Operation -eq 'SyncExpiry') {
  $record = Invoke-Controller @('get', '--environment-id', $env:ENVIRONMENT_ID) | ConvertFrom-Json
  if (-not $record.expirySyncPending) { Write-Host 'Expiry metadata is already synchronized.'; return }
  $leaseId = Enter-EnvironmentLease -EnvironmentId $record.environmentId
  Set-EnvironmentLeaseFence -LeaseHandle $leaseId -Record $record
  try {
    Assert-EnvironmentLease -EnvironmentId $record.environmentId -LeaseHandle $leaseId -Before 'retrying Azure expiry-tag synchronization'
    $recordJson = $record | ConvertTo-Json -Depth 20 -Compress
    & (Join-Path $PSScriptRoot 'Update-AzureExpiryTags.ps1') -RecordJson $recordJson | Write-Host
    Assert-EnvironmentLease -EnvironmentId $record.environmentId -LeaseHandle $leaseId -Before 'retrying generated-repository expiry metadata'
    Update-GitHubAppInstallationToken
    & (Join-Path $PSScriptRoot 'Update-GeneratedRepositoryExpiry.ps1') -RecordJson $recordJson
    Assert-EnvironmentLease -EnvironmentId $record.environmentId -LeaseHandle $leaseId -Before 'confirming retried expiry synchronization'
    $record = Invoke-Controller @('complete-expiry-sync', '--environment-id', $record.environmentId) | ConvertFrom-Json
    Set-EnvironmentLeaseFence -LeaseHandle $leaseId -Record $record
  }
  catch {
    $originalErrorRecord = $_
    $failed = Save-LifecycleFailure -EnvironmentId $record.environmentId -ErrorRecord $originalErrorRecord
    if ($failed) { Set-EnvironmentLeaseFence -LeaseHandle $leaseId -Record $failed }
    throw $originalErrorRecord
  }
  finally { Exit-EnvironmentLease -EnvironmentId $record.environmentId -LeaseHandle $leaseId }
  return
}

if ($Operation -eq 'Request') {
  $record = $null
  $repositoryIdentity = $null
  $leaseId = $null
  try {
    # Serialize the inventory-first admission checkpoint with destructive
    # shared-platform applies. Once REQUESTED is durable, the platform guard
    # will see it and refuse to remove shared dependencies.
    $admissionLease = Enter-EnvironmentLease -EnvironmentId 'platform-admission'
    try { $record = Invoke-Controller @('initialize') | ConvertFrom-Json }
    finally { Exit-EnvironmentLease -EnvironmentId 'platform-admission' -LeaseHandle $admissionLease }
    $leaseId = Enter-EnvironmentLease -EnvironmentId $record.environmentId
    Set-EnvironmentLeaseFence -LeaseHandle $leaseId -Record $record
    $recordJson = $record | ConvertTo-Json -Depth 20 -Compress

    if ($record.goldenPath -eq 'aks') {
      Assert-EnvironmentLease -EnvironmentId $record.environmentId -LeaseHandle $leaseId -Before 'verifying AKS approval protection'
      Update-GitHubAppInstallationToken
      & (Join-Path $PSScriptRoot 'Test-AksApprovalProtection.ps1')
    }
    Assert-EnvironmentLease -EnvironmentId $record.environmentId -LeaseHandle $leaseId -Before 'live regional and quota preflight'
    & (Join-Path $PSScriptRoot 'Test-GoldenPathPreflight.ps1') -RecordJson $recordJson | Write-Host
    Assert-EnvironmentLease -EnvironmentId $record.environmentId -LeaseHandle $leaseId -Before 'creating the generated repository'
    Update-GitHubAppInstallationToken
    $env:REPOSITORY_GENERATION_POST_ATTEMPTED = 'false'
    $repositoryJson = & (Join-Path $PSScriptRoot 'New-GeneratedRepository.ps1') -RepositoryName $record.requestedRepositoryName -Requester $record.owner -EnvironmentId $record.environmentId
    if ($LASTEXITCODE -ne 0) { throw 'Generated repository creation failed.' }
    $env:REPOSITORY_JSON = ($repositoryJson | Out-String).Trim()
    try {
      $repositoryIdentity = $env:REPOSITORY_JSON | ConvertFrom-Json
      if (-not $repositoryIdentity.nodeId -or -not $repositoryIdentity.numericId -or -not $repositoryIdentity.owner) {
        throw 'Generated repository output omitted immutable identity fields.'
      }
      if ($repositoryIdentity.provenanceVerified -ne $true) {
        throw 'Generated repository output omitted exact reviewed provenance proof; attachment and deletion are forbidden.'
      }
    }
    catch {
      throw "AMBIGUOUS_REPOSITORY_CREATION: a repository may exist but its immutable identity output could not be parsed; reconciliation must resolve the UUID claim. $($_.Exception.Message)"
    }
    try { Assert-EnvironmentLease -EnvironmentId $record.environmentId -LeaseHandle $leaseId -Before 'persisting generated-repository identity' }
    catch {
      throw "AMBIGUOUS_REPOSITORY_CREATION: the lease or fence was lost after repository creation and before identity persistence; reconciliation must resolve the UUID claim. $($_.Exception.Message)"
    }
    $attached = $false
    foreach ($delay in @(0, 2, 4, 8, 16, 30)) {
      if ($delay -gt 0) { Start-Sleep -Seconds $delay }
      try {
        $record = Invoke-Controller @('attach-repository', '--environment-id', $record.environmentId) | ConvertFrom-Json
        Set-EnvironmentLeaseFence -LeaseHandle $leaseId -Record $record
        $attached = $true
        break
      }
      catch {
        try {
          $current = Invoke-Controller @('get', '--environment-id', $record.environmentId) | ConvertFrom-Json
          if ($current.repository.nodeId -eq $repositoryIdentity.nodeId -and [int64]$current.repository.numericId -eq [int64]$repositoryIdentity.numericId -and $current.repository.owner -eq $repositoryIdentity.owner) {
            $record = $current
            Set-EnvironmentLeaseFence -LeaseHandle $leaseId -Record $record
            $attached = $true
            break
          }
        }
        catch { Write-Warning "Inventory readback failed during repository identity retry: $($_.Exception.Message)" }
      }
    }
    if (-not $attached) {
      throw 'AMBIGUOUS_REPOSITORY_CREATION: generated repository identity could not be persisted after bounded retries; reconciliation must attach the immutable identity before normal teardown.'
    }
    $repositoryIdentity = $null
    $recordJson = $record | ConvertTo-Json -Depth 20 -Compress
    Assert-EnvironmentLease -EnvironmentId $record.environmentId -LeaseHandle $leaseId -Before 'publishing the selected scaffold'
    Update-GitHubAppInstallationToken
    & (Join-Path $PSScriptRoot 'Publish-Scaffold.ps1') -RecordJson $recordJson

    $record = Invoke-Controller @('begin-provision', '--environment-id', $record.environmentId) | ConvertFrom-Json
    Set-EnvironmentLeaseFence -LeaseHandle $leaseId -Record $record
    $recordJson = $record | ConvertTo-Json -Depth 20 -Compress
    $terraformOutput = Join-Path ([System.IO.Path]::GetTempPath()) "outputs-$($record.environmentId)-$([guid]::NewGuid().ToString('N')).json"
    try {
      Assert-EnvironmentLease -EnvironmentId $record.environmentId -LeaseHandle $leaseId -Before 'applying the saved Terraform plan'
      & (Join-Path $PSScriptRoot 'Invoke-GoldenPathTerraform.ps1') -Operation Apply -RecordJson $recordJson -OutputFile $terraformOutput
      Assert-EnvironmentLease -EnvironmentId $record.environmentId -LeaseHandle $leaseId -Before 'recording Terraform outputs'
      $record = Invoke-Controller @('record-outputs', '--environment-id', $record.environmentId, '--terraform-output', $terraformOutput) | ConvertFrom-Json
      Set-EnvironmentLeaseFence -LeaseHandle $leaseId -Record $record
      $recordJson = $record | ConvertTo-Json -Depth 20 -Compress
      Assert-EnvironmentLease -EnvironmentId $record.environmentId -LeaseHandle $leaseId -Before 'dispatching generated-repository deployment'
      Update-GitHubAppInstallationToken -MinimumValidityMinutes 15
      & (Join-Path $PSScriptRoot 'Set-GeneratedRepository.ps1') -RecordJson $recordJson -TerraformOutputFile $terraformOutput -Dispatch
      Assert-EnvironmentLease -EnvironmentId $record.environmentId -LeaseHandle $leaseId -Before 'marking the environment active'
      $record = Invoke-Controller @('activate', '--environment-id', $record.environmentId, '--terraform-output', $terraformOutput) | ConvertFrom-Json
      Set-EnvironmentLeaseFence -LeaseHandle $leaseId -Record $record
    }
    finally { Remove-Item -LiteralPath $terraformOutput -Force -ErrorAction SilentlyContinue }

    $budget = switch ($record.goldenPath) { 'web-app' { 10 }; 'container-app' { 15 }; 'aks' { 75 } }
    $primaryResourceGroup = [uri]::EscapeDataString([string]$record.resourceGroupNames[0])
    $monitoringUrl = "https://portal.azure.com/#resource/subscriptions/$($env:AZURE_SUBSCRIPTION_ID)/resourceGroups/$primaryResourceGroup/overview"
    Write-LabSummary @(
      '# Environment ready', '',
      "- Environment ID: ``$($record.environmentId)``",
      "- Golden path: ``$($record.goldenPath)``",
      "- Repository: $($record.repository.htmlUrl)",
      "- Endpoint: $($record.endpoint)",
      "- Resource groups: ``$($record.resourceGroupNames -join ', ')``",
      "- Expires: ``$($record.expiresAt)``",
      "- Monthly alert budget: ``$budget`` (subscription currency; alert only)",
      "- Monitoring and resources: $monitoringUrl",
      "- State key: ``$($record.stateKey)``",
      "- Destroy: Actions → Destroy environment → ``$($record.environmentId)``",
      '- Extend: Actions → Extend environment (4, 8, or 24 hours)'
    )
    Exit-EnvironmentLease -EnvironmentId $record.environmentId -LeaseHandle $leaseId
    $leaseId = $null
    Remove-Item Env:REPOSITORY_GENERATION_POST_ATTEMPTED -ErrorAction SilentlyContinue
    return
  }
  catch {
    $originalErrorRecord = $_
    Write-Warning "Request transaction failed: $($originalErrorRecord.Exception.Message)"
    if ($record -and $record.environmentId) {
      try {
        $failureCodeOverride = if ($env:REPOSITORY_GENERATION_POST_ATTEMPTED -ne 'true') { 'PRE_REPOSITORY_FAILURE' } else { $null }
        $failed = Save-LifecycleFailure -EnvironmentId $record.environmentId -ErrorRecord $originalErrorRecord -CodeOverride $failureCodeOverride
        if ($failed -and $leaseId) { Set-EnvironmentLeaseFence -LeaseHandle $leaseId -Record $failed }
        if ($leaseId) {
          Exit-EnvironmentLease -EnvironmentId $record.environmentId -LeaseHandle $leaseId
          $leaseId = $null
        }
        if ($originalErrorRecord.Exception.Message -match 'AMBIGUOUS_REPOSITORY_CREATION') {
          Write-Warning 'Repository creation is ambiguous. Inventory remains non-terminal so reconciliation can recover immutable identity or prove absence.'
        }
        else {
          $env:ENVIRONMENT_ID = $record.environmentId
          $env:CONFIRMATION = $record.environmentId
          & $PSCommandPath -Operation Destroy
        }
      }
      catch { Write-Warning "Transactional cleanup also failed and will be retried by reconciliation: $($_.Exception.Message)" }
    }
    Remove-Item Env:REPOSITORY_GENERATION_POST_ATTEMPTED -ErrorAction SilentlyContinue
    throw $originalErrorRecord
  }
}

if ($Operation -eq 'Destroy') {
  if (-not $env:ENVIRONMENT_ID -or $env:CONFIRMATION -ne $env:ENVIRONMENT_ID) { throw 'Destroy confirmation must exactly equal ENVIRONMENT_ID.' }
  $record = Invoke-Controller @('get', '--environment-id', $env:ENVIRONMENT_ID) | ConvertFrom-Json
  $leaseId = Enter-EnvironmentLease -EnvironmentId $record.environmentId
  Set-EnvironmentLeaseFence -LeaseHandle $leaseId -Record $record
  try {

  if ($record.phase -eq 'REQUESTED' -and -not $record.repository -and $record.lastErrorCode -ne 'PRE_REPOSITORY_FAILURE') {
    Update-GitHubAppInstallationToken
    $resolution = & (Join-Path $PSScriptRoot 'Resolve-PendingRepository.ps1') -RecordJson ($record | ConvertTo-Json -Depth 20 -Compress) | ConvertFrom-Json
    if ($resolution.status -eq 'pending') {
      throw 'AMBIGUOUS_REPOSITORY_CREATION: readback is still within the 15-minute window; terminal cleanup is forbidden.'
    }
    if ($resolution.status -eq 'resolved') {
      if ($resolution.repository.provenanceVerified -ne $true) {
        throw 'AMBIGUOUS_REPOSITORY_CREATION: pending repository lacks exact reviewed provenance proof; attachment and deletion are forbidden.'
      }
      $env:REPOSITORY_JSON = $resolution.repository | ConvertTo-Json -Depth 8 -Compress
      $record = Invoke-Controller @('attach-repository', '--environment-id', $record.environmentId) | ConvertFrom-Json
      Set-EnvironmentLeaseFence -LeaseHandle $leaseId -Record $record
      Remove-Item Env:REPOSITORY_JSON -ErrorAction SilentlyContinue
    }
  }

  if ($record.phase -notin @('QUIESCING', 'AZURE_DELETING', 'AZURE_ABSENT', 'REPO_DELETING')) {
    $record = Invoke-Controller @('request-destroy', '--environment-id', $record.environmentId) | ConvertFrom-Json
    Set-EnvironmentLeaseFence -LeaseHandle $leaseId -Record $record
  }
  if ($record.phase -eq 'QUIESCING') {
    $recordJson = $record | ConvertTo-Json -Depth 20 -Compress
    Assert-EnvironmentLease -EnvironmentId $record.environmentId -LeaseHandle $leaseId -Before 'quiescing the generated repository'
    try {
      Update-GitHubAppInstallationToken
      $quiesceRaw = & (Join-Path $PSScriptRoot 'Set-RepositoryQuiesced.ps1') -RecordJson $recordJson
      if ($quiesceRaw) {
        $quiesceResult = ($quiesceRaw | Out-String) | ConvertFrom-Json
        if ($quiesceResult.status -eq 'repository-observed-absent') {
          if ($quiesceResult.nodeId -ne $record.repository.nodeId) { throw 'Repository absence result does not match the inventoried immutable node ID.' }
          Assert-EnvironmentLease -EnvironmentId $record.environmentId -LeaseHandle $leaseId -Before 'persisting immutable repository absence'
          $record = Invoke-Controller @('record-repository-absence', '--environment-id', $record.environmentId) | ConvertFrom-Json
          Set-EnvironmentLeaseFence -LeaseHandle $leaseId -Record $record
        }
      }
    }
    catch {
      if ($_.Exception.Message -match 'identity mismatch|transferred|outside the configured owner') {
        Write-Warning "Repository identity cannot be safely mutated: $($_.Exception.Message). Proven Azure resources will still be cleaned up."
      }
      else { throw }
    }
    $record = Invoke-Controller @('advance-deletion', '--environment-id', $record.environmentId, '--to', 'AZURE_DELETING') | ConvertFrom-Json
    Set-EnvironmentLeaseFence -LeaseHandle $leaseId -Record $record
  }

  if ($record.phase -eq 'AZURE_DELETING') {
    $recordJson = $record | ConvertTo-Json -Depth 20 -Compress
    Assert-EnvironmentLease -EnvironmentId $record.environmentId -LeaseHandle $leaseId -Before 'destroying Azure resources'
    & (Join-Path $PSScriptRoot 'Invoke-GoldenPathTerraform.ps1') -Operation Destroy -RecordJson $recordJson
    $trackedImageRepository = $record.imageRepository
    if ($trackedImageRepository) {
      $acrName = Assert-TrackedRegistryIdentity -Record $record
      $acrCheck = & az acr repository show --name $acrName --repository $trackedImageRepository --output none 2>&1
      $acrCheckExit = $LASTEXITCODE
      if ($acrCheckExit -eq 0) {
        Assert-EnvironmentLease -EnvironmentId $record.environmentId -LeaseHandle $leaseId -Before 'deleting the tracked ACR repository'
        & az acr repository delete --name $acrName --repository $trackedImageRepository --yes --output none
        if ($LASTEXITCODE -ne 0) { throw "Tracked ACR repository still exists: $trackedImageRepository" }
      }
      elseif (($acrCheck | Out-String) -notmatch '(?i)\bNAME_UNKNOWN\b') {
        throw "Could not prove ACR repository presence or absence: $($acrCheck | Out-String)"
      }
    }
    $evidenceFile = Join-Path ([System.IO.Path]::GetTempPath()) "absence-$($record.environmentId)-$([guid]::NewGuid().ToString('N')).json"
    try {
      Assert-EnvironmentLease -EnvironmentId $record.environmentId -LeaseHandle $leaseId -Before 'verifying Azure absence'
      & (Join-Path $PSScriptRoot 'Test-AzureAbsence.ps1') -RecordJson $recordJson -EvidenceFile $evidenceFile | Out-Host
      Publish-LifecycleEvidence -EnvironmentId $record.environmentId -Category 'azure-absence' -File $evidenceFile
      Assert-EnvironmentLease -EnvironmentId $record.environmentId -LeaseHandle $leaseId -Before 'recording Azure absence'
      $record = Invoke-Controller @('advance-deletion', '--environment-id', $record.environmentId, '--to', 'AZURE_ABSENT', '--evidence', $evidenceFile) | ConvertFrom-Json
      Set-EnvironmentLeaseFence -LeaseHandle $leaseId -Record $record
    }
    finally { Remove-Item -LiteralPath $evidenceFile -Force -ErrorAction SilentlyContinue }
  }

  if ($record.phase -in @('AZURE_ABSENT', 'REPO_DELETING')) {
    if (-not $record.repository -or $env:ENABLE_REPOSITORY_DELETE -eq 'true') {
      $trackedImageRepository = $record.imageRepository
      if ($trackedImageRepository) {
        $acrName = Assert-TrackedRegistryIdentity -Record $record
        $acrCheck = & az acr repository show --name $acrName --repository $trackedImageRepository --output none 2>&1
        $acrCheckExit = $LASTEXITCODE
        if ($acrCheckExit -eq 0) { throw "Repository DELETE blocked: ACR repository still exists: $trackedImageRepository" }
        if (($acrCheck | Out-String) -notmatch '(?i)\bNAME_UNKNOWN\b') {
          throw "Repository DELETE blocked: ACR absence could not be proven: $($acrCheck | Out-String)"
        }
      }
      Assert-EnvironmentLease -EnvironmentId $record.environmentId -LeaseHandle $leaseId -Before 'deleting the generated repository'
      Update-GitHubAppInstallationToken
      $record = Invoke-Controller @('delete-repository', '--environment-id', $record.environmentId) | ConvertFrom-Json
      if ($record.record) { $record = $record.record }
      Set-EnvironmentLeaseFence -LeaseHandle $leaseId -Record $record
    }
    else { Write-Warning 'Azure is absent, but repository deletion remains disabled by platform opt-in.' }
  }
  if ($record.phase -eq 'DELETED') {
    $record = Save-DeletedTombstone -Record $record -LeaseHandle $leaseId
  }
  Write-LabSummary @('# Environment cleanup', '', "- ID: ``$($record.environmentId)``", "- Phase: ``$($record.phase)``", '- Azure absence is verified before any repository DELETE.')
  }
  catch {
    $originalErrorRecord = $_
    $failed = Save-LifecycleFailure -EnvironmentId $record.environmentId -ErrorRecord $originalErrorRecord
    if ($failed) { Set-EnvironmentLeaseFence -LeaseHandle $leaseId -Record $failed }
    throw $originalErrorRecord
  }
  finally { Exit-EnvironmentLease -EnvironmentId $record.environmentId -LeaseHandle $leaseId }
  return
}

if ($Operation -eq 'Reconcile') {
  Update-GitHubAppInstallationToken
  $report = Invoke-Controller @('reconcile') | ConvertFrom-Json
  $dryRun = $report.dryRun -eq $true
  $reconcileErrors = @()
  if (-not $dryRun) {
    $inventory = @(Invoke-Controller @('list') | ConvertFrom-Json)
    $pendingClaimCutoff = [DateTimeOffset]::UtcNow.AddMinutes(-15)
    foreach ($pending in @($inventory | Where-Object {
      $_.phase -eq 'REQUESTED' -and -not $_.repository -and $_.lastErrorCode -ne 'PRE_REPOSITORY_FAILURE' -and
      [DateTimeOffset]::Parse($_.createdAt) -le $pendingClaimCutoff -and
      (-not $_.nextAttemptAt -or [DateTimeOffset]::Parse($_.nextAttemptAt) -le [DateTimeOffset]::UtcNow)
    })) {
      $pendingLease = $null
      try {
        $pendingLease = Enter-EnvironmentLease -EnvironmentId $pending.environmentId
        Set-EnvironmentLeaseFence -LeaseHandle $pendingLease -Record $pending
        Update-GitHubAppInstallationToken
        $resolution = & (Join-Path $PSScriptRoot 'Resolve-PendingRepository.ps1') -RecordJson ($pending | ConvertTo-Json -Depth 20 -Compress) | ConvertFrom-Json
        if ($resolution.status -eq 'resolved') {
          if ($resolution.repository.provenanceVerified -ne $true) {
            throw 'AMBIGUOUS_REPOSITORY_CREATION: pending repository lacks exact reviewed provenance proof; attachment and deletion are forbidden.'
          }
          $env:REPOSITORY_JSON = $resolution.repository | ConvertTo-Json -Depth 8 -Compress
          $pending = Invoke-Controller @('attach-repository', '--environment-id', $pending.environmentId) | ConvertFrom-Json
          Set-EnvironmentLeaseFence -LeaseHandle $pendingLease -Record $pending
        }
        if ($resolution.status -in @('resolved', 'absent-safe')) {
          Exit-EnvironmentLease -EnvironmentId $pending.environmentId -LeaseHandle $pendingLease
          $pendingLease = $null
          $env:ENVIRONMENT_ID = $pending.environmentId
          $env:CONFIRMATION = $pending.environmentId
          & $PSCommandPath -Operation Destroy
        }
      }
      catch {
        if ($pendingLease) {
          $failed = Save-LifecycleFailure -EnvironmentId $pending.environmentId -ErrorRecord $_
          if ($failed) { Set-EnvironmentLeaseFence -LeaseHandle $pendingLease -Record $failed }
        }
        $reconcileErrors += [pscustomobject]@{ environmentId = $pending.environmentId; kind = 'AMBIGUOUS_REPOSITORY_READBACK'; message = $_.Exception.Message }
        Write-Warning "Pending repository resolution failed for $($pending.environmentId); later environments will still be processed. $($_.Exception.Message)"
      }
      finally {
        Remove-Item Env:REPOSITORY_JSON -ErrorAction SilentlyContinue
        if ($pendingLease) { Exit-EnvironmentLease -EnvironmentId $pending.environmentId -LeaseHandle $pendingLease }
      }
    }
    $inventory = @(Invoke-Controller @('list') | ConvertFrom-Json)
    foreach ($candidate in @($inventory | Where-Object { $_.phase -eq 'ACTIVE' })) {
      $observationLease = $null
      try {
        $observationLease = Enter-EnvironmentLease -EnvironmentId $candidate.environmentId
        Set-EnvironmentLeaseFence -LeaseHandle $observationLease -Record $candidate
        $candidateJson = $candidate | ConvertTo-Json -Depth 20 -Compress
        $observation = & (Join-Path $PSScriptRoot 'Sync-AzureInventory.ps1') -RecordJson $candidateJson | ConvertFrom-Json
        if (@($observation.adoptedResourceIds).Count -gt 0) {
          $env:RESOURCE_IDS_JSON = @($observation.adoptedResourceIds) | ConvertTo-Json -Compress
          $candidate = Invoke-Controller @('adopt-resources', '--environment-id', $candidate.environmentId) | ConvertFrom-Json
          Set-EnvironmentLeaseFence -LeaseHandle $observationLease -Record $candidate
          Remove-Item Env:RESOURCE_IDS_JSON -ErrorAction SilentlyContinue
        }
        if ($observation.requiresDestroy -eq $true) {
          Exit-EnvironmentLease -EnvironmentId $candidate.environmentId -LeaseHandle $observationLease
          $observationLease = $null
          $env:ENVIRONMENT_ID = $candidate.environmentId
          $env:CONFIRMATION = $candidate.environmentId
          & $PSCommandPath -Operation Destroy
        }
      }
      catch {
        if ($observationLease) {
          $failed = Save-LifecycleFailure -EnvironmentId $candidate.environmentId -ErrorRecord $_
          if ($failed) { Set-EnvironmentLeaseFence -LeaseHandle $observationLease -Record $failed }
        }
        $reconcileErrors += [pscustomobject]@{ environmentId = $candidate.environmentId; kind = 'AZURE_OBSERVATION'; message = $_.Exception.Message }
        Write-Warning "Azure observation failed for $($candidate.environmentId); later environments will still be processed. $($_.Exception.Message)"
      }
      finally {
        Remove-Item Env:RESOURCE_IDS_JSON -ErrorAction SilentlyContinue
        if ($observationLease) { Exit-EnvironmentLease -EnvironmentId $candidate.environmentId -LeaseHandle $observationLease }
      }
    }
    Update-GitHubAppInstallationToken
    $report = Invoke-Controller @('reconcile') | ConvertFrom-Json
  }
  foreach ($action in @($report.actions)) {
    if ($action.kind -eq 'NONE' -or $dryRun) { continue }
    try {
      if ($action.kind -in @('DESTROY', 'RETRY_AZURE_DELETE')) {
        $env:ENVIRONMENT_ID = $action.environmentId
        $env:CONFIRMATION = $action.environmentId
        & $PSCommandPath -Operation Destroy
      }
      elseif ($action.kind -eq 'RETRY_REPOSITORY_DELETE' -and $env:ENABLE_REPOSITORY_DELETE -eq 'true') {
        $env:ENVIRONMENT_ID = $action.environmentId
        $env:CONFIRMATION = $action.environmentId
        & $PSCommandPath -Operation Destroy
      }
      elseif ($action.kind -eq 'SYNC_EXPIRY') {
        $env:ENVIRONMENT_ID = $action.environmentId
        & $PSCommandPath -Operation SyncExpiry
      }
      elseif ($action.kind -eq 'OBSERVATION_ERROR') {
        throw "Repository observation failed after bounded retries: $($action.reason)"
      }
    }
    catch {
      $reconcileErrors += [pscustomobject]@{ environmentId = $action.environmentId; kind = $action.kind; message = $_.Exception.Message }
      Write-Warning "Reconciliation action $($action.kind) failed for $($action.environmentId); later environments will still be processed. $($_.Exception.Message)"
    }
  }
  if (-not $dryRun) {
    $deletedInventory = @(Invoke-Controller @('list', '--include-deleted') | ConvertFrom-Json)
    foreach ($deleted in @($deletedInventory | Where-Object {
      $_.phase -eq 'DELETED' -and -not $_.tombstoneRetainedAt -and
      (-not $_.nextAttemptAt -or [DateTimeOffset]::Parse($_.nextAttemptAt) -le [DateTimeOffset]::UtcNow)
    })) {
      try {
        $env:ENVIRONMENT_ID = $deleted.environmentId
        $env:CONFIRMATION = $deleted.environmentId
        & $PSCommandPath -Operation Destroy
      }
      catch {
        $reconcileErrors += [pscustomobject]@{ environmentId = $deleted.environmentId; kind = 'TOMBSTONE_RETENTION'; message = $_.Exception.Message }
        Write-Warning "Final tombstone retention failed for $($deleted.environmentId); it remains in terminal inventory for retry. $($_.Exception.Message)"
      }
    }
    $retentionCutoff = [DateTimeOffset]::UtcNow.AddDays(-90)
    $retainedInventory = @(Invoke-Controller @('list', '--include-deleted') | ConvertFrom-Json)
    foreach ($retained in @($retainedInventory | Where-Object {
      $_.phase -eq 'DELETED' -and $_.tombstoneRetainedAt -and [DateTimeOffset]::Parse($_.updatedAt) -le $retentionCutoff
    })) {
      $retentionLease = $null
      try {
        $retentionLease = Enter-EnvironmentLease -EnvironmentId $retained.environmentId
        Set-EnvironmentLeaseFence -LeaseHandle $retentionLease -Record $retained
        Assert-EnvironmentLease -EnvironmentId $retained.environmentId -LeaseHandle $retentionLease -Before 'purging 90-day lifecycle history'
        Invoke-Controller @('purge-retained-environment', '--environment-id', $retained.environmentId) | Out-Null
      }
      catch {
        $reconcileErrors += [pscustomobject]@{ environmentId = $retained.environmentId; kind = 'RETENTION_PURGE'; message = $_.Exception.Message }
        Write-Warning "Retention purge failed for $($retained.environmentId); later environments will still be processed. $($_.Exception.Message)"
      }
      finally {
        if ($retentionLease) { Exit-EnvironmentLease -EnvironmentId $retained.environmentId -LeaseHandle $retentionLease }
      }
    }
  }
  Write-LabSummary @('# Reconciliation report', '', "- Dry run: ``$dryRun``", "- Records evaluated: ``$(@($report.actions).Count)``", '```json', ($report.actions | ConvertTo-Json -Depth 8), '```')
  if ($reconcileErrors.Count -gt 0) {
    throw "Reconciliation completed with $($reconcileErrors.Count) isolated environment failure(s): $($reconcileErrors | ConvertTo-Json -Compress)"
  }
  return
}
