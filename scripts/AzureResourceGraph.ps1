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

  # PowerShell on Windows removes the JSON quotes when an inline object is
  # passed through the native-command boundary. Azure CLI supports @file
  # request bodies, which also keeps KQL quoting deterministic across shells.
  $bodyFile = Join-Path ([IO.Path]::GetTempPath()) "pelab-resource-graph-$([guid]::NewGuid().ToString('N')).json"
  $raw = $null
  $exitCode = $null
  try {
    [IO.File]::WriteAllText($bodyFile, $body, [Text.UTF8Encoding]::new($false))
    $raw = & az rest `
      --method post `
      --uri 'https://management.azure.com/providers/Microsoft.ResourceGraph/resources?api-version=2024-04-01' `
      --headers 'Content-Type=application/json' `
      --body "@$bodyFile" `
      --output json 2>&1
    $exitCode = $LASTEXITCODE
  }
  finally {
    if (Test-Path -LiteralPath $bodyFile) { Remove-Item -LiteralPath $bodyFile -Force }
  }
  if ($exitCode -ne 0) { throw "Azure Resource Graph ARM query failed: $($raw | Out-String)" }
  try { return (($raw | Out-String) | ConvertFrom-Json) }
  catch { throw "Azure Resource Graph returned malformed JSON: $($_.Exception.Message)" }
}
