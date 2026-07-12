[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $RecordJson
)

$ErrorActionPreference = 'Stop'
$record = $RecordJson | ConvertFrom-Json
if ($record.phase -ne 'ACTIVE' -or -not $record.expirySyncPending) { throw 'Azure expiry tags may be synchronized only for an ACTIVE pending extension.' }
if (-not $record.expiresAt -or [DateTimeOffset]::Parse($record.expiresAt) -le [DateTimeOffset]::UtcNow) { throw 'The extended expiry must be a future RFC3339 timestamp.' }

& (Join-Path $PSScriptRoot 'Assert-ActiveLease.ps1') -Before 'updating Azure expiry tags'
$subscriptionId = $env:AZURE_SUBSCRIPTION_ID
$updated = @()

foreach ($groupName in @($record.resourceGroupNames)) {
  $groupJson = & az group show --name $groupName --output json 2>&1
  if ($LASTEXITCODE -ne 0) { throw "Tracked resource group could not be read during expiry synchronization: $groupName. $($groupJson | Out-String)" }
  $group = ($groupJson | Out-String) | ConvertFrom-Json
  $taggedEnvironment = [string]$group.tags.'platform.environment_id'
  $isManagedNodeGroup = $record.goldenPath -eq 'aks' -and $groupName -eq @($record.resourceGroupNames)[-1]
  if ($taggedEnvironment -and $taggedEnvironment -ne $record.environmentId) {
    throw "Resource group $groupName belongs to a different environment; tag mutation is forbidden."
  }
  if (-not $taggedEnvironment -and -not $isManagedNodeGroup) {
    throw "Primary resource group $groupName lacks the immutable environment tag; tag mutation is forbidden."
  }
  $tags = @("platform.environment_id=$($record.environmentId)", "platform.expires_at=$($record.expiresAt)")
  if ($isManagedNodeGroup) {
    $tags += @("platform.owner=$($record.owner)", 'platform.golden_path=aks-workload-v1', 'platform.managed=terraform')
  }
  & az tag update --resource-id $group.id --operation Merge --tags @tags --output none
  if ($LASTEXITCODE -ne 0) { throw "Could not update expiry tags on resource group $groupName." }
  $updated += $group.id
}

$taggableTypes = @(
  '/providers/Microsoft.Web/serverfarms/[^/]+$',
  '/providers/Microsoft.Web/sites/[^/]+$',
  '/providers/Microsoft.Insights/components/[^/]+$',
  '/providers/Microsoft.ManagedIdentity/userAssignedIdentities/[^/]+$',
  '/providers/Microsoft.App/managedEnvironments/[^/]+$',
  '/providers/Microsoft.App/containerApps/[^/]+$',
  '/providers/Microsoft.ContainerService/managedClusters/[^/]+$',
  '/providers/Microsoft.Insights/metricAlerts/[^/]+$',
  '/providers/Microsoft.Insights/activityLogAlerts/[^/]+$'
)
foreach ($resourceId in @($record.resourceIds)) {
  if ($resourceId -match '/resourceGroups/[^/]+$') { continue }
  if (-not ($taggableTypes | Where-Object { $resourceId -match $_ })) { continue }
  $resourceJson = & az resource show --ids $resourceId --output json 2>&1
  if ($LASTEXITCODE -ne 0) { throw "Tracked taggable resource could not be read during expiry synchronization: $resourceId. $($resourceJson | Out-String)" }
  $resource = ($resourceJson | Out-String) | ConvertFrom-Json
  if ([string]$resource.tags.'platform.environment_id' -ne $record.environmentId) {
    throw "Tracked resource lacks the matching immutable environment tag; mutation is forbidden: $resourceId"
  }
  & az tag update --resource-id $resourceId --operation Merge --tags "platform.expires_at=$($record.expiresAt)" --output none
  if ($LASTEXITCODE -ne 0) { throw "Could not update expiry tag on tracked resource: $resourceId" }
  $updated += $resourceId
}

[ordered]@{
  environmentId = $record.environmentId
  expiresAt = $record.expiresAt
  updatedResourceIds = @($updated)
  subscriptionId = $subscriptionId
} | ConvertTo-Json -Depth 5 -Compress
