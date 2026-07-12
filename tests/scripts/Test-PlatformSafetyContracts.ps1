[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$platformPath = Join-Path $root 'scripts\Invoke-Platform.ps1'
$environmentPath = Join-Path $root 'scripts\Invoke-Environment.ps1'
$aksPreflightPath = Join-Path $root 'scripts\Test-GoldenPathPreflight.ps1'
$aksMainPath = Join-Path $root 'golden-paths\aks-workload-v1\main.tf'
$adeDeliveryPath = Join-Path $root 'runner\ade-terraform\scripts\delivery.sh'

foreach ($path in @($platformPath, $environmentPath, $aksPreflightPath)) {
  $tokens = $null
  $errors = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
  if ($errors.Count -gt 0) { throw "PowerShell parse failure in $path`: $($errors[0].Message)" }
}

$platform = Get-Content -LiteralPath $platformPath -Raw
foreach ($contract in @(
    "show -json `$planFile",
    "'delete' -in @(`$_.change.actions)",
    'platform-admission.lease',
    'Set-AdeEnvironmentTypeStatus -EnvironmentTypeId $adeEnvironmentTypeId -Status Disabled',
    'A destructive shared plan may not create or replace an enabled ADE environment type',
    'environmentCount',
    'Assert-NoLivePlatformEnvironments -AdeOutput $adeOutput',
    'Start-Sleep -Seconds 15',
    'terraform "-chdir=$platformDirectory" apply'
  )) {
  if (-not $platform.Contains($contract)) { throw "Destructive platform safety contract is missing: $contract" }
}

$finalGuard = $platform.LastIndexOf('Assert-NoLivePlatformEnvironments -AdeOutput $adeOutput')
$apply = $platform.LastIndexOf('terraform "-chdir=$platformDirectory" apply')
if ($finalGuard -lt 0 -or $apply -lt 0 -or $finalGuard -gt $apply) {
  throw 'The final inventory/ADE check must occur immediately before the saved platform plan is applied.'
}

$environment = Get-Content -LiteralPath $environmentPath -Raw
$admission = $environment.IndexOf("Enter-EnvironmentLease -EnvironmentId 'platform-admission'")
$initialize = $environment.IndexOf("Invoke-Controller @('initialize')")
if ($admission -lt 0 -or $initialize -lt 0 -or $admission -gt $initialize) {
  throw 'A request must acquire the global platform admission lease before its inventory-first initialization checkpoint.'
}

$aksPreflight = Get-Content -LiteralPath $aksPreflightPath -Raw
foreach ($contract in @(
    'az feature show --namespace Microsoft.ContainerService --name AppRoutingIstioGatewayAPIPreview',
    "`$gatewayApiFeatureState -ine 'Registered'",
    'AKS Gateway API Standard requires Microsoft.ContainerService/AppRoutingIstioGatewayAPIPreview'
  )) {
  if (-not $aksPreflight.Contains($contract)) { throw "AKS feature preflight contract is missing: $contract" }
}

$adeDelivery = Get-Content -LiteralPath $adeDeliveryPath -Raw
foreach ($contract in @('az feature show', '--name AppRoutingIstioGatewayAPIPreview', 'gateway_api_feature_state" == "Registered"')) {
  if (-not $adeDelivery.Contains($contract)) { throw "ADE AKS feature preflight contract is missing: $contract" }
}

$aksMain = Get-Content -LiteralPath $aksMainPath -Raw
foreach ($contract in @(
    'resource "azapi_update_resource" "node_resource_group_tags"',
    'Microsoft.Resources/tags@2021-04-01',
    '${module.aks.node_resource_group_id}/providers/Microsoft.Resources/tags/default',
    'operation = "Merge"',
    'tags = local.tags',
    'admin_group_object_ids = []',
    'resource "azapi_resource_action" "workload_namespace"',
    'resource "azurerm_role_assignment" "deployment_rbac_writer"',
    'depends_on = [module.aks]'
  )) {
  if (-not $aksMain.Contains($contract)) { throw "AKS node resource-group tag contract is missing: $contract" }
}
if ($aksMain.Contains('Azure Kubernetes Service RBAC Cluster Admin')) {
  throw 'Generated-repository and developer identities must remain namespace-scoped AKS writers.'
}

Write-Host 'Destructive platform plans, AKS feature gating, and managed node resource-group tags satisfy the fail-closed contracts.'
