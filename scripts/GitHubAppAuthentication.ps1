. (Join-Path $PSScriptRoot 'GitHubAppPermissions.ps1')

function Initialize-GitHubAppAuthentication {
  [CmdletBinding()]
  param()

  # Keep the long-lived private key in this PowerShell process only. Removing
  # it from the process environment prevents Terraform, Azure CLI, npm and
  # other child processes from inheriting it during a long lifecycle run.
  if ($env:PLATFORM_GITHUB_APP_PRIVATE_KEY) {
    $global:PlatformGitHubAppPrivateKeyMaterial = [string]$env:PLATFORM_GITHUB_APP_PRIVATE_KEY
    Remove-Item Env:PLATFORM_GITHUB_APP_PRIVATE_KEY -ErrorAction SilentlyContinue
  }
}

function ConvertTo-GitHubBase64Url {
  param([Parameter(Mandatory)] [byte[]] $Bytes)
  return [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function New-GitHubAppJwt {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] [string] $AppId,
    [Parameter(Mandatory)] [string] $PrivateKey
  )

  $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  $headerJson = @{ alg = 'RS256'; typ = 'JWT' } | ConvertTo-Json -Compress
  $payloadJson = @{ iat = $now - 60; exp = $now + 540; iss = $AppId } | ConvertTo-Json -Compress
  $header = ConvertTo-GitHubBase64Url -Bytes ([Text.Encoding]::UTF8.GetBytes($headerJson))
  $payload = ConvertTo-GitHubBase64Url -Bytes ([Text.Encoding]::UTF8.GetBytes($payloadJson))
  $unsigned = "$header.$payload"
  $rsa = [Security.Cryptography.RSA]::Create()
  try {
    $normalizedKey = $PrivateKey.Replace('\n', "`n")
    $rsa.ImportFromPem($normalizedKey)
    $signature = $rsa.SignData(
      [Text.Encoding]::UTF8.GetBytes($unsigned),
      [Security.Cryptography.HashAlgorithmName]::SHA256,
      [Security.Cryptography.RSASignaturePadding]::Pkcs1
    )
  }
  catch {
    throw "PLATFORM_GITHUB_APP_PRIVATE_KEY is not a usable RSA PEM private key. $($_.Exception.Message)"
  }
  finally { $rsa.Dispose() }
  return "$unsigned.$(ConvertTo-GitHubBase64Url -Bytes $signature)"
}

function Update-GitHubAppInstallationToken {
  [CmdletBinding()]
  param([ValidateRange(1, 30)] [int] $MinimumValidityMinutes = 10)

  Initialize-GitHubAppAuthentication
  $privateKeyVariable = Get-Variable -Name PlatformGitHubAppPrivateKeyMaterial -Scope Global -ErrorAction SilentlyContinue
  if (-not $privateKeyVariable -or -not [string]$privateKeyVariable.Value) {
    if (-not $env:GITHUB_TOKEN) {
      throw 'GitHub authentication requires GITHUB_TOKEN or the refreshable PLATFORM_GITHUB_APP_PRIVATE_KEY provider.'
    }
    return
  }

  $expiresVariable = Get-Variable -Name PlatformGitHubAppTokenExpiresAt -Scope Global -ErrorAction SilentlyContinue
  if ($env:GITHUB_TOKEN -and $expiresVariable -and
      [DateTimeOffset]$expiresVariable.Value -gt [DateTimeOffset]::UtcNow.AddMinutes($MinimumValidityMinutes)) {
    return
  }

  foreach ($name in @('PLATFORM_GITHUB_APP_ID', 'GENERATED_REPOSITORY_OWNER', 'GENERATED_OWNER_MODE')) {
    if (-not [Environment]::GetEnvironmentVariable($name)) {
      throw "$name is required to refresh the GitHub App installation token."
    }
  }
  if ($env:PLATFORM_GITHUB_APP_ID -notmatch '^\d+$') { throw 'PLATFORM_GITHUB_APP_ID must be numeric.' }
  if ($env:GENERATED_REPOSITORY_OWNER -notmatch '^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$') {
    throw 'GENERATED_REPOSITORY_OWNER is malformed.'
  }
  if ($env:GENERATED_OWNER_MODE -notin @('organization', 'personal')) {
    throw 'GENERATED_OWNER_MODE must be organization or personal.'
  }

  $jwt = New-GitHubAppJwt -AppId $env:PLATFORM_GITHUB_APP_ID -PrivateKey ([string]$privateKeyVariable.Value)
  $jwtHeaders = @{
    Authorization = "Bearer $jwt"
    Accept = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2026-03-10'
  }
  $owner = [uri]::EscapeDataString($env:GENERATED_REPOSITORY_OWNER)
  $installationUri = if ($env:GENERATED_OWNER_MODE -eq 'organization') {
    "https://api.github.com/orgs/$owner/installation"
  }
  else { "https://api.github.com/users/$owner/installation" }

  $installation = Invoke-RestMethod -Method Get -Uri $installationUri -Headers $jwtHeaders
  if (-not $installation.id) { throw 'GitHub App installation lookup omitted its immutable installation ID.' }
  Assert-GitHubAppPermissions -Permissions $installation.permissions -OwnerMode $env:GENERATED_OWNER_MODE
  # GitHub's installation-token endpoint cannot currently downscope the
  # repository Variables permission independently. The installation is
  # therefore required to have the exact permission set above, and the minted
  # token response is checked again below; unexpected privilege fails closed.
  $tokenResponse = Invoke-RestMethod -Method Post `
    -Uri "https://api.github.com/app/installations/$([int64]$installation.id)/access_tokens" `
    -Headers $jwtHeaders -ContentType 'application/json' -Body '{}'
  if (-not $tokenResponse.token -or -not $tokenResponse.expires_at) {
    throw 'GitHub App installation-token response omitted token or expiry.'
  }
  Assert-GitHubAppPermissions -Permissions $tokenResponse.permissions -OwnerMode $env:GENERATED_OWNER_MODE
  $expiresAt = [DateTimeOffset]::Parse([string]$tokenResponse.expires_at)
  if ($expiresAt -le [DateTimeOffset]::UtcNow.AddMinutes($MinimumValidityMinutes)) {
    throw 'GitHub returned an installation token without the required validity window.'
  }

  $env:GITHUB_TOKEN = [string]$tokenResponse.token
  $global:PlatformGitHubAppTokenExpiresAt = $expiresAt
  Write-Host "::add-mask::$($tokenResponse.token)"
  Write-Host "Refreshed GitHub App installation token; expires $($expiresAt.ToString('O'))."
}
