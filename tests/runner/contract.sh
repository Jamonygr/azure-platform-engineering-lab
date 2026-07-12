#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
runner="$root/runner/ade-terraform"

grep -q 'TERRAFORM_VERSION=1.15.8' "$runner/Dockerfile"
grep -q 'd25ce7b6902013ad905db3d2eab0be4cd905887fe88b81a6171b8d5503c31f3d' "$runner/Dockerfile"
grep -q 'terraform init -backend=false' "$runner/scripts/common.sh"
grep -q 'ARM_USE_MSI=true' "$runner/scripts/common.sh"
grep -q 'ARM_USE_OIDC=false' "$runner/scripts/common.sh"
grep -q 'export ARM_CLIENT_ID=' "$runner/scripts/common.sh"
grep -q 'create_resource_group: false' "$runner/scripts/common.sh"
grep -q 'provisioning_channel: "ade"' "$runner/scripts/common.sh"
grep -q 'platform-metadata.json is missing' "$runner/scripts/common.sh"
grep -q 'ALLOWED_OUTPUTS' "$runner/scripts/common.sh"
grep -q 'persistent environment.tfstate is missing' "$runner/scripts/delete.sh"
grep -q -- '-destroy' "$runner/scripts/delete.sh"
grep -q 'terraform state list' "$runner/scripts/delete.sh"
grep -q 'deploy_sample' "$runner/scripts/deploy.sh"
grep -q 'cleanup_sample_before_destroy' "$runner/scripts/delete.sh"
grep -q 'cleanup_sample_after_destroy' "$runner/scripts/delete.sh"
grep -q 'az webapp deploy' "$runner/scripts/delivery.sh"
grep -q 'az acr build' "$runner/scripts/delivery.sh"
grep -q -- "--source-acr-auth-id '\[caller\]'" "$runner/scripts/delivery.sh"
grep -q 'az containerapp update' "$runner/scripts/delivery.sh"
grep -q 'tag_ade_resource_group' "$runner/scripts/delivery.sh"
grep -q 'platform.expires_at=' "$runner/scripts/delivery.sh"
grep -q 'az aks command invoke' "$runner/scripts/delivery.sh"
grep -q -- '--enable-default-domain' "$runner/scripts/delivery.sh"
grep -q 'helm upgrade --install' "$runner/scripts/delivery.sh"
grep -q 'helm uninstall' "$runner/scripts/delivery.sh"
grep -q 'az acr repository delete' "$runner/scripts/delivery.sh"
grep -q 'acr purge' "$runner/scripts/delivery.sh"
grep -q 'COPY sample/ /samples/' "$runner/Dockerfile"
grep -q 'AKS_PREVIEW_EXTENSION_URL=https://azcliprod.blob.core.windows.net/cli-extensions/aks_preview-21.0.0b8-py2.py3-none-any.whl' "$runner/Dockerfile"
grep -q 'AKS_PREVIEW_EXTENSION_SHA256=aa39868b5441c659afc11d069ef42bd48dbbd86d257058a76dfb552dc2748763' "$runner/Dockerfile"
grep -q 'sha256sum -c /tmp/aks-preview.sha256' "$runner/Dockerfile"
grep -q 'az extension add --source /tmp/aks_preview-21.0.0b8-py2.py3-none-any.whl' "$runner/Dockerfile"
grep -q 'containerapp-1.3.0b4-py2.py3-none-any.whl' "$runner/Dockerfile"
grep -q '8f9bd1ab0cceb683dad4cef73ba26344d0a40e528da920134a5a86c4feda4577' "$runner/Dockerfile"
grep -q "extension show --name containerapp --query version --output tsv).*1.3.0b4" "$runner/Dockerfile"
grep -q 'install-containerapp-extension.sh' "$root/scaffolds/application/base/.github/workflows/deploy.yml"
if grep -q 'az extension add --name aks-preview --version' "$runner/Dockerfile"; then
  echo 'Version-only aks-preview index installation found' >&2
  exit 1
fi
grep -q 'ADE_CORE_IMAGE=mcr.microsoft.com/deployment-environments/runners/core@sha256:0146f2afc24910cffa7d95eb17c21fc5ff6a64516e2cdbfe32e5d77bf4b2dd23' "$runner/Dockerfile"
if grep -q 'deployment-environments/runners/core:latest' "$runner/Dockerfile"; then
  echo 'Movable ADE core image reference found' >&2
  exit 1
fi
[[ "$(grep -Evc '^[[:space:]]*(#|$)' "$root/.trivyignore")" == '1' ]]
grep -Fxq 'AVD-DS-0002' "$root/.trivyignore"
grep -Eq '^USER[[:space:]]+node$' "$root/scaffolds/application/base/Dockerfile"
grep -Eq '^USER[[:space:]]+node$' "$runner/sample/node/Dockerfile"
test -f "$runner/sample/node/src/server.js"
test -f "$runner/sample/node/test/server.test.js"
test -f "$runner/sample/helm/Chart.yaml"
test -f "$runner/sample/helm/templates/ingress.yaml"
for definition in web-app-v1 container-app-v1 aks-workload-v1; do
  test -f "$root/ade/catalog/$definition/environment.yaml"
  grep -q '^version: 1\.0\.0$' "$root/ade/catalog/$definition/environment.yaml"
  grep -q '__ADE_RUNNER_IMAGE__' "$root/ade/catalog/$definition/environment.yaml"
  grep -q 'templatePath: main.tf' "$root/ade/catalog/$definition/environment.yaml"
  grep -q 'id: sample_delivery' "$root/ade/catalog/$definition/environment.yaml"
  grep -q 'id: golden_path' "$root/ade/catalog/$definition/environment.yaml"
  grep -q 'allowed: \["4", "8", "24", "48", "72"\]' "$root/ade/catalog/$definition/environment.yaml"
done
grep -q 'RunnerImage.*sha256 digest' "$root/scripts/Publish-AdeCatalog.ps1"
grep -q 'movable tags are forbidden' "$root/scripts/Publish-AdeCatalog.ps1"
grep -q '\.terraform\.lock\.hcl' "$root/scripts/Publish-AdeCatalog.ps1"
grep -q 'Get-ReviewedTextBlob' "$root/scripts/Publish-AdeCatalog.ps1"
grep -q 'git/trees/.*recursive=1' "$root/scripts/Publish-AdeCatalog.ps1"
if grep -Eq 'Get-Content|Get-ChildItem' "$root/scripts/Publish-AdeCatalog.ps1"; then
  echo 'ADE catalog publisher must read executable content from ReviewedCommit, not the local worktree' >&2
  exit 1
fi
grep -q 'runner/ade-terraform/sample' "$root/scripts/Publish-AdeCatalog.ps1"
grep -q 'Assert-GitHubCommitReachableFromMain' "$root/scripts/Publish-AdeCatalog.ps1"
grep -q 'Set-GitHubAdeCatalogProtection' "$root/scripts/Publish-AdeCatalog.ps1"
grep -q 'Assert-GitHubAdeCatalogProtection' "$root/scripts/Publish-AdeCatalog.ps1"
grep -q 'Published ADE definition.*is immutable' "$root/scripts/Publish-AdeCatalog.ps1"
grep -q 'unexpected added or removed path' "$root/scripts/Publish-AdeCatalog.ps1"
grep -q 'V1 is an exact immutable subtree' "$root/scripts/Publish-AdeCatalog.ps1"
grep -q 'publication history is ambiguous, so v1 replacement is forbidden' "$root/scripts/Publish-AdeCatalog.ps1"
grep -Fq "\$enforceV1Immutability = -not \$newCatalogBranch" "$root/scripts/Publish-AdeCatalog.ps1"
grep -q "existing\[0\]\.mode -cne '100644'" "$root/scripts/Publish-AdeCatalog.ps1"
grep -q 'new \*-v2 path' "$root/scripts/Publish-AdeCatalog.ps1"
grep -Fq "base_tree = \$catalogHeadCommit.tree.sha" "$root/scripts/Publish-AdeCatalog.ps1"
grep -Fq "force = \$false" "$root/scripts/Publish-AdeCatalog.ps1"
if grep -Fq "force = \$true" "$root/scripts/Publish-AdeCatalog.ps1"; then
  echo 'Force-updating the ADE catalog branch is forbidden' >&2
  exit 1
fi
grep -q 'update-expiration-date' "$root/scripts/Invoke-AdeJanitor.ps1"

set +e
movable_runner_output="$(
  pwsh -NoProfile -File "$root/scripts/Publish-AdeCatalog.ps1" \
    -Repository owner/repository \
    -RunnerImage example.azurecr.io/platform/ade-terraform:1.1.0 \
    -LogAnalyticsWorkspaceIdsJson '{"westeurope":"/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.OperationalInsights/workspaces/law-weu","northeurope":"/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.OperationalInsights/workspaces/law-neu","germanywestcentral":"/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.OperationalInsights/workspaces/law-gwc"}' \
    -ActionGroupId /subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Insights/actionGroups/platform \
    -PlatformAdminEmail platform@example.invalid \
    -SharedAcrId /subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.ContainerRegistry/registries/example \
    -DeveloperGroupObjectId 00000000-0000-0000-0000-000000000000 \
    -ReviewedCommit 0000000000000000000000000000000000000000 \
    2>&1
)"
movable_runner_status=$?
set -e
[[ $movable_runner_status -ne 0 ]]
grep -q 'movable tags are forbidden' <<<"$movable_runner_output"

if grep -R -E 'ARM_CLIENT_SECRET|client[_-]?secret' "$runner" --exclude=README.md; then
  echo 'Static credential input found in ADE runner' >&2
  exit 1
fi

temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT
mkdir -p "$temporary/storage"
set +e
missing_state_output="$(
  cd "$temporary"
  ADE_STORAGE="$temporary/storage" \
  ADE_OPERATION_PARAMETERS='{}' \
  ADE_RESOURCE_GROUP_NAME='rg-contract-test' \
  ADE_OPERATION_NAME=delete \
  bash "$runner/scripts/delete.sh" 2>&1
)"
status=$?
set -e
[[ $status -ne 0 ]]
grep -q 'state is missing' <<<"$missing_state_output"

bash "$root/tests/runner/delivery-contract.sh"
node --test "$runner/sample/node/test/server.test.js"

printf 'ADE runner safety contract passed.\n'
