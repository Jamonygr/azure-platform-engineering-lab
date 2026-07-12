[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$paths = @(
  (Join-Path $root 'scripts\GitHubTrust.ps1'),
  (Join-Path $root 'scripts\Set-GitHubPlatformConfiguration.ps1'),
  (Join-Path $root 'scripts\Publish-AdeCatalog.ps1'),
  (Join-Path $root 'scripts\Set-GeneratedRepository.ps1'),
  (Join-Path $root 'scripts\Publish-TemplateRepository.ps1'),
  (Join-Path $root 'scripts\New-GeneratedRepository.ps1'),
  (Join-Path $root 'scripts\Publish-Scaffold.ps1'),
  (Join-Path $root 'scripts\GitHubRepositoryProvenance.ps1'),
  (Join-Path $root 'scripts\Resolve-PendingRepository.ps1'),
  (Join-Path $root 'scripts\GitHubAppAuthentication.ps1'),
  (Join-Path $root 'scripts\GitHubAppPermissions.ps1')
)
foreach ($path in $paths) {
  $tokens = $null
  $errors = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
  if ($errors.Count -gt 0) { throw "PowerShell parse failure in $path`: $($errors[0].Message)" }
}

$trust = Get-Content -LiteralPath $paths[0] -Raw
foreach ($contract in @(
    'Resolve-GitHubPlatformAdmins',
    "@('admin', 'maintain', 'write', 'push')",
    'Set-GitHubCodeOwners',
    'Set-GitHubMainBranchProtection',
    'PlatformRequiredStatusChecks',
    'main must require the exact ten CI job contexts',
    'dismiss_stale_reviews',
    'require_code_owner_reviews',
    'require_last_push_approval',
    'bypass_pull_request_allowances',
    'allow_force_pushes',
    'allow_deletions',
    'required_conversation_resolution',
    'Set-GitHubDeploymentEnvironment',
    'custom_branch_policies',
    "name = 'main'; type = 'branch'",
    'lifecycle must not have required reviewers',
    'Assert-GitHubCommitReachableFromMain',
    'Set-GitHubAdeCatalogProtection',
    'Assert-GitHubAdeCatalogProtection'
  )) {
  if (-not $trust.Contains($contract)) { throw "GitHub trust contract is missing: $contract" }
}
$requiredChecks = @(
  'controller', 'scaffold', 'runner', 'terraform', 'terraform-docs',
  'terraform-lint', 'supply-chain', 'shell-container-helm',
  'documentation-links', 'workflow-policy'
)
$ci = Get-Content -LiteralPath (Join-Path $root '.github\workflows\ci.yml') -Raw
foreach ($check in $requiredChecks) {
  if (-not $trust.Contains("'$check'")) { throw "Required main status-check context is missing from GitHubTrust.ps1: $check" }
  if ($ci -notmatch "(?m)^  $([regex]::Escape($check)):\s*$") { throw "Required status-check job is missing from ci.yml: $check" }
}
if ($trust -notmatch 'required_status_checks\s+= \[ordered\]@\{') {
  throw 'main protection must configure required status checks rather than null.'
}

$configuration = Get-Content -LiteralPath $paths[1] -Raw
foreach ($contract in @(
    'PlatformAdmins is required in organization mode',
    'Repository-level PLATFORM_GITHUB_APP_PRIVATE_KEY is forbidden',
    'repos/$Repository/actions/organization-secrets?per_page=100',
    'Organization-level PLATFORM_GITHUB_APP_PRIVATE_KEY access is forbidden',
    'Assert-GitHubAppPermissions -Permissions $installation.permissions -OwnerMode $OwnerMode',
    "'platform-operations'     = `$true",
    "'lifecycle'               = `$false",
    "'aks-approval'            = `$true",
    "'destructive-operations' = `$true",
    'Set-GitHubDeploymentEnvironment',
    'Assert-GitHubAdeCatalogProtection'
  )) {
  if (-not $configuration.Contains($contract)) { throw "Repository configuration trust contract is missing: $contract" }
}

$publisher = Get-Content -LiteralPath $paths[2] -Raw
foreach ($contract in @(
    'Assert-GitHubCommitReachableFromMain',
    'Get-ReviewedTextBlob',
    'git/trees/$($baseCommit.tree.sha)?recursive=1',
    '$reviewedTree.tree',
    'actions/variables/PLATFORM_ADMINS',
    'Resolve-GitHubPlatformAdmins',
    'Set-GitHubAdeCatalogProtection',
    'Assert-GitHubAdeCatalogProtection',
    'parents = @($catalogHead)',
    'catalog-metadata.json',
    '$publishedMetadata',
    '$existingLeaves.Count -ne $pathEntries.Count',
    "[string]`$existing[0].mode -cne '100644'",
    'unexpected added or removed path',
    'V1 is an exact immutable subtree',
    'Published ADE definition $path is immutable',
    'new *-v2 path',
    'base_tree = $catalogHeadCommit.tree.sha',
    'force = $false'
  )) {
  if (-not $publisher.Contains($contract)) { throw "ADE publisher trust contract is missing: $contract" }
}
if ($publisher.Contains('force = $true')) { throw 'ADE catalog publication must never force-update its protected branch.' }
if ($publisher -match 'Get-Content|Get-ChildItem') {
  throw 'ADE catalog executable content must come from ReviewedCommit Git blobs, never the local working tree.'
}

$generated = Get-Content -LiteralPath $paths[3] -Raw
foreach ($contract in @(
    'custom_branch_policies = $true',
    'deployment-branch-policies',
    "@{ name = 'main'; type = 'branch' }",
    'Generated deployment environment must allow the exact main branch only.'
  )) {
  if (-not $generated.Contains($contract)) { throw "Generated-repository OIDC trust contract is missing: $contract" }
}

$templatePublisher = Get-Content -LiteralPath $paths[4] -Raw
foreach ($contract in @(
    'must already be public',
    "default_branch = 'main'",
    "new_name = 'main'",
    'must be public, marked as a template, and use main as its default branch'
  )) {
  if (-not $templatePublisher.Contains($contract)) { throw "Template publication contract is missing: $contract" }
}
if (-not $templatePublisher.Contains('Get-ChildItem -LiteralPath $baseDirectory -Force -File -Recurse')) {
  throw 'Template publication must include dot-directories such as .github and .platform on Linux runners.'
}

$generatedPublisher = Get-Content -LiteralPath $paths[5] -Raw
foreach ($contract in @(
    'Get-CanonicalTree',
    'Assert-ExactCanonicalTree',
    'Assert-AmbiguousRepositoryProvenance',
    'provenanceVerified',
    'attachment and deletion are forbidden'
  )) {
  if (-not $generatedPublisher.Contains($contract)) { throw "Generated canonical-tree verification is missing: $contract" }
}
$provenance = Get-Content -LiteralPath $paths[7] -Raw
foreach ($contract in @(
    'Get-GitBlobSha',
    "ContainsKey('.github/workflows/deploy.yml')",
    '?recursive=1',
    'Assert-AmbiguousRepositoryProvenance',
    '-not $Repository.template_repository',
    'exact GitHub template lineage is absent or mismatched',
    'Assert-ExactCanonicalTree'
  )) {
  if (-not $provenance.Contains($contract)) { throw "Immutable generated-repository provenance contract is missing: $contract" }
}
$pendingResolver = Get-Content -LiteralPath $paths[8] -Raw
foreach ($contract in @('Get-CanonicalTree', 'Assert-AmbiguousRepositoryProvenance', 'provenanceVerified = $true', 'attachment and deletion are forbidden')) {
  if (-not $pendingResolver.Contains($contract)) { throw "Pending repository resolution provenance contract is missing: $contract" }
}
$appAuthentication = Get-Content -LiteralPath $paths[9] -Raw
foreach ($contract in @(
    'Initialize-GitHubAppAuthentication',
    'Update-GitHubAppInstallationToken',
    'Remove-Item Env:PLATFORM_GITHUB_APP_PRIVATE_KEY',
    'New-GitHubAppJwt',
    '/access_tokens',
    'Assert-GitHubAppPermissions -Permissions $installation.permissions',
    'Assert-GitHubAppPermissions -Permissions $tokenResponse.permissions',
    'PlatformGitHubAppTokenExpiresAt',
    'MinimumValidityMinutes'
  )) {
  if (-not $appAuthentication.Contains($contract)) { throw "Refreshable GitHub App authentication contract is missing: $contract" }
}
$appPermissions = Get-Content -LiteralPath $paths[10] -Raw
foreach ($contract in @(
    'Get-ExpectedGitHubAppPermissions',
    "actions        = 'write'",
    "administration = 'write'",
    "contents       = 'write'",
    "metadata       = 'read'",
    "variables      = 'write'",
    "`$expected.members = 'read'",
    'unexpected.Count -gt 0',
    'actual.Count -ne $expected.Count'
  )) {
  if (-not $appPermissions.Contains($contract)) { throw "Exact GitHub App permission contract is missing: $contract" }
}
$lifecycle = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-Environment.ps1') -Raw
  foreach ($pattern in @(
    'Update-GitHubAppInstallationToken -MinimumValidityMinutes 15',
    '(?s)Update-GitHubAppInstallationToken\s+\$record = Invoke-Controller @\(''delete-repository''',
    '(?s)Update-GitHubAppInstallationToken\s+\$report = Invoke-Controller @\(''reconcile'''
  )) {
  if ($lifecycle -notmatch $pattern) { throw "Long-running lifecycle token refresh contract is missing: $pattern" }
}
foreach ($workflow in @('request-environment.yml', 'destroy-environment.yml', 'extend-environment.yml', 'reconcile-environments.yml', 'live-validation.yml')) {
  $workflowContent = Get-Content -LiteralPath (Join-Path $root ".github\workflows\$workflow") -Raw
  foreach ($contract in @('GENERATED_OWNER_MODE:', 'PLATFORM_GITHUB_APP_ID:', 'PLATFORM_GITHUB_APP_PRIVATE_KEY: ${{ secrets.PLATFORM_GITHUB_APP_PRIVATE_KEY }}')) {
    if (-not $workflowContent.Contains($contract)) { throw "$workflow lacks refreshable GitHub App provider input: $contract" }
  }
  if ($workflowContent.Contains('actions/create-github-app-token') -or $workflowContent -match 'steps\..*app-token\.outputs\.token') {
    throw "$workflow must mint through the exact-permission refresh provider rather than an unrestricted action token."
  }
}
$scaffoldPublisher = Get-Content -LiteralPath $paths[6] -Raw
if (($scaffoldPublisher | Select-String -Pattern 'Get-ChildItem .* -Force -File -Recurse' -AllMatches).Matches.Count -lt 2) {
  throw 'Scaffold base and overlay publication must include dot-directories on Linux runners.'
}

# Every external JavaScript or Docker action executes code in CI or a
# privileged deployment job. Only immutable commit/digest references pass.
$workflowFiles = @(
  Get-ChildItem -LiteralPath (Join-Path $root '.github') -Force -File -Recurse -Include *.yml,*.yaml
  Get-ChildItem -LiteralPath (Join-Path $root 'scaffolds') -Force -File -Recurse -Include *.yml,*.yaml
)
foreach ($workflowFile in $workflowFiles) {
  $lineNumber = 0
  foreach ($line in Get-Content -LiteralPath $workflowFile.FullName) {
    $lineNumber++
    if ($line -notmatch '^\s*(?:-\s*)?uses:\s*(?<reference>\S+)') { continue }
    $reference = $Matches.reference
    if ($reference.StartsWith('./')) { continue }
    if ($reference -match '^docker://[^@\s]+@sha256:[0-9a-f]{64}$') { continue }
    if ($reference -match '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@[0-9a-f]{40}$') { continue }
    throw "Mutable external action reference in $($workflowFile.FullName):$lineNumber`: $reference"
  }
}

$codeOwners = Join-Path $root '.github\CODEOWNERS'
if (Test-Path -LiteralPath $codeOwners) {
  $content = Get-Content -LiteralPath $codeOwners -Raw
  if ($content -match '@platform-admins|__PLATFORM') { throw 'Portable source must not ship a non-resolvable placeholder CODEOWNERS file.' }
}

$setup = Get-Content -LiteralPath (Join-Path $root 'docs\setup.md') -Raw
foreach ($contract in @(
    "--env `$environment",
    'Never create a repository- or organization-level copy',
    'last-push approval',
    'exact custom `main` deployment branch policy',
    '`lifecycle` reviewer-free'
  )) {
  if (-not $setup.Contains($contract)) { throw "Setup trust documentation is missing: $contract" }
}

Write-Host 'GitHub administrator, branch, environment-secret, and ADE catalog trust contracts are present and parse cleanly.'
