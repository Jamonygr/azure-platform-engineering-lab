[CmdletBinding()]
param(
  [Parameter(Mandatory)] [ValidateSet('plan', 'apply', 'destroy')] [string] $Operation
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$platformDirectory = Join-Path $root 'platform'
if (-not (Test-Path (Join-Path $platformDirectory 'main.tf'))) { throw 'platform/main.tf was not found.' }

function Enter-PlatformAdmissionLease {
  if (-not $env:TF_STATE_STORAGE_ACCOUNT) { throw 'TF_STATE_STORAGE_ACCOUNT is required for the platform admission lease.' }
  $container = if ($env:TF_LOCK_CONTAINER) { $env:TF_LOCK_CONTAINER } else { 'locks' }
  $blob = 'platform-admission.lease'
  $emptyFile = Join-Path ([System.IO.Path]::GetTempPath()) "platform-admission-$([guid]::NewGuid().ToString('N'))"
  try {
    New-Item -ItemType File -Path $emptyFile | Out-Null
    & az storage blob upload --auth-mode login --account-name $env:TF_STATE_STORAGE_ACCOUNT --container-name $container --name $blob --file $emptyFile --overwrite false --output none 2>$null
    if ($LASTEXITCODE -ne 0) {
      & az storage blob show --auth-mode login --account-name $env:TF_STATE_STORAGE_ACCOUNT --container-name $container --name $blob --output none
      if ($LASTEXITCODE -ne 0) { throw "Could not create or verify the platform admission blob $container/$blob." }
    }
  }
  finally { Remove-Item -LiteralPath $emptyFile -Force -ErrorAction SilentlyContinue }

  $leaseId = & az storage blob lease acquire --auth-mode login --account-name $env:TF_STATE_STORAGE_ACCOUNT --container-name $container --blob-name $blob --lease-duration 60 --query leaseId --output tsv
  if ($LASTEXITCODE -ne 0 -or -not $leaseId) { throw 'A request admission or destructive platform operation already holds the global platform lease.' }
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
      if (-not $renewed) { throw "Platform admission lease renewal failed for $ContainerName/$BlobName." }
    }
  }
  return [pscustomobject]@{ LeaseId = [string]$leaseId; Container = $container; Blob = $blob; RenewalJob = $renewalJob }
}

function Assert-PlatformAdmissionLease {
  param([Parameter(Mandatory)] $LeaseHandle, [Parameter(Mandatory)] [string] $Before)
  if (-not $LeaseHandle.RenewalJob -or $LeaseHandle.RenewalJob.State -ne 'Running') {
    $detail = if ($LeaseHandle.RenewalJob) { (Receive-Job -Job $LeaseHandle.RenewalJob -ErrorAction SilentlyContinue | Out-String).Trim() } else { 'renewal job is missing' }
    throw "The platform admission lease is no longer renewable before ${Before}; refusing shared mutations. $detail"
  }
  $renew = & az storage blob lease renew --auth-mode login --account-name $env:TF_STATE_STORAGE_ACCOUNT --container-name $LeaseHandle.Container --blob-name $LeaseHandle.Blob --lease-id $LeaseHandle.LeaseId --output none 2>&1
  if ($LASTEXITCODE -ne 0) { throw "Could not synchronously prove the platform admission lease before ${Before}. $($renew | Out-String)" }
}

function Exit-PlatformAdmissionLease {
  param([Parameter(Mandatory)] $LeaseHandle)
  if ($LeaseHandle.RenewalJob) {
    Stop-Job -Job $LeaseHandle.RenewalJob -ErrorAction SilentlyContinue
    Receive-Job -Job $LeaseHandle.RenewalJob -ErrorAction SilentlyContinue | Out-Null
    Remove-Job -Job $LeaseHandle.RenewalJob -Force -ErrorAction SilentlyContinue
  }
  & az storage blob lease release --auth-mode login --account-name $env:TF_STATE_STORAGE_ACCOUNT --container-name $LeaseHandle.Container --blob-name $LeaseHandle.Blob --lease-id $LeaseHandle.LeaseId --output none
  if ($LASTEXITCODE -ne 0) { Write-Warning 'Could not release the platform admission lease; its 60-second duration will expire automatically.' }
}

function Get-CurrentAdeOutput {
  $raw = & terraform "-chdir=$platformDirectory" output -json ade 2>&1
  if ($LASTEXITCODE -ne 0) { throw "Could not inspect optional ADE platform state. $($raw | Out-String)" }
  try { return (($raw | Out-String) | ConvertFrom-Json) }
  catch { throw 'The optional ADE platform output is malformed.' }
}

function Get-AdeEnvironmentType {
  param([Parameter(Mandatory)] [string] $EnvironmentTypeId)
  if ($EnvironmentTypeId -notmatch '(?i)^/subscriptions/[0-9a-f-]{36}/resourceGroups/[^/]+/providers/Microsoft\.DevCenter/projects/[^/]+/environmentTypes/[^/]+$') {
    throw 'ADE project environment-type ID is missing or malformed.'
  }
  $raw = & az rest --method get --url "https://management.azure.com${EnvironmentTypeId}?api-version=2025-02-01" --output json 2>&1
  if ($LASTEXITCODE -ne 0) { throw "Could not query the ADE project environment type. $($raw | Out-String)" }
  try { return (($raw | Out-String) | ConvertFrom-Json) }
  catch { throw 'The ADE project environment-type response is malformed.' }
}

function Set-AdeEnvironmentTypeStatus {
  param(
    [Parameter(Mandatory)] [string] $EnvironmentTypeId,
    [Parameter(Mandatory)] [ValidateSet('Enabled', 'Disabled')] [string] $Status
  )
  $body = @{ properties = @{ status = $Status } } | ConvertTo-Json -Compress
  $raw = & az rest --method patch --url "https://management.azure.com${EnvironmentTypeId}?api-version=2025-02-01" --body $body --output none 2>&1
  if ($LASTEXITCODE -ne 0) { throw "Could not set the ADE project environment type to $Status. $($raw | Out-String)" }
  $deadline = [DateTimeOffset]::UtcNow.AddMinutes(5)
  do {
    $current = Get-AdeEnvironmentType -EnvironmentTypeId $EnvironmentTypeId
    if ([string]$current.properties.status -eq $Status) { return }
    Start-Sleep -Seconds 5
  } while ([DateTimeOffset]::UtcNow -lt $deadline)
  throw "ADE project environment type did not reach $Status within five minutes."
}

function Assert-NoLivePlatformEnvironments {
  param($AdeOutput)
  if (-not $env:INVENTORY_STORAGE_ACCOUNT) { throw 'Authoritative inventory access is required before destructive shared changes.' }
  $recordsJson = & node --experimental-strip-types (Join-Path $root 'controller/src/cli.ts') list
  if ($LASTEXITCODE -ne 0) { throw 'Could not read environment inventory; refusing destructive shared changes.' }
  $active = @($recordsJson | ConvertFrom-Json | Where-Object { $_.phase -ne 'DELETED' })
  if ($active.Count -gt 0) { throw "Destructive shared change refused: $($active.Count) GitHub-channel environment(s) are not DELETED." }

  if ($null -ne $AdeOutput) {
    $environmentType = Get-AdeEnvironmentType -EnvironmentTypeId ([string]$AdeOutput.environment_type_id)
    $environmentCount = $environmentType.properties.environmentCount
    if ($null -eq $environmentCount -or [string]$environmentCount -notmatch '^\d+$') {
      throw 'ADE environment count was absent or malformed; refusing destructive shared changes.'
    }
    if ([int64]$environmentCount -gt 0) {
      throw "Destructive shared change refused: $environmentCount ADE environment(s) still exist or are deleting."
    }
  }
}

$backend = @(
  "resource_group_name=$($env:TF_STATE_RESOURCE_GROUP)",
  "storage_account_name=$($env:TF_STATE_STORAGE_ACCOUNT)",
  "container_name=$($env:TF_STATE_CONTAINER)",
  'key=platform/platform.tfstate',
  'use_azuread_auth=true'
)
if ($backend.Where({ $_ -match '=$' }).Count -gt 0) { throw 'Terraform backend environment variables are incomplete.' }

$initArgs = @("-chdir=$platformDirectory", 'init', '-input=false', '-reconfigure')
foreach ($entry in $backend) { $initArgs += "-backend-config=$entry" }
& terraform @initArgs
if ($LASTEXITCODE -ne 0) { throw 'terraform init failed.' }

$planFile = Join-Path ([System.IO.Path]::GetTempPath()) "platform-$Operation-$([guid]::NewGuid().ToString('N')).tfplan"
$admissionLease = $null
$adeOutput = $null
$adeEnvironmentTypeId = $null
$adeWasEnabled = $false
$adeTypeWillDelete = $false
$adeTypeWillCreate = $false
$applyStarted = $false
try {
  if ($Operation -eq 'destroy' -and $env:DESTROY_CONFIRMATION -ne 'DESTROY PLATFORM') {
    throw 'Platform destroy requires the exact confirmation DESTROY PLATFORM.'
  }

  $planArguments = @("-chdir=$platformDirectory", 'plan', '-input=false', "-out=$planFile")
  if ($Operation -eq 'destroy') { $planArguments += '-destroy' }
  & terraform @planArguments
  if ($LASTEXITCODE -ne 0) { throw 'terraform plan failed.' }

  $planJsonRaw = & terraform "-chdir=$platformDirectory" show -json $planFile
  if ($LASTEXITCODE -ne 0) { throw 'Could not inspect the saved platform plan.' }
  try { $planJson = ($planJsonRaw | Out-String) | ConvertFrom-Json }
  catch { throw 'The saved platform plan JSON is malformed.' }
  $destructiveChanges = @($planJson.resource_changes | Where-Object { 'delete' -in @($_.change.actions) })
  $requiresDestructiveGuard = $Operation -eq 'destroy' -or ($Operation -eq 'apply' -and $destructiveChanges.Count -gt 0)
  $adeTypeWillDelete = @($destructiveChanges | Where-Object { $_.address -match '^azapi_resource\.ade_project_environment_type(?:\[0\])?$' }).Count -gt 0
  $adeTypeWillCreate = @($planJson.resource_changes | Where-Object {
    $_.address -match '^azapi_resource\.ade_project_environment_type(?:\[0\])?$' -and 'create' -in @($_.change.actions)
  }).Count -gt 0

  if ($requiresDestructiveGuard) {
    if ($adeTypeWillCreate) {
      throw 'A destructive shared plan may not create or replace an enabled ADE environment type in the same apply; split the reviewed changes so admissions remain closed.'
    }
    Write-Host "The saved plan contains $($destructiveChanges.Count) delete/replace action(s); closing admissions and proving zero live environments."
    $admissionLease = Enter-PlatformAdmissionLease
    Assert-PlatformAdmissionLease -LeaseHandle $admissionLease -Before 'closing ADE admissions'
    $adeOutput = Get-CurrentAdeOutput
    if ($null -ne $adeOutput) {
      $adeEnvironmentTypeId = [string]$adeOutput.environment_type_id
      $environmentType = Get-AdeEnvironmentType -EnvironmentTypeId $adeEnvironmentTypeId
      $status = [string]$environmentType.properties.status
      if ($status -eq 'Enabled') {
        Set-AdeEnvironmentTypeStatus -EnvironmentTypeId $adeEnvironmentTypeId -Status Disabled
        $adeWasEnabled = $true
      }
      elseif ($status -ne 'Disabled') {
        throw "ADE project environment type has unexpected admission status '$status'."
      }
    }
    Assert-NoLivePlatformEnvironments -AdeOutput $adeOutput
  }

  & terraform "-chdir=$platformDirectory" show -no-color $planFile
  if ($LASTEXITCODE -ne 0) { throw 'Could not render the saved platform plan.' }
  if ($Operation -eq 'plan') { return }

  if ($requiresDestructiveGuard) {
    Assert-PlatformAdmissionLease -LeaseHandle $admissionLease -Before 'the first final destructive-plan guard'
    Assert-NoLivePlatformEnvironments -AdeOutput $adeOutput
    Start-Sleep -Seconds 15
    Assert-PlatformAdmissionLease -LeaseHandle $admissionLease -Before 'the immediate pre-apply destructive-plan guard'
    Assert-NoLivePlatformEnvironments -AdeOutput $adeOutput
  }

  $applyStarted = $true
  & terraform "-chdir=$platformDirectory" apply -input=false -auto-approve $planFile
  if ($LASTEXITCODE -ne 0) { throw 'terraform apply failed.' }
}
finally {
  try {
    if ($adeWasEnabled -and (-not $adeTypeWillDelete -or -not $applyStarted)) {
      Set-AdeEnvironmentTypeStatus -EnvironmentTypeId $adeEnvironmentTypeId -Status Enabled
    }
    elseif ($adeWasEnabled -and $adeTypeWillDelete -and $applyStarted) {
      Write-Warning 'ADE admissions remain closed after a delete/replace apply began. Re-enable only through a reviewed platform apply if the environment type still exists.'
    }
  }
  finally {
    if ($admissionLease) { Exit-PlatformAdmissionLease -LeaseHandle $admissionLease }
    Remove-Item -LiteralPath $planFile -Force -ErrorAction SilentlyContinue
  }
}
