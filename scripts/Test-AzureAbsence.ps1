[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $RecordJson,
  [Parameter(Mandatory)] [string] $EvidenceFile
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$record = $RecordJson | ConvertFrom-Json
$pathDirectoryName = switch ($record.goldenPath) {
  'web-app' { 'web-app-v1' }
  'container-app' { 'container-app-v1' }
  'aks' { 'aks-workload-v1' }
  default { throw 'Unsupported golden path in inventory.' }
}
$terraformDirectory = Join-Path $root "golden-paths/$pathDirectoryName"

if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw 'Azure CLI is required for absence verification.' }
. (Join-Path $PSScriptRoot 'AzureResourceGraph.ps1')

function Get-AzureCliErrorCode {
  param([object[]] $Output)

  $text = $Output | Out-String
  if ($text -match '(?m)^\s*(?:ERROR:\s*)?\((?<code>[A-Za-z0-9_.-]+)\)') {
    return $Matches.code
  }
  if ($text -match '"code"\s*:\s*"(?<code>[A-Za-z0-9_.-]+)"') {
    return $Matches.code
  }
  return $null
}

function Test-ProvenAzureAbsence {
  param(
    [Parameter(Mandatory)] [string] $ResourceId,
    [object[]] $Output
  )

  $code = Get-AzureCliErrorCode -Output $Output
  if ($code -in @('ResourceNotFound', 'ResourceGroupNotFound', 'ParentResourceNotFound')) { return $true }
  if ($ResourceId -match '(?i)/providers/Microsoft\.Authorization/roleAssignments/[^/]+$') {
    return $code -eq 'RoleAssignmentNotFound'
  }
  if ($ResourceId -match '(?i)/providers/Microsoft\.Authorization/policyAssignments/[^/]+$') {
    return $code -eq 'PolicyAssignmentNotFound'
  }
  if ($ResourceId -match '(?i)/providers/Microsoft\.Consumption/budgets/[^/]+$') {
    return $code -eq 'BudgetNotFound'
  }
  return $false
}

function Invoke-AbsencePass {
  $state = & terraform "-chdir=$terraformDirectory" state list 2>&1
  if ($LASTEXITCODE -ne 0) { throw "Terraform state inspection failed: $state" }
  $stateCount = @($state | Where-Object { $_ -and $_ -notmatch '^\s*$' }).Count
  if ($stateCount -ne 0) { throw "Terraform state still contains $stateCount resource(s)." }

  foreach ($resourceId in @($record.resourceIds)) {
    if ($resourceId -match '/resourceGroups/[^/]+$') {
      $groupName = ($resourceId -split '/resourceGroups/')[1]
      $exists = & az group exists --name $groupName --output tsv
      if ($LASTEXITCODE -ne 0 -or $exists -eq 'true') { throw "Tracked resource group still exists: $resourceId" }
    }
    else {
      $resourceCheck = & az resource show --ids $resourceId --output none 2>&1
      $resourceCheckExit = $LASTEXITCODE
      if ($resourceCheckExit -eq 0) { throw "Tracked Azure resource still exists: $resourceId" }
      if (-not (Test-ProvenAzureAbsence -ResourceId $resourceId -Output @($resourceCheck))) {
        throw "Could not prove tracked resource absence for ${resourceId}: $($resourceCheck | Out-String)"
      }
    }
  }
  foreach ($groupName in @($record.resourceGroupNames)) {
    $exists = & az group exists --name $groupName --output tsv
    if ($LASTEXITCODE -ne 0 -or $exists -eq 'true') { throw "Tracked resource group still exists: $groupName" }
  }

  $safeId = $record.environmentId.Replace("'", "''")
  $query = "Resources | where tags['platform.environment_id'] == '$safeId' | count"
  $graphResult = Invoke-PlatformResourceGraphQuery -Query $query -First 1
  $matches = [string]$graphResult.data[0].Count
  if (-not ($matches -match '^\d+$')) { throw 'Azure Resource Graph verification returned no numeric count.' }
  if ([int]$matches -ne 0) { throw "Azure Resource Graph found $matches residual resource(s)." }
  if ($record.imageRepository) {
    if (-not $record.sharedAcrId -or -not $env:SHARED_ACR_ID -or $record.sharedAcrId.TrimEnd('/').ToLowerInvariant() -ne $env:SHARED_ACR_ID.TrimEnd('/').ToLowerInvariant()) {
      throw 'The configured and inventoried shared ACR IDs must match before repository absence can be checked.'
    }
    $acrName = ($record.sharedAcrId -split '/')[-1]
    $acrGroup = ($record.sharedAcrId -split '/resourceGroups/')[1].Split('/')[0]
    $actualAcrId = & az acr show --name $acrName --resource-group $acrGroup --query id --output tsv 2>&1
    if ($LASTEXITCODE -ne 0 -or -not $actualAcrId -or $actualAcrId.TrimEnd('/').ToLowerInvariant() -ne $record.sharedAcrId.TrimEnd('/').ToLowerInvariant()) {
      throw "The exact inventoried shared ACR could not be proven: $($actualAcrId | Out-String)"
    }
    $acrCheck = & az acr repository show --name $acrName --repository $record.imageRepository --output none 2>&1
    $acrCheckExit = $LASTEXITCODE
    if ($acrCheckExit -eq 0) { throw "Tracked ACR repository still exists: $($record.imageRepository)" }
    if (($acrCheck | Out-String) -notmatch '(?i)\bNAME_UNKNOWN\b') {
      throw "Could not prove tracked ACR repository absence: $($acrCheck | Out-String)"
    }
  }
  return @{ stateCount = $stateCount; graphCount = [int]$matches }
}

& (Join-Path $PSScriptRoot 'Assert-ActiveLease.ps1') -Before 'the first Azure absence pass'
$first = Invoke-AbsencePass
Start-Sleep -Seconds 10
& (Join-Path $PSScriptRoot 'Assert-ActiveLease.ps1') -Before 'the second Azure absence pass'
$second = Invoke-AbsencePass
$evidence = [ordered]@{
  verifiedAt = [DateTimeOffset]::UtcNow.ToString('o')
  consecutivePasses = 2
  remainingStateResources = $second.stateCount
  resourceGraphMatchCount = $second.graphCount
  checkedResourceIds = @($record.resourceIds)
  checkedResourceGroupNames = @($record.resourceGroupNames)
  imageRepositoryAbsent = $true
}
if ($record.imageRepository) { $evidence['checkedImageRepository'] = [string]$record.imageRepository }
$evidence | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $EvidenceFile -Encoding utf8NoBOM
$evidence | ConvertTo-Json -Compress
