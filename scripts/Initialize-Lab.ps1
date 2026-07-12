[CmdletBinding(SupportsShouldProcess)]
param(
  [Parameter(Mandatory)] [ValidatePattern('^[0-9a-fA-F-]{36}$')] [string] $SubscriptionId,
  [Parameter(Mandatory)] [ValidatePattern('^[0-9a-fA-F-]{36}$')] [string] $TenantId,
  [string] $Location = 'westeurope',
  [switch] $SkipLogin
)

$ErrorActionPreference = 'Stop'
$requiredCommands = @('az', 'terraform', 'gh', 'node', 'npm')
foreach ($command in $requiredCommands) {
  if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
    throw "Required command '$command' was not found on PATH."
  }
}

$terraformVersion = (& terraform version -json | ConvertFrom-Json).terraform_version
if ($terraformVersion -ne '1.15.8') {
  throw "Terraform 1.15.8 is required; found $terraformVersion."
}

$nodeMajor = (& node --version).TrimStart('v').Split('.')[0]
if ([int]$nodeMajor -lt 24) { throw 'Node.js 24 or newer is required.' }

if (-not $SkipLogin) {
  if ($PSCmdlet.ShouldProcess("tenant $TenantId", 'Sign in to Azure CLI')) {
    & az login --tenant $TenantId | Out-Null
  }
}

& az account set --subscription $SubscriptionId
$account = & az account show --output json | ConvertFrom-Json
if ($account.tenantId -ne $TenantId) { throw 'The selected subscription is not in the expected tenant.' }

$providers = @('Microsoft.App', 'Microsoft.ContainerService', 'Microsoft.ContainerRegistry', 'Microsoft.Insights', 'Microsoft.DevCenter', 'Microsoft.Quota')
foreach ($provider in $providers) {
  $state = & az provider show --namespace $provider --query registrationState --output tsv
  if ($state -ne 'Registered') {
    Write-Warning "Provider $provider is not registered. Bootstrap Terraform will register required providers."
  }
}

Write-Host "Preflight passed for subscription $SubscriptionId in $Location."
Write-Host 'Next: terraform -chdir=bootstrap init; terraform -chdir=bootstrap apply'
