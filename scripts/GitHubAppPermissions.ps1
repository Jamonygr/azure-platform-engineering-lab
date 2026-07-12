function Get-ExpectedGitHubAppPermissions {
  [CmdletBinding()]
  param([Parameter(Mandatory)] [ValidateSet('personal', 'organization')] [string] $OwnerMode)

  $expected = [ordered]@{
    actions        = 'write'
    administration = 'write'
    contents       = 'write'
    metadata       = 'read'
    variables      = 'write'
  }
  if ($OwnerMode -eq 'organization') { $expected.members = 'read' }
  return $expected
}

function Assert-GitHubAppPermissions {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] $Permissions,
    [Parameter(Mandatory)] [ValidateSet('personal', 'organization')] [string] $OwnerMode
  )

  $expected = Get-ExpectedGitHubAppPermissions -OwnerMode $OwnerMode
  $actual = @{}
  if ($Permissions -is [Collections.IDictionary]) {
    foreach ($key in $Permissions.Keys) { $actual[[string]$key] = [string]$Permissions[$key] }
  }
  else {
    foreach ($property in $Permissions.PSObject.Properties) { $actual[[string]$property.Name] = [string]$property.Value }
  }

  $unexpected = @($actual.Keys | Where-Object { -not $expected.Contains($_) } | Sort-Object)
  $missingOrWrong = @($expected.Keys | Where-Object {
    -not $actual.ContainsKey($_) -or [string]$actual[$_] -cne [string]$expected[$_]
  })
  if ($unexpected.Count -gt 0 -or $missingOrWrong.Count -gt 0 -or $actual.Count -ne $expected.Count) {
    $expectedJson = $expected | ConvertTo-Json -Compress
    $actualJson = $actual | ConvertTo-Json -Compress
    throw "GitHub App permissions must exactly match the reviewed least-privilege contract for $OwnerMode mode. Expected $expectedJson; received $actualJson."
  }
}
