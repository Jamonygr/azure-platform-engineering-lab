[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$setRepositoryPath = Join-Path $root 'scripts\Set-GeneratedRepository.ps1'
$terraformPath = Join-Path $root 'scripts\Invoke-GoldenPathTerraform.ps1'
$aksExtensionPath = Join-Path $root 'scripts\Install-AksPreviewExtension.ps1'
$preflightPath = Join-Path $root 'scripts\Test-GoldenPathPreflight.ps1'

foreach ($path in @($setRepositoryPath, $terraformPath, $aksExtensionPath, $preflightPath)) {
  $tokens = $null
  $errors = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
  if ($errors.Count -gt 0) {
    throw "PowerShell parse failure in $path`: $($errors[0].Message)"
  }
}

$setRepository = Get-Content -LiteralPath $setRepositoryPath -Raw
foreach ($contract in @(
    'platform_dispatch_id',
    'rerun-failed-jobs',
    'Authenticate to Azure over OIDC',
    'Wait for Azure role readiness',
    '$maximumRunAttempts = 3',
    '$unsafeFailures'
  )) {
  if (-not $setRepository.Contains($contract)) {
    throw "Generated-repository propagation contract is missing: $contract"
  }
}
if ($setRepository -notmatch 'failedSteps\.Count -eq 0 -or \$unsafeFailures\.Count -gt 0') {
  throw 'Automatic reruns must fail closed unless every failure is in a named non-mutating propagation step.'
}

$terraform = Get-Content -LiteralPath $terraformPath -Raw
foreach ($contract in @(
    '$domainDeadline = [DateTimeOffset]::UtcNow.AddMinutes(15)',
    '$domainDelaySeconds = 10',
    'defaultdomain show',
    'Start-Sleep -Seconds $domainDelaySeconds',
    '[math]::Min'
  )) {
  if (-not $terraform.Contains($contract)) {
    throw "AKS default-domain polling contract is missing: $contract"
  }
}

$aksExtension = Get-Content -LiteralPath $aksExtensionPath -Raw
foreach ($contract in @(
    "`$version = '21.0.0b8'",
    "`$sha256 = 'aa39868b5441c659afc11d069ef42bd48dbbd86d257058a76dfb552dc2748763'",
    'Get-FileHash',
    'az extension add --source',
    '--enable-default-domain'
  )) {
  if (-not $aksExtension.Contains($contract)) {
    throw "Checksum-pinned AKS preview extension contract is missing: $contract"
  }
}
$preflight = Get-Content -LiteralPath $preflightPath -Raw
if (-not $preflight.Contains('Install-AksPreviewExtension.ps1') -or -not $terraform.Contains('Install-AksPreviewExtension.ps1')) {
  throw 'Both AKS preflight and Terraform apply must verify the checksum-pinned preview extension.'
}
foreach ($contract in @(
    'Microsoft.Web/locations/$($record.location)/usages?api-version=2025-03-01',
    'App Service B1 requires one available regional core',
    'Microsoft.Quota/quotas?api-version=2025-09-01',
    'ManagedEnvironmentCount',
    'Microsoft.App/managedEnvironments?api-version=2025-07-01',
    'ManagedEnvironmentCount quota is exhausted'
  )) {
  if (-not $preflight.Contains($contract)) { throw "Web/Container regional quota preflight contract is missing: $contract" }
}

Write-Host 'Propagation retry and AKS default-domain polling contracts are present and parse cleanly.'
