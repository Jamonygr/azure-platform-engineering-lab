[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$scanRoots = @('.github', 'controller', 'scaffolds', 'runner', 'scripts') |
  ForEach-Object { Join-Path $repositoryRoot $_ } |
  Where-Object { Test-Path $_ }

# Construct forbidden names so this policy file does not flag its own source.
$forbidden = @(
  ('AZURE' + '_CLIENT' + '_SECRET'),
  ('ARM' + '_CLIENT' + '_SECRET'),
  ('service' + 'Principal' + 'Key'),
  ('client' + '_secret' + '\s*[:=]\s*["''][^"'']+["'']')
)

$violations = @()
foreach ($root in $scanRoots) {
  $files = Get-ChildItem -LiteralPath $root -File -Recurse |
    Where-Object { $_.FullName -ne $PSCommandPath -and $_.Extension -notin @('.svg', '.png', '.jpg') }
  foreach ($pattern in $forbidden) {
    $violations += $files | Select-String -Pattern $pattern -CaseSensitive:$false
  }
}

if ($violations.Count -gt 0) {
  $violations | ForEach-Object { Write-Error "$($_.Path):$($_.LineNumber): static credential pattern detected" }
  throw 'Static Azure credential policy failed. Use GitHub Actions OIDC and managed identity.'
}

Write-Host 'Static credential policy passed: no Azure client-secret patterns found.'
