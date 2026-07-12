[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $RecordJson,
  [Parameter(Mandatory)] [string] $TerraformOutputFile,
  [switch] $Dispatch
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'GitHubAppAuthentication.ps1')
Initialize-GitHubAppAuthentication
Update-GitHubAppInstallationToken -MinimumValidityMinutes 15
$record = $RecordJson | ConvertFrom-Json
$outputs = Get-Content -LiteralPath $TerraformOutputFile -Raw | ConvertFrom-Json
if (-not $env:GITHUB_TOKEN) { throw 'GITHUB_TOKEN is required.' }
$headers = @{
  Authorization = "Bearer $($env:GITHUB_TOKEN)"
  Accept = 'application/vnd.github+json'
  'X-GitHub-Api-Version' = '2026-03-10'
}
function Update-GitHubRequestHeaders {
  Update-GitHubAppInstallationToken -MinimumValidityMinutes 15
  $script:headers['Authorization'] = "Bearer $($env:GITHUB_TOKEN)"
}
$owner = [uri]::EscapeDataString($record.repository.owner)
$name = [uri]::EscapeDataString($record.repository.name)
$api = "https://api.github.com/repos/$owner/$name"
$current = Invoke-RestMethod -Uri $api -Headers $headers
if ([int64]$current.id -ne [int64]$record.repository.numericId -or $current.node_id -ne $record.repository.nodeId) {
  throw 'Repository identity changed before configuration; failing closed.'
}

if ($env:GENERATED_OWNER_MODE -eq 'organization') {
  & (Join-Path $PSScriptRoot 'Assert-ActiveLease.ps1') -Before 'granting requester access to the generated repository'
  Invoke-WebRequest -Method Get -Uri "https://api.github.com/orgs/$($record.repository.owner)/members/$($record.owner)" -Headers $headers -SkipHttpErrorCheck -StatusCodeVariable membershipStatus | Out-Null
  if ($membershipStatus -ne 204) { throw 'Requester is no longer a current organization member; generated-repository access is not granted.' }
  $collaboratorBody = @{ permission = 'push' } | ConvertTo-Json
  Invoke-WebRequest -Method Put -Uri "$api/collaborators/$([uri]::EscapeDataString($record.owner))" -Headers $headers -ContentType 'application/json' -Body $collaboratorBody -SkipHttpErrorCheck -StatusCodeVariable collaboratorStatus | Out-Null
  if ($collaboratorStatus -notin @(201, 204)) { throw "Could not grant the requester push access to the generated repository (HTTP $collaboratorStatus)." }
  $permission = Invoke-RestMethod -Method Get -Uri "$api/collaborators/$([uri]::EscapeDataString($record.owner))/permission" -Headers $headers
  if ($permission.permission -notin @('admin', 'maintain', 'write', 'push')) {
    throw 'Requester push access is not effective yet; pending invitations are not accepted as a runnable self-service result.'
  }
}

& (Join-Path $PSScriptRoot 'Assert-ActiveLease.ps1') -Before 'configuring the generated repository'
$deploymentEnvironmentBody = @{
  wait_timer = 0
  prevent_self_review = $false
  reviewers = @()
  deployment_branch_policy = @{
    protected_branches = $false
    custom_branch_policies = $true
  }
} | ConvertTo-Json -Depth 5
Invoke-RestMethod -Method Put -Uri "$api/environments/deployment" -Headers $headers -ContentType 'application/json' -Body $deploymentEnvironmentBody | Out-Null

# The OIDC subject is intentionally environment-scoped. Restrict that
# environment to the exact main branch so a side branch cannot mint the same
# workload token through a copied workflow.
$policyApi = "$api/environments/deployment/deployment-branch-policies"
$existingPolicies = Invoke-RestMethod -Method Get -Uri "${policyApi}?per_page=100" -Headers $headers
foreach ($policy in @($existingPolicies.branch_policies)) {
  Invoke-RestMethod -Method Delete -Uri "$policyApi/$($policy.id)" -Headers $headers | Out-Null
}
$mainPolicy = @{ name = 'main'; type = 'branch' } | ConvertTo-Json
Invoke-RestMethod -Method Post -Uri $policyApi -Headers $headers -ContentType 'application/json' -Body $mainPolicy | Out-Null
$policyReadback = Invoke-RestMethod -Method Get -Uri "${policyApi}?per_page=100" -Headers $headers
if (@($policyReadback.branch_policies).Count -ne 1 -or [string]$policyReadback.branch_policies[0].name -ne 'main') {
  throw 'Generated deployment environment must allow the exact main branch only.'
}
$azureResourceName = if ($outputs.resource_name) { [string]$outputs.resource_name.value } elseif ($outputs.cluster_name) { [string]$outputs.cluster_name.value } else {
  $resourcePattern = if ($record.goldenPath -eq 'web-app') { '/providers/Microsoft\.Web/sites/[^/]+$' } elseif ($record.goldenPath -eq 'container-app') { '/providers/Microsoft\.App/containerApps/[^/]+$' } else { $null }
  $resourceId = if ($resourcePattern) { @($outputs.resource_ids.value | Where-Object { $_ -match $resourcePattern })[0] } else { $null }
  if ($resourceId) { ($resourceId -split '/')[-1] } else { '' }
}
$variables = [ordered]@{
  PLATFORM_READY = 'false'
  ENVIRONMENT_ID = $record.environmentId
  ENVIRONMENT_NAME = $record.environmentName
  REGION_NAME = $record.location
  GOLDEN_PATH = $record.goldenPath
  AZURE_CLIENT_ID = [string]$outputs.deployment_client_id.value
  AZURE_TENANT_ID = $env:AZURE_TENANT_ID
  AZURE_SUBSCRIPTION_ID = $env:AZURE_SUBSCRIPTION_ID
  ENDPOINT = [string]$outputs.endpoint.value
  RESOURCE_GROUP = [string]$outputs.resource_group_names.value[0]
  AZURE_RESOURCE_NAME = $azureResourceName
  IMAGE_REPOSITORY = if ($outputs.image_repository) { [string]$outputs.image_repository.value } else { '' }
}
if (-not $variables.AZURE_RESOURCE_NAME) { throw 'Terraform must output resource_name (Web/Container App) or cluster_name (AKS); list-based discovery is forbidden.' }
$sharedAcrName = if ($env:SHARED_ACR_ID) { ($env:SHARED_ACR_ID -split '/')[-1] } else { '' }
$variables.ACR_NAME = $sharedAcrName
foreach ($entry in $variables.GetEnumerator()) {
  $body = @{ name = $entry.Key; value = [string]$entry.Value } | ConvertTo-Json
  Invoke-RestMethod -Method Patch -Uri "$api/actions/variables/$($entry.Key)" -Headers $headers -ContentType 'application/json' -Body $body -SkipHttpErrorCheck -StatusCodeVariable patchStatus | Out-Null
  if ($patchStatus -eq 404) {
    Invoke-RestMethod -Method Post -Uri "$api/actions/variables" -Headers $headers -ContentType 'application/json' -Body $body | Out-Null
  }
  elseif ($patchStatus -notin @(201, 204)) { throw "Could not configure repository variable $($entry.Key)." }
}

# This flag is deliberately written last. Generated deployment jobs cannot authenticate before it is true.
& (Join-Path $PSScriptRoot 'Assert-ActiveLease.ps1') -Before 'activating the generated-repository workflow'
$readyBody = @{ name = 'PLATFORM_READY'; value = 'true' } | ConvertTo-Json
Invoke-RestMethod -Method Patch -Uri "$api/actions/variables/PLATFORM_READY" -Headers $headers -ContentType 'application/json' -Body $readyBody | Out-Null

if (-not $Dispatch) { return }
$dispatchStarted = [DateTimeOffset]::UtcNow.AddSeconds(-5)
$dispatchCorrelation = [guid]::NewGuid().ToString('D')
$dispatchTitle = "Deploy $($record.environmentId) / $dispatchCorrelation"
$dispatchBody = @{
  ref = $current.default_branch
  inputs = @{ platform_dispatch_id = $dispatchCorrelation }
} | ConvertTo-Json -Depth 4
& (Join-Path $PSScriptRoot 'Assert-ActiveLease.ps1') -Before 'dispatching the initial generated-repository deployment'
Invoke-RestMethod -Method Post -Uri "$api/actions/workflows/deploy.yml/dispatches" -Headers $headers -ContentType 'application/json' -Body $dispatchBody | Out-Null

$deadline = [DateTimeOffset]::UtcNow.AddMinutes(45)
$run = $null
$runId = $null
while (-not $runId -and [DateTimeOffset]::UtcNow -lt $deadline) {
  & (Join-Path $PSScriptRoot 'Assert-ActiveLease.ps1') -Before 'waiting for the generated-repository deployment'
  Update-GitHubRequestHeaders
  $runs = Invoke-RestMethod -Uri "$api/actions/workflows/deploy.yml/runs?event=workflow_dispatch&branch=$($current.default_branch)&per_page=100" -Headers $headers
  $run = $runs.workflow_runs |
    Where-Object { [DateTimeOffset]$_.created_at -ge $dispatchStarted -and $_.display_title -eq $dispatchTitle } |
    Sort-Object created_at -Descending |
    Select-Object -First 1
  if ($run) { $runId = [int64]$run.id; break }
  Start-Sleep -Seconds 15
}
if (-not $runId) { throw 'The correlated initial generated-repository deployment did not start within 45 minutes.' }

$safePropagationSteps = @(
  'Authenticate to Azure over OIDC',
  'Wait for Azure role readiness'
)
$maximumRunAttempts = 3
$minimumRunAttempt = 1
for ($controllerAttempt = 1; $controllerAttempt -le $maximumRunAttempts; $controllerAttempt++) {
  $run = $null
  while ([DateTimeOffset]::UtcNow -lt $deadline) {
    & (Join-Path $PSScriptRoot 'Assert-ActiveLease.ps1') -Before 'waiting for the generated-repository deployment'
    Update-GitHubRequestHeaders
    $candidate = Invoke-RestMethod -Uri "$api/actions/runs/$runId" -Headers $headers
    $candidateAttempt = if ($candidate.run_attempt) { [int]$candidate.run_attempt } else { 1 }
    if ($candidateAttempt -ge $minimumRunAttempt -and $candidate.status -eq 'completed') {
      $run = $candidate
      break
    }
    Start-Sleep -Seconds 15
  }
  if (-not $run) { throw 'Initial generated-repository deployment did not finish within 45 minutes.' }
  if ($run.conclusion -eq 'success') { break }

  Update-GitHubRequestHeaders
  $jobs = Invoke-RestMethod -Uri "$api/actions/runs/$runId/jobs?filter=latest&per_page=100" -Headers $headers
  $failedSteps = @(
    $jobs.jobs |
      ForEach-Object { $_.steps } |
      Where-Object { $_.conclusion -in @('failure', 'timed_out', 'cancelled') }
  )
  $unsafeFailures = @($failedSteps | Where-Object { $_.name -notin $safePropagationSteps })
  if ($failedSteps.Count -eq 0 -or $unsafeFailures.Count -gt 0) {
    throw "Initial generated-repository deployment concluded $($run.conclusion) outside the non-mutating propagation gates: $($run.html_url)"
  }
  if ($controllerAttempt -eq $maximumRunAttempts) {
    throw "Initial generated-repository deployment exhausted $maximumRunAttempts safe propagation attempts: $($run.html_url)"
  }

  # Only authentication/readiness failures are re-run. Every application mutation
  # follows those named steps, so a failed deploy is never automatically repeated.
  & (Join-Path $PSScriptRoot 'Assert-ActiveLease.ps1') -Before 'retrying generated-repository authentication propagation'
  Update-GitHubRequestHeaders
  $rerunBody = @{ enable_debug_logging = $false } | ConvertTo-Json
  Invoke-WebRequest -Method Post -Uri "$api/actions/runs/$runId/rerun-failed-jobs" -Headers $headers -ContentType 'application/json' -Body $rerunBody -SkipHttpErrorCheck -StatusCodeVariable rerunStatus | Out-Null
  if ($rerunStatus -ne 201) { throw "GitHub rejected the bounded propagation retry (HTTP $rerunStatus)." }
  $completedRunAttempt = if ($run.run_attempt) { [int]$run.run_attempt } else { 1 }
  $minimumRunAttempt = $completedRunAttempt + 1
  $retryDelay = 15 * [math]::Pow(2, $controllerAttempt - 1)
  Start-Sleep -Seconds ([int][math]::Min($retryDelay, 60))
}
if (-not $run -or $run.conclusion -ne 'success') { throw 'Initial generated-repository deployment did not complete successfully.' }

$healthUri = ([string]$outputs.endpoint.value).TrimEnd('/') + '/healthz'
$healthDeadline = [DateTimeOffset]::UtcNow.AddMinutes(10)
do {
  & (Join-Path $PSScriptRoot 'Assert-ActiveLease.ps1') -Before 'smoke-testing the generated endpoint'
  try {
    $response = Invoke-WebRequest -Uri $healthUri -TimeoutSec 20
    if ($response.StatusCode -eq 200) { Write-Host "Smoke test passed: $healthUri"; return }
  }
  catch { Write-Host "Endpoint not ready yet: $($_.Exception.Message)" }
  Start-Sleep -Seconds 15
} while ([DateTimeOffset]::UtcNow -lt $healthDeadline)
throw "HTTPS health check did not succeed: $healthUri"
