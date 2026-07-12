[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $RecordJson
)

$ErrorActionPreference = 'Stop'
$record = $RecordJson | ConvertFrom-Json
$allowedLocations = @('westeurope', 'northeurope', 'germanywestcentral')

if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw 'Azure CLI is required for the live golden-path preflight.' }
if ($record.location -notin $allowedLocations) { throw "Location '$($record.location)' is outside the configured EU allowlist." }
if ($record.goldenPath -eq 'aks') {
  & (Join-Path $PSScriptRoot 'Install-AksPreviewExtension.ps1')
}

$account = & az account show --output json 2>&1
if ($LASTEXITCODE -ne 0) { throw "Azure subscription context could not be read: $($account | Out-String)" }
$account = ($account | Out-String) | ConvertFrom-Json
if ($account.id.ToLowerInvariant() -ne $env:AZURE_SUBSCRIPTION_ID.ToLowerInvariant()) {
  throw "Azure CLI is authenticated to subscription $($account.id), not AZURE_SUBSCRIPTION_ID."
}
if (-not $env:PLATFORM_LOG_ANALYTICS_WORKSPACE_IDS_JSON) { throw 'PLATFORM_LOG_ANALYTICS_WORKSPACE_IDS_JSON is required.' }
try { $workspaceIds = $env:PLATFORM_LOG_ANALYTICS_WORKSPACE_IDS_JSON | ConvertFrom-Json -AsHashtable }
catch { throw 'PLATFORM_LOG_ANALYTICS_WORKSPACE_IDS_JSON must be a location-keyed JSON object.' }
$workspaceId = [string]$workspaceIds[$record.location]
if ($workspaceId -notmatch '(?i)^/subscriptions/[0-9a-f-]{36}/resourceGroups/[^/]+/providers/Microsoft\.OperationalInsights/workspaces/[^/]+$') {
  throw "No valid shared Log Analytics workspace is configured for $($record.location)."
}
$workspaceLocation = & az resource show --ids $workspaceId --query location --output tsv 2>&1
if ($LASTEXITCODE -ne 0 -or ([string]$workspaceLocation -replace '[^A-Za-z0-9]', '').ToLowerInvariant() -ne ($record.location -replace '[^A-Za-z0-9]', '').ToLowerInvariant()) {
  throw "The shared Log Analytics workspace for $($record.location) is absent or in a different region; same-region monitoring is required. $($workspaceLocation | Out-String)"
}

function Assert-ProviderRegistered {
  param([Parameter(Mandatory)] [string] $Namespace)
  $registration = & az provider show --namespace $Namespace --query registrationState --output tsv 2>&1
  if ($LASTEXITCODE -ne 0 -or $registration -ne 'Registered') {
    throw "Resource provider $Namespace must be Registered before a request is accepted (current result: $($registration | Out-String))."
  }
}

function Assert-ResourceTypeLocation {
  param(
    [Parameter(Mandatory)] [string] $Namespace,
    [Parameter(Mandatory)] [string] $ResourceType,
    [Parameter(Mandatory)] [string] $Location
  )
  $providerJson = & az provider show --namespace $Namespace --expand 'resourceTypes/locations' --output json 2>&1
  if ($LASTEXITCODE -ne 0) { throw "Could not read $Namespace regional capabilities: $($providerJson | Out-String)" }
  $provider = ($providerJson | Out-String) | ConvertFrom-Json
  $definition = @($provider.resourceTypes | Where-Object { $_.resourceType -eq $ResourceType }) | Select-Object -First 1
  if (-not $definition) { throw "Provider $Namespace did not advertise resource type $ResourceType." }
  $normalized = @($definition.locations | ForEach-Object { ([string]$_ -replace '[^A-Za-z0-9]', '').ToLowerInvariant() })
  $expected = ($Location -replace '[^A-Za-z0-9]', '').ToLowerInvariant()
  if ($normalized.Count -gt 0 -and $expected -notin $normalized) {
    throw "$Namespace/$ResourceType is not advertised in $Location for this subscription."
  }
}

$providers = @('Microsoft.Authorization', 'Microsoft.Insights', 'Microsoft.OperationalInsights', 'Microsoft.Consumption')
switch ($record.goldenPath) {
  'web-app' { $providers += 'Microsoft.Web' }
  'container-app' { $providers += @('Microsoft.App', 'Microsoft.ManagedIdentity', 'Microsoft.Quota') }
  'aks' { $providers += @('Microsoft.ContainerService', 'Microsoft.Compute', 'Microsoft.Network', 'Microsoft.ManagedIdentity', 'Microsoft.PolicyInsights') }
  default { throw "Unsupported golden path '$($record.goldenPath)' in preflight." }
}
$providers | Sort-Object -Unique | ForEach-Object { Assert-ProviderRegistered -Namespace $_ }

switch ($record.goldenPath) {
  'web-app' {
    Assert-ResourceTypeLocation -Namespace 'Microsoft.Web' -ResourceType 'serverFarms' -Location $record.location
    Assert-ResourceTypeLocation -Namespace 'Microsoft.Web' -ResourceType 'sites' -Location $record.location
    $locationsJson = & az appservice list-locations --sku B1 --linux-workers-enabled --output json 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Could not verify Linux App Service B1 availability: $($locationsJson | Out-String)" }
    $locations = ($locationsJson | Out-String) | ConvertFrom-Json
    $candidateNames = @($locations | ForEach-Object {
      if ($_ -is [string]) { $_ }
      elseif ($_.name) { $_.name }
      elseif ($_.geoRegion) { $_.geoRegion }
      elseif ($_.displayName) { $_.displayName }
    } | Where-Object { $_ } | ForEach-Object { ([string]$_ -replace '[^A-Za-z0-9]', '').ToLowerInvariant() })
    $expected = ($record.location -replace '[^A-Za-z0-9]', '').ToLowerInvariant()
    if ($expected -notin $candidateNames) { throw "Linux App Service B1 is not available in $($record.location) for this subscription." }

    $usageUri = "https://management.azure.com/subscriptions/$($env:AZURE_SUBSCRIPTION_ID)/providers/Microsoft.Web/locations/$($record.location)/usages?api-version=2025-03-01"
    $usageJson = & az rest --method get --uri $usageUri --output json 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Could not read App Service regional core quota: $($usageJson | Out-String)" }
    $usage = ($usageJson | Out-String) | ConvertFrom-Json
    $coreQuota = @($usage.value | Where-Object {
      [string]$_.unit -match '(?i)core' -or [string]$_.name.value -match '(?i)core'
    }) | Select-Object -First 1
    if (-not $coreQuota) { throw "App Service returned no regional core quota for $($record.location); B1 preflight fails closed." }
    $remainingCores = [decimal]$coreQuota.limit - [decimal]$coreQuota.currentValue
    if ($remainingCores -lt 1) { throw "App Service B1 requires one available regional core in $($record.location); only $remainingCores remain." }
  }
  'container-app' {
    Assert-ResourceTypeLocation -Namespace 'Microsoft.App' -ResourceType 'managedEnvironments' -Location $record.location
    Assert-ResourceTypeLocation -Namespace 'Microsoft.App' -ResourceType 'containerApps' -Location $record.location

    $quotaScope = "/subscriptions/$($env:AZURE_SUBSCRIPTION_ID)/providers/Microsoft.App/locations/$($record.location)"
    $quotaUri = "https://management.azure.com${quotaScope}/providers/Microsoft.Quota/quotas?api-version=2025-09-01"
    $quotaJson = & az rest --method get --uri $quotaUri --output json 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Could not read Container Apps regional quota through Microsoft.Quota: $($quotaJson | Out-String)" }
    $quotaResponse = ($quotaJson | Out-String) | ConvertFrom-Json
    $environmentQuota = @($quotaResponse.value | Where-Object {
      [string]$_.name -ieq 'ManagedEnvironmentCount' -or [string]$_.properties.name.value -ieq 'ManagedEnvironmentCount'
    }) | Select-Object -First 1
    if (-not $environmentQuota -or $null -eq $environmentQuota.properties.limit.value) {
      throw "Microsoft.Quota returned no ManagedEnvironmentCount limit for Container Apps in $($record.location); preflight fails closed."
    }

    $environmentCount = 0
    $nextUri = "https://management.azure.com/subscriptions/$($env:AZURE_SUBSCRIPTION_ID)/providers/Microsoft.App/managedEnvironments?api-version=2025-07-01"
    do {
      $environmentJson = & az rest --method get --uri $nextUri --output json 2>&1
      if ($LASTEXITCODE -ne 0) { throw "Could not enumerate existing Container Apps environments for quota usage: $($environmentJson | Out-String)" }
      $environmentResponse = ($environmentJson | Out-String) | ConvertFrom-Json
      $environmentCount += @($environmentResponse.value | Where-Object {
        ([string]$_.location -replace '[^A-Za-z0-9]', '').ToLowerInvariant() -eq ($record.location -replace '[^A-Za-z0-9]', '').ToLowerInvariant()
      }).Count
      $nextUri = [string]$environmentResponse.nextLink
    } while ($nextUri)
    $environmentLimit = [int64]$environmentQuota.properties.limit.value
    if ($environmentLimit - $environmentCount -lt 1) {
      throw "Container Apps ManagedEnvironmentCount quota is exhausted in $($record.location): $environmentCount of $environmentLimit are already used."
    }
  }
  'aks' {
    Assert-ResourceTypeLocation -Namespace 'Microsoft.ContainerService' -ResourceType 'managedClusters' -Location $record.location

    # The pinned AKS root enables Gateway API Standard. That control-plane
    # surface is gated by a subscription feature registration independently of
    # whether the installed CLI happens to expose the default-domain commands.
    $gatewayApiFeature = & az feature show --namespace Microsoft.ContainerService --name AppRoutingIstioGatewayAPIPreview --query properties.state --output tsv 2>&1
    $gatewayApiFeatureState = ($gatewayApiFeature | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $gatewayApiFeatureState -ine 'Registered') {
      throw "AKS Gateway API Standard requires Microsoft.ContainerService/AppRoutingIstioGatewayAPIPreview in state Registered (current result: '$gatewayApiFeatureState'). Register the feature and re-register Microsoft.ContainerService before retrying."
    }

    $skuJson = & az vm list-skus --location $record.location --resource-type virtualMachines --size Standard_B2s --all --output json 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Could not verify Standard_B2s availability: $($skuJson | Out-String)" }
    $skus = @(($skuJson | Out-String) | ConvertFrom-Json)
    $availableSku = @($skus | Where-Object {
      $_.name -eq 'Standard_B2s' -and
      @($_.restrictions | Where-Object { $_.reasonCode -eq 'NotAvailableForSubscription' }).Count -eq 0
    }) | Select-Object -First 1
    if (-not $availableSku) { throw "Standard_B2s is unavailable for this subscription in $($record.location)." }

    $usageJson = & az vm list-usage --location $record.location --output json 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Could not read regional compute quota: $($usageJson | Out-String)" }
    $usage = @(($usageJson | Out-String) | ConvertFrom-Json)
    foreach ($quotaName in @('cores', 'standardBSFamily')) {
      $quota = @($usage | Where-Object { $_.name.value -ieq $quotaName }) | Select-Object -First 1
      if (-not $quota) { throw "Compute quota '$quotaName' was not returned for $($record.location); AKS preflight fails closed." }
      if (([int64]$quota.limit - [int64]$quota.currentValue) -lt 2) {
        throw "AKS requires two available vCPUs in quota '$quotaName' in $($record.location); only $([int64]$quota.limit - [int64]$quota.currentValue) remain."
      }
    }

    $updateHelp = & az aks approuting update --help 2>&1 | Out-String
    $domainHelp = & az aks approuting defaultdomain show --help 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0 -or $updateHelp -notmatch '--enable-default-domain' -or $domainHelp -notmatch 'default domain') {
      throw 'The AKS managed Application Routing default-domain capability is unavailable; no HTTP or self-signed fallback is permitted.'
    }
  }
}

[ordered]@{
  checkedAt = [DateTimeOffset]::UtcNow.ToString('o')
  subscriptionId = $account.id
  goldenPath = $record.goldenPath
  location = $record.location
  result = 'passed'
} | ConvertTo-Json -Compress
