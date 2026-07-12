#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT
cp -R "$root/tests/runner/fixture/." "$temporary/"
mkdir -p "$temporary/storage"
export ADE_STORAGE="$temporary/storage"
export ADE_OPERATION_PARAMETERS='{}'
export ADE_RESOURCE_GROUP_NAME='rg-ade-contract'
export ADE_OUTPUTS="$temporary/outputs.json"

pushd "$temporary" >/dev/null
ADE_OPERATION_NAME=deploy bash "$root/runner/ade-terraform/scripts/deploy.sh"
ADE_OPERATION_NAME=deploy bash "$root/runner/ade-terraform/scripts/deploy.sh"
jq -e '.outputs.endpoint.value == "https://contract.example.invalid"' "$ADE_OUTPUTS" >/dev/null
jq -e 'has("outputs") and (.outputs | has("deployment_client_id") | not)' "$ADE_OUTPUTS" >/dev/null
jq -e '.schema_version == 2 and .sample_delivery == false and .golden_path == null' "$ADE_STORAGE/platform-metadata.json" >/dev/null
test ! -e "$ADE_STORAGE/sample-delivery.json"
ADE_OPERATION_NAME=delete bash "$root/runner/ade-terraform/scripts/delete.sh"
[[ -z "$(terraform state list -state="$ADE_STORAGE/environment.tfstate")" ]]
popd >/dev/null

printf 'ADE runner deploy/redeploy/delete smoke test passed.\n'
