Set-StrictMode -Version Latest

function Invoke-PlatformResourceGraphQuery {
  param(
    [Parameter(Mandatory)] [string] $Query,
    [ValidateRange(1, 1000)] [int] $First = 1000
  )

  if ($env:AZURE_SUBSCRIPTION_ID -notmatch '^[0-9a-fA-F-]{36}$') {
    throw 'AZURE_SUBSCRIPTION_ID must be a UUID before Azure Resource Graph can be queried.'
  }
  $body = [ordered]@{
    subscriptions = @($env:AZURE_SUBSCRIPTION_ID)
    query = $Query
    options = @{ '$top' = $First; resultFormat = 'objectArray' }
  } | ConvertTo-Json -Depth 6 -Compress
  $raw = & az rest `
    --method post `
    --uri 'https://management.azure.com/providers/Microsoft.ResourceGraph/resources?api-version=2024-04-01' `
    --headers 'Content-Type=application/json' `
    --body $body `
    --output json 2>&1
  if ($LASTEXITCODE -ne 0) { throw "Azure Resource Graph ARM query failed: $($raw | Out-String)" }
  try { return (($raw | Out-String) | ConvertFrom-Json) }
  catch { throw "Azure Resource Graph returned malformed JSON: $($_.Exception.Message)" }
}
