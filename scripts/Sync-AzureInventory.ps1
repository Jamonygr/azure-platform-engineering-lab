[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $RecordJson
)

$ErrorActionPreference = 'Stop'
$record = $RecordJson | ConvertFrom-Json
if ($record.phase -ne 'ACTIVE') { throw 'Azure drift observation and adoption are valid only for ACTIVE environments.' }
& (Join-Path $PSScriptRoot 'Assert-ActiveLease.ps1') -Before 'observing active Azure inventory'
. (Join-Path $PSScriptRoot 'AzureResourceGraph.ps1')

function Get-AzureCliErrorCode {
  param([Parameter(Mandatory)] [object[]] $Output)

  $text = ($Output | Out-String)
  foreach ($pattern in @(
      '(?i)"code"\s*:\s*"(?<code>[A-Za-z][A-Za-z0-9_.-]+)"',
      '(?im)^\s*(?:ERROR:\s*)?\((?<code>[A-Za-z][A-Za-z0-9_.-]+)\)',
      '(?im)^\s*Code:\s*(?<code>[A-Za-z][A-Za-z0-9_.-]+)\s*$'
    )) {
    $match = [regex]::Match($text, $pattern)
    if ($match.Success) { return $match.Groups['code'].Value }
  }
  return $null
}

function Test-ExactNotFoundCode {
  param([AllowNull()] [string] $Code)
  return $Code -in @(
    'ResourceGroupNotFound',
    'ResourceNotFound',
    'ParentResourceNotFound',
    'RoleAssignmentNotFound',
    'PolicyAssignmentNotFound',
    'IdentityNotFound',
    'EntityNotFound'
  )
}

$groupNames = @($record.resourceGroupNames)
foreach ($groupName in $groupNames) {
  $groupResult = @(& az group show --name $groupName --output json 2>&1)
  if ($LASTEXITCODE -ne 0) {
    $errorCode = Get-AzureCliErrorCode -Output $groupResult
    if (Test-ExactNotFoundCode -Code $errorCode) {
      [ordered]@{ requiresDestroy = $true; reason = "Tracked resource group is missing: $groupName"; adoptedResourceIds = @() } | ConvertTo-Json -Compress
      return
    }
    throw "Could not observe tracked resource group $groupName (Azure error code: $($errorCode ?? 'unresolved')): $($groupResult | Out-String)"
  }
}

$subscriptionPrefix = "/subscriptions/$($env:AZURE_SUBSCRIPTION_ID)/"
if ($subscriptionPrefix -notmatch '^/subscriptions/[0-9a-fA-F-]{36}/$') { throw 'AZURE_SUBSCRIPTION_ID must be a UUID before inventory reconciliation.' }
foreach ($resourceId in @($record.resourceIds)) {
  $resourceId = ([string]$resourceId).TrimEnd('/')
  if (-not $resourceId.StartsWith($subscriptionPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Tracked resource is outside the authenticated subscription and cannot be observed: $resourceId"
  }
  if ($resourceId -match '(?i)^/subscriptions/[^/]+/resourceGroups/[^/]+$') {
    # Resource-group existence was already checked by exact inventoried name.
    continue
  }

  $apiVersion = switch -Regex ($resourceId) {
    '(?i)/providers/Microsoft\.Authorization/roleAssignments/[^/]+$' { '2022-04-01'; break }
    '(?i)/providers/Microsoft\.Authorization/policyAssignments/[^/]+$' { '2023-04-01'; break }
    '(?i)/providers/Microsoft\.Consumption/budgets/[^/]+$' { '2023-11-01'; break }
    '(?i)/providers/Microsoft\.ManagedIdentity/userAssignedIdentities/[^/]+/federatedIdentityCredentials/[^/]+$' { '2023-01-31'; break }
    '(?i)/providers/Microsoft\.Insights/diagnosticSettings/[^/]+$' { '2021-05-01-preview'; break }
    '(?i)/providers/Microsoft\.Resources/tags/[^/]+$' { '2021-04-01'; break }
    default { $null }
  }
  if ($apiVersion) {
    $managementUrl = "https://management.azure.com${resourceId}?api-version=$apiVersion"
    $resourceResult = @(& az rest --method get --url $managementUrl --output none 2>&1)
  }
  else {
    $resourceResult = @(& az resource show --ids $resourceId --output none 2>&1)
  }
  if ($LASTEXITCODE -ne 0) {
    $errorCode = Get-AzureCliErrorCode -Output $resourceResult
    if (Test-ExactNotFoundCode -Code $errorCode) {
      [ordered]@{ requiresDestroy = $true; reason = "Tracked resource is missing: $resourceId"; adoptedResourceIds = @() } | ConvertTo-Json -Compress
      return
    }
    throw "Could not observe tracked resource $resourceId (Azure error code: $($errorCode ?? 'unresolved')): $($resourceResult | Out-String)"
  }
}

if ($record.imageRepository) {
  if (-not $record.sharedAcrId -or -not $env:SHARED_ACR_ID -or
      $record.sharedAcrId.TrimEnd('/').ToLowerInvariant() -ne $env:SHARED_ACR_ID.TrimEnd('/').ToLowerInvariant()) {
    throw 'The exact configured and inventoried shared ACR IDs must match before image-repository drift can be observed.'
  }
  $acrName = ([string]$record.sharedAcrId -split '/')[-1]
  $acrGroup = ([string]$record.sharedAcrId -split '/resourceGroups/')[1].Split('/')[0]
  $actualAcrId = @(& az acr show --name $acrName --resource-group $acrGroup --query id --output tsv 2>&1)
  if ($LASTEXITCODE -ne 0 -or -not $actualAcrId -or
      ([string]($actualAcrId | Select-Object -First 1)).TrimEnd('/').ToLowerInvariant() -ne $record.sharedAcrId.TrimEnd('/').ToLowerInvariant()) {
    throw "The exact inventoried shared ACR could not be observed: $($actualAcrId | Out-String)"
  }
  $acrRepositoryResult = @(& az acr repository show --name $acrName --repository $record.imageRepository --output none 2>&1)
  if ($LASTEXITCODE -ne 0) {
    $acrText = $acrRepositoryResult | Out-String
    $acrCode = Get-AzureCliErrorCode -Output $acrRepositoryResult
    if ($acrCode -eq 'NAME_UNKNOWN' -or $acrText -match '(?im)(?:^|:\s)NAME_UNKNOWN:\s') {
      [ordered]@{ requiresDestroy = $true; reason = "Tracked ACR image repository is missing: $($record.imageRepository)"; adoptedResourceIds = @() } | ConvertTo-Json -Compress
      return
    }
    throw "Could not observe tracked ACR image repository $($record.imageRepository) (registry error code: $($acrCode ?? 'unresolved')): $acrText"
  }
}

$safeEnvironmentId = $record.environmentId.Replace("'", "''")
$query = "Resources | where tostring(tags['platform.environment_id']) =~ '$safeEnvironmentId' | project id, resourceGroup, type, tags"
$graph = Invoke-PlatformResourceGraphQuery -Query $query -First 1000
$knownIds = @($record.resourceIds | ForEach-Object { $_.TrimEnd('/').ToLowerInvariant() })
$adopt = @()
foreach ($resource in @($graph.data)) {
  $id = [string]$resource.id
  if (-not $id.StartsWith($subscriptionPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Tag-matched resource belongs to another subscription and cannot be adopted: $id"
  }
  if ([string]$resource.tags.'platform.environment_id' -ne $record.environmentId) {
    throw "Resource Graph returned a resource without the exact immutable environment tag: $id"
  }
  if ([string]$resource.resourceGroup -notin $groupNames) {
    $groupMatch = @($groupNames | Where-Object { $_ -ieq [string]$resource.resourceGroup }).Count -gt 0
    if (-not $groupMatch) { throw "Tag-matched resource is outside inventoried resource groups and cannot be adopted automatically: $id" }
  }
  if ($id.TrimEnd('/').ToLowerInvariant() -notin $knownIds) { $adopt += $id.TrimEnd('/') }
}

[ordered]@{
  requiresDestroy = $false
  reason = ''
  adoptedResourceIds = @($adopt | Sort-Object -Unique)
} | ConvertTo-Json -Depth 5 -Compress
