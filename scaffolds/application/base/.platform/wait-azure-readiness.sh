#!/usr/bin/env bash
set -uo pipefail

required=(GOLDEN_PATH RESOURCE_GROUP ENVIRONMENT_ID AZURE_RESOURCE_NAME)
for name in "${required[@]}"; do
  if [[ -z "${!name:-}" ]]; then
    echo "Required readiness input is missing: ${name}" >&2
    exit 2
  fi
done

readiness_attempts="${AZURE_READINESS_ATTEMPTS:-12}"
case "$readiness_attempts" in
  ''|*[!0-9]*)
    echo "AZURE_READINESS_ATTEMPTS must be an integer." >&2
    exit 2
    ;;
esac
if (( readiness_attempts < 1 || readiness_attempts > 20 )); then
  echo "AZURE_READINESS_ATTEMPTS must be between 1 and 20." >&2
  exit 2
fi

kubeconfig=""
# shellcheck disable=SC2317,SC2329 # Invoked indirectly by the EXIT trap below.
cleanup() {
  if [[ -n "$kubeconfig" ]]; then
    rm -f "$kubeconfig"
  fi
}
trap cleanup EXIT

probe_target_role() {
  local actual
  case "$GOLDEN_PATH" in
    web-app)
      actual=$(az webapp show \
        --resource-group "$RESOURCE_GROUP" \
        --name "$AZURE_RESOURCE_NAME" \
        --query 'tags."platform.environment_id"' \
        --output tsv 2>/dev/null) || return 1
      ;;
    container-app)
      actual=$(az containerapp show \
        --resource-group "$RESOURCE_GROUP" \
        --name "$AZURE_RESOURCE_NAME" \
        --query 'tags."platform.environment_id"' \
        --output tsv 2>/dev/null) || return 1
      ;;
    aks)
      actual=$(az aks show \
        --resource-group "$RESOURCE_GROUP" \
        --name "$AZURE_RESOURCE_NAME" \
        --query 'tags."platform.environment_id"' \
        --output tsv 2>/dev/null) || return 1
      ;;
    *)
      echo "Unsupported golden path: $GOLDEN_PATH" >&2
      return 2
      ;;
  esac
  [[ "$actual" == "$ENVIRONMENT_ID" ]]
}

probe_acr_repository_role() {
  [[ -n "${ACR_NAME:-}" && -n "${IMAGE_REPOSITORY:-}" && -n "${AZURE_TENANT_ID:-}" ]] || return 1

  local server aad_token refresh_token registry_token
  server="${ACR_NAME}.azurecr.io"
  aad_token=$(az account get-access-token \
    --resource https://containerregistry.azure.net \
    --query accessToken --output tsv 2>/dev/null) || return 1
  refresh_token=$(curl --fail --silent --show-error \
    --request POST "https://${server}/oauth2/exchange" \
    --data-urlencode grant_type=access_token \
    --data-urlencode "service=${server}" \
    --data-urlencode "tenant=${AZURE_TENANT_ID}" \
    --data-urlencode "access_token=${aad_token}" 2>/dev/null | jq -er .refresh_token) || return 1
  registry_token=$(curl --fail --silent --show-error \
    --request POST "https://${server}/oauth2/token" \
    --data-urlencode grant_type=refresh_token \
    --data-urlencode "service=${server}" \
    --data-urlencode "scope=repository:${IMAGE_REPOSITORY}:pull,push" \
    --data-urlencode "refresh_token=${refresh_token}" 2>/dev/null | jq -er .access_token) || return 1
  [[ -n "$registry_token" ]]
}

probe_aks_data_plane_role() {
  if [[ -z "$kubeconfig" ]]; then
    kubeconfig=$(mktemp "${RUNNER_TEMP:-/tmp}/platform-kubeconfig.XXXXXX")
  fi
  az aks get-credentials \
    --resource-group "$RESOURCE_GROUP" \
    --name "$AZURE_RESOURCE_NAME" \
    --file "$kubeconfig" \
    --overwrite-existing \
    --format exec \
    --output none 2>/dev/null || return 1
  KUBECONFIG="$kubeconfig" kubelogin convert-kubeconfig -l azurecli 2>/dev/null || return 1
  [[ "$(KUBECONFIG="$kubeconfig" kubectl auth can-i create namespaces 2>/dev/null)" == "yes" ]]
}

probe_readiness() {
  probe_target_role || return 1
  case "$GOLDEN_PATH" in
    web-app)
      return 0
      ;;
    container-app)
      probe_acr_repository_role
      ;;
    aks)
      probe_acr_repository_role && probe_aks_data_plane_role
      ;;
  esac
}

delay=10
for ((attempt = 1; attempt <= readiness_attempts; attempt += 1)); do
  if probe_readiness; then
    echo "OIDC session and required Azure roles are ready."
    exit 0
  fi

  if (( attempt == readiness_attempts )); then
    break
  fi
  echo "Azure role propagation is not ready (attempt ${attempt}/${readiness_attempts}); retrying in ${delay}s."
  sleep "$delay"
  delay=$(( (delay * 3 + 1) / 2 ))
  if (( delay > 60 )); then
    delay=60
  fi
done

echo "Azure role readiness did not converge within the bounded retry window; no application mutation was attempted." >&2
exit 1
