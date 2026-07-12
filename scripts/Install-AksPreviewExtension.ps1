[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$version = '21.0.0b8'
$sha256 = 'aa39868b5441c659afc11d069ef42bd48dbbd86d257058a76dfb552dc2748763'
$downloadUrl = "https://azcliprod.blob.core.windows.net/cli-extensions/aks_preview-$version-py2.py3-none-any.whl"
$extensionRoot = if ($env:RUNNER_TEMP) { Join-Path $env:RUNNER_TEMP 'pelab-azure-cli-extensions' } else { Join-Path ([System.IO.Path]::GetTempPath()) 'pelab-azure-cli-extensions' }
$env:AZURE_EXTENSION_DIR = $extensionRoot
New-Item -ItemType Directory -Path $extensionRoot -Force | Out-Null

$installedVersion = & az extension show --name aks-preview --query version --output tsv 2>$null
if ($LASTEXITCODE -ne 0 -or [string]$installedVersion -ne $version) {
  $wheel = Join-Path ([System.IO.Path]::GetTempPath()) "aks_preview-$version-$([guid]::NewGuid().ToString('N')).whl"
  try {
    Invoke-WebRequest -Uri $downloadUrl -OutFile $wheel -MaximumRetryCount 4 -RetryIntervalSec 3
    $actualSha256 = (Get-FileHash -LiteralPath $wheel -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualSha256 -ne $sha256) {
      throw "AKS preview extension checksum mismatch: expected $sha256, received $actualSha256."
    }
    & az extension add --source $wheel --yes --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw "Could not install checksum-pinned aks-preview $version." }
  }
  finally { Remove-Item -LiteralPath $wheel -Force -ErrorAction SilentlyContinue }
}

$verifiedVersion = & az extension show --name aks-preview --query version --output tsv 2>&1
if ($LASTEXITCODE -ne 0 -or [string]$verifiedVersion -ne $version) {
  throw "Expected aks-preview $version after installation; received $($verifiedVersion | Out-String)."
}
$capability = & az aks approuting update --help 2>&1
if ($LASTEXITCODE -ne 0 -or ($capability | Out-String) -notmatch '(?m)--enable-default-domain\b') {
  throw "aks-preview $version does not expose the required --enable-default-domain capability."
}

Write-Host "Verified checksum-pinned aks-preview $version in $extensionRoot."
