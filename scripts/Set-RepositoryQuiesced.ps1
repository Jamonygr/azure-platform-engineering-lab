[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $RecordJson
)

$ErrorActionPreference = 'Stop'
$record = $RecordJson | ConvertFrom-Json
if (-not $record.repository) { return }
if (-not $env:GITHUB_TOKEN) { throw 'GITHUB_TOKEN is required to quiesce the generated repository.' }

$headers = @{
  Authorization = "Bearer $($env:GITHUB_TOKEN)"
  Accept = 'application/vnd.github+json'
  'X-GitHub-Api-Version' = '2026-03-10'
}
$query = @'
query RepositoryByNodeId($id: ID!) {
  node(id: $id) {
    ... on Repository { id databaseId name owner { login } }
  }
}
'@
$body = @{ query = $query; variables = @{ id = $record.repository.nodeId } } | ConvertTo-Json -Depth 5
& (Join-Path $PSScriptRoot 'Assert-ActiveLease.ps1') -Before 'observing the generated repository by immutable node ID'
$resolved = Invoke-RestMethod -Method Post -Uri 'https://api.github.com/graphql' -Headers $headers -ContentType 'application/json' -Body $body
if (@($resolved.errors).Count -gt 0) { throw 'GitHub GraphQL returned errors while resolving the immutable repository node ID; absence is not proven.' }
$dataProperty = $resolved.PSObject.Properties['data']
if (-not $dataProperty -or $null -eq $dataProperty.Value) { throw 'GitHub GraphQL response omitted repository data; absence is not proven.' }
$nodeProperty = $dataProperty.Value.PSObject.Properties['node']
if (-not $nodeProperty) { throw 'GitHub GraphQL response omitted the repository node field; absence is not proven.' }
$repository = $nodeProperty.Value
if (-not $repository) {
  # This is an authoritative null for the inventoried immutable node ID, not a
  # name lookup. Renew the lease immediately before returning the fact that the
  # caller will persist with its current Table ETag/fencing generation.
  & (Join-Path $PSScriptRoot 'Assert-ActiveLease.ps1') -Before 'recording immutable repository absence'
  [pscustomobject]@{
    status = 'repository-observed-absent'
    nodeId = [string]$record.repository.nodeId
  } | ConvertTo-Json -Compress
  return
}
if ($repository.id -ne $record.repository.nodeId -or [int64]$repository.databaseId -ne [int64]$record.repository.numericId) {
  throw 'Repository immutable identity mismatch; repository mutation is forbidden.'
}
if ($repository.owner.login.ToLowerInvariant() -ne $record.repository.owner.ToLowerInvariant() -or
    $repository.owner.login.ToLowerInvariant() -ne $env:GENERATED_REPOSITORY_OWNER.ToLowerInvariant()) {
  throw 'Repository was transferred or is outside the configured owner; repository mutation is forbidden.'
}

$owner = [uri]::EscapeDataString($repository.owner.login)
$name = [uri]::EscapeDataString($repository.name)
$api = "https://api.github.com/repos/$owner/$name"
$permissionsBody = @{ enabled = $false } | ConvertTo-Json
& (Join-Path $PSScriptRoot 'Assert-ActiveLease.ps1') -Before 'disabling generated-repository Actions'
Invoke-RestMethod -Method Put -Uri "$api/actions/permissions" -Headers $headers -ContentType 'application/json' -Body $permissionsBody | Out-Null
$activeStatuses = @('requested', 'queued', 'in_progress', 'waiting', 'pending')
$deadline = [DateTimeOffset]::UtcNow.AddMinutes(5)
$active = @()
do {
  & (Join-Path $PSScriptRoot 'Assert-ActiveLease.ps1') -Before 'waiting for generated-repository workflows to quiesce'
  $active = @()
  foreach ($status in $activeStatuses) {
    # Query one active status at a time. If a repository has more than 100
    # runs in a status, cancelling this page makes the next page become the
    # first page on the following pass; no completed run can hide it.
    $encodedStatus = [uri]::EscapeDataString($status)
    $remaining = Invoke-RestMethod -Uri "$api/actions/runs?status=$encodedStatus&per_page=100" -Headers $headers
    $active += @($remaining.workflow_runs | Where-Object { [string]$_.status -eq $status })
  }
  $active = @($active | Sort-Object -Property id -Unique)
  if ($active.Count -eq 0) { break }
  foreach ($run in $active) {
    & (Join-Path $PSScriptRoot 'Assert-ActiveLease.ps1') -Before 'cancelling a remaining generated-repository workflow run'
    try { Invoke-RestMethod -Method Post -Uri "$api/actions/runs/$($run.id)/cancel" -Headers $headers -ContentType 'application/json' -Body '{}' | Out-Null }
    catch {
      if ($_.Exception.Response.StatusCode.value__ -ne 409) { throw }
    }
  }
  if ([DateTimeOffset]::UtcNow.AddSeconds(10) -lt $deadline) { Start-Sleep -Seconds 10 }
} while ([DateTimeOffset]::UtcNow -lt $deadline)
if ($active.Count -ne 0) {
  $statusSummary = ($active | Group-Object status | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ', '
  throw "Timed out waiting for generated-repository workflow runs to stop ($statusSummary). Azure deletion is forbidden."
}
$archiveBody = @{ archived = $true } | ConvertTo-Json
& (Join-Path $PSScriptRoot 'Assert-ActiveLease.ps1') -Before 'archiving the generated repository'
Invoke-RestMethod -Method Patch -Uri $api -Headers $headers -ContentType 'application/json' -Body $archiveBody | Out-Null
Write-Host "Quiesced verified repository $($repository.owner.login)/$($repository.name)."
[pscustomobject]@{
  status = 'quiesced'
  nodeId = [string]$repository.id
} | ConvertTo-Json -Compress
