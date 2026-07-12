#!/usr/bin/env bash

# Application delivery for the optional ADE maintenance-mode compatibility
# runner. The ADE project identity authenticates every Azure CLI operation;
# no static Azure credential is accepted by this script.

delivery_enabled() {
  jq -e '.sample_delivery == true' "$ADE_STORAGE/$METADATA_FILE_NAME" >/dev/null
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "$1 is required for fixed sample delivery"
}

resolve_sample_root() {
  local candidate
  for candidate in "${ADE_SAMPLE_ROOT:-}" "$PWD/sample" /samples "$(dirname "${BASH_SOURCE[0]}")/../sample"; do
    if [[ -n "$candidate" && -f "$candidate/node/package.json" ]]; then
      (cd "$candidate" && pwd)
      return
    fi
  done
  fail "fixed Node sample assets are missing from the catalog and runner image"
}

ensure_azure_cli_identity() {
  require_command az
  if ! az account show --only-show-errors --output none >/dev/null 2>&1; then
    local login_arguments=(--identity --allow-no-subscriptions --only-show-errors --output none)
    if [[ -n "${ARM_CLIENT_ID:-}" ]]; then
      login_arguments+=(--client-id "$ARM_CLIENT_ID")
    fi
    az login "${login_arguments[@]}"
  fi

  local subscription_id="${ARM_SUBSCRIPTION_ID:-${ADE_SUBSCRIPTION_ID:-}}"
  if [[ -n "$subscription_id" ]]; then
    az account set --subscription "$subscription_id" --only-show-errors
  fi
}

tag_ade_resource_group() {
  local metadata_file="$ADE_STORAGE/$METADATA_FILE_NAME" resource_group_id golden_path golden_path_tag
  validate_adapter_metadata "$metadata_file"
  resource_group_id="$(az group show \
    --name "$ADE_RESOURCE_GROUP_NAME" \
    --query id \
    --output tsv \
    --only-show-errors)"
  [[ "$resource_group_id" =~ ^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/]+$ ]] \
    || fail "could not resolve the ADE-owned resource group ID for expiry tagging"
  golden_path="$(jq -r '.golden_path' "$metadata_file")"
  case "$golden_path" in
    web-app) golden_path_tag=web-app-v1 ;;
    container-app) golden_path_tag=container-app-v1 ;;
    aks) golden_path_tag=aks-workload-v1 ;;
    *) fail "cannot tag an ADE resource group for an unknown golden path" ;;
  esac
  az tag update \
    --resource-id "$resource_group_id" \
    --operation Merge \
    --tags \
      "platform.environment_id=$(jq -r '.environment_id' "$metadata_file")" \
      "platform.environment=$(jq -r '.environment_name' "$metadata_file")" \
      "platform.owner=$(jq -r '.owner' "$metadata_file")" \
      "platform.created_at=$(jq -r '.created_at' "$metadata_file")" \
      "platform.expires_at=$(jq -r '.expires_at' "$metadata_file")" \
      "platform.golden_path=$golden_path_tag" \
      platform.channel=ade \
      platform.managed=terraform \
      platform.public_https=expected \
    --only-show-errors \
    --output none
}

preflight_sample_delivery() {
  delivery_enabled || return 0
  require_command curl
  require_command jq
  require_command python3
  require_command tar
  resolve_sample_root >/dev/null
  ensure_azure_cli_identity
  tag_ade_resource_group

  local golden_path
  golden_path="$(jq -r '.golden_path' "$ADE_STORAGE/$METADATA_FILE_NAME")"
  if [[ "$golden_path" == "container-app" || "$golden_path" == "aks" ]]; then
    local acr_name
    acr_name="$(shared_acr_name)"
    shared_acr_login_server >/dev/null
    az acr repository list --name "$acr_name" --only-show-errors --output none \
      || fail "ADE managed identity lacks the shared ACR Repository Catalog Lister role"
  fi
  if [[ "$golden_path" == "aks" ]]; then
    [[ -f "$(resolve_sample_root)/helm/Chart.yaml" ]] || fail "AKS Helm sample assets are missing"
    local gateway_api_feature_state
    gateway_api_feature_state="$(az feature show \
      --namespace Microsoft.ContainerService \
      --name AppRoutingIstioGatewayAPIPreview \
      --query properties.state \
      --output tsv \
      --only-show-errors)" \
      || fail "could not read AppRoutingIstioGatewayAPIPreview registration state"
    [[ "$gateway_api_feature_state" == "Registered" ]] \
      || fail "AKS Gateway API Standard requires Microsoft.ContainerService/AppRoutingIstioGatewayAPIPreview in state Registered"
    az aks approuting update --help 2>&1 | grep -q -- '--enable-default-domain' \
      || fail "AKS managed default-domain preview is unavailable; no insecure fallback is permitted"
    az aks approuting defaultdomain show --help >/dev/null 2>&1 \
      || fail "AKS default-domain discovery is unavailable; no insecure fallback is permitted"
  fi
}

terraform_output_raw() {
  terraform output -state="$ADE_STORAGE/$STATE_FILE_NAME" -raw "$1" 2>/dev/null || true
}

resource_name_from_inventory() {
  local marker="$1" inventory
  inventory="$(terraform output -state="$ADE_STORAGE/$STATE_FILE_NAME" -json resource_ids 2>/dev/null || printf '[]')"
  jq -r --arg marker "${marker,,}" '
    first(
      .[]
      | select((ascii_downcase | contains($marker)))
      | split("/")[-1]
    ) // ""
  ' <<<"$inventory"
}

resolve_resource_name() {
  local marker="$1" fallback_prefix="$2" name environment_name short_id
  name="$(terraform_output_raw resource_name)"
  if [[ -z "$name" ]]; then
    name="$(resource_name_from_inventory "$marker")"
  fi
  if [[ -z "$name" ]]; then
    environment_name="$(jq -r '.environment_name' "$ADE_STORAGE/$METADATA_FILE_NAME")"
    short_id="$(jq -r '.environment_id | gsub("-"; "") | .[0:8]' "$ADE_STORAGE/$METADATA_FILE_NAME")"
    name="${fallback_prefix}-${environment_name}-${short_id}"
  fi
  [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9-]{1,62}$ ]] || fail "could not resolve a safe Azure resource name"
  printf '%s\n' "$name"
}

shared_acr_id() {
  local id
  id="$(jq -r '.shared_acr_id // ""' "$VAR_FILE")"
  [[ "$id" =~ ^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[A-Za-z0-9._()-]+/providers/Microsoft\.ContainerRegistry/registries/[A-Za-z0-9]+$ ]] \
    || fail "shared_acr_id is not a valid Azure Container Registry resource ID"
  printf '%s\n' "$id"
}

shared_acr_name() {
  local id name
  id="$(shared_acr_id)"
  name="${id##*/}"
  printf '%s\n' "${name,,}"
}

shared_acr_login_server() {
  local login_server
  login_server="$(az acr show --ids "$(shared_acr_id)" --query loginServer --output tsv --only-show-errors)"
  [[ "$login_server" =~ ^[a-z0-9]+\.azurecr\.io$ ]] || fail "could not resolve the shared ACR login server"
  printf '%s\n' "$login_server"
}

image_repository() {
  local repository
  repository="$(terraform_output_raw image_repository)"
  if [[ -z "$repository" ]]; then
    repository="$(jq -r '.image_repository' "$ADE_STORAGE/$METADATA_FILE_NAME")"
  fi
  [[ "$repository" =~ ^apps/[0-9]{16}$ ]] || fail "ADE image repository is outside its immutable apps/<repository-id> scope"
  printf '%s\n' "$repository"
}

image_tag() {
  jq -r '"ade-v1-" + (.environment_id | gsub("-"; "") | .[0:12])' "$ADE_STORAGE/$METADATA_FILE_NAME"
}

write_delivery_record() {
  local golden_path="$1" resource_name="$2" endpoint="$3" acr_name="$4" repository="$5" image_reference="$6" node_resource_group="$7"
  local metadata_file="$ADE_STORAGE/$METADATA_FILE_NAME" delivery_file="$ADE_STORAGE/$DELIVERY_FILE_NAME"
  local temporary="${delivery_file}.tmp"
  jq -n \
    --arg golden_path "$golden_path" \
    --arg resource_group "$ADE_RESOURCE_GROUP_NAME" \
    --arg resource_name "$resource_name" \
    --arg endpoint "$endpoint" \
    --arg acr_name "$acr_name" \
    --arg image_repository "$repository" \
    --arg image_reference "$image_reference" \
    --arg node_resource_group "$node_resource_group" \
    --arg environment_id "$(jq -r '.environment_id' "$metadata_file")" \
    --arg created_at "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" '
    {
      schema_version: 1,
      status: "deploying",
      golden_path: $golden_path,
      environment_id: $environment_id,
      resource_group: $resource_group,
      resource_name: $resource_name,
      endpoint: $endpoint,
      acr_name: $acr_name,
      image_repository: $image_repository,
      image_reference: $image_reference,
      node_resource_group: $node_resource_group,
      updated_at: $created_at
    }
  ' >"$temporary"
  mv "$temporary" "$delivery_file"
}

update_delivery_endpoint() {
  local endpoint="$1" delivery_file="$ADE_STORAGE/$DELIVERY_FILE_NAME" temporary
  temporary="${delivery_file}.tmp"
  jq --arg endpoint "$endpoint" --arg updated_at "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" '
    .endpoint = $endpoint | .updated_at = $updated_at
  ' "$delivery_file" >"$temporary"
  mv "$temporary" "$delivery_file"
}

activate_delivery_record() {
  local delivery_file="$ADE_STORAGE/$DELIVERY_FILE_NAME" temporary
  temporary="${delivery_file}.tmp"
  jq --arg updated_at "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" '
    .status = "active" | .updated_at = $updated_at
  ' "$delivery_file" >"$temporary"
  mv "$temporary" "$delivery_file"
}

validate_delivery_record() {
  local delivery_file="$ADE_STORAGE/$DELIVERY_FILE_NAME" metadata_file="$ADE_STORAGE/$METADATA_FILE_NAME"
  jq -e '
    .schema_version == 1
    and (.status == "deploying" or .status == "active")
    and (.golden_path == "web-app" or .golden_path == "container-app" or .golden_path == "aks")
    and (.environment_id | type == "string")
    and (.resource_group | type == "string")
    and (.resource_name | test("^[A-Za-z0-9][A-Za-z0-9-]{1,62}$"))
    and (.endpoint | type == "string")
    and (.acr_name | type == "string")
    and (.image_repository | type == "string")
    and (.image_reference | type == "string")
    and (.node_resource_group | type == "string")
  ' "$delivery_file" >/dev/null || fail "persisted sample delivery record is invalid"
  [[ "$(jq -r '.environment_id' "$delivery_file")" == "$(jq -r '.environment_id' "$metadata_file")" ]] \
    || fail "sample delivery record does not belong to this environment"
  [[ "$(jq -r '.resource_group' "$delivery_file")" == "$ADE_RESOURCE_GROUP_NAME" ]] \
    || fail "sample delivery record does not belong to the ADE resource group"
  [[ "$(jq -r '.golden_path' "$delivery_file")" == "$(jq -r '.golden_path' "$metadata_file")" ]] \
    || fail "sample delivery record does not match the immutable golden path"

  local golden_path
  golden_path="$(jq -r '.golden_path' "$delivery_file")"
  if [[ "$golden_path" == "container-app" || "$golden_path" == "aks" ]]; then
    [[ "$(jq -r '.acr_name' "$delivery_file")" == "$(shared_acr_name)" ]] \
      || fail "sample delivery record does not reference the configured shared ACR"
    [[ "$(jq -r '.image_repository' "$delivery_file")" == "$(jq -r '.image_repository' "$metadata_file")" ]] \
      || fail "sample delivery record does not reference this environment's ACR repository"
  else
    jq -e '.acr_name == "" and .image_repository == "" and .image_reference == ""' "$delivery_file" >/dev/null \
      || fail "Web App delivery record contains unexpected ACR artifacts"
  fi
  if [[ "$golden_path" == "aks" ]]; then
    jq -e '.node_resource_group | test("^[A-Za-z0-9][A-Za-z0-9._()-]{0,89}$")' "$delivery_file" >/dev/null \
      || fail "AKS delivery record does not contain a safe node resource group"
  else
    jq -e '.node_resource_group == ""' "$delivery_file" >/dev/null \
      || fail "non-AKS delivery record contains an unexpected node resource group"
  fi
  if [[ "$(jq -r '.status' "$delivery_file")" == "active" ]]; then
    require_https_endpoint "$(jq -r '.endpoint' "$delivery_file")"
  fi
}

require_https_endpoint() {
  [[ "$1" =~ ^https://[A-Za-z0-9.-]+(:443)?/?$ ]] \
    || fail "sample endpoint must be a trusted HTTPS URL; no HTTP or self-signed fallback is permitted"
}

smoke_test_endpoint() {
  local endpoint="${1%/}" attempts="${ADE_SMOKE_ATTEMPTS:-36}" delay="${ADE_SMOKE_RETRY_DELAY_SECONDS:-10}"
  local attempt response
  require_https_endpoint "$endpoint"
  [[ "$attempts" =~ ^[1-9][0-9]*$ && "$delay" =~ ^[0-9]+$ ]] || fail "invalid smoke-test retry configuration"
  for ((attempt = 1; attempt <= attempts; attempt += 1)); do
    response="$(curl --fail --silent --show-error --connect-timeout 10 --max-time 20 "$endpoint/healthz" 2>/dev/null || true)"
    if jq -e '.status == "ok"' <<<"$response" >/dev/null 2>&1; then
      return
    fi
    if ((attempt < attempts)); then
      sleep "$delay"
    fi
  done
  fail "fixed sample did not pass the trusted HTTPS /healthz smoke test at $endpoint"
}

create_web_zip() {
  local sample_root="$1" archive="$2"
  python3 - "$sample_root/node" "$archive" <<'PY'
import pathlib
import sys
import zipfile

root = pathlib.Path(sys.argv[1])
archive = pathlib.Path(sys.argv[2])
included = [root / "package.json", root / "package-lock.json"]
included.extend(sorted((root / "src").rglob("*")))
with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as output:
    for path in included:
        if path.is_file():
            output.write(path, path.relative_to(root))
PY
  [[ -s "$archive" ]] || fail "could not package the fixed Web App sample"
}

build_container_image() {
  local acr_name="$1" repository="$2" tag="$3" sample_root="$4" attempt delay
  for ((attempt = 1; attempt <= 6; attempt += 1)); do
    if az acr build \
      --registry "$acr_name" \
      --image "$repository:$tag" \
      --file "$sample_root/node/Dockerfile" \
      --source-acr-auth-id '[caller]' \
      --timeout 1200 \
      --only-show-errors \
      --output none \
      "$sample_root/node"; then
      return
    fi
    if ((attempt < 6)); then
      delay=$((10 * (2 ** (attempt - 1))))
      if ((delay > 60)); then delay=60; fi
      printf 'ADE Terraform runner: ACR build not ready; retrying in %s seconds.\n' "$delay" >&2
      sleep "$delay"
    fi
  done
  fail "ACR Quick Build failed after bounded managed-identity/ABAC propagation retries"
}

deploy_web_app_sample() {
  local sample_root endpoint resource_name archive
  sample_root="$(resolve_sample_root)"
  endpoint="$(terraform_output_raw endpoint)"
  require_https_endpoint "$endpoint"
  resource_name="$(resolve_resource_name '/providers/microsoft.web/sites/' app)"
  archive="/tmp/ade-node-sample.zip"
  write_delivery_record web-app "$resource_name" "$endpoint" "" "" "" ""
  create_web_zip "$sample_root" "$archive"
  az webapp deploy \
    --resource-group "$ADE_RESOURCE_GROUP_NAME" \
    --name "$resource_name" \
    --src-path "$archive" \
    --type zip \
    --clean true \
    --restart true \
    --only-show-errors \
    --output none
  smoke_test_endpoint "$endpoint"
  activate_delivery_record
}

deploy_container_app_sample() {
  local sample_root endpoint resource_name acr_name login_server repository tag image_reference
  sample_root="$(resolve_sample_root)"
  endpoint="$(terraform_output_raw endpoint)"
  require_https_endpoint "$endpoint"
  resource_name="$(resolve_resource_name '/providers/microsoft.app/containerapps/' ca)"
  acr_name="$(shared_acr_name)"
  login_server="$(shared_acr_login_server)"
  repository="$(image_repository)"
  tag="$(image_tag)"
  image_reference="${login_server}/${repository}:${tag}"
  write_delivery_record container-app "$resource_name" "$endpoint" "$acr_name" "$repository" "$image_reference" ""
  build_container_image "$acr_name" "$repository" "$tag" "$sample_root"
  az containerapp update \
    --resource-group "$ADE_RESOURCE_GROUP_NAME" \
    --name "$resource_name" \
    --image "$image_reference" \
    --set-env-vars \
      "ENVIRONMENT_ID=$(jq -r '.environment_id' "$ADE_STORAGE/$METADATA_FILE_NAME")" \
      "ENVIRONMENT_NAME=$(jq -r '.environment_name' "$ADE_STORAGE/$METADATA_FILE_NAME")" \
      GOLDEN_PATH=container-app \
      "REGION_NAME=$(jq -r '.location' "$VAR_FILE")" \
    --only-show-errors \
    --output none
  smoke_test_endpoint "$endpoint"
  activate_delivery_record
}

wait_for_default_domain() {
  local cluster_name="$1" attempt domain_name
  for ((attempt = 1; attempt <= 90; attempt += 1)); do
    domain_name="$(az aks approuting defaultdomain show \
      --resource-group "$ADE_RESOURCE_GROUP_NAME" \
      --name "$cluster_name" \
      --query domainName \
      --output tsv \
      --only-show-errors 2>/dev/null || true)"
    domain_name="${domain_name%.}"
    if [[ "$domain_name" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ && "$domain_name" == *.* ]]; then
      printf '%s\n' "${domain_name,,}"
      return
    fi
    sleep 10
  done
  fail "AKS managed default-domain enablement did not return a valid signed domain"
}

deploy_aks_sample() {
  local sample_root cluster_name acr_name login_server repository tag image_reference
  local domain_name host endpoint chart_archive remote_command node_resource_group
  sample_root="$(resolve_sample_root)"
  cluster_name="$(terraform_output_raw cluster_name)"
  [[ "$cluster_name" =~ ^[A-Za-z0-9][A-Za-z0-9-]{1,62}$ ]] || fail "could not resolve the AKS cluster name"
  acr_name="$(shared_acr_name)"
  login_server="$(shared_acr_login_server)"
  repository="$(image_repository)"
  tag="$(image_tag)"
  image_reference="${login_server}/${repository}:${tag}"
  node_resource_group="$(terraform_output_raw node_resource_group)"
  [[ "$node_resource_group" =~ ^[A-Za-z0-9][A-Za-z0-9._()-]{0,89}$ ]] || fail "could not resolve a safe AKS node resource group"
  write_delivery_record aks "$cluster_name" "" "$acr_name" "$repository" "$image_reference" "$node_resource_group"
  build_container_image "$acr_name" "$repository" "$tag" "$sample_root"

  az aks approuting update \
    --resource-group "$ADE_RESOURCE_GROUP_NAME" \
    --name "$cluster_name" \
    --enable-default-domain \
    --only-show-errors \
    --output none \
    || fail "AKS managed default-domain preview is unavailable for this cluster; no insecure fallback is permitted"
  domain_name="$(wait_for_default_domain "$cluster_name")"
  host="ade-sample.${domain_name}"
  endpoint="https://${host}"
  require_https_endpoint "$endpoint"
  update_delivery_endpoint "$endpoint"

  chart_archive="/tmp/ade-node-sample-chart.tgz"
  tar -czf "$chart_archive" -C "$sample_root/helm" .
  [[ -s "$chart_archive" ]] || fail "could not package the fixed AKS Helm sample"
  remote_command="$(cat <<EOF
set -eu
rm -rf /tmp/ade-node-sample-chart
mkdir -p /tmp/ade-node-sample-chart
tar -xzf ade-node-sample-chart.tgz -C /tmp/ade-node-sample-chart
helm upgrade --install ade-node-sample /tmp/ade-node-sample-chart \\
  --namespace ade-node-sample --create-namespace \\
  --set-string image.repository=${login_server}/${repository} \\
  --set-string image.tag=${tag} \\
  --set-string environment.id=$(jq -r '.environment_id' "$ADE_STORAGE/$METADATA_FILE_NAME") \\
  --set-string environment.name=$(jq -r '.environment_name' "$ADE_STORAGE/$METADATA_FILE_NAME") \\
  --set-string environment.region=$(jq -r '.location' "$VAR_FILE") \\
  --set-string ingress.host=${host} \\
  --wait --timeout 10m
kubectl wait --namespace ade-node-sample --for=condition=available deployment/ade-node-sample --timeout=5m
EOF
)"
  az aks command invoke \
    --resource-group "$ADE_RESOURCE_GROUP_NAME" \
    --name "$cluster_name" \
    --command "$remote_command" \
    --file "$chart_archive" \
    --only-show-errors \
    --output none
  smoke_test_endpoint "$endpoint"
  activate_delivery_record
}

deploy_sample() {
  delivery_enabled || return 0
  case "$(jq -r '.golden_path' "$ADE_STORAGE/$METADATA_FILE_NAME")" in
    web-app) deploy_web_app_sample ;;
    container-app) deploy_container_app_sample ;;
    aks) deploy_aks_sample ;;
    *) fail "persisted ADE golden path is not supported by the deploy/delete-only runner" ;;
  esac
}

cleanup_sample_before_destroy() {
  local delivery_file="$ADE_STORAGE/$DELIVERY_FILE_NAME"
  [[ -s "$delivery_file" ]] || return 0
  validate_delivery_record
  ensure_azure_cli_identity
  local golden_path resource_name resource_group
  golden_path="$(jq -r '.golden_path' "$delivery_file")"
  resource_name="$(jq -r '.resource_name' "$delivery_file")"
  resource_group="$(jq -r '.resource_group' "$delivery_file")"
  [[ "$resource_group" == "$ADE_RESOURCE_GROUP_NAME" ]] || fail "sample delivery record does not belong to the ADE resource group"

  case "$golden_path" in
    web-app)
      if az webapp show --resource-group "$resource_group" --name "$resource_name" --only-show-errors --output none >/dev/null 2>&1; then
        az webapp stop --resource-group "$resource_group" --name "$resource_name" --only-show-errors --output none
      fi
      ;;
    container-app)
      if az containerapp show --resource-group "$resource_group" --name "$resource_name" --only-show-errors --output none >/dev/null 2>&1; then
        az containerapp ingress disable \
          --resource-group "$resource_group" \
          --name "$resource_name" \
          --only-show-errors \
          --output none
      fi
      ;;
    aks)
      if az aks show --resource-group "$resource_group" --name "$resource_name" --only-show-errors --output none >/dev/null 2>&1; then
        az aks command invoke \
          --resource-group "$resource_group" \
          --name "$resource_name" \
          --command 'helm uninstall ade-node-sample --namespace ade-node-sample --wait --timeout 5m 2>/dev/null || true; kubectl delete namespace ade-node-sample --ignore-not-found=true --wait=true --timeout=5m' \
          --only-show-errors \
          --output none
        az aks approuting update \
          --resource-group "$resource_group" \
          --name "$resource_name" \
          --disable-default-domain \
          --only-show-errors \
          --output none \
          || printf 'ADE Terraform runner: default-domain disable failed; cluster destroy will remove it.\n' >&2
      fi
      ;;
    *) fail "sample delivery record contains an unsupported golden path" ;;
  esac
}

purge_acr_repository() {
  local acr_name="$1" repository="$2"
  [[ "$acr_name" =~ ^[a-z0-9]+$ && "$repository" =~ ^apps/[0-9]{16}$ ]] \
    || fail "refusing to purge an ACR repository outside the recorded ADE scope"
  if az acr repository delete \
    --name "$acr_name" \
    --repository "$repository" \
    --yes \
    --only-show-errors \
    --output none >/dev/null 2>&1; then
    return
  fi
  # RBAC-plus-ABAC registries can reject a direct data-plane delete for the
  # deployment identity. A registry quick task remains a scoped control-plane
  # operation and removes all tagged and untagged manifests in this one repo.
  az acr run \
    --registry "$acr_name" \
    --cmd "acr purge --filter '${repository}:.*' --ago 0d --untagged" \
    --source-acr-auth-id '[caller]' \
    --only-show-errors \
    --output none \
    /dev/null
}

wait_for_acr_repository_absence() {
  local acr_name="$1" repository="$2" attempt repositories
  for ((attempt = 1; attempt <= 30; attempt += 1)); do
    repositories="$(az acr repository list --name "$acr_name" --output tsv --only-show-errors)" \
      || fail "could not verify ACR repository cleanup"
    if ! grep -Fxq -- "$repository" <<<"$repositories"; then
      return
    fi
    sleep 5
  done
  fail "ACR repository $repository remains after cleanup"
}

wait_for_node_resource_group_absence() {
  local resource_group="$1" attempt exists
  for ((attempt = 1; attempt <= 60; attempt += 1)); do
    exists="$(az group exists --name "$resource_group" --output tsv --only-show-errors)"
    case "$exists" in
      false) return ;;
      true) ;;
      *) fail "could not verify AKS node resource group cleanup" ;;
    esac
    sleep 10
  done
  fail "AKS node resource group $resource_group remains after Terraform destroy"
}

cleanup_sample_after_destroy() {
  local delivery_file="$ADE_STORAGE/$DELIVERY_FILE_NAME"
  [[ -s "$delivery_file" ]] || return 0
  validate_delivery_record
  local acr_name repository
  acr_name="$(jq -r '.acr_name // ""' "$delivery_file")"
  repository="$(jq -r '.image_repository // ""' "$delivery_file")"
  if [[ -n "$acr_name" || -n "$repository" ]]; then
    ensure_azure_cli_identity
    purge_acr_repository "$acr_name" "$repository"
    wait_for_acr_repository_absence "$acr_name" "$repository"
  fi
  if [[ "$(jq -r '.golden_path' "$delivery_file")" == "aks" ]]; then
    ensure_azure_cli_identity
    wait_for_node_resource_group_absence "$(jq -r '.node_resource_group' "$delivery_file")"
  fi
}
