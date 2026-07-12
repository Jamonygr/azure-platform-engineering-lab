[CmdletBinding()]
param(
  [Parameter(Mandatory)] [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')] [string] $Repository,
  [Parameter(Mandatory)] [string] $GeneratedRepositoryOwner,
  [Parameter(Mandatory)] [string] $TemplateRepositoryOwner,
  [Parameter(Mandatory)] [string] $TemplateRepositoryName,
  [Parameter(Mandatory)] [string] $GitHubAppId,
  [Parameter(Mandatory)] [ValidatePattern('^[^@\s]+@[^@\s]+\.[^@\s]+$')] [string] $PlatformAdminEmail,
  [Parameter(Mandatory)] [ValidatePattern('^[a-z0-9]{4,10}$')] [string] $PlatformUniqueSuffix,
  [string] $PlatformAdmins,
  [string] $OrganizationRequesters,
  [string] $DeveloperGroupObjectId,
  [ValidateSet('personal', 'organization')] [string] $OwnerMode = 'organization',
  [switch] $DisableRepositoryDeletion,
  [switch] $EnableAde
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $PSScriptRoot 'GitHubTrust.ps1')
. (Join-Path $PSScriptRoot 'GitHubAppPermissions.ps1')
if ($OwnerMode -eq 'organization') {
  if (-not $OrganizationRequesters) { throw 'OrganizationRequesters is required in organization mode and must list reviewed current organization members.' }
  if (-not $PlatformAdmins) { throw 'PlatformAdmins is required in organization mode and must identify real repository-admin users.' }
  if ($Repository.Split('/', 2)[0].ToLowerInvariant() -ne $GeneratedRepositoryOwner.ToLowerInvariant()) {
    throw 'Organization mode requires the platform repository and generated repositories to use the same owner.'
  }
}
foreach ($command in @('gh', 'az', 'terraform')) {
  if (-not (Get-Command $command -ErrorAction SilentlyContinue)) { throw "$command is required." }
}
& gh auth status | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Authenticate gh before configuring the repository.' }
if ($OwnerMode -eq 'organization') {
  $installationResponse = & gh api "orgs/$GeneratedRepositoryOwner/installations?per_page=100" 2>&1
  if ($LASTEXITCODE -ne 0) { throw "Could not inspect GitHub App installation scope for $GeneratedRepositoryOwner. $($installationResponse | Out-String)" }
  $installations = ($installationResponse | Out-String) | ConvertFrom-Json
  $installation = @($installations.installations | Where-Object { [string]$_.app_id -eq [string]$GitHubAppId }) | Select-Object -First 1
  if (-not $installation) { throw "GitHub App $GitHubAppId is not installed on organization $GeneratedRepositoryOwner." }
}
else {
  $authenticatedLogin = & gh api user --jq '.login' 2>&1
  if ($LASTEXITCODE -ne 0 -or -not $authenticatedLogin) { throw "Could not resolve the authenticated GitHub account. $($authenticatedLogin | Out-String)" }
  if ([string]$authenticatedLogin -ine $GeneratedRepositoryOwner) {
    throw 'Personal mode requires the authenticated GitHub account to be the generated-repository owner.'
  }
  $installationResponse = & gh api 'user/installations?per_page=100' 2>&1
  if ($LASTEXITCODE -ne 0) { throw "Could not inspect personal GitHub App installations. $($installationResponse | Out-String)" }
  $installations = ($installationResponse | Out-String) | ConvertFrom-Json
  $installation = @($installations.installations | Where-Object {
    [string]$_.app_id -eq [string]$GitHubAppId -and [string]$_.account.login -ieq $GeneratedRepositoryOwner
  }) | Select-Object -First 1
  if (-not $installation) { throw "GitHub App $GitHubAppId is not installed on personal account $GeneratedRepositoryOwner." }
}
if ($installation.repository_selection -ne 'all') {
  throw 'The GitHub App installation must use All repositories so future generated repositories are immediately manageable.'
}
Assert-GitHubAppPermissions -Permissions $installation.permissions -OwnerMode $OwnerMode

$admins = @(Resolve-GitHubPlatformAdmins -Repository $Repository -PlatformAdmins $PlatformAdmins -OwnerMode $OwnerMode)
$PlatformAdmins = ($admins.Login -join ',')

$repositorySecretNames = @(& gh api -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2026-03-10' --paginate "repos/$Repository/actions/secrets?per_page=100" --jq '.secrets[].name' 2>&1)
if ($LASTEXITCODE -ne 0) { throw "Could not inspect repository Actions secrets. $($repositorySecretNames | Out-String)" }
if (@($repositorySecretNames | Where-Object { [string]$_ -eq 'PLATFORM_GITHUB_APP_PRIVATE_KEY' }).Count -gt 0) {
  throw 'Repository-level PLATFORM_GITHUB_APP_PRIVATE_KEY is forbidden. Delete it and store separate copies only as environment secrets in lifecycle, aks-approval, and destructive-operations.'
}
if ($OwnerMode -eq 'organization') {
  $organizationSecretNames = @(& gh api -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2026-03-10' --paginate "repos/$Repository/actions/organization-secrets?per_page=100" --jq '.secrets[].name' 2>&1)
  if ($LASTEXITCODE -ne 0) { throw "Could not inspect organization Actions secrets accessible to this repository. $($organizationSecretNames | Out-String)" }
  if (@($organizationSecretNames | Where-Object { [string]$_ -eq 'PLATFORM_GITHUB_APP_PRIVATE_KEY' }).Count -gt 0) {
    throw 'Organization-level PLATFORM_GITHUB_APP_PRIVATE_KEY access is forbidden for the platform repository. Remove this repository from that secret and keep separate copies only in lifecycle, aks-approval, and destructive-operations.'
  }
}

# Install validated catch-all ownership before enabling code-owner protection.
Set-GitHubCodeOwners -Repository $Repository -Admins $admins
Set-GitHubMainBranchProtection -Repository $Repository -Admins $admins -OwnerMode $OwnerMode

$environmentReview = [ordered]@{
  'platform-operations'     = $true
  'lifecycle'               = $false
  'aks-approval'            = $true
  'destructive-operations' = $true
}
foreach ($entry in $environmentReview.GetEnumerator()) {
  Set-GitHubDeploymentEnvironment -Repository $Repository -Environment $entry.Key -Admins $admins -RequireReviewers $entry.Value
}
if ($EnableAde) {
  if ($OwnerMode -ne 'organization') { throw 'ADE catalog publication is supported only in organization mode because trusted push restrictions are required.' }
  if (-not (Test-PlatformGitHubEndpoint -Endpoint "repos/$Repository/git/ref/heads/ade-catalog")) {
    throw 'ENABLE_ADE cannot be set until Publish-AdeCatalog.ps1 creates and protects ade-catalog.'
  }
  $mainProtection = Assert-GitHubMainBranchProtection -Repository $Repository -ExpectedAdmins $admins
  Assert-GitHubAdeCatalogProtection -Repository $Repository -ExpectedMainProtection $mainProtection | Out-Null
}

$bootstrap = & terraform "-chdir=$(Join-Path $root 'bootstrap')" output -json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw 'Read the applied bootstrap outputs first.' }
$platform = & terraform "-chdir=$(Join-Path $root 'platform')" output -json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw 'Read the applied platform outputs first.' }
$account = & az account show --output json | ConvertFrom-Json
$backend = $bootstrap.backend.value

$variables = [ordered]@{
  AZURE_SUBSCRIPTION_ID = $account.id
  AZURE_TENANT_ID = $account.tenantId
  AZURE_PLATFORM_CLIENT_ID = $bootstrap.platform_identity.value.client_id
  AZURE_LIFECYCLE_CLIENT_ID = $platform.lifecycle_identity.value.client_id
  INVENTORY_STORAGE_ACCOUNT = $backend.storage_account_name
  TF_STATE_RESOURCE_GROUP = $backend.resource_group_name
  TF_STATE_STORAGE_ACCOUNT = $backend.storage_account_name
  TF_STATE_CONTAINER = $backend.container_name
  TF_LOCK_CONTAINER = 'locks'
  BOOTSTRAP_STORAGE_ACCOUNT_ID = $bootstrap.storage_account_id.value
  GENERATED_REPOSITORY_OWNER = $GeneratedRepositoryOwner
  GENERATED_OWNER_MODE = $OwnerMode
  TEMPLATE_REPOSITORY_OWNER = $TemplateRepositoryOwner
  TEMPLATE_REPOSITORY_NAME = $TemplateRepositoryName
  PLATFORM_GITHUB_APP_ID = $GitHubAppId
  PLATFORM_ADMIN_EMAIL = $PlatformAdminEmail
  PLATFORM_UNIQUE_SUFFIX = $PlatformUniqueSuffix
  PLATFORM_ADMINS = $PlatformAdmins
  ORGANIZATION_REQUESTERS = $OrganizationRequesters
  PLATFORM_LOG_ANALYTICS_WORKSPACE_ID = $platform.log_analytics_workspace.value.id
  PLATFORM_LOG_ANALYTICS_WORKSPACE_IDS_JSON = ($platform.log_analytics_workspace_ids.value | ConvertTo-Json -Compress)
  PLATFORM_ACTION_GROUP_ID = $platform.action_group_id.value
  PLATFORM_LOGS_INGESTION_ENDPOINT = $platform.lifecycle_log_ingestion.value.endpoint
  PLATFORM_DCR_IMMUTABLE_ID = $platform.lifecycle_log_ingestion.value.immutable_id
  PLATFORM_DCR_STREAM = $platform.lifecycle_log_ingestion.value.stream
  SHARED_ACR_ID = $platform.shared_acr.value.id
  PLATFORM_POLICY_DEFINITION_IDS_JSON = ($platform.policy_definition_ids.value | ConvertTo-Json -Compress)
  ENABLE_REPOSITORY_DELETE = (-not $DisableRepositoryDeletion.IsPresent).ToString().ToLowerInvariant()
  ENABLE_ADE = $EnableAde.IsPresent.ToString().ToLowerInvariant()
  DEVELOPER_GROUP_OBJECT_ID = $DeveloperGroupObjectId
}
if ($platform.ade.value) {
  $variables.ADE_DEVCENTER_NAME = ([string]$platform.ade.value.devcenter_id -split '/')[-1]
  $variables.ADE_PROJECT_NAME = ([string]$platform.ade.value.project_id -split '/')[-1]
}
foreach ($entry in $variables.GetEnumerator()) {
  if ($null -ne $entry.Value -and [string]$entry.Value -ne '') {
    & gh variable set $entry.Key --repo $Repository --body ([string]$entry.Value)
    if ($LASTEXITCODE -ne 0) { throw "Could not set GitHub variable $($entry.Key)." }
  }
}

& gh label create platform-alert --repo $Repository --color 'B60205' --description 'Deduplicated platform lifecycle or heartbeat incident' --force
if ($LASTEXITCODE -ne 0) { throw 'Could not create or update the platform-alert label.' }

Write-Host 'Repository variables, validated CODEOWNERS, main protection, and exact environment deployment policies are configured.'
Write-Warning 'If this run created CODEOWNERS, refresh the local checkout with git pull --ff-only before creating another branch.'
Write-Warning 'Store PLATFORM_GITHUB_APP_PRIVATE_KEY only as three separate environment secrets: lifecycle, aks-approval, and destructive-operations. Repository- and organization-level copies accessible to this repository are forbidden.'
