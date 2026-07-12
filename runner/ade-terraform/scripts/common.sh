#!/usr/bin/env bash
set -euo pipefail

readonly STATE_FILE_NAME="environment.tfstate"
readonly METADATA_FILE_NAME="platform-metadata.json"
readonly DELIVERY_FILE_NAME="sample-delivery.json"
# Consumed by deploy.sh and delete.sh after sourcing.
# shellcheck disable=SC2034
readonly PLAN_FILE="/tmp/environment.tfplan"
readonly VAR_FILE="/tmp/environment.tfvars.json"
readonly ALLOWED_OUTPUTS='["endpoint","resource_name","resource_group_names","resource_ids","image_repository","node_resource_group","state_contract","endpoint_strategy","cluster_name"]'

fail() {
  printf 'ADE Terraform runner: %s\n' "$1" >&2
  exit 1
}

require_environment() {
  local name
  for name in ADE_STORAGE ADE_OPERATION_PARAMETERS ADE_RESOURCE_GROUP_NAME; do
    [[ -n "${!name:-}" ]] || fail "$name is required"
  done
  [[ -d "$ADE_STORAGE" ]] || fail "ADE_STORAGE must be an existing directory"
  jq -e 'type == "object"' <<<"$ADE_OPERATION_PARAMETERS" >/dev/null || fail "ADE_OPERATION_PARAMETERS must be a JSON object"
}

read_delivery_controls() {
  local golden_path sample_delivery
  jq -e '((.golden_path // "") | type == "string") and ((.sample_delivery // false) | type == "boolean")' \
    <<<"$ADE_OPERATION_PARAMETERS" >/dev/null || fail "golden_path and sample_delivery have invalid types"
  golden_path="$(jq -r '.golden_path // ""' <<<"$ADE_OPERATION_PARAMETERS")"
  sample_delivery="$(jq -r '.sample_delivery // false' <<<"$ADE_OPERATION_PARAMETERS")"
  [[ "$sample_delivery" == "true" || "$sample_delivery" == "false" ]] || fail "sample_delivery must be a boolean"
  if [[ "$sample_delivery" == "true" ]]; then
    case "$golden_path" in
      web-app | container-app | aks) ;;
      *) fail "golden_path must be web-app, container-app, or aks when sample delivery is enabled" ;;
    esac
  elif [[ -n "$golden_path" ]]; then
    fail "golden_path cannot be set when sample delivery is disabled"
  fi
  printf '%s|%s\n' "$golden_path" "$sample_delivery"
}

validate_adapter_metadata() {
  jq -e '
    .schema_version == 2
    and (.environment_id | test("^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"))
    and (.environment_name | test("^[a-z][a-z0-9-]{1,18}[a-z0-9]$"))
    and ((.owner | type == "string") and (.owner | length) > 0 and (.owner | length) <= 64)
    and (.created_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
    and (.expires_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
    and (.image_repository | test("^apps/[0-9]{16}$"))
    and (.sample_delivery | type == "boolean")
    and (
      if .sample_delivery then
        (.golden_path == "web-app" or .golden_path == "container-app" or .golden_path == "aks")
      else .golden_path == null end
    )
  ' "$1" >/dev/null || fail "persisted ADE adapter metadata is invalid"
}

ensure_adapter_metadata() {
  local metadata_file="$ADE_STORAGE/$METADATA_FILE_NAME"
  local controls requested_path requested_delivery temporary
  controls="$(read_delivery_controls)"
  IFS='|' read -r requested_path requested_delivery <<<"$controls"
  if [[ -s "$metadata_file" ]]; then
    if [[ "${ADE_OPERATION_NAME:-deploy}" == "deploy" && "$requested_delivery" == "true" ]]; then
      local persisted_path
      persisted_path="$(jq -r '.golden_path // ""' "$metadata_file")"
      if [[ -n "$persisted_path" && "$persisted_path" != "$requested_path" ]]; then
        fail "persisted ADE golden path cannot be changed"
      fi
    fi
    temporary="${metadata_file}.tmp"
    jq \
      --arg requested_path "$requested_path" \
      --argjson requested_delivery "$requested_delivery" \
      --arg operation "${ADE_OPERATION_NAME:-deploy}" '
      .schema_version = 2
      | .sample_delivery = (
          (.sample_delivery // false)
          or ($operation == "deploy" and $requested_delivery)
        )
      | .golden_path = (
          if .sample_delivery then
            (.golden_path // (if $requested_path == "" then null else $requested_path end))
          else null end
        )
    ' "$metadata_file" >"$temporary"
    mv "$temporary" "$metadata_file"
    validate_adapter_metadata "$metadata_file"
    return
  fi
  [[ "${ADE_OPERATION_NAME:-deploy}" == "deploy" ]] || fail "persistent platform-metadata.json is missing; refusing an untracked delete"

  local ttl_hours
  ttl_hours="$(jq -r '.ttl_hours // 24' <<<"$ADE_OPERATION_PARAMETERS")"
  [[ "$ttl_hours" =~ ^(4|8|24|48|72)$ ]] || fail "ttl_hours must be 4, 8, 24, 48, or 72"
  ADE_TTL_HOURS="$ttl_hours" \
  ADE_GOLDEN_PATH="$requested_path" \
  ADE_SAMPLE_DELIVERY="$requested_delivery" \
  python3 - "$metadata_file" <<'PY'
import datetime
import json
import os
import re
import secrets
import sys
import time

now = datetime.datetime.now(datetime.timezone.utc)
milliseconds = int(time.time() * 1000)
raw = bytearray(secrets.token_bytes(16))
raw[0:6] = milliseconds.to_bytes(6, "big")
raw[6] = 0x70 | (raw[6] & 0x0F)
raw[8] = 0x80 | (raw[8] & 0x3F)
hexed = raw.hex()
environment_id = f"{hexed[:8]}-{hexed[8:12]}-{hexed[12:16]}-{hexed[16:20]}-{hexed[20:]}"
source_name = os.environ.get("ADE_ENVIRONMENT_NAME", "ade-environment").lower()
slug = re.sub(r"[^a-z0-9-]+", "-", source_name).strip("-")
if not slug or not slug[0].isalpha():
    slug = f"ade-{slug}"
slug = slug[:20].rstrip("-")
if len(slug) < 3:
    slug = f"{slug}-lab"[:20].rstrip("-")
ttl = int(os.environ["ADE_TTL_HOURS"])
metadata = {
    "schema_version": 2,
    "environment_id": environment_id,
    "environment_name": slug,
    "owner": f"ade:{source_name}"[:64],
    "created_at": now.isoformat(timespec="seconds").replace("+00:00", "Z"),
    "expires_at": (now + datetime.timedelta(hours=ttl)).isoformat(timespec="seconds").replace("+00:00", "Z"),
    "image_repository": f"apps/{milliseconds}{secrets.randbelow(1000):03d}",
    "sample_delivery": os.environ["ADE_SAMPLE_DELIVERY"] == "true",
    "golden_path": os.environ["ADE_GOLDEN_PATH"] or None,
}
temporary = f"{sys.argv[1]}.tmp"
with open(temporary, "w", encoding="utf-8") as handle:
    json.dump(metadata, handle, separators=(",", ":"))
os.replace(temporary, sys.argv[1])
PY
  [[ -s "$metadata_file" ]] || fail "could not persist ADE adapter metadata"
  validate_adapter_metadata "$metadata_file"
}

prepare_terraform() {
  require_environment
  if [[ "${ADE_OPERATION_NAME:-deploy}" == "deploy" ]] && jq -e 'has("developer_group_object_id") and .acknowledge_aks_cost != true' <<<"$ADE_OPERATION_PARAMETERS" >/dev/null; then
    fail "acknowledge_aks_cost must be true for the AKS definition"
  fi
  export ARM_USE_MSI=true
  export ARM_USE_OIDC=false
  export TF_IN_AUTOMATION=true
  export TF_INPUT=false
  if [[ -n "${ADE_CLIENT_ID:-}" ]]; then export ARM_CLIENT_ID="$ADE_CLIENT_ID"; fi
  if [[ -n "${ADE_TENANT_ID:-}" ]]; then export ARM_TENANT_ID="$ADE_TENANT_ID"; fi
  if [[ -n "${ADE_SUBSCRIPTION_ID:-}" ]]; then export ARM_SUBSCRIPTION_ID="$ADE_SUBSCRIPTION_ID"; fi
  ensure_adapter_metadata
  jq \
    --arg resource_group_name "$ADE_RESOURCE_GROUP_NAME" \
    --arg fallback_location "${ADE_ENVIRONMENT_LOCATION:-westeurope}" \
    --argjson metadata "$(cat "$ADE_STORAGE/$METADATA_FILE_NAME")" '
    del(.ttl_hours, .acknowledge_aks_cost, .golden_path, .sample_delivery)
    | . + {
        environment_id: $metadata.environment_id,
        environment_name: $metadata.environment_name,
        owner: $metadata.owner,
        expires_at: $metadata.expires_at,
        location: (.location // $fallback_location),
        create_resource_group: false,
        resource_group_name: $resource_group_name,
        provisioning_channel: "ade",
        github_owner: null,
        github_repository: null
      }
    | if has("shared_acr_id") then .image_repository = $metadata.image_repository else . end
    | if has("log_analytics_workspace_ids") then
        .log_analytics_workspace_id = (
          .log_analytics_workspace_ids[.location]
          // error("no same-region Log Analytics workspace is configured")
        )
        | del(.log_analytics_workspace_ids)
      else . end
    | if has("developer_group_object_id") then .default_domain_preflight_passed = true else . end
    ' \
    <<<"$ADE_OPERATION_PARAMETERS" >"$VAR_FILE"
  terraform init -backend=false -input=false -no-color
}

write_allowlisted_outputs() {
  [[ -n "${ADE_OUTPUTS:-}" ]] || fail "ADE_OUTPUTS is required during deploy"
  local raw
  raw="$(terraform output -state="$ADE_STORAGE/$STATE_FILE_NAME" -json)"
  if [[ -s "$ADE_STORAGE/$DELIVERY_FILE_NAME" ]]; then
    raw="$(jq --slurpfile delivery "$ADE_STORAGE/$DELIVERY_FILE_NAME" '
      if ($delivery[0].status == "active" and ($delivery[0].endpoint | type == "string") and $delivery[0].endpoint != "") then
        .endpoint = {sensitive: false, type: "string", value: $delivery[0].endpoint}
      else . end
      | if (($delivery[0].resource_name | type == "string") and $delivery[0].resource_name != "") then
          .resource_name = {sensitive: false, type: "string", value: $delivery[0].resource_name}
        else . end
    ' <<<"$raw")"
  fi
  jq --argjson allowed "$ALLOWED_OUTPUTS" '
    with_entries(select(.key as $key | $allowed | index($key)))
    | with_entries(select(.value.sensitive != true))
    | walk(
        if type == "object" and has("type") then
          if .type == "bool" then .type = "boolean"
          elif .type == "list" or .type == "set" then .type = "array"
          elif .type == "map" then .type = "object"
          elif (.type | type) == "array" then
            if .type[0] == "tuple" or .type[0] == "set" then .type = "array"
            elif .type[0] == "object" then .type = "object"
            else . end
          else . end
        else . end
      )
    | {outputs: .}
  ' <<<"$raw" >"$ADE_OUTPUTS"
}
