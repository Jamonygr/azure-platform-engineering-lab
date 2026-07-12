[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
foreach ($name in @('GITHUB_TOKEN', 'PLATFORM_REPOSITORY')) {
  if (-not [Environment]::GetEnvironmentVariable($name)) { throw "$name is required to prove AKS approval protection." }
}
if ($env:PLATFORM_REPOSITORY -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { throw 'PLATFORM_REPOSITORY is malformed.' }
$headers = @{
  Authorization = "Bearer $($env:GITHUB_TOKEN)"
  Accept = 'application/vnd.github+json'
  'X-GitHub-Api-Version' = '2026-03-10'
}
$environment = Invoke-RestMethod -Method Get -Uri "https://api.github.com/repos/$($env:PLATFORM_REPOSITORY)/environments/aks-approval" -Headers $headers
$reviewRule = @($environment.protection_rules | Where-Object { $_.type -eq 'required_reviewers' }) | Select-Object -First 1
if (-not $reviewRule -or @($reviewRule.reviewers).Count -lt 1) {
  throw 'AKS provisioning is forbidden until aks-approval has at least one required reviewer.'
}
Write-Host "AKS approval protection is configured with $(@($reviewRule.reviewers).Count) reviewer entry/entries."
