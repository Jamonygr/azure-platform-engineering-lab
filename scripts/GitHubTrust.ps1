Set-StrictMode -Version Latest

$script:PlatformRequiredStatusChecks = @(
  'controller',
  'scaffold',
  'runner',
  'terraform',
  'terraform-docs',
  'terraform-lint',
  'supply-chain',
  'shell-container-helm',
  'documentation-links',
  'workflow-policy'
)

function Invoke-PlatformGitHubApi {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] [ValidateSet('Get', 'Post', 'Put', 'Patch', 'Delete')] [string] $Method,
    [Parameter(Mandatory)] [string] $Endpoint,
    [object] $Body,
    [switch] $NoResponse
  )

  $arguments = @('api', '-H', 'Accept: application/vnd.github+json', '-H', 'X-GitHub-Api-Version: 2026-03-10')
  if ($Method -ne 'Get') { $arguments += @('--method', $Method) }
  $arguments += $Endpoint
  if ($null -ne $Body) {
    $response = ($Body | ConvertTo-Json -Depth 30 -Compress) | & gh @arguments --input - 2>&1
  }
  else {
    $response = & gh @arguments 2>&1
  }
  if ($LASTEXITCODE -ne 0) {
    throw "GitHub API $Method $Endpoint failed. The repository plan, feature availability, token permission, or configured protection may be unsupported: $($response | Out-String)"
  }
  if ($NoResponse -or -not $response) { return $null }
  try { return (($response | Out-String) | ConvertFrom-Json) }
  catch { throw "GitHub API $Method $Endpoint returned an unexpected response." }
}

function Test-PlatformGitHubEndpoint {
  [CmdletBinding()]
  param([Parameter(Mandatory)] [string] $Endpoint)

  & gh api -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2026-03-10' $Endpoint --silent 2>$null
  return ($LASTEXITCODE -eq 0)
}

function Resolve-GitHubPlatformAdmins {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')] [string] $Repository,
    [string] $PlatformAdmins,
    [Parameter(Mandatory)] [ValidateSet('personal', 'organization')] [string] $OwnerMode
  )

  $repositoryObject = Invoke-PlatformGitHubApi -Method Get -Endpoint "repos/$Repository"
  if (-not $repositoryObject.permissions.admin) {
    throw 'The authenticated GitHub operator must have repository Administration permission to establish the trust boundary.'
  }
  if ([string]$repositoryObject.default_branch -ne 'main') {
    throw 'The platform repository default branch must be exactly main before trust configuration.'
  }
  if ($repositoryObject.private) {
    throw 'This lab requires a public platform repository; required-reviewer and protection availability is not assumed for a private repository plan.'
  }

  $owner = $Repository.Split('/', 2)[0]
  if ($OwnerMode -eq 'organization' -and -not $PlatformAdmins) {
    throw 'PlatformAdmins is required in organization mode. Supply two to six comma-separated repository-admin user logins.'
  }
  if (-not $PlatformAdmins) { $PlatformAdmins = $owner }

  $requestedOwners = @($PlatformAdmins -split '[,\r\n]+' | ForEach-Object { $_.Trim().TrimStart('@') } | Where-Object { $_ })
  if ($requestedOwners.Count -eq 0) { throw 'At least one platform administrator is required.' }
  if ($requestedOwners.Count -gt 6) { throw 'GitHub environment protection supports at most six required reviewers; reduce PlatformAdmins to six trusted owners.' }

  $resolved = @()
  $eligibleApproverLogins = @()
  foreach ($requestedOwner in $requestedOwners) {
    if ($requestedOwner.Contains('/')) {
      throw 'PlatformAdmins must contain explicit GitHub user logins, not teams. The lifecycle controller authorizes immutable actor logins and must not depend on a stale team-membership snapshot.'
    }

    if ($requestedOwner -notmatch '^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$') {
      throw "Platform admin user @$requestedOwner is not a valid GitHub login."
    }
    $user = Invoke-PlatformGitHubApi -Method Get -Endpoint "users/$requestedOwner"
    $login = [string]$user.login
    if ($OwnerMode -eq 'organization' -and -not (Test-PlatformGitHubEndpoint -Endpoint "orgs/$owner/members/$login")) {
      throw "Platform admin @$login must be a current public or private member of $owner."
    }
    $permission = Invoke-PlatformGitHubApi -Method Get -Endpoint "repos/$Repository/collaborators/$login/permission"
    if ($OwnerMode -eq 'organization' -and [string]$permission.permission -ne 'admin') {
      throw "Platform admin @$login must have Administration permission on $Repository."
    }
    if ($OwnerMode -eq 'personal' -and [string]$permission.permission -notin @('admin', 'maintain', 'write', 'push')) {
      throw "Personal-mode platform reviewer @$login must be the owner or a trusted push-equivalent collaborator on $Repository."
    }
    $eligibleApproverLogins += $login
    $resolved += [pscustomobject]@{
      Type      = 'User'
      Id        = [int64]$user.id
      CodeOwner = "@$login"
      Login     = $login
      Slug      = $null
      Permission = [string]$permission.permission
    }
  }

  $duplicates = @($resolved | Group-Object CodeOwner | Where-Object Count -gt 1)
  if ($duplicates.Count -gt 0) { throw 'PlatformAdmins contains duplicate users.' }
  if ($OwnerMode -eq 'personal') {
    $ownerAdmin = @($resolved | Where-Object { $_.Login -ieq $owner -and $_.Permission -eq 'admin' })
    if ($ownerAdmin.Count -ne 1) { throw 'Personal-mode PlatformAdmins must include the repository owner with Administration permission.' }
  }
  $distinctApprovers = @($eligibleApproverLogins | Where-Object { $_ } | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object -Unique)
  if ($distinctApprovers.Count -lt 2) {
    throw 'PlatformAdmins must contain at least two distinct GitHub users so last-push approval and prevent-self-review controls cannot deadlock platform operations.'
  }
  return $resolved
}

function Set-GitHubCodeOwners {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] [string] $Repository,
    [Parameter(Mandatory)] [array] $Admins
  )

  $owners = ($Admins | ForEach-Object CodeOwner) -join ' '
  $desired = "# Managed by scripts/Set-GitHubPlatformConfiguration.ps1.`n# All changes require a reviewed platform administrator.`n* $owners`n"
  $endpoint = "repos/$Repository/contents/.github/CODEOWNERS?ref=main"
  $mainAlreadyProtected = Test-PlatformGitHubEndpoint -Endpoint "repos/$Repository/branches/main/protection"
  $existing = $null
  if (Test-PlatformGitHubEndpoint -Endpoint $endpoint) {
    $existing = Invoke-PlatformGitHubApi -Method Get -Endpoint $endpoint
    $existingText = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(([string]$existing.content -replace '\s', '')))
    if ($existingText -eq $desired) { return }
    if ($mainAlreadyProtected) {
      throw 'Protected main contains different CODEOWNERS. Submit the generated catch-all ownership change through an administrator-reviewed pull request, then rerun configuration; protection will not be weakened.'
    }
  }
  elseif ($mainAlreadyProtected) {
    throw 'Protected main has no validated CODEOWNERS file. Add the generated catch-all ownership through an administrator-reviewed pull request, then rerun configuration; protection will not be weakened.'
  }

  $body = [ordered]@{
    message = 'Establish validated platform administrator CODEOWNERS'
    content = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($desired))
    branch  = 'main'
  }
  if ($existing) { $body.sha = [string]$existing.sha }
  Invoke-PlatformGitHubApi -Method Put -Endpoint "repos/$Repository/contents/.github/CODEOWNERS" -Body $body | Out-Null

  $readback = Invoke-PlatformGitHubApi -Method Get -Endpoint $endpoint
  $readbackText = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(([string]$readback.content -replace '\s', '')))
  if ($readbackText -ne $desired) { throw 'CODEOWNERS readback did not match the validated catch-all administrator list.' }
}

function Assert-GitHubMainBranchProtection {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] [string] $Repository,
    [array] $ExpectedAdmins
  )

  $protection = Invoke-PlatformGitHubApi -Method Get -Endpoint "repos/$Repository/branches/main/protection"
  $statusChecks = $protection.required_status_checks
  $actualContexts = @($statusChecks.contexts | ForEach-Object { [string]$_ } | Sort-Object)
  $expectedContexts = @($script:PlatformRequiredStatusChecks | Sort-Object)
  if (-not $statusChecks -or -not $statusChecks.strict -or ($actualContexts -join ',') -ne ($expectedContexts -join ',')) {
    throw 'main must require the exact ten CI job contexts and require the branch to be current before merge.'
  }
  $reviews = $protection.required_pull_request_reviews
  if (-not $reviews -or -not $reviews.dismiss_stale_reviews -or -not $reviews.require_code_owner_reviews -or
    -not $reviews.require_last_push_approval -or [int]$reviews.required_approving_review_count -lt 1) {
    throw 'main must require an approving code-owner review, dismiss stale approvals, and require approval of the last push.'
  }
  if (-not $protection.enforce_admins.enabled) { throw 'main protection must apply to repository administrators.' }
  if ($protection.allow_force_pushes.enabled -or $protection.allow_deletions.enabled) {
    throw 'main must forbid force pushes and branch deletion.'
  }
  $bypassProperty = $reviews.PSObject.Properties['bypass_pull_request_allowances']
  $bypass = if ($bypassProperty) { $bypassProperty.Value } else { $null }
  if ($bypass -and (@($bypass.users).Count + @($bypass.teams).Count + @($bypass.apps).Count) -gt 0) {
    throw 'main pull-request review bypass allowances must be empty.'
  }
  if (-not $protection.required_conversation_resolution.enabled) {
    throw 'main must require pull-request conversation resolution.'
  }

  if ($ExpectedAdmins) {
    if (-not $protection.restrictions) { throw 'main is missing required PlatformAdmins push restrictions.' }
    $expectedUsers = @($ExpectedAdmins | Where-Object Type -eq 'User' | ForEach-Object { $_.Login.ToLowerInvariant() } | Sort-Object)
    $expectedTeams = @($ExpectedAdmins | Where-Object Type -eq 'Team' | ForEach-Object { $_.Slug.ToLowerInvariant() } | Sort-Object)
    $actualUsers = @($protection.restrictions.users | ForEach-Object { ([string]$_.login).ToLowerInvariant() } | Sort-Object)
    $actualTeams = @($protection.restrictions.teams | ForEach-Object { ([string]$_.slug).ToLowerInvariant() } | Sort-Object)
    $actualApps = @($protection.restrictions.apps)
    if (($expectedUsers -join ',') -ne ($actualUsers -join ',') -or ($expectedTeams -join ',') -ne ($actualTeams -join ',') -or $actualApps.Count -gt 0) {
      throw 'main push restrictions do not exactly match the validated PlatformAdmins.'
    }
  }
  return $protection
}

function Set-GitHubMainBranchProtection {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] [string] $Repository,
    [Parameter(Mandatory)] [array] $Admins,
    [Parameter(Mandatory)] [ValidateSet('personal', 'organization')] [string] $OwnerMode
  )

  $restrictions = if ($OwnerMode -eq 'organization') {
    [ordered]@{
      users = @($Admins | Where-Object Type -eq 'User' | ForEach-Object Login)
      teams = @($Admins | Where-Object Type -eq 'Team' | ForEach-Object Slug)
      apps  = @()
    }
  }
  else { $null }

  $pullRequestReviews = [ordered]@{
    dismiss_stale_reviews           = $true
    require_code_owner_reviews      = $true
    required_approving_review_count = 1
    require_last_push_approval      = $true
  }
  if ($OwnerMode -eq 'organization') {
    $pullRequestReviews.dismissal_restrictions = [ordered]@{ users = @(); teams = @(); apps = @() }
    $pullRequestReviews.bypass_pull_request_allowances = [ordered]@{ users = @(); teams = @(); apps = @() }
  }

  $body = [ordered]@{
    required_status_checks           = [ordered]@{
      strict   = $true
      contexts = $script:PlatformRequiredStatusChecks
    }
    enforce_admins                   = $true
    required_pull_request_reviews    = $pullRequestReviews
    restrictions                     = $restrictions
    required_linear_history          = $false
    allow_force_pushes               = $false
    allow_deletions                  = $false
    block_creations                  = $true
    required_conversation_resolution = $true
    lock_branch                      = $false
    allow_fork_syncing               = $true
  }
  Invoke-PlatformGitHubApi -Method Put -Endpoint "repos/$Repository/branches/main/protection" -Body $body | Out-Null
  if ($OwnerMode -eq 'organization') {
    Assert-GitHubMainBranchProtection -Repository $Repository -ExpectedAdmins $Admins | Out-Null
  }
  else {
    Assert-GitHubMainBranchProtection -Repository $Repository | Out-Null
  }
}

function Set-GitHubDeploymentEnvironment {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] [string] $Repository,
    [Parameter(Mandatory)] [ValidateSet('platform-operations', 'lifecycle', 'aks-approval', 'destructive-operations')] [string] $Environment,
    [Parameter(Mandatory)] [array] $Admins,
    [Parameter(Mandatory)] [bool] $RequireReviewers
  )

  $reviewers = if ($RequireReviewers) {
    @($Admins | ForEach-Object { [ordered]@{ type = $_.Type; id = [int64]$_.Id } })
  }
  else { @() }
  $body = [ordered]@{
    wait_timer               = 0
    prevent_self_review      = $RequireReviewers
    reviewers                = $reviewers
    deployment_branch_policy = [ordered]@{
      protected_branches     = $false
      custom_branch_policies = $true
    }
  }
  Invoke-PlatformGitHubApi -Method Put -Endpoint "repos/$Repository/environments/$Environment" -Body $body | Out-Null

  $policies = Invoke-PlatformGitHubApi -Method Get -Endpoint "repos/$Repository/environments/$Environment/deployment-branch-policies?per_page=100"
  $keptMain = $false
  foreach ($policy in @($policies.branch_policies)) {
    if (-not $keptMain -and [string]$policy.name -eq 'main' -and
      $policy.PSObject.Properties['type'] -and [string]$policy.type -eq 'branch') {
      $keptMain = $true
      continue
    }
    Invoke-PlatformGitHubApi -Method Delete -Endpoint "repos/$Repository/environments/$Environment/deployment-branch-policies/$($policy.id)" -NoResponse | Out-Null
  }
  if (-not $keptMain) {
    Invoke-PlatformGitHubApi -Method Post -Endpoint "repos/$Repository/environments/$Environment/deployment-branch-policies" -Body @{ name = 'main'; type = 'branch' } | Out-Null
  }

  $configured = Invoke-PlatformGitHubApi -Method Get -Endpoint "repos/$Repository/environments/$Environment"
  if ($configured.deployment_branch_policy.protected_branches -or -not $configured.deployment_branch_policy.custom_branch_policies) {
    throw "$Environment must use custom deployment branch policies instead of every protected branch."
  }
  $reviewRule = @($configured.protection_rules | Where-Object type -eq 'required_reviewers') | Select-Object -First 1
  if ($RequireReviewers) {
    $expectedIds = @($Admins.Id | ForEach-Object { [int64]$_ } | Sort-Object)
    if (-not $reviewRule) {
      throw "$Environment has no required-reviewer protection rule. The GitHub plan may not support required reviewers."
    }
    if (-not $reviewRule.prevent_self_review) { throw "$Environment must prevent deployment self-review." }
    $actualIds = @($reviewRule.reviewers.reviewer.id | ForEach-Object { [int64]$_ } | Sort-Object)
    if (($expectedIds -join ',') -ne ($actualIds -join ',')) {
      throw "$Environment required reviewers do not exactly match PlatformAdmins. The GitHub plan may not support required reviewers."
    }
  }
  elseif ($reviewRule) {
    throw 'lifecycle must not have required reviewers because scheduled and automatic cleanup must remain available.'
  }
  $readbackPolicies = Invoke-PlatformGitHubApi -Method Get -Endpoint "repos/$Repository/environments/$Environment/deployment-branch-policies?per_page=100"
  $allPolicies = @($readbackPolicies.branch_policies)
  # GitHub's branch-policy read model omits the branch/tag discriminator in
  # some API versions. Delete all pre-existing entries and create this sole
  # policy explicitly with type=branch, then verify its exact name/count.
  if ($allPolicies.Count -ne 1 -or [string]$allPolicies[0].name -ne 'main') {
    throw "$Environment must allow deployments from the exact main branch only."
  }
}

function Assert-GitHubCommitReachableFromMain {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] [string] $Repository,
    [Parameter(Mandatory)] [ValidatePattern('^[0-9a-f]{40}$')] [string] $Commit
  )

  Assert-GitHubMainBranchProtection -Repository $Repository | Out-Null
  $comparison = Invoke-PlatformGitHubApi -Method Get -Endpoint "repos/$Repository/compare/$Commit...main"
  if ([string]$comparison.merge_base_commit.sha -ne $Commit -or [string]$comparison.status -notin @('ahead', 'identical')) {
    throw 'ReviewedCommit must be the protected main head or an ancestor reachable from protected main; arbitrary repository commits are forbidden.'
  }
}

function Assert-GitHubAdeCatalogProtection {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] [string] $Repository,
    [object] $ExpectedMainProtection
  )

  $protection = Invoke-PlatformGitHubApi -Method Get -Endpoint "repos/$Repository/branches/ade-catalog/protection"
  if (-not $protection.enforce_admins.enabled -or $protection.allow_force_pushes.enabled -or $protection.allow_deletions.enabled) {
    throw 'ade-catalog must enforce protection for administrators and forbid force pushes and deletion.'
  }
  if ($protection.required_pull_request_reviews) {
    throw 'ade-catalog is a generated publisher-only branch and must not depend on a pull-request review that prevents atomic publication.'
  }
  if (-not $protection.restrictions) { throw 'ade-catalog has no trusted publisher push restriction.' }
  $restrictionCount = @($protection.restrictions.users).Count + @($protection.restrictions.teams).Count + @($protection.restrictions.apps).Count
  if ($restrictionCount -eq 0) { throw 'ade-catalog must restrict pushes to trusted platform administrators/publishers.' }
  if ($ExpectedMainProtection) {
    if (-not $ExpectedMainProtection.restrictions) {
      throw 'ADE catalog publication requires organization main-branch push restrictions.'
    }
    foreach ($kind in @('users', 'teams', 'apps')) {
      $mainValues = @($ExpectedMainProtection.restrictions.$kind | ForEach-Object { ([string]$(if ($kind -eq 'users') { $_.login } else { $_.slug })).ToLowerInvariant() } | Sort-Object)
      $catalogValues = @($protection.restrictions.$kind | ForEach-Object { ([string]$(if ($kind -eq 'users') { $_.login } else { $_.slug })).ToLowerInvariant() } | Sort-Object)
      if (($mainValues -join ',') -ne ($catalogValues -join ',')) {
        throw "ade-catalog $kind push restrictions must exactly match protected main."
      }
    }
  }
  return $protection
}

function Set-GitHubAdeCatalogProtection {
  [CmdletBinding()]
  param([Parameter(Mandatory)] [string] $Repository)

  $mainProtection = Assert-GitHubMainBranchProtection -Repository $Repository
  if (-not $mainProtection.restrictions) {
    throw 'ADE catalog publication requires an organization repository whose protected main branch has explicit PlatformAdmins push restrictions.'
  }
  $owner = $Repository.Split('/', 2)[0]
  $publisher = Invoke-PlatformGitHubApi -Method Get -Endpoint 'user'
  $permission = Invoke-PlatformGitHubApi -Method Get -Endpoint "repos/$Repository/collaborators/$($publisher.login)/permission"
  if ([string]$permission.permission -ne 'admin') {
    throw 'The ADE catalog publisher must be a repository administrator.'
  }

  $trustedPublisher = @($mainProtection.restrictions.users | Where-Object { [string]$_.login -ieq [string]$publisher.login }).Count -gt 0
  if (-not $trustedPublisher) {
    foreach ($team in @($mainProtection.restrictions.teams)) {
      $membershipEndpoint = "orgs/$owner/teams/$($team.slug)/memberships/$($publisher.login)"
      if (Test-PlatformGitHubEndpoint -Endpoint $membershipEndpoint) {
        $membership = Invoke-PlatformGitHubApi -Method Get -Endpoint $membershipEndpoint
        if ([string]$membership.state -eq 'active') { $trustedPublisher = $true; break }
      }
    }
  }
  if (-not $trustedPublisher) {
    throw 'The authenticated ADE publisher must be included directly or through a team in protected main push restrictions.'
  }

  $body = [ordered]@{
    required_status_checks           = $null
    enforce_admins                   = $true
    required_pull_request_reviews    = $null
    restrictions                     = [ordered]@{
      users = @($mainProtection.restrictions.users | ForEach-Object login)
      teams = @($mainProtection.restrictions.teams | ForEach-Object slug)
      apps  = @($mainProtection.restrictions.apps | ForEach-Object slug)
    }
    required_linear_history          = $false
    allow_force_pushes               = $false
    allow_deletions                  = $false
    block_creations                  = $true
    required_conversation_resolution = $false
    lock_branch                      = $false
    allow_fork_syncing               = $true
  }
  Invoke-PlatformGitHubApi -Method Put -Endpoint "repos/$Repository/branches/ade-catalog/protection" -Body $body | Out-Null
  Assert-GitHubAdeCatalogProtection -Repository $Repository -ExpectedMainProtection $mainProtection | Out-Null
}
