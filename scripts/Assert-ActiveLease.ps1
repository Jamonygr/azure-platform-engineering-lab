[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $Before
)

$ErrorActionPreference = 'Stop'
foreach ($name in @('PLATFORM_LEASE_ID', 'PLATFORM_LEASE_BLOB', 'PLATFORM_LEASE_CONTAINER', 'PLATFORM_LEASE_ENVIRONMENT_ID', 'PLATFORM_FENCING_GENERATION', 'TF_STATE_STORAGE_ACCOUNT')) {
  if (-not [Environment]::GetEnvironmentVariable($name)) { throw "Active lifecycle lease variable $name is missing before $Before." }
}

$renew = & az storage blob lease renew `
  --auth-mode login `
  --account-name $env:TF_STATE_STORAGE_ACCOUNT `
  --container-name $env:PLATFORM_LEASE_CONTAINER `
  --blob-name $env:PLATFORM_LEASE_BLOB `
  --lease-id $env:PLATFORM_LEASE_ID `
  --output none 2>&1
if ($LASTEXITCODE -ne 0) { throw "Azure Blob lease validation failed before ${Before}: $($renew | Out-String)" }

$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$controller = Join-Path $root 'controller/src/cli.ts'
$githubOutput = $env:GITHUB_OUTPUT
try {
  Remove-Item Env:GITHUB_OUTPUT -ErrorAction SilentlyContinue
  $currentJson = & node --experimental-strip-types $controller get --environment-id $env:PLATFORM_LEASE_ENVIRONMENT_ID
  if ($LASTEXITCODE -ne 0) { throw "Inventory fence could not be read before $Before." }
}
finally {
  if ($githubOutput) { $env:GITHUB_OUTPUT = $githubOutput }
}
$current = ($currentJson | Out-String) | ConvertFrom-Json
if ([int64]$current.fencingGeneration -ne [int64]$env:PLATFORM_FENCING_GENERATION) {
  throw "Inventory fencing generation changed before ${Before}; refusing stale side effects."
}
