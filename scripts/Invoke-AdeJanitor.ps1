[CmdletBinding()]
param([switch] $DryRun)

$ErrorActionPreference = 'Stop'
if ($env:ENABLE_ADE -ne 'true') { Write-Host 'ADE compatibility is disabled; janitor has no work.'; return }
foreach ($name in @('ADE_DEVCENTER_NAME', 'ADE_PROJECT_NAME')) {
  if (-not [Environment]::GetEnvironmentVariable($name)) { throw "$name is required when ADE is enabled." }
}
& az config set extension.use_dynamic_install=yes_without_prompt | Out-Null
$json = & az devcenter dev environment list --dev-center-name $env:ADE_DEVCENTER_NAME --project-name $env:ADE_PROJECT_NAME --output json
if ($LASTEXITCODE -ne 0) { throw 'Could not list ADE project environments.' }
$environments = @($json | ConvertFrom-Json)
$changes = @()
$errors = @()
foreach ($environment in $environments) {
  if ($environment.provisioningState -in @('Deleting', 'Deleted')) { continue }
  $name = [string]$environment.name
  $userId = if ($environment.user) { [string]$environment.user } elseif ($environment.userId) { [string]$environment.userId } elseif ($environment.id -match '/users/([^/]+)/environments/') { $Matches[1] } else { '' }
  $resourceGroupId = [string]$environment.resourceGroupId
  if (-not $name -or -not $userId -or $resourceGroupId -notmatch '(?i)^/subscriptions/(?<subscription>[0-9a-f-]{36})/resourceGroups/(?<group>[^/]+)$') {
    $errors += "Environment '$name' lacks immutable user/resource-group metadata; expiry was not guessed."
    continue
  }
  $resourceSubscription = $Matches.subscription
  $resourceGroupName = $Matches.group
  if ($env:AZURE_SUBSCRIPTION_ID -and $resourceSubscription -ine $env:AZURE_SUBSCRIPTION_ID) {
    $errors += "Environment '$name' points outside the configured subscription; expiry was not changed."
    continue
  }
  $resourceGroupJson = & az group show --name $resourceGroupName --subscription $resourceSubscription --output json 2>&1
  if ($LASTEXITCODE -ne 0) {
    $errors += "Environment '$name' resource-group metadata could not be read; expiry was not guessed. $($resourceGroupJson | Out-String)"
    continue
  }
  try { $resourceGroup = ($resourceGroupJson | Out-String) | ConvertFrom-Json }
  catch { $errors += "Environment '$name' returned malformed resource-group metadata."; continue }
  if ([string]$resourceGroup.id -ine $resourceGroupId) {
    $errors += "Environment '$name' resource-group identity did not match the ADE record."
    continue
  }
  $createdRaw = [string]$resourceGroup.tags.'platform.created_at'
  $taggedExpirationRaw = [string]$resourceGroup.tags.'platform.expires_at'
  $reportedCreatedRaw = if ($environment.createdTime) { [string]$environment.createdTime } elseif ($environment.createdAt) { [string]$environment.createdAt } else { '' }
  if ([string]::IsNullOrWhiteSpace($createdRaw) -xor [string]::IsNullOrWhiteSpace($taggedExpirationRaw)) {
    $errors += "Environment '$name' has a partial runner creation/expiry tag bridge; expiry was not guessed."
    continue
  }
  if ([string]::IsNullOrWhiteSpace($createdRaw)) {
    if (-not $reportedCreatedRaw) {
      $errors += "Environment '$name' has neither runner tags nor an ADE creation time; expiry was not guessed."
      continue
    }
    try { $created = [DateTimeOffset]::Parse($reportedCreatedRaw).ToUniversalTime() }
    catch { $errors += "Environment '$name' has invalid ADE creation time."; continue }
    $taggedExpiration = $created.AddHours(24)
    $taggedHours = 24
    $usedRunnerBridge = $false
  }
  else {
    if ($createdRaw -notmatch 'Z$' -or $taggedExpirationRaw -notmatch 'Z$') {
      $errors += "Environment '$name' runner creation/expiry tags are not UTC; expiry was not guessed."
      continue
    }
    try {
      $created = [DateTimeOffset]::Parse($createdRaw).ToUniversalTime()
      $taggedExpiration = [DateTimeOffset]::Parse($taggedExpirationRaw).ToUniversalTime()
    }
    catch { $errors += "Environment '$name' has invalid runner creation/expiry tags."; continue }
    $taggedHours = ($taggedExpiration - $created).TotalHours
    $allowedHours = @(4, 8, 24, 48, 72)
    if (-not @($allowedHours | Where-Object { [Math]::Abs($taggedHours - $_) -lt 0.001 }).Count) {
      $errors += "Environment '$name' runner expiry is not one of the allowed TTL values; expiry was not changed."
      continue
    }
    $usedRunnerBridge = $true
    if ($reportedCreatedRaw) {
      try { $reportedCreated = [DateTimeOffset]::Parse($reportedCreatedRaw).ToUniversalTime() }
      catch { $errors += "Environment '$name' has invalid ADE creation time."; continue }
      if ($created -lt $reportedCreated.AddMinutes(-1) -or $created -gt $reportedCreated.AddMinutes(30)) {
        $errors += "Environment '$name' runner creation tag is inconsistent with ADE creation time."
        continue
      }
    }
  }
  $maximum = $created.AddHours(72)
  $expirationRaw = if ($environment.expirationDate) { $environment.expirationDate } elseif ($environment.expirationTime) { $environment.expirationTime } else { $null }
  $reason = $null
  if (-not $expirationRaw) {
    $desired = $taggedExpiration
    $reason = if ($usedRunnerBridge) { "APPLY_TAGGED_$([int]$taggedHours)H" } else { 'DEFAULT_24H' }
  }
  else {
    try { $current = [DateTimeOffset]::Parse([string]$expirationRaw).ToUniversalTime() }
    catch { $errors += "Environment '$name' has invalid expiration time."; continue }
    if ($current -gt $maximum) { $desired = $maximum; $reason = 'CLAMP_72H' }
  }
  if (-not $reason) { continue }
  $change = [ordered]@{ name = $name; userId = $userId; expiration = $desired.ToString('o'); reason = $reason; dryRun = $DryRun.IsPresent }
  $changes += $change
  if (-not $DryRun) {
    & az devcenter dev environment update-expiration-date --dev-center-name $env:ADE_DEVCENTER_NAME --project-name $env:ADE_PROJECT_NAME --name $name --user-id $userId --expiration $desired.ToString('o') --output none
    if ($LASTEXITCODE -ne 0) { $errors += "Failed to apply $reason to '$name'." }
  }
}
@{ changes = $changes; errors = $errors; evaluated = $environments.Count; dryRun = $DryRun.IsPresent } | ConvertTo-Json -Depth 8
if ($errors.Count -gt 0) { throw "ADE janitor completed with $($errors.Count) fail-closed error(s): $($errors -join ' ')" }
