#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
temporary="$(mktemp -d)"
trap 'rm -rf "$temporary" /tmp/ade-node-sample.zip /tmp/ade-node-sample-chart.tgz' EXIT
mkdir -p "$temporary/storage"
export ADE_STORAGE="$temporary/storage"
export ADE_RESOURCE_GROUP_NAME=rg-ade-delivery-contract
export ADE_SAMPLE_ROOT="$root/runner/ade-terraform/sample"

# shellcheck disable=SC1091
source "$root/runner/ade-terraform/scripts/common.sh"
# shellcheck disable=SC1091
source "$root/runner/ade-terraform/scripts/delivery.sh"

log="$temporary/commands.log"

ensure_azure_cli_identity() { :; }
smoke_test_endpoint() { printf 'smoke %s\n' "$1" >>"$log"; }
build_container_image() { printf 'build %s %s %s %s\n' "$1" "$2" "$3" "$4" >>"$log"; }
create_web_zip() { printf 'zip\n' >"$2"; }
shared_acr_name() { printf 'pelabacr\n'; }
shared_acr_login_server() { printf 'pelabacr.azurecr.io\n'; }
wait_for_default_domain() { printf 'signed-default.example.aksapp.io\n'; }

terraform_output_raw() {
  local golden_path
  golden_path="$(jq -r '.golden_path' "$ADE_STORAGE/$METADATA_FILE_NAME")"
  case "$1" in
    endpoint)
      case "$golden_path" in
        web-app) printf 'https://app-contract.azurewebsites.net\n' ;;
        container-app) printf 'https://ca-contract.azurecontainerapps.io\n' ;;
      esac
      ;;
    resource_name)
      case "$golden_path" in
        web-app) printf 'app-contract\n' ;;
        container-app) printf 'ca-contract\n' ;;
      esac
      ;;
    cluster_name) printf 'aks-contract\n' ;;
    node_resource_group) printf 'rg-contract-aksnodes\n' ;;
    image_repository) printf 'apps/1234567890123456\n' ;;
  esac
}

az() {
  printf 'az %s\n' "$*" >>"$log"
  case "$*" in
    'acr repository delete '*) return 1 ;;
    'group exists '*) printf 'false\n' ;;
    'group show '*) printf '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-ade-delivery-contract\n' ;;
  esac
}

write_metadata() {
  local golden_path="$1"
  jq -n --arg golden_path "$golden_path" '{
    schema_version: 2,
    environment_id: "018f8f5e-8c4a-7abc-8def-1234567890ab",
    environment_name: "contract",
    owner: "ade:contract",
    created_at: "2026-07-11T00:00:00Z",
    expires_at: "2026-07-12T00:00:00Z",
    image_repository: "apps/1234567890123456",
    sample_delivery: true,
    golden_path: $golden_path
  }' >"$ADE_STORAGE/$METADATA_FILE_NAME"
  jq -n '{
    location: "westeurope",
    shared_acr_id: "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-platform/providers/Microsoft.ContainerRegistry/registries/pelabacr"
  }' >"$VAR_FILE"
  rm -f "$ADE_STORAGE/$DELIVERY_FILE_NAME"
  : >"$log"
}

write_metadata web-app
tag_ade_resource_group
grep -q 'az tag update .*platform.expires_at=2026-07-12T00:00:00Z' "$log"
cp "$ADE_STORAGE/$METADATA_FILE_NAME" "$temporary/valid-metadata.json"
jq '.expires_at = "not-an-iso-expiry"' "$ADE_STORAGE/$METADATA_FILE_NAME" >"$temporary/invalid-metadata.json"
mv "$temporary/invalid-metadata.json" "$ADE_STORAGE/$METADATA_FILE_NAME"
set +e
invalid_metadata_output="$(tag_ade_resource_group 2>&1)"
invalid_metadata_status=$?
set -e
[[ $invalid_metadata_status -ne 0 ]]
grep -q 'adapter metadata is invalid' <<<"$invalid_metadata_output"
cp "$temporary/valid-metadata.json" "$ADE_STORAGE/$METADATA_FILE_NAME"
deploy_sample
jq -e '.status == "active" and .golden_path == "web-app" and .resource_name == "app-contract"' "$ADE_STORAGE/$DELIVERY_FILE_NAME" >/dev/null
grep -q 'az webapp deploy' "$log"
grep -q 'smoke https://app-contract.azurewebsites.net' "$log"
cleanup_sample_before_destroy
grep -q 'az webapp stop' "$log"
temporary_record="$temporary/tampered-delivery.json"
jq '.resource_group = "rg-not-this-environment"' "$ADE_STORAGE/$DELIVERY_FILE_NAME" >"$temporary_record"
mv "$temporary_record" "$ADE_STORAGE/$DELIVERY_FILE_NAME"
set +e
tamper_output="$(cleanup_sample_before_destroy 2>&1)"
tamper_status=$?
set -e
[[ $tamper_status -ne 0 ]]
grep -q 'does not belong to the ADE resource group' <<<"$tamper_output"

write_metadata container-app
deploy_sample
jq -e '.status == "active" and .image_repository == "apps/1234567890123456"' "$ADE_STORAGE/$DELIVERY_FILE_NAME" >/dev/null
grep -q 'build pelabacr apps/1234567890123456' "$log"
grep -q 'az containerapp update' "$log"
cleanup_sample_before_destroy
cleanup_sample_after_destroy
grep -q 'az containerapp ingress disable' "$log"
grep -q 'az acr run' "$log"

write_metadata aks
deploy_sample
jq -e '.status == "active" and .endpoint == "https://ade-sample.signed-default.example.aksapp.io" and .node_resource_group == "rg-contract-aksnodes"' "$ADE_STORAGE/$DELIVERY_FILE_NAME" >/dev/null
grep -q -- '--enable-default-domain' "$log"
grep -q 'helm upgrade --install ade-node-sample' "$log"
cleanup_sample_before_destroy
cleanup_sample_after_destroy
grep -q 'helm uninstall ade-node-sample' "$log"
grep -q -- '--disable-default-domain' "$log"
grep -q 'az acr run' "$log"
grep -q 'az group exists --name rg-contract-aksnodes' "$log"

terraform() {
  printf '%s\n' '{"endpoint":{"sensitive":false,"type":"string","value":""},"cluster_name":{"sensitive":false,"type":"string","value":"aks-contract"}}'
}
export ADE_OUTPUTS="$temporary/outputs.json"
write_allowlisted_outputs
jq -e '.outputs.endpoint.value == "https://ade-sample.signed-default.example.aksapp.io"' "$ADE_OUTPUTS" >/dev/null
jq -e '.outputs.resource_name.value == "aks-contract"' "$ADE_OUTPUTS" >/dev/null

printf 'ADE fixed-sample delivery contract passed.\n'
