[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

$requiredFiles = @(
  'bootstrap\versions.tf',
  'bootstrap\variables.tf',
  'bootstrap\outputs.tf',
  'platform\versions.tf',
  'platform\variables.tf',
  'platform\outputs.tf',
  'golden-paths\web-app-v1\versions.tf',
  'golden-paths\web-app-v1\variables.tf',
  'golden-paths\web-app-v1\outputs.tf',
  'golden-paths\container-app-v1\versions.tf',
  'golden-paths\container-app-v1\variables.tf',
  'golden-paths\container-app-v1\outputs.tf',
  'golden-paths\aks-workload-v1\versions.tf',
  'golden-paths\aks-workload-v1\variables.tf',
  'golden-paths\aks-workload-v1\outputs.tf'
)

foreach ($relativePath in $requiredFiles) {
  $path = Join-Path $root $relativePath
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw "Required Terraform contract file is missing: $relativePath"
  }
}

$goldenPaths = @('web-app-v1', 'container-app-v1', 'aks-workload-v1')
foreach ($goldenPath in $goldenPaths) {
  $directory = Join-Path $root "golden-paths\$goldenPath"
  $content = (Get-ChildItem -LiteralPath $directory -Filter '*.tf' |
      Get-Content -Raw) -join "`n"

  foreach ($outputName in @('endpoint', 'resource_group_names', 'resource_ids', 'deployment_client_id', 'deployment_principal_id', 'state_contract')) {
    if ($content -notmatch ('output\s+"' + [regex]::Escape($outputName) + '"')) {
      throw "$goldenPath does not expose required output $outputName"
    }
  }

  if ($goldenPath -in @('container-app-v1', 'aks-workload-v1') -and $content -notmatch 'output\s+"shared_acr_id"') {
    throw "$goldenPath does not expose immutable shared_acr_id for fail-closed image cleanup"
  }

  if ($content -notmatch 'repo:\$\{var\.github_owner\}/\$\{var\.github_repository\}:environment:deployment') {
    throw "$goldenPath does not use the exact generated-repository OIDC subject"
  }
}

$containerAppTerraform = (Get-ChildItem -LiteralPath (Join-Path $root 'golden-paths\container-app-v1') -Filter '*.tf' | Get-Content -Raw) -join "`n"
foreach ($contract in @(
    'target_port                = 80',
    'Container Apps supplies native TCP probes against the ingress target',
    'resource "azurerm_monitor_diagnostic_setting" "managed_environment"',
    'from = module.managed_environment.azurerm_monitor_diagnostic_setting.this["platform"]',
    'enabled_metric'
  )) {
  if (-not $containerAppTerraform.Contains($contract)) {
    throw "Container App bootstrap and generated application port contract is missing: $contract"
  }
}
if ($containerAppTerraform.Contains('log_analytics_destination_type')) {
  throw 'Container Apps managed-environment diagnostics must keep the provider-default destination type to prevent drift.'
}
if ($containerAppTerraform.Contains('liveness_probes') -or $containerAppTerraform.Contains('readiness_probes')) {
  throw 'Container App v1 must use native target-port probes so bootstrap and generated revisions can change ports safely.'
}
$generatedWorkflow = Get-Content -LiteralPath (Join-Path $root 'scaffolds\application\base\.github\workflows\deploy.yml') -Raw
foreach ($contract in @('az containerapp ingress update', '--target-port 3000 --transport auto --allow-insecure false')) {
  if (-not $generatedWorkflow.Contains($contract)) {
    throw "Generated Container App deployment is missing the port-transition contract: $contract"
  }
}

$aksTerraform = (Get-ChildItem -LiteralPath (Join-Path $root 'golden-paths\aks-workload-v1') -Filter '*.tf' | Get-Content -Raw) -join "`n"
foreach ($contract in @(
    'resource "azurerm_resource_group_policy_assignment" "node_platform"',
    'resource_group_id    = module.aks.node_resource_group_id',
    '[for assignment in azurerm_resource_group_policy_assignment.node_platform : assignment.id]',
    'admin_group_object_ids = []',
    'resource "azapi_resource_action" "workload_namespace"',
    'action      = "runCommand"',
    'AKS workload namespace creation did not complete successfully',
    'scope                = "${module.aks.resource_id}/namespaces/${local.workload_namespace}"',
    'resource "azurerm_role_assignment" "deployment_rbac_writer"',
    'role_definition_name = "Azure Kubernetes Service RBAC Writer"',
    'resource "azurerm_resource_policy_assignment" "kubernetes_guardrail"',
    'effect             = { value = "Deny" }',
    'allowedExternalIPs = { value = [] }',
    'allowedServicePortsList = { value = [80] }',
    '[for assignment in azurerm_resource_policy_assignment.kubernetes_guardrail : assignment.id]'
  )) {
  if (-not $aksTerraform.Contains($contract)) { throw "AKS managed node-RG policy contract is missing: $contract" }
}
if ($aksTerraform.Contains('Azure Kubernetes Service RBAC Cluster Admin') -or
    $aksTerraform.Contains('admin_group_object_ids = [var.developer_group_object_id]')) {
  throw 'AKS workload principals must never receive cluster-admin access.'
}

Get-ChildItem -LiteralPath (Join-Path $root 'policies\definitions') -Filter '*.json' |
  ForEach-Object {
    $null = Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json
  }

$absenceVerifier = Get-Content -LiteralPath (Join-Path $root 'scripts\Test-AzureAbsence.ps1') -Raw
foreach ($contract in @('RoleAssignmentNotFound', 'PolicyAssignmentNotFound', 'BudgetNotFound', 'ResourceGroupNotFound', 'ParentResourceNotFound')) {
  if (-not $absenceVerifier.Contains($contract)) { throw "Azure absence verifier is missing exact provider code $contract" }
}
if ($absenceVerifier -match "ResourceNotFound\|not found\|does not exist") {
  throw 'Azure absence verifier must not accept broad human-readable not-found text.'
}

Write-Host 'Terraform file, output, OIDC-subject, and policy JSON contracts are present.'
