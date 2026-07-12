#!/usr/bin/env bash
set -euo pipefail
# The absolute path exists in the image; fallback supports local contracts.
# shellcheck disable=SC1091
source /scripts/common.sh 2>/dev/null || source "$(dirname "$0")/common.sh"
# shellcheck disable=SC1091
source /scripts/delivery.sh 2>/dev/null || source "$(dirname "$0")/delivery.sh"

[[ "${ADE_OPERATION_NAME:-delete}" == "delete" ]] || fail "delete.sh only accepts the delete operation"
require_environment
[[ -s "$ADE_STORAGE/$STATE_FILE_NAME" ]] || fail "persistent environment.tfstate is missing; refusing an untracked delete"
prepare_terraform
cleanup_sample_before_destroy

terraform plan \
  -no-color -compact-warnings -input=false -destroy -refresh=true -lock=true \
  -state="$ADE_STORAGE/$STATE_FILE_NAME" \
  -out="$PLAN_FILE" \
  -var-file="$VAR_FILE"
terraform apply \
  -no-color -compact-warnings -input=false -auto-approve -lock=true \
  -state="$ADE_STORAGE/$STATE_FILE_NAME" \
  "$PLAN_FILE"

remaining="$(terraform state list -state="$ADE_STORAGE/$STATE_FILE_NAME")"
[[ -z "$remaining" ]] || fail "Terraform destroy left resources in state"
cleanup_sample_after_destroy
