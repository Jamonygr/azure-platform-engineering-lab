[CmdletBinding()]
param(
  [Parameter(Mandatory)] [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')] [string] $Repository,
  [Parameter(Mandatory)] [string] $RunnerImage,
  [Parameter(Mandatory)] [string] $LogAnalyticsWorkspaceIdsJson,
  [Parameter(Mandatory)] [string] $ActionGroupId,
  [Parameter(Mandatory)] [string] $PlatformAdminEmail,
  [Parameter(Mandatory)] [string] $SharedAcrId,
  [Parameter(Mandatory)] [string] $DeveloperGroupObjectId,
  [string] $PolicyDefinitionIdsJson = '{}',
  [ValidatePattern('^[0-9a-f]{40}$')] [string] $ReviewedCommit,
  [ValidateSet('ade-catalog')] [string] $Branch = 'ade-catalog'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'GitHubTrust.ps1')
if ($RunnerImage -notmatch '^[a-z0-9]+\.azurecr\.io/[a-z0-9]+(?:[._/-][a-z0-9]+)*@sha256:[0-9a-f]{64}$') {
  throw 'RunnerImage must be a private ACR reference pinned by sha256 digest; movable tags are forbidden.'
}
try { $PolicyDefinitionIdsJson = ($PolicyDefinitionIdsJson | ConvertFrom-Json -AsHashtable | ConvertTo-Json -Compress) }
catch { throw 'PolicyDefinitionIdsJson must be a JSON object.' }
try { $workspaceIds = $LogAnalyticsWorkspaceIdsJson | ConvertFrom-Json -AsHashtable }
catch { throw 'LogAnalyticsWorkspaceIdsJson must be a JSON object.' }
$requiredWorkspaceLocations = @('westeurope', 'northeurope', 'germanywestcentral')
if ($workspaceIds.Count -ne $requiredWorkspaceLocations.Count) { throw 'LogAnalyticsWorkspaceIdsJson must contain exactly the three allowed EU locations.' }
foreach ($location in $requiredWorkspaceLocations) {
  if ([string]$workspaceIds[$location] -notmatch '(?i)^/subscriptions/[0-9a-f-]{36}/resourceGroups/[^/]+/providers/Microsoft\.OperationalInsights/workspaces/[^/]+$') {
    throw "LogAnalyticsWorkspaceIdsJson lacks a valid workspace ID for $location."
  }
}
$LogAnalyticsWorkspaceIdsJson = $workspaceIds | ConvertTo-Json -Compress
if (-not $ReviewedCommit) {
  $ReviewedCommit = (& gh api "repos/$Repository/commits/main" --jq '.sha').Trim()
}
if ($ReviewedCommit -notmatch '^[0-9a-f]{40}$') { throw 'Could not resolve a reviewed source commit.' }
Assert-GitHubCommitReachableFromMain -Repository $Repository -Commit $ReviewedCommit
$baseCommit = Invoke-PlatformGitHubApi -Method Get -Endpoint "repos/$Repository/git/commits/$ReviewedCommit"
$reviewedTree = Invoke-PlatformGitHubApi -Method Get -Endpoint "repos/$Repository/git/trees/$($baseCommit.tree.sha)?recursive=1"
if ($reviewedTree.truncated) { throw 'The reviewed source tree is truncated; catalog provenance cannot be proven.' }

function Get-ReviewedTextBlob {
  param([Parameter(Mandatory)] [string] $Path)
  $matches = @($reviewedTree.tree | Where-Object { $_.type -eq 'blob' -and [string]$_.path -ceq $Path })
  if ($matches.Count -ne 1) { throw "Reviewed commit must contain exactly one text blob at $Path." }
  $blob = Invoke-PlatformGitHubApi -Method Get -Endpoint "repos/$Repository/git/blobs/$($matches[0].sha)"
  if ([string]$blob.encoding -ne 'base64') { throw "Reviewed blob $Path did not use GitHub base64 encoding." }
  try {
    $bytes = [Convert]::FromBase64String(([string]$blob.content -replace '\s', ''))
    $utf8 = [Text.UTF8Encoding]::new($false, $true)
    return $utf8.GetString($bytes)
  }
  catch { throw "Reviewed blob $Path is not valid UTF-8 text." }
}
$adminVariable = Invoke-PlatformGitHubApi -Method Get -Endpoint "repos/$Repository/actions/variables/PLATFORM_ADMINS"
if (-not $adminVariable.value) { throw 'PLATFORM_ADMINS must be configured before ADE catalog publication.' }
$catalogAdmins = @(Resolve-GitHubPlatformAdmins -Repository $Repository -PlatformAdmins ([string]$adminVariable.value) -OwnerMode organization)
$mainProtection = Assert-GitHubMainBranchProtection -Repository $Repository -ExpectedAdmins $catalogAdmins

$branchEndpoint = "repos/$Repository/git/ref/heads/$Branch"
$newCatalogBranch = -not (Test-PlatformGitHubEndpoint -Endpoint $branchEndpoint)
if ($newCatalogBranch) {
  Invoke-PlatformGitHubApi -Method Post -Endpoint "repos/$Repository/git/refs" -Body @{ ref = "refs/heads/$Branch"; sha = $ReviewedCommit } | Out-Null
  # A protection rule cannot be attached before the branch exists. Protect it
  # immediately and then prove its head did not move during that bootstrap gap.
  Set-GitHubAdeCatalogProtection -Repository $Repository
}
else {
  # Never repair and then trust a previously weak/unprotected catalog branch:
  # the existing restriction must already be exact before its head is a parent.
  Assert-GitHubAdeCatalogProtection -Repository $Repository -ExpectedMainProtection $mainProtection | Out-Null
}
$catalogRef = Invoke-PlatformGitHubApi -Method Get -Endpoint $branchEndpoint
$catalogHead = [string]$catalogRef.object.sha
if ($catalogHead -notmatch '^[0-9a-f]{40}$') { throw 'Could not resolve the protected ADE catalog branch head.' }
if ($newCatalogBranch -and $catalogHead -ne $ReviewedCommit) {
  throw 'The new ADE catalog branch moved before protection was verified; publication is forbidden.'
}
$catalogHeadCommit = Invoke-PlatformGitHubApi -Method Get -Endpoint "repos/$Repository/git/commits/$catalogHead"
$catalogHeadTree = Invoke-PlatformGitHubApi -Method Get -Endpoint "repos/$Repository/git/trees/$($catalogHeadCommit.tree.sha)?recursive=1"
if ($catalogHeadTree.truncated) { throw 'The existing ADE catalog tree is truncated; version immutability cannot be proven.' }
$publishedMetadata = @($catalogHeadTree.tree | Where-Object {
  $_.type -eq 'blob' -and [string]$_.path -ceq 'ade/catalog/catalog-metadata.json'
}).Count -eq 1
$enforceV1Immutability = -not $newCatalogBranch
if ($enforceV1Immutability -and -not $publishedMetadata) {
  throw 'The existing protected ADE catalog branch lacks catalog-metadata.json. Its publication history is ambiguous, so v1 replacement is forbidden; recover through the approved break-glass runbook rather than treating it as a first publication.'
}

$tokens = [ordered]@{
  '__ADE_RUNNER_IMAGE__' = $RunnerImage
  '__LOG_ANALYTICS_WORKSPACE_IDS_JSON__' = $LogAnalyticsWorkspaceIdsJson
  '__ACTION_GROUP_ID__' = $ActionGroupId
  '__PLATFORM_ADMIN_EMAIL__' = $PlatformAdminEmail
  '__SHARED_ACR_ID__' = $SharedAcrId
  '__DEVELOPER_GROUP_OBJECT_ID__' = $DeveloperGroupObjectId
  '__POLICY_DEFINITION_IDS_JSON__' = $PolicyDefinitionIdsJson
}
$paths = @('web-app-v1', 'container-app-v1', 'aks-workload-v1')
$entries = @()
foreach ($path in $paths) {
  $manifestPath = "ade/catalog/$path/environment.yaml"
  $manifest = Get-ReviewedTextBlob -Path $manifestPath
  foreach ($token in $tokens.Keys) { $manifest = $manifest.Replace($token, [string]$tokens[$token]) }
  if ($manifest -match '__[A-Z0-9_]+__') { throw "Catalog manifest $path contains unresolved render tokens." }
  $sources = @([pscustomobject]@{ Target = "ade/catalog/$path/environment.yaml"; Content = $manifest })
  $terraformPrefix = "golden-paths/$path/"
  $terraformSources = @($reviewedTree.tree |
    Where-Object {
      $_.type -eq 'blob' -and [string]$_.path -like "$terraformPrefix*" -and
      ([string]$_.path).Substring($terraformPrefix.Length) -notmatch '/' -and
      (([string]$_.path).EndsWith('.tf') -or ([string]$_.path).EndsWith('/.terraform.lock.hcl'))
    } |
    Sort-Object path)
  if ($terraformSources.Count -eq 0 -or -not @($terraformSources | Where-Object path -eq "${terraformPrefix}.terraform.lock.hcl").Count) {
    throw "Reviewed commit lacks the Terraform root or lockfile for $path."
  }
  $terraformSources |
    ForEach-Object {
      $name = ([string]$_.path).Substring($terraformPrefix.Length)
      $sources += [pscustomobject]@{ Target = "ade/catalog/$path/$name"; Content = (Get-ReviewedTextBlob -Path ([string]$_.path)) }
    }
  $assetFolders = @('node')
  if ($path -eq 'aks-workload-v1') { $assetFolders += 'helm' }
  foreach ($assetFolder in $assetFolders) {
    $assetPrefix = "runner/ade-terraform/sample/$assetFolder/"
    $assetSources = @($reviewedTree.tree |
      Where-Object { $_.type -eq 'blob' -and [string]$_.path -like "$assetPrefix*" } |
      Sort-Object path)
    if ($assetSources.Count -eq 0) { throw "Reviewed commit lacks fixed sample assets under $assetPrefix." }
    $assetSources |
      ForEach-Object {
        $relative = ([string]$_.path).Substring($assetPrefix.Length)
        $sources += [pscustomobject]@{
          Target = "ade/catalog/$path/sample/$assetFolder/$relative"
          Content = (Get-ReviewedTextBlob -Path ([string]$_.path))
        }
      }
  }
  $pathEntries = @()
  foreach ($source in $sources) {
    $blob = Invoke-PlatformGitHubApi -Method Post -Endpoint "repos/$Repository/git/blobs" -Body @{ content = $source.Content; encoding = 'utf-8' }
    $entry = @{ path = $source.Target; mode = '100644'; type = 'blob'; sha = [string]$blob.sha }
    $pathEntries += $entry
    $entries += $entry
  }
  if (@($pathEntries.path | Group-Object | Where-Object Count -ne 1).Count -gt 0) {
    throw "Rendered ADE definition $path contains duplicate target paths."
  }
  if ($enforceV1Immutability) {
    $definitionPrefix = "ade/catalog/$path/"
    $existingLeaves = @($catalogHeadTree.tree | Where-Object {
      ([string]$_.path).StartsWith($definitionPrefix, [StringComparison]::Ordinal) -and $_.type -ne 'tree'
    })
    if ($existingLeaves.Count -ne $pathEntries.Count) {
      throw "Published ADE definition $path has an unexpected added or removed path. V1 is an exact immutable subtree; release changes under a new *-v2 path."
    }
    foreach ($expected in $pathEntries) {
      $existing = @($existingLeaves | Where-Object { [string]$_.path -ceq [string]$expected.path })
      if ($existing.Count -ne 1 -or [string]$existing[0].type -cne 'blob' -or
          [string]$existing[0].mode -cne '100644' -or [string]$existing[0].sha -cne [string]$expected.sha) {
        throw "Published ADE definition $path is immutable. Breaking runner, module, manifest, mode, input, sample, addition, or removal changes must be released under a new *-v2 path; live v1 content is retained."
      }
    }
  }
}
$metadata = @{ sourceCommit = $ReviewedCommit; runnerImage = $RunnerImage; generatedAt = [DateTimeOffset]::UtcNow.ToString('o'); compatibility = 'ADE maintenance mode' } | ConvertTo-Json
$metadataBlob = Invoke-PlatformGitHubApi -Method Post -Endpoint "repos/$Repository/git/blobs" -Body @{ content = $metadata; encoding = 'utf-8' }
$entries += @{ path = 'ade/catalog/catalog-metadata.json'; mode = '100644'; type = 'blob'; sha = $metadataBlob.sha }

$tree = Invoke-PlatformGitHubApi -Method Post -Endpoint "repos/$Repository/git/trees" -Body @{ base_tree = $catalogHeadCommit.tree.sha; tree = $entries }
$commit = Invoke-PlatformGitHubApi -Method Post -Endpoint "repos/$Repository/git/commits" -Body @{ message = "Generate ADE v1 catalog from $ReviewedCommit"; tree = $tree.sha; parents = @($catalogHead) }
if (-not $commit.sha) { throw 'Could not create the generated ADE catalog commit.' }
Invoke-PlatformGitHubApi -Method Patch -Endpoint "repos/$Repository/git/refs/heads/$Branch" -Body @{ sha = $commit.sha; force = $false } | Out-Null
Assert-GitHubAdeCatalogProtection -Repository $Repository -ExpectedMainProtection $mainProtection | Out-Null
$publishedRef = Invoke-PlatformGitHubApi -Method Get -Endpoint $branchEndpoint
if ([string]$publishedRef.object.sha -ne [string]$commit.sha) { throw 'ADE catalog branch readback did not match the generated commit.' }
Write-Output "Published $Repository@$Branch catalog from reviewed commit $ReviewedCommit with runner $RunnerImage"
