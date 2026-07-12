[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
  [string] $BootstrapDirectory,
  [string] $ResourceGroupName,
  [string] $StorageAccountName,
  [string] $ContainerName
)

$ErrorActionPreference = 'Stop'
$stateKey = 'bootstrap/bootstrap.tfstate'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if (-not $BootstrapDirectory) { $BootstrapDirectory = Join-Path $root 'bootstrap' }
$BootstrapDirectory = (Resolve-Path -LiteralPath $BootstrapDirectory).Path
$localStatePath = Join-Path $BootstrapDirectory 'terraform.tfstate'
$backendTemplatePath = Join-Path $BootstrapDirectory 'backend_override.tf.example'
$backendOverridePath = Join-Path $BootstrapDirectory 'backend_override.tf'
$remoteStatePath = Join-Path ([IO.Path]::GetTempPath()) "bootstrap-remote-$([guid]::NewGuid().ToString('N')).tfstate"
$createdOverride = $false
$remoteExistedBefore = $false
$verified = $false

function Assert-Command {
  param([Parameter(Mandatory)] [string] $Name)
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "Required command '$Name' was not found on PATH."
  }
}

function Invoke-NativeJson {
  param(
    [Parameter(Mandatory)] [string] $Command,
    [Parameter(Mandatory)] [string[]] $Arguments,
    [Parameter(Mandatory)] [string] $FailureMessage
  )

  $output = & $Command @Arguments 2>&1
  if ($LASTEXITCODE -ne 0) { throw $FailureMessage }
  try {
    return (($output -join "`n") | ConvertFrom-Json)
  }
  catch {
    throw "$FailureMessage The command returned invalid JSON."
  }
}

function Get-BackendOutput {
  param([Parameter(Mandatory)] $StateDocument)

  if ($StateDocument.outputs -and $StateDocument.outputs.backend) {
    return $StateDocument.outputs.backend.value
  }
  return $null
}

function Test-RemoteBlob {
  $document = Invoke-NativeJson -Command 'az' -Arguments @(
    'storage', 'blob', 'exists',
    '--account-name', $StorageAccountName,
    '--container-name', $ContainerName,
    '--name', $stateKey,
    '--auth-mode', 'login',
    '--only-show-errors',
    '--output', 'json'
  ) -FailureMessage 'Could not inspect the bootstrap state blob with Azure AD. Grant the signed-in identity Storage Blob Data Contributor on the bootstrap storage account and retry.'
  return [bool]$document.exists
}

function Get-RemoteStateDocument {
  if (Test-Path -LiteralPath $remoteStatePath) {
    Remove-Item -LiteralPath $remoteStatePath -Force
  }
  & az storage blob download `
    --account-name $StorageAccountName `
    --container-name $ContainerName `
    --name $stateKey `
    --file $remoteStatePath `
    --auth-mode login `
    --overwrite true `
    --no-progress `
    --only-show-errors `
    --output none
  if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $remoteStatePath -PathType Leaf)) {
    throw 'Could not download the existing bootstrap state with Azure AD; refusing to change backend configuration.'
  }
  try {
    return (Get-Content -LiteralPath $remoteStatePath -Raw | ConvertFrom-Json)
  }
  catch {
    throw 'The existing bootstrap state blob is not valid Terraform state; refusing to overwrite it.'
  }
}

function Select-BackendValue {
  param(
    [string] $ExplicitValue,
    [string] $StateValue,
    [string] $EnvironmentValue,
    [Parameter(Mandatory)] [string] $Name
  )

  $selected = if ($ExplicitValue) { $ExplicitValue } elseif ($StateValue) { $StateValue } else { $EnvironmentValue }
  if (-not $selected) { throw "Backend value '$Name' could not be derived. Supply it as a script parameter." }
  if ($ExplicitValue -and $StateValue -and $ExplicitValue -ne $StateValue) {
    throw "Explicit backend value '$Name' does not match the applied bootstrap state."
  }
  return $selected
}

try {
  Assert-Command -Name 'terraform'
  Assert-Command -Name 'az'
  if (-not (Test-Path -LiteralPath $backendTemplatePath -PathType Leaf)) {
    throw 'bootstrap/backend_override.tf.example was not found.'
  }

  $localStateDocument = $null
  $backendOutput = $null
  if (Test-Path -LiteralPath $localStatePath -PathType Leaf) {
    try {
      $localStateDocument = Get-Content -LiteralPath $localStatePath -Raw | ConvertFrom-Json
    }
    catch {
      throw 'bootstrap/terraform.tfstate is not valid JSON; refusing migration.'
    }
    if (-not $localStateDocument.lineage -or $null -eq $localStateDocument.serial) {
      throw 'bootstrap/terraform.tfstate does not contain Terraform lineage and serial metadata.'
    }
    $backendOutput = Get-BackendOutput -StateDocument $localStateDocument
  }
  elseif (Test-Path -LiteralPath $backendOverridePath -PathType Leaf) {
    $outputJson = & terraform "-chdir=$BootstrapDirectory" output -json 2>$null
    if ($LASTEXITCODE -eq 0 -and $outputJson) {
      try {
        $currentOutputs = ($outputJson -join "`n") | ConvertFrom-Json
        $backendOutput = $currentOutputs.backend.value
      }
      catch {
        throw 'The configured bootstrap backend returned invalid Terraform output JSON.'
      }
    }
  }

  $ResourceGroupName = Select-BackendValue -ExplicitValue $ResourceGroupName -StateValue $backendOutput.resource_group_name -EnvironmentValue $env:TF_STATE_RESOURCE_GROUP -Name 'resource_group_name'
  $StorageAccountName = Select-BackendValue -ExplicitValue $StorageAccountName -StateValue $backendOutput.storage_account_name -EnvironmentValue $env:TF_STATE_STORAGE_ACCOUNT -Name 'storage_account_name'
  $ContainerName = Select-BackendValue -ExplicitValue $ContainerName -StateValue $backendOutput.container_name -EnvironmentValue $env:TF_STATE_CONTAINER -Name 'container_name'

  if ($StorageAccountName -notmatch '^[a-z0-9]{3,24}$') { throw 'The derived storage account name is invalid.' }
  if ($ContainerName -notmatch '^[a-z0-9](?:[a-z0-9-]{1,61}[a-z0-9])$') { throw 'The derived state container name is invalid.' }

  $account = Invoke-NativeJson -Command 'az' -Arguments @('account', 'show', '--only-show-errors', '--output', 'json') -FailureMessage 'Azure CLI is not authenticated. Run az login and select the bootstrap subscription.'
  if ($backendOutput.subscription_id -and $account.id -ne $backendOutput.subscription_id) {
    throw 'The active Azure subscription does not match the subscription recorded in bootstrap state.'
  }
  if ($backendOutput.tenant_id -and $account.tenantId -ne $backendOutput.tenant_id) {
    throw 'The active Azure tenant does not match the tenant recorded in bootstrap state.'
  }

  $remoteExistedBefore = Test-RemoteBlob
  if ($remoteExistedBefore) {
    $remoteStateDocument = Get-RemoteStateDocument
    if ($localStateDocument) {
      if ($remoteStateDocument.lineage -ne $localStateDocument.lineage) {
        throw 'Remote bootstrap state already exists with a different lineage; refusing to overwrite it.'
      }
      if ([int64]$remoteStateDocument.serial -lt [int64]$localStateDocument.serial) {
        throw 'Remote bootstrap state is older than local state; refusing an automatic overwrite. Reconcile the states manually.'
      }
    }
    $remoteBackendOutput = Get-BackendOutput -StateDocument $remoteStateDocument
    if ($remoteBackendOutput -and $remoteBackendOutput.storage_account_name -ne $StorageAccountName) {
      throw 'Remote state backend metadata does not match the selected storage account.'
    }
  }
  elseif (-not $localStateDocument) {
    throw 'No local bootstrap state and no remote bootstrap state were found; there is nothing safe to migrate.'
  }

  if (-not $PSCmdlet.ShouldProcess("Azure Storage key $stateKey", 'Configure and verify the bootstrap Terraform backend')) {
    return
  }

  if (Test-Path -LiteralPath $backendOverridePath -PathType Leaf) {
    $overrideContent = Get-Content -LiteralPath $backendOverridePath -Raw
    if ($overrideContent -notmatch 'backend\s+"azurerm"') {
      throw 'Existing bootstrap/backend_override.tf is not an azurerm backend declaration; refusing to replace it.'
    }
  }
  else {
    [IO.File]::Copy($backendTemplatePath, $backendOverridePath, $false)
    $createdOverride = $true
  }

  $backendArguments = @(
    "-backend-config=resource_group_name=$ResourceGroupName",
    "-backend-config=storage_account_name=$StorageAccountName",
    "-backend-config=container_name=$ContainerName",
    "-backend-config=key=$stateKey",
    '-backend-config=use_azuread_auth=true'
  )
  if ($backendOutput.subscription_id) { $backendArguments += "-backend-config=subscription_id=$($backendOutput.subscription_id)" }
  if ($backendOutput.tenant_id) { $backendArguments += "-backend-config=tenant_id=$($backendOutput.tenant_id)" }

  if (-not $remoteExistedBefore) {
    $backupPath = "$localStatePath.pre-migration.$((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')).backup"
    [IO.File]::Copy($localStatePath, $backupPath, $false)
    $initArguments = @("-chdir=$BootstrapDirectory", 'init', '-input=false', '-migrate-state', '-force-copy') + $backendArguments
  }
  else {
    $initArguments = @("-chdir=$BootstrapDirectory", 'init', '-input=false', '-reconfigure') + $backendArguments
  }

  & terraform @initArguments
  if ($LASTEXITCODE -ne 0) { throw 'terraform init did not complete; bootstrap state has not been declared migrated.' }

  $pulledState = & terraform "-chdir=$BootstrapDirectory" state pull 2>$null
  if ($LASTEXITCODE -ne 0 -or -not $pulledState) {
    throw 'Terraform could not pull bootstrap state from the configured Azure backend.'
  }
  try {
    $pulledStateDocument = ($pulledState -join "`n") | ConvertFrom-Json
  }
  catch {
    throw 'Terraform returned invalid remote state JSON after backend initialization.'
  }

  if ($localStateDocument) {
    if ($pulledStateDocument.lineage -ne $localStateDocument.lineage) {
      throw 'Post-migration state lineage does not match local bootstrap state.'
    }
    if ([int64]$pulledStateDocument.serial -lt [int64]$localStateDocument.serial) {
      throw 'Post-migration state serial is older than local bootstrap state.'
    }
  }
  if (-not (Test-RemoteBlob)) { throw 'Bootstrap state verification failed because the Azure blob is absent.' }

  $verified = $true
  Write-Information "Bootstrap state is verified in Azure Storage at key '$stateKey'." -InformationAction Continue
  Write-Information 'The backend uses Azure AD authentication; no storage access key or client secret was read or written.' -InformationAction Continue
}
finally {
  if (Test-Path -LiteralPath $remoteStatePath) {
    Remove-Item -LiteralPath $remoteStatePath -Force -ErrorAction SilentlyContinue
  }
  if (-not $verified -and $createdOverride -and -not $remoteExistedBefore) {
    $remoteNowExists = $true
    try { $remoteNowExists = Test-RemoteBlob } catch { $remoteNowExists = $true }
    if (-not $remoteNowExists) {
      Remove-Item -LiteralPath $backendOverridePath -Force -ErrorAction SilentlyContinue
    }
    else {
      Write-Warning 'A remote state blob may have been created. backend_override.tf was retained to prevent accidental fallback to local state; rerun the migration helper.'
    }
  }
}
