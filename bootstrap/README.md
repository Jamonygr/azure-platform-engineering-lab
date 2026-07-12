# Bootstrap Terraform root

This root intentionally begins with local state. It creates the durable Azure
Storage account, private containers, ARM-managed Tables, and the GitHub Actions
OIDC identity used by later roots. Apply it once with an Azure CLI session that
has `Owner` on a dedicated disposable subscription.

```powershell
az login
terraform init
terraform apply
terraform output -json backend
```

Before making any further bootstrap changes, migrate its local state to the
created Azure backend. The signed-in identity needs `Storage Blob Data
Contributor` on the bootstrap storage account because subscription `Owner`
does not grant blob data-plane access.

From the repository root, run:

```powershell
$storageScope = terraform -chdir=bootstrap output -raw storage_account_id
$operatorId = az ad signed-in-user show --query id --output tsv
az role assignment create --assignee-object-id $operatorId `
  --assignee-principal-type User `
  --role 'Storage Blob Data Contributor' `
  --scope $storageScope

./scripts/Migrate-BootstrapState.ps1
```

If the assignment is new, allow Azure RBAC propagation to complete before
retrying the migration helper.

The helper checks the local state lineage, refuses to overwrite an unrelated or
older remote state, creates a timestamped local backup, and migrates only to
`bootstrap/bootstrap.tfstate` with Azure AD authentication. It then pulls and
verifies the remote state. Re-running it is safe: an existing state with the
same lineage and an equal or newer serial is treated as already migrated. Use
`-WhatIf` to perform the preflight without changing backend configuration.

The helper copies `backend_override.tf.example` to the ignored
`backend_override.tf` only after its safety checks. Keep that file so Terraform
cannot silently fall back to local state. If the local `.terraform` directory
is removed later, rerun the helper with backend parameters or the
`TF_STATE_RESOURCE_GROUP`, `TF_STATE_STORAGE_ACCOUNT`, and
`TF_STATE_CONTAINER` environment variables.

Use the `backend` output values when initializing `platform/` and the
golden-path roots, with their documented state keys. Shared Key is disabled;
local and CI commands must use Entra ID (`use_azuread_auth=true`).

The storage account is protected by `prevent_destroy`. A human-approved
break-glass procedure is required to remove it after all workloads and retained
evidence have been handled.
