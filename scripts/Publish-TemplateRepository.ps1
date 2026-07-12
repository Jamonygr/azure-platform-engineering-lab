[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $Owner,
  [Parameter(Mandatory)] [ValidatePattern('^[a-z0-9](?:[a-z0-9-]{1,48}[a-z0-9])$')] [string] $Name,
  [ValidateSet('personal', 'organization')] [string] $OwnerMode = 'organization'
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$baseDirectory = Join-Path $root 'scaffolds/application/base'
if (-not (Test-Path $baseDirectory)) { throw 'Canonical application scaffold was not found.' }
& gh auth status | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Authenticate gh before publishing the template.' }

& gh api "repos/$Owner/$Name" --silent 2>$null
if ($LASTEXITCODE -ne 0) {
  $body = @{ name = $Name; description = 'Canonical public template for azure-platform-engineering-lab'; private = $false; auto_init = $true } | ConvertTo-Json
  if ($OwnerMode -eq 'personal') {
    $body | & gh api --method Post user/repos --input - | Out-Null
  }
  else {
    $body | & gh api --method Post "orgs/$Owner/repos" --input - | Out-Null
  }
  if ($LASTEXITCODE -ne 0) { throw "Could not create $Owner/$Name." }
}

function Invoke-GitHubJson {
  param(
    [Parameter(Mandatory)] [ValidateSet('Get', 'Post', 'Patch')] [string] $Method,
    [Parameter(Mandatory)] [string] $Endpoint,
    [object] $Body
  )
  $arguments = @('api', '-H', 'Accept: application/vnd.github+json', '-H', 'X-GitHub-Api-Version: 2026-03-10')
  if ($Method -ne 'Get') { $arguments += @('--method', $Method) }
  $arguments += $Endpoint
  if ($null -ne $Body) {
    $json = $Body | ConvertTo-Json -Depth 20 -Compress
    $response = $json | & gh @arguments --input - 2>&1
  }
  else { $response = & gh @arguments 2>&1 }
  if ($LASTEXITCODE -ne 0) { throw "GitHub API $Method $Endpoint failed: $($response | Out-String)" }
  return (($response | Out-String) | ConvertFrom-Json)
}

$repository = Invoke-GitHubJson -Method Get -Endpoint "repos/$Owner/$Name"
if ($repository.private) {
  throw 'The companion template repository must already be public; the publisher will not expose an existing private repository implicitly.'
}
$defaultBranch = [string]$repository.default_branch
if (-not $defaultBranch) { throw 'The template repository has no default branch.' }
if ($defaultBranch -ne 'main') {
  $existingMain = $false
  & gh api -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2026-03-10' "repos/$Owner/$Name/branches/main" --silent 2>$null
  $existingMain = $LASTEXITCODE -eq 0
  if ($existingMain) {
    Invoke-GitHubJson -Method Patch -Endpoint "repos/$Owner/$Name" -Body @{ default_branch = 'main' } | Out-Null
  }
  else {
    $encodedOriginalBranch = [uri]::EscapeDataString($defaultBranch)
    Invoke-GitHubJson -Method Post -Endpoint "repos/$Owner/$Name/branches/$encodedOriginalBranch/rename" -Body @{ new_name = 'main' } | Out-Null
  }
  $repository = Invoke-GitHubJson -Method Get -Endpoint "repos/$Owner/$Name"
  $defaultBranch = [string]$repository.default_branch
  if ($defaultBranch -ne 'main') { throw 'The template repository default branch could not be normalized to main.' }
}
$encodedBranch = [uri]::EscapeDataString($defaultBranch)
$currentRef = Invoke-GitHubJson -Method Get -Endpoint "repos/$Owner/$Name/git/ref/heads/$encodedBranch"
$currentCommit = [string]$currentRef.object.sha
if (-not $currentCommit) { throw 'Could not resolve the current template default-branch commit.' }

$treeEntries = @()
Get-ChildItem -LiteralPath $baseDirectory -Force -File -Recurse | Sort-Object FullName | ForEach-Object {
  $relative = [IO.Path]::GetRelativePath($baseDirectory, $_.FullName).Replace('\', '/')
  $content = [Convert]::ToBase64String([IO.File]::ReadAllBytes($_.FullName))
  $blob = Invoke-GitHubJson -Method Post -Endpoint "repos/$Owner/$Name/git/blobs" -Body @{ content = $content; encoding = 'base64' }
  $treeEntries += [ordered]@{ path = $relative; mode = '100644'; type = 'blob'; sha = [string]$blob.sha }
}

# Build a root tree without base_tree so files removed or renamed in the
# canonical scaffold cannot survive a repeat publication.
$newTree = Invoke-GitHubJson -Method Post -Endpoint "repos/$Owner/$Name/git/trees" -Body @{ tree = $treeEntries }
$currentCommitObject = Invoke-GitHubJson -Method Get -Endpoint "repos/$Owner/$Name/git/commits/$currentCommit"
if ([string]$currentCommitObject.tree.sha -ne [string]$newTree.sha) {
  $commit = Invoke-GitHubJson -Method Post -Endpoint "repos/$Owner/$Name/git/commits" -Body @{
    message = 'Synchronize canonical generated-application scaffold'
    tree    = [string]$newTree.sha
    parents = @($currentCommit)
  }
  Invoke-GitHubJson -Method Patch -Endpoint "repos/$Owner/$Name/git/refs/heads/$encodedBranch" -Body @{
    sha   = [string]$commit.sha
    force = $false
  } | Out-Null
}

@{ is_template = $true } | ConvertTo-Json | & gh api -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2026-03-10' --method Patch "repos/$Owner/$Name" --input - | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Could not mark the repository as a template.' }
$published = Invoke-GitHubJson -Method Get -Endpoint "repos/$Owner/$Name"
if (-not $published.is_template -or $published.private -or [string]$published.default_branch -ne 'main') {
  throw 'Template readback must be public, marked as a template, and use main as its default branch.'
}
Write-Host "Published public template https://github.com/$Owner/$Name"
