[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $RecordJson
)

$ErrorActionPreference = 'Stop'
$record = $RecordJson | ConvertFrom-Json
if (-not $record.repository.nodeId -or -not $record.repository.numericId) { throw 'Immutable repository identity is required to update expiry metadata.' }
if (-not $env:GITHUB_TOKEN) { throw 'GITHUB_TOKEN is required to update generated-repository expiry metadata.' }
if (-not $env:GENERATED_REPOSITORY_OWNER) { throw 'GENERATED_REPOSITORY_OWNER is required.' }

$headers = @{
  Authorization = "Bearer $($env:GITHUB_TOKEN)"
  Accept = 'application/vnd.github+json'
  'X-GitHub-Api-Version' = '2026-03-10'
}
$query = @'
query RepositoryForExpiry($id: ID!) {
  node(id: $id) {
    ... on Repository { id databaseId name owner { login } defaultBranchRef { name } }
  }
}
'@
$queryBody = @{ query = $query; variables = @{ id = $record.repository.nodeId } } | ConvertTo-Json -Depth 5
$response = Invoke-RestMethod -Method Post -Uri 'https://api.github.com/graphql' -Headers $headers -ContentType 'application/json' -Body $queryBody
$repository = $response.data.node
if (-not $repository) { throw 'Repository node ID is unresolvable; expiry metadata mutation is forbidden.' }
if ($repository.id -ne $record.repository.nodeId -or [int64]$repository.databaseId -ne [int64]$record.repository.numericId) {
  throw 'Repository immutable identity mismatch; expiry metadata mutation is forbidden.'
}
if ($repository.owner.login.ToLowerInvariant() -ne $record.repository.owner.ToLowerInvariant() -or
    $repository.owner.login.ToLowerInvariant() -ne $env:GENERATED_REPOSITORY_OWNER.ToLowerInvariant()) {
  throw 'Repository was transferred or is outside the configured owner; expiry metadata mutation is forbidden.'
}
if (-not $repository.defaultBranchRef.name) { throw 'Generated repository has no resolvable default branch.' }

$owner = [uri]::EscapeDataString($repository.owner.login)
$name = [uri]::EscapeDataString($repository.name)
$api = "https://api.github.com/repos/$owner/$name"
$metadataPath = '.platform/environment.json'
$encodedPath = [uri]::EscapeDataString($metadataPath).Replace('%2F', '/')
$existing = Invoke-RestMethod -Method Get -Uri "$api/contents/${encodedPath}?ref=$([uri]::EscapeDataString($repository.defaultBranchRef.name))" -Headers $headers
$content = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(([string]$existing.content -replace '\s', '')))
$metadata = $content | ConvertFrom-Json
if ($metadata.environmentId -ne $record.environmentId -or $metadata.managed -ne $true) {
  throw 'Generated-repository metadata does not match the authoritative environment identity.'
}
$metadata.expiresAt = $record.expiresAt
$updatedContent = $metadata | ConvertTo-Json -Depth 10
$updateBody = @{
  message = "chore(platform): extend $($record.environmentId) [skip ci]"
  content = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($updatedContent + "`n"))
  sha = $existing.sha
  branch = $repository.defaultBranchRef.name
} | ConvertTo-Json
& (Join-Path $PSScriptRoot 'Assert-ActiveLease.ps1') -Before 'committing generated-repository expiry metadata'
Invoke-RestMethod -Method Put -Uri "$api/contents/$encodedPath" -Headers $headers -ContentType 'application/json' -Body $updateBody | Out-Null

$variableBody = @{ name = 'EXPIRES_AT'; value = [string]$record.expiresAt } | ConvertTo-Json
Invoke-RestMethod -Method Patch -Uri "$api/actions/variables/EXPIRES_AT" -Headers $headers -ContentType 'application/json' -Body $variableBody -SkipHttpErrorCheck -StatusCodeVariable patchStatus | Out-Null
if ($patchStatus -eq 404) {
  Invoke-RestMethod -Method Post -Uri "$api/actions/variables" -Headers $headers -ContentType 'application/json' -Body $variableBody | Out-Null
}
elseif ($patchStatus -notin @(201, 204)) { throw 'Could not update the generated-repository EXPIRES_AT variable.' }

Write-Host "Updated verified repository expiry metadata to $($record.expiresAt)."
