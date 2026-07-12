[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$quiescePath = Join-Path $root 'scripts\Set-RepositoryQuiesced.ps1'
$syncPath = Join-Path $root 'scripts\Sync-AzureInventory.ps1'
$environmentPath = Join-Path $root 'scripts\Invoke-Environment.ps1'
$pendingPath = Join-Path $root 'scripts\Resolve-PendingRepository.ps1'
$resourceGraphPath = Join-Path $root 'scripts\AzureResourceGraph.ps1'
$lifecyclePath = Join-Path $root 'controller\src\lifecycle.ts'
$alertActionPath = Join-Path $root '.github\actions\open-platform-alert\action.yml'

foreach ($path in @($quiescePath, $syncPath, $environmentPath, $pendingPath, $resourceGraphPath)) {
  $tokens = $null
  $errors = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
  if ($errors.Count -gt 0) { throw "PowerShell parse failure in $path`: $($errors[0].Message)" }
}

$environment = Get-Content -LiteralPath $environmentPath -Raw
foreach ($contract in @(
    'AMBIGUOUS_REPOSITORY_CREATION: generated repository identity could not be persisted',
    'PRE_REPOSITORY_FAILURE',
    'REPOSITORY_GENERATION_POST_ATTEMPTED',
    'if ($repositoryIdentity.provenanceVerified -ne $true)',
    'pending repository lacks exact reviewed provenance proof',
    'Save-DeletedTombstone',
    'complete-tombstone-retention',
    '$blobName = "$($Record.environmentId)/tombstone/final.json"',
    "`$_.phase -eq 'DELETED' -and -not `$_.tombstoneRetainedAt",
    "`$record.phase -eq 'REQUESTED' -and -not `$record.repository -and `$record.lastErrorCode -ne 'PRE_REPOSITORY_FAILURE'",
    "`$pendingClaimCutoff = [DateTimeOffset]::UtcNow.AddMinutes(-15)"
  )) {
  if (-not $environment.Contains($contract)) { throw "Inventory-first repository recovery contract is missing: $contract" }
}
if ($environment.Contains('Remove-UntrackedRepositorySafely') -or $environment -match 'Invoke-RestMethod\s+-Method\s+Delete') {
  throw 'Invoke-Environment must never issue a direct repository DELETE outside the Azure-absence-gated controller path.'
}
if ($environment.Contains('elseif ($record.goldenPath -in') -and $environment.Contains('"apps/$($record.repository.numericId)"')) {
  throw 'Cleanup must consume the ACR repository inventoried during repository attachment, never derive it after a partial apply.'
}

$quiesce = Get-Content -LiteralPath $quiescePath -Raw
foreach ($contract in @(
    "`$activeStatuses = @('requested', 'queued', 'in_progress', 'waiting', 'pending')",
    'actions/runs?status=$encodedStatus&per_page=100',
    'Sort-Object -Property id -Unique',
    'Azure deletion is forbidden'
  )) {
  if (-not $quiesce.Contains($contract)) { throw "Generated-repository quiesce contract is missing: $contract" }
}
if ($quiesce.Contains('actions/runs?per_page=100')) {
  throw 'Quiesce must never rely on an unfiltered first page of workflow runs.'
}

$sync = Get-Content -LiteralPath $syncPath -Raw
foreach ($contract in @(
    'foreach ($resourceId in @($record.resourceIds))',
    'Microsoft\.Authorization/roleAssignments',
    'Microsoft\.Authorization/policyAssignments',
    'Microsoft\.Consumption/budgets',
    'federatedIdentityCredentials',
    'Microsoft\.Insights/diagnosticSettings',
    'Microsoft\.Resources/tags',
    'az acr repository show',
    'Tracked ACR image repository is missing',
    'Test-ExactNotFoundCode'
  )) {
  if (-not $sync.Contains($contract)) { throw "ACTIVE inventory reconciliation contract is missing: $contract" }
}
if ($sync.Contains('$taggableTypes')) {
  throw 'ACTIVE reconciliation must observe every tracked ID, not a taggable allowlist.'
}
if ($sync.Contains('az graph query')) { throw 'ACTIVE reconciliation must use the Azure Resource Graph ARM API without an extension dependency.' }
$absence = Get-Content -LiteralPath (Join-Path $root 'scripts\Test-AzureAbsence.ps1') -Raw
if ($absence.Contains('az graph query')) { throw 'Azure absence proof must use the Azure Resource Graph ARM API without an extension dependency.' }
$resourceGraph = Get-Content -LiteralPath $resourceGraphPath -Raw
foreach ($contract in @('Microsoft.ResourceGraph/resources?api-version=2024-04-01', 'AZURE_SUBSCRIPTION_ID', "resultFormat = 'objectArray'")) {
  if (-not $resourceGraph.Contains($contract)) { throw "Resource Graph REST contract is missing: $contract" }
}

$lifecycle = Get-Content -LiteralPath $lifecyclePath -Raw
foreach ($contract in @(
    'Microsoft.ContainerRegistry/registries/repositories',
    'acrRepositoryInventoryId',
    'ACR_INVENTORY_INCOMPLETE',
    'validateProvisioningInventory',
    'RESOURCE_GROUP_INVENTORY_MISMATCH',
    'RESOURCE_GROUP_ID_MISSING',
    'RESOURCE_SUBSCRIPTION_MISMATCH',
    'RESOURCE_INVENTORY_MISMATCH',
    'resourceGroupNames: record.resourceGroupNames',
    'resourceIds: record.resourceIds'
  )) {
  if (-not $lifecycle.Contains($contract)) { throw "PlatformResources residual inventory contract is missing: $contract" }
}

$alertAction = Get-Content -LiteralPath $alertActionPath -Raw
foreach ($contract in @('gh issue list', 'jq -r --arg title', 'gh issue comment', 'gh issue create', 'No credentials, application source, or Terraform state')) {
  if (-not $alertAction.Contains($contract)) { throw "Deduplicated lifecycle alert contract is missing: $contract" }
}
foreach ($workflow in @('request-environment.yml', 'destroy-environment.yml', 'extend-environment.yml', 'reconcile-environments.yml', 'heartbeat-watchdog.yml', 'live-validation.yml', 'ade-janitor.yml')) {
  $workflowContent = Get-Content -LiteralPath (Join-Path $root ".github\workflows\$workflow") -Raw
  if (-not $workflowContent.Contains('./.github/actions/open-platform-alert')) { throw "$workflow does not route failures to the central deduplicated issue action." }
}

foreach ($rootName in @('web-app-v1', 'container-app-v1', 'aks-workload-v1')) {
  $outputs = Get-Content -LiteralPath (Join-Path $root "golden-paths\$rootName\outputs.tf") -Raw
  if (-not $outputs.Contains('/providers/Microsoft.Insights/diagnosticSettings/')) {
    throw "$rootName must expose its diagnostic-setting ID in resource_ids."
  }
}

Write-Host 'Workflow quiesce, complete ACTIVE drift observation, diagnostic inventory, and ACR residual contracts are present.'
