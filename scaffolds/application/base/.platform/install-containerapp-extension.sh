#!/usr/bin/env bash
set -euo pipefail

version='1.3.0b4'
wheel='containerapp-1.3.0b4-py2.py3-none-any.whl'
url="https://azcliprod.blob.core.windows.net/cli-extensions/${wheel}"
sha256='8f9bd1ab0cceb683dad4cef73ba26344d0a40e528da920134a5a86c4feda4577'
temporary="${RUNNER_TEMP:-/tmp}/${wheel}"

cleanup() { rm -f "$temporary"; }
trap cleanup EXIT
curl --fail --show-error --silent --location --retry 5 "$url" --output "$temporary"
printf '%s  %s\n' "$sha256" "$temporary" | sha256sum --check --status
az extension add --source "$temporary" --yes --only-show-errors
actual=$(az extension show --name containerapp --query version --output tsv)
[[ "$actual" == "$version" ]] || {
  echo "Expected Azure CLI containerapp extension ${version}, received ${actual:-missing}." >&2
  exit 1
}
