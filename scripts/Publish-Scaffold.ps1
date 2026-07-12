[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $RecordJson
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$record = $RecordJson | ConvertFrom-Json
if (-not $record.repository.nodeId -or -not $record.repository.numericId) { throw 'Immutable repository identity is required before publishing.' }
if (-not $env:GITHUB_TOKEN) { throw 'GITHUB_TOKEN is required.' }

$headers = @{
  Authorization = "Bearer $($env:GITHUB_TOKEN)"
  Accept = 'application/vnd.github+json'
  'X-GitHub-Api-Version' = '2026-03-10'
}
$owner = [uri]::EscapeDataString($record.repository.owner)
$name = [uri]::EscapeDataString($record.repository.name)
$api = "https://api.github.com/repos/$owner/$name"
$repository = Invoke-RestMethod -Uri $api -Headers $headers
if ([int64]$repository.id -ne [int64]$record.repository.numericId -or $repository.node_id -ne $record.repository.nodeId) {
  throw 'Repository identity changed before scaffold publication; failing closed.'
}
$branch = $repository.default_branch
$reference = Invoke-RestMethod -Uri "$api/git/ref/heads/$branch" -Headers $headers
$baseCommit = Invoke-RestMethod -Uri "$api/git/commits/$($reference.object.sha)" -Headers $headers

$sources = @()
$baseDirectory = Join-Path $root 'scaffolds/application/base'
if (-not (Test-Path $baseDirectory)) { throw 'Application scaffold base was not found.' }
Get-ChildItem -LiteralPath $baseDirectory -Force -File -Recurse | ForEach-Object {
  $relative = [IO.Path]::GetRelativePath($baseDirectory, $_.FullName).Replace('\', '/')
  if (-not $relative.StartsWith('.github/workflows/', [System.StringComparison]::OrdinalIgnoreCase)) {
    $sources += [pscustomobject]@{ Source = $_.FullName; Target = $relative }
  }
}
$overlayDirectory = Join-Path $root "scaffolds/application/overlays/$($record.goldenPath)"
if (-not (Test-Path $overlayDirectory)) { throw "Application scaffold overlay $($record.goldenPath) was not found." }
Get-ChildItem -LiteralPath $overlayDirectory -Force -File -Recurse | ForEach-Object {
  $relative = [IO.Path]::GetRelativePath($overlayDirectory, $_.FullName).Replace('\', '/')
  if (-not $relative.StartsWith('.github/workflows/', [System.StringComparison]::OrdinalIgnoreCase)) {
    $sources += [pscustomobject]@{ Source = $_.FullName; Target = $relative }
  }
}

$tokens = @{
  '__ENVIRONMENT_ID__' = $record.environmentId
  '__ENVIRONMENT_NAME__' = $record.environmentName
  '__GOLDEN_PATH__' = $record.goldenPath
  '__EXPIRES_AT__' = $record.expiresAt
  '__PLATFORM_REPOSITORY__' = $env:PLATFORM_REPOSITORY
  '__OWNER__' = $record.owner
}
$treeEntries = @()
foreach ($source in $sources) {
  $content = Get-Content -LiteralPath $source.Source -Raw
  foreach ($token in $tokens.Keys) { $content = $content.Replace($token, [string]$tokens[$token]) }
  $blobBody = @{ content = $content; encoding = 'utf-8' } | ConvertTo-Json
  $blob = Invoke-RestMethod -Method Post -Uri "$api/git/blobs" -Headers $headers -ContentType 'application/json' -Body $blobBody
  $treeEntries += @{ path = $source.Target; mode = '100644'; type = 'blob'; sha = $blob.sha }
}
$treeBody = @{ base_tree = $baseCommit.tree.sha; tree = $treeEntries } | ConvertTo-Json -Depth 8
$tree = Invoke-RestMethod -Method Post -Uri "$api/git/trees" -Headers $headers -ContentType 'application/json' -Body $treeBody
$commitBody = @{
  message = "Configure $($record.goldenPath) golden path for $($record.environmentId)"
  tree = $tree.sha
  parents = @($reference.object.sha)
} | ConvertTo-Json -Depth 5
$commit = Invoke-RestMethod -Method Post -Uri "$api/git/commits" -Headers $headers -ContentType 'application/json' -Body $commitBody
$updateBody = @{ sha = $commit.sha; force = $false } | ConvertTo-Json
& (Join-Path $PSScriptRoot 'Assert-ActiveLease.ps1') -Before 'moving the generated-repository branch to the rendered scaffold'
Invoke-RestMethod -Method Patch -Uri "$api/git/refs/heads/$branch" -Headers $headers -ContentType 'application/json' -Body $updateBody | Out-Null

Write-Host "Published selected scaffold in commit $($commit.sha)."
