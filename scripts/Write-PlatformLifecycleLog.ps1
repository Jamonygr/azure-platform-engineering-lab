[CmdletBinding()]
param(
  [Parameter(Mandatory)] [ValidatePattern('^[a-z0-9-]{1,80}$')] [string] $Operation,
  [Parameter(Mandatory)] [ValidateSet('success', 'failure', 'retry', 'dry-run')] [string] $Outcome,
  [string] $EnvironmentId = '',
  [string] $Phase = '',
  [int] $FencingGeneration = 0,
  [string] $Message = '',
  [switch] $BestEffort
)

$ErrorActionPreference = 'Stop'
try {
  foreach ($name in @('PLATFORM_LOGS_INGESTION_ENDPOINT', 'PLATFORM_DCR_IMMUTABLE_ID', 'PLATFORM_DCR_STREAM')) {
    if (-not [Environment]::GetEnvironmentVariable($name)) { throw "$name is required for Azure Monitor lifecycle ingestion." }
  }
  $token = & az account get-access-token --scope 'https://monitor.azure.com/.default' --query accessToken --output tsv 2>&1
  if ($LASTEXITCODE -ne 0 -or -not $token) { throw "Could not acquire the OIDC session's Azure Monitor ingestion token: $($token | Out-String)" }
  $safeMessage = $Message `
    -replace '(?:ghp|github_pat|ghs|ghu|gho)_[A-Za-z0-9_]+', '[REDACTED_GITHUB_TOKEN]' `
    -replace '(?i)Bearer\s+[A-Za-z0-9._~-]+', 'Bearer [REDACTED]'
  if ($safeMessage.Length -gt 1000) { $safeMessage = $safeMessage.Substring(0, 1000) }
  $runUrl = if ($env:GITHUB_SERVER_URL -and $env:GITHUB_REPOSITORY -and $env:GITHUB_RUN_ID) {
    "$($env:GITHUB_SERVER_URL)/$($env:GITHUB_REPOSITORY)/actions/runs/$($env:GITHUB_RUN_ID)"
  } else { '' }
  $payload = @([ordered]@{
    TimeGenerated = [DateTimeOffset]::UtcNow.ToString('o')
    Operation = $Operation
    EnvironmentId = $EnvironmentId
    Phase = $Phase
    Outcome = $Outcome
    FencingGeneration = $FencingGeneration
    Message = $safeMessage
    RunUrl = $runUrl
  }) | ConvertTo-Json -Depth 5 -AsArray
  $endpoint = $env:PLATFORM_LOGS_INGESTION_ENDPOINT.TrimEnd('/')
  $uri = "$endpoint/dataCollectionRules/$($env:PLATFORM_DCR_IMMUTABLE_ID)/streams/$($env:PLATFORM_DCR_STREAM)?api-version=2023-01-01"
  Invoke-RestMethod -Method Post -Uri $uri -Headers @{ Authorization = "Bearer $token" } -ContentType 'application/json' -Body $payload | Out-Null
  Write-Host "Ingested sanitized platform lifecycle event: $Operation/$Outcome"
}
catch {
  if ($BestEffort) { Write-Warning "Azure Monitor lifecycle ingestion failed: $($_.Exception.Message)"; return }
  throw
}
