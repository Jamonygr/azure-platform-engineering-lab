Set-StrictMode -Version Latest

function Get-GitBlobSha {
  param([Parameter(Mandatory)] [byte[]] $Bytes)

  $header = [Text.Encoding]::UTF8.GetBytes("blob $($Bytes.Length)`0")
  $buffer = [byte[]]::new($header.Length + $Bytes.Length)
  [Array]::Copy($header, 0, $buffer, 0, $header.Length)
  [Array]::Copy($Bytes, 0, $buffer, $header.Length, $Bytes.Length)
  $sha1 = [Security.Cryptography.SHA1]::Create()
  try { return [Convert]::ToHexString($sha1.ComputeHash($buffer)).ToLowerInvariant() }
  finally { $sha1.Dispose() }
}

function Get-CanonicalTree {
  param([Parameter(Mandatory)] [string] $CanonicalRoot)

  if (-not (Test-Path -LiteralPath $CanonicalRoot)) {
    throw 'Canonical generated-repository scaffold is missing.'
  }
  $expected = @{}
  Get-ChildItem -LiteralPath $CanonicalRoot -Force -File -Recurse | ForEach-Object {
    $path = [IO.Path]::GetRelativePath($CanonicalRoot, $_.FullName).Replace('\', '/')
    $expected[$path] = Get-GitBlobSha -Bytes ([IO.File]::ReadAllBytes($_.FullName))
  }
  if ($expected.Count -eq 0 -or -not $expected.ContainsKey('.github/workflows/deploy.yml')) {
    throw 'Canonical scaffold tree is empty or lacks the inert deployment workflow.'
  }
  return $expected
}

function Assert-ExactCanonicalTree {
  param(
    [Parameter(Mandatory)] [hashtable] $Headers,
    [Parameter(Mandatory)] [string] $RepositoryOwner,
    [Parameter(Mandatory)] [string] $RepositoryName,
    [Parameter(Mandatory)] [hashtable] $Expected,
    [switch] $RequireTemplate
  )

  $repositoryApi = "https://api.github.com/repos/$([uri]::EscapeDataString($RepositoryOwner))/$([uri]::EscapeDataString($RepositoryName))"
  $repositoryObject = Invoke-RestMethod -Uri $repositoryApi -Headers $Headers
  if ($repositoryObject.private -or [string]$repositoryObject.default_branch -ne 'main') {
    throw "$RepositoryOwner/$RepositoryName must be public with exact default branch main."
  }
  if ($RequireTemplate -and -not $repositoryObject.is_template) {
    throw "$RepositoryOwner/$RepositoryName is not marked as a GitHub template repository."
  }
  $reference = Invoke-RestMethod -Uri "$repositoryApi/git/ref/heads/main" -Headers $Headers
  $commit = Invoke-RestMethod -Uri "$repositoryApi/git/commits/$($reference.object.sha)" -Headers $Headers
  $remoteTree = Invoke-RestMethod -Uri "$repositoryApi/git/trees/$($commit.tree.sha)?recursive=1" -Headers $Headers
  if ($remoteTree.truncated) { throw "$RepositoryOwner/$RepositoryName returned a truncated Git tree." }
  $blobs = @($remoteTree.tree | Where-Object type -eq 'blob')
  if ($blobs.Count -ne $Expected.Count) {
    throw "$RepositoryOwner/$RepositoryName contains $($blobs.Count) files; the reviewed canonical tree contains $($Expected.Count)."
  }
  foreach ($blob in $blobs) {
    if (-not $Expected.ContainsKey([string]$blob.path) -or [string]$Expected[[string]$blob.path] -ne [string]$blob.sha) {
      throw "$RepositoryOwner/$RepositoryName differs from the reviewed canonical scaffold at $($blob.path)."
    }
  }
}

function Assert-AmbiguousRepositoryProvenance {
  param(
    [Parameter(Mandatory)] $Repository,
    [Parameter(Mandatory)] [string] $ExpectedTemplate,
    [Parameter(Mandatory)] [hashtable] $Headers,
    [Parameter(Mandatory)] [hashtable] $ExpectedTree
  )

  # A matching name, description, and creation time are mutable claims. For an
  # ambiguous template-generation response, attachment and deletion are
  # forbidden unless GitHub also reports the exact reviewed template lineage
  # and the repository still has the byte-for-byte canonical initial tree.
  if (-not $Repository.template_repository -or
      [string]$Repository.template_repository.full_name -ne $ExpectedTemplate) {
    throw 'AMBIGUOUS_REPOSITORY_PROVENANCE_UNPROVEN: exact GitHub template lineage is absent or mismatched; attachment and deletion are forbidden.'
  }
  Assert-ExactCanonicalTree `
    -Headers $Headers `
    -RepositoryOwner ([string]$Repository.owner.login) `
    -RepositoryName ([string]$Repository.name) `
    -Expected $ExpectedTree
}
