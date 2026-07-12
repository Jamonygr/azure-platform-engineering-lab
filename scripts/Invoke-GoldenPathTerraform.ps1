[CmdletBinding()]
param(
  [Parameter(Mandatory)] [ValidateSet('Apply', 'Destroy')] [string] $Operation,
  [Parameter(Mandatory)] [string] $RecordJson,
  [string] $OutputFile
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$record = $RecordJson | ConvertFrom-Json
$pathDirectoryName = switch ($record.goldenPath) {
  'web-app' { 'web-app-v1' }
  'container-app' { 'container-app-v1' }
  'aks' { 'aks-workload-v1' }
  default { throw 'Inventory contains an unsupported golden path.' }
}
$terraformDirectory = Join-Path $root "golden-paths/$pathDirectoryName"
if (-not (Test-Path (Join-Path $terraformDirectory 'main.tf'))) { throw "Terraform root not found: $terraformDirectory" }

$expectedConftestVersion = '0.68.2'
$conftestCommand = Get-Command conftest -ErrorAction SilentlyContinue
if (-not $conftestCommand) {
  throw "Conftest $expectedConftestVersion is required to evaluate every saved Terraform plan."
}
$conftestVersionLines = @(& conftest --version 2>&1)
$conftestVersionExitCode = $LASTEXITCODE
$conftestVersionOutput = ($conftestVersionLines | Out-String).Trim()
$hasExpectedConftestVersion = @($conftestVersionLines | Where-Object { ([string]$_).Trim() -eq "Conftest: $expectedConftestVersion" }).Count -eq 1
if ($conftestVersionExitCode -ne 0 -or -not $hasExpectedConftestVersion) {
  throw "Conftest $expectedConftestVersion is required; detected output: $conftestVersionOutput"
}
$policyDirectory = Join-Path $root 'policies/opa'
if (-not (Test-Path (Join-Path $policyDirectory 'terraform.rego'))) {
  throw "The required Terraform plan policy is missing from $policyDirectory."
}

$required = @(
  'TF_STATE_RESOURCE_GROUP', 'TF_STATE_STORAGE_ACCOUNT', 'TF_STATE_CONTAINER',
  'AZURE_SUBSCRIPTION_ID', 'AZURE_TENANT_ID', 'PLATFORM_LOG_ANALYTICS_WORKSPACE_IDS_JSON',
  'PLATFORM_ACTION_GROUP_ID', 'PLATFORM_ADMIN_EMAIL'
)
foreach ($name in $required) { if (-not [Environment]::GetEnvironmentVariable($name)) { throw "$name is required." } }
if ($record.goldenPath -in @('container-app', 'aks') -and -not $env:SHARED_ACR_ID) { throw 'SHARED_ACR_ID is required.' }
if ($record.goldenPath -eq 'aks' -and -not $env:DEVELOPER_GROUP_OBJECT_ID) { throw 'DEVELOPER_GROUP_OBJECT_ID is required.' }
try { $workspaceIds = $env:PLATFORM_LOG_ANALYTICS_WORKSPACE_IDS_JSON | ConvertFrom-Json -AsHashtable }
catch { throw 'PLATFORM_LOG_ANALYTICS_WORKSPACE_IDS_JSON must be a location-keyed JSON object.' }
$workspaceId = [string]$workspaceIds[$record.location]
if ($workspaceId -notmatch '(?i)^/subscriptions/[0-9a-f-]{36}/resourceGroups/[^/]+/providers/Microsoft\.OperationalInsights/workspaces/[^/]+$') {
  throw "No valid shared Log Analytics workspace is configured for $($record.location)."
}

if ($record.goldenPath -eq 'aks' -and $Operation -eq 'Apply') {
  & (Join-Path $PSScriptRoot 'Install-AksPreviewExtension.ps1')
  $help = & az aks approuting update --help 2>&1 | Out-String
  if ($LASTEXITCODE -ne 0 -or $help -notmatch '--enable-default-domain') { throw 'AKS default-domain capability is unavailable in this Azure CLI; no HTTP fallback is permitted.' }
}

$backend = @(
  "resource_group_name=$($env:TF_STATE_RESOURCE_GROUP)",
  "storage_account_name=$($env:TF_STATE_STORAGE_ACCOUNT)",
  "container_name=$($env:TF_STATE_CONTAINER)",
  "key=$($record.stateKey)",
  'use_azuread_auth=true'
)
$initArgs = @("-chdir=$terraformDirectory", 'init', '-input=false', '-reconfigure', '-lockfile=readonly')
foreach ($entry in $backend) { $initArgs += "-backend-config=$entry" }
& terraform @initArgs
if ($LASTEXITCODE -ne 0) { throw 'terraform init failed.' }

$repositoryOwner = if ($record.repository) { $record.repository.owner } else { $env:GENERATED_REPOSITORY_OWNER }
$repositoryName = if ($record.repository) { $record.repository.name } else { $record.requestedRepositoryName }
$variables = [ordered]@{
  environment_id = $record.environmentId
  environment_name = $record.environmentName
  location = $record.location
  owner = $record.owner
  expires_at = $record.expiresAt
  create_resource_group = $true
  log_analytics_workspace_id = $workspaceId
  action_group_id = $env:PLATFORM_ACTION_GROUP_ID
  platform_admin_email = $env:PLATFORM_ADMIN_EMAIL
  github_owner = $repositoryOwner
  github_repository = $repositoryName
  provisioning_channel = 'github'
}
if ($env:PLATFORM_POLICY_DEFINITION_IDS_JSON) {
  try { $variables.policy_definition_ids = $env:PLATFORM_POLICY_DEFINITION_IDS_JSON | ConvertFrom-Json -AsHashtable }
  catch { throw 'PLATFORM_POLICY_DEFINITION_IDS_JSON must be a JSON object.' }
}
if ($record.goldenPath -in @('container-app', 'aks')) {
  $variables.shared_acr_id = $env:SHARED_ACR_ID
  if ($record.repository.numericId) {
    $variables.image_repository = if ($record.imageRepository) { $record.imageRepository } else { "apps/$($record.repository.numericId)" }
  }
  elseif ($Operation -eq 'Destroy' -and $record.phase -eq 'AZURE_DELETING' -and @($record.resourceIds).Count -eq 0) {
    # A request that failed before repository attachment/Azure apply still runs
    # the normal saved-state destroy path. This validation-only namespace is
    # never inventoried or deleted from the shared registry.
    $variables.image_repository = 'apps/0'
  }
  else {
    throw 'Container golden paths require the immutable numeric GitHub repository ID before Terraform apply.'
  }
}
if ($record.goldenPath -eq 'aks') {
  $variables.developer_group_object_id = $env:DEVELOPER_GROUP_OBJECT_ID
  $variables.default_domain_preflight_passed = $true
}

$temporaryDirectory = Join-Path ([System.IO.Path]::GetTempPath()) "platform-$($record.environmentId)-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $temporaryDirectory | Out-Null
$variableFile = Join-Path $temporaryDirectory 'environment.auto.tfvars.json'
$planFile = Join-Path $temporaryDirectory 'environment.tfplan'
$variables | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $variableFile -Encoding utf8NoBOM
try {
  $planArgs = @("-chdir=$terraformDirectory", 'plan', '-input=false', "-var-file=$variableFile", "-out=$planFile")
  if ($Operation -eq 'Destroy') { $planArgs += '-destroy' }
  & terraform @planArgs
  if ($LASTEXITCODE -ne 0) { throw "Terraform $Operation plan failed." }

  $planJson = Join-Path $temporaryDirectory 'plan.json'
  $planJsonContent = & terraform "-chdir=$terraformDirectory" show -json $planFile
  if ($LASTEXITCODE -ne 0) { throw 'Could not render the saved Terraform plan for policy evaluation.' }
  $planJsonContent | Set-Content -LiteralPath $planJson -Encoding utf8NoBOM
  & conftest test $planJson --policy $policyDirectory --namespace main
  if ($LASTEXITCODE -ne 0) { throw 'Policy check rejected the saved Terraform plan.' }

  & (Join-Path $PSScriptRoot 'Assert-ActiveLease.ps1') -Before "Terraform $Operation apply"
  & terraform "-chdir=$terraformDirectory" apply -input=false -auto-approve $planFile
  if ($LASTEXITCODE -ne 0) { throw "Terraform $Operation apply failed." }
  if ($Operation -eq 'Apply' -and $OutputFile) {
    $outputRaw = & terraform "-chdir=$terraformDirectory" output -json
    if ($LASTEXITCODE -ne 0) { throw 'Could not read Terraform outputs.' }
    $outputObject = ($outputRaw | Out-String) | ConvertFrom-Json
    if ($record.goldenPath -eq 'aks') {
      $resourceGroup = [string]$outputObject.resource_group_names.value[0]
      $clusterName = [string]$outputObject.cluster_name.value
      if (-not $resourceGroup -or -not $clusterName) { throw 'AKS outputs must include resource_group_names and cluster_name.' }
      & (Join-Path $PSScriptRoot 'Assert-ActiveLease.ps1') -Before 'enabling the AKS managed default domain'
      & az aks approuting update --resource-group $resourceGroup --name $clusterName --enable-default-domain --nginx External --output none
      if ($LASTEXITCODE -ne 0) { throw 'AKS managed default domain could not be enabled; no insecure fallback is permitted.' }

      # Enabling the preview capability is asynchronous. Poll only its read-only
      # status command and never substitute an HTTP or self-signed endpoint.
      $domainDeadline = [DateTimeOffset]::UtcNow.AddMinutes(15)
      $domainDelaySeconds = 10
      $domainName = $null
      do {
        & (Join-Path $PSScriptRoot 'Assert-ActiveLease.ps1') -Before 'waiting for the AKS managed default domain'
        try {
          $domainJson = & az aks approuting defaultdomain show --resource-group $resourceGroup --name $clusterName --output json 2>$null
          $domainExitCode = $LASTEXITCODE
        }
        catch {
          $domainJson = $null
          $domainExitCode = 1
        }
        if ($domainExitCode -eq 0 -and $domainJson) {
          try {
            $domainProfile = ($domainJson | Out-String) | ConvertFrom-Json
            $domainName = @($domainProfile.domainName, $domainProfile.domain_name, $domainProfile.defaultDomain, $domainProfile.fqdn) |
              Where-Object { $_ } |
              Select-Object -First 1
          }
          catch {
            $domainName = $null
          }
        }
        if ($domainName -and $domainName -match '^[A-Za-z0-9.-]+$') { break }
        $domainName = $null
        if ([DateTimeOffset]::UtcNow.AddSeconds($domainDelaySeconds) -ge $domainDeadline) { break }
        Write-Host "AKS managed default domain is still provisioning; retrying in $domainDelaySeconds seconds."
        Start-Sleep -Seconds $domainDelaySeconds
        $domainDelaySeconds = [math]::Min([int][math]::Ceiling($domainDelaySeconds * 1.5), 60)
      } while ([DateTimeOffset]::UtcNow -lt $domainDeadline)
      if (-not $domainName -or $domainName -notmatch '^[A-Za-z0-9.-]+$') {
        throw 'AKS managed default-domain provisioning did not return a valid hostname within 15 minutes; no insecure fallback is permitted.'
      }
      $outputObject.endpoint.value = "https://$($record.environmentName).$domainName"
    }
    $outputObject | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $OutputFile -Encoding utf8NoBOM
  }
}
finally {
  Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force -ErrorAction SilentlyContinue
}
