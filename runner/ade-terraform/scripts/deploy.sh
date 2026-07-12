#!/usr/bin/env bash
set -euo pipefail
# The absolute path exists in the image; fallback supports local contracts.
# shellcheck disable=SC1091
source /scripts/common.sh 2>/dev/null || source "$(dirname "$0")/common.sh"
# shellcheck disable=SC1091
source /scripts/delivery.sh 2>/dev/null || source "$(dirname "$0")/delivery.sh"

[[ "${ADE_OPERATION_NAME:-deploy}" == "deploy" ]] || fail "deploy.sh only accepts the deploy operation"
prepare_terraform
preflight_sample_delivery

terraform plan \
  -no-color -compact-warnings -input=false -refresh=true -lock=true \
  -state="$ADE_STORAGE/$STATE_FILE_NAME" \
  -out="$PLAN_FILE" \
  -var-file="$VAR_FILE"
terraform apply \
  -no-color -compact-warnings -input=false -auto-approve -lock=true \
  -state="$ADE_STORAGE/$STATE_FILE_NAME" \
  "$PLAN_FILE"

[[ -s "$ADE_STORAGE/$STATE_FILE_NAME" ]] || fail "Terraform apply produced no persistent ADE state"
deploy_sample
write_allowlisted_outputs
