# Optional Azure Deployment Environments compatibility

> [!IMPORTANT]
> This track is **disabled by default** and is not the recommended self-service path. Microsoft documents Azure Deployment Environments (ADE) as being in maintenance mode with no additional features planned; existing capabilities remain available. Review the current [Microsoft maintenance-mode notice](https://learn.microsoft.com/azure/deployment-environments/maintenance-mode) before investing in this integration.

The ADE track exists to demonstrate portability of a versioned golden-path contract and managed-identity execution. The primary GitHub request → generated repository → OIDC deployment lifecycle does not depend on ADE.

## What it adds

- One Dev Center and project.
- A `sandbox` environment type.
- Existing developer-group RBAC.
- A managed deployment identity.
- A private, immutable Terraform runner image in shared ACR.
- Catalog definitions for `web-app-v1`, `container-app-v1`, and `aks-workload-v1`.
- Native scheduled deletion plus a 15-minute OIDC janitor.

ADE deploys the fixed sample endpoint; it does not generate an application repository.

## Prerequisites

- The default GitHub-first platform and shared ACR are healthy.
- Appropriate Dev Center/project subscription permissions.
- An existing Microsoft Entra developer group object ID.
- Permission to install/use the Microsoft Dev Center GitHub App for the catalog connection.
- A built, scanned runner image published and referenced by its immutable `@sha256:` digest.
- An organization-owned repository already configured with validated PlatformAdmins and the protected `main` contract in [Setup](setup.md); personal repositories cannot express the catalog's required push restriction.
- Valid path-region/quota capability, especially for AKS.

No personal access token is introduced by default. Catalog connection through the Microsoft Dev Center GitHub App is a documented one-time interactive setup step.

## Activation runbook

Run this track only after the GitHub-first Web App slice and normal cleanup are healthy.

### 1. Enable the optional platform resources

Re-plan the existing remote `platform/` state with ADE explicitly enabled:

```powershell
terraform -chdir=platform plan -out ade-platform.tfplan `
  -var unique_suffix='<stable-suffix>' `
  -var platform_admin_email='<email>' `
  -var github_owner='<owner>' `
  -var github_repository='azure-platform-engineering-lab' `
  -var bootstrap_storage_account_id='<bootstrap-storage-resource-id>' `
  -var enable_ade=true `
  -var developer_group_object_id='<entra-group-object-id>'
terraform -chdir=platform apply ade-platform.tfplan
```

Review the Dev Center, project, `sandbox` project environment type, deployment identity, developer-group assignment, ACR ABAC assignments, and lifecycle janitor role before continuing.

### 2. Build, scan, and resolve the private runner

The publishing operator temporarily needs ACR Repository Catalog Lister plus an ABAC-conditioned Container Registry Repository Contributor assignment limited to the output `runner_repository`. Remove those operator assignments after publication; the ADE deployment identity already receives only the permanent roles it needs.

```powershell
$sharedAcr = terraform -chdir=platform output -json shared_acr | ConvertFrom-Json
$ade = terraform -chdir=platform output -json ade | ConvertFrom-Json
$tag = "1.1.0-$(git rev-parse --short=12 HEAD)"

az acr build `
  --registry $sharedAcr.name `
  --image "$($ade.runner_repository):$tag" `
  --source-acr-auth-id '[caller]' `
  runner/ade-terraform

$digest = az acr manifest show-metadata `
  --registry $sharedAcr.name `
  --name "$($ade.runner_repository):$tag" `
  --query digest --output tsv
if ($digest -notmatch '^sha256:[0-9a-f]{64}$') { throw 'Runner digest resolution failed.' }
$runnerImage = "$($sharedAcr.login_server)/$($ade.runner_repository)@$digest"

az acr login --name $sharedAcr.name
trivy image --severity HIGH,CRITICAL --exit-code 1 $runnerImage
```

Never publish a catalog with the movable `$tag` reference. `Publish-AdeCatalog.ps1` rejects anything other than an ACR `@sha256:` reference.

### 3. Generate the reviewed catalog branch

The source commit must be the protected `main` head or an ancestor reachable from protected `main`. Authenticate `gh` as one of the validated PlatformAdmins, then generate rather than hand-edit the live branch:

```powershell
$repository = '<owner>/azure-platform-engineering-lab'
$reviewedCommit = gh api "repos/$repository/commits/main" --jq '.sha'
$workspaceIds = terraform -chdir=platform output -json log_analytics_workspace_ids
$actionGroup = terraform -chdir=platform output -raw action_group_id
$policies = (terraform -chdir=platform output -json policy_definition_ids | Out-String).Trim()

./scripts/Publish-AdeCatalog.ps1 `
  -Repository $repository `
  -RunnerImage $runnerImage `
  -LogAnalyticsWorkspaceIdsJson $workspaceIds `
  -ActionGroupId $actionGroup `
  -PlatformAdminEmail '<email>' `
  -SharedAcrId $sharedAcr.id `
  -DeveloperGroupObjectId '<entra-group-object-id>' `
  -PolicyDefinitionIdsJson $policies `
  -ReviewedCommit $reviewedCommit
```

The publisher proves source ancestry, creates `ade-catalog` if necessary, protects it before moving it, copies the exact validated-admin push restrictions from `main`, and uses a non-force fast-forward update. Every pre-existing catalog branch is treated as previously published: it must retain `catalog-metadata.json`, and a missing marker is an ambiguous fail-closed recovery condition rather than permission to replace v1. Each complete `*-v1` subtree is immutable—every expected path, byte SHA, blob type, and file mode must match, and additions or removals also fail closed. This covers the runner digest, Terraform root, inputs, lockfile, and sample assets. Any change must be released as a reviewed `*-v2` definition; the existing v1 tree remains on the catalog branch for live environments. It fails if the authenticated publisher is not an allowed admin. Confirm `ade-catalog:ade/catalog/catalog-metadata.json` names the reviewed commit and digest, every definition contains its `.terraform.lock.hcl`, and no `__TOKEN__` remains.

### 4. Connect the catalog without a PAT

Only after `Publish-AdeCatalog.ps1` has read back the branch protection successfully, open the created Dev Center in Azure Portal, add a catalog backed by GitHub, and use the Microsoft Dev Center GitHub App authorization flow. Select:

- repository: `azure-platform-engineering-lab`;
- branch: `ade-catalog`;
- folder: `ade/catalog`.

Grant the Microsoft App access only to this repository, complete the one-time interactive connection, and wait for a successful catalog sync. Do not substitute a classic or fine-grained personal access token by default.

### 5. Configure the janitor workflow

Re-run the repository configuration helper with the same inputs used for the default platform and add `-EnableAde`. It reads the applied outputs and writes `ENABLE_ADE=true`, `ADE_DEVCENTER_NAME`, and `ADE_PROJECT_NAME` along with the existing OIDC variables:

```powershell
./scripts/Set-GitHubPlatformConfiguration.ps1 `
  -Repository '<owner>/azure-platform-engineering-lab' `
  -GeneratedRepositoryOwner '<owner>' `
  -TemplateRepositoryOwner '<owner>' `
  -TemplateRepositoryName 'azure-platform-node-template' `
  -GitHubAppId '<app-id>' `
  -PlatformAdminEmail '<email>' `
  -PlatformUniqueSuffix '<stable-suffix>' `
  -DeveloperGroupObjectId '<entra-group-object-id>' `
  -OwnerMode organization `
  -PlatformAdmins 'platform-admin-one,platform-admin-two' `
  -OrganizationRequesters 'alice,bob' `
  -EnableAde
```

The `-EnableAde` configuration run independently verifies that `ade-catalog` still has administrator enforcement, explicit trusted push restrictions, and no force-push/delete path before enabling catalog-dependent automation.

Run **ADE expiry janitor** once with `dry_run=true`, inspect its output, then run it with `dry_run=false`. The scheduled workflow continues every 15 minutes through the lifecycle OIDC identity.

### 6. Prove one ADE slice

Start with `web-app-v1`, West Europe, and four hours. Verify that catalog sync succeeds, the ADE-owned resource group has the immutable platform tag set, `$ADE_STORAGE/environment.tfstate` survives redeploy, all four HTTPS routes respond, diagnostics/budget/policy exist, and native expiration matches the selected bounded TTL. Delete through ADE and verify the state is empty and the ADE resource group is gone. Run Container App next; run AKS only after quota/default-domain preflight and explicit cost approval.

Before any shared-platform delete or replacement, the guard disables new ADE admissions, reads the project environment type's `environmentCount` twice, and refuses the saved apply while any ADE environment still exists or is deleting. An unreadable count or lost global admission lease also fails closed.

## Adapter contract

| Concern | GitHub channel | ADE channel |
| --- | --- | --- |
| Application repository | Generated and lifecycle-managed | None |
| Azure authentication | Exact repository/environment OIDC | ADE deployment managed identity |
| Resource group | Terraform creates (`create_resource_group=true`) | ADE supplies (`create_resource_group=false`) |
| State | Azure Blob backend under `workloads/github/...` | `terraform init -backend=false`; `$ADE_STORAGE/environment.tfstate` |
| Expiry | Platform inventory/reconciler | ADE native scheduled deletion + clamp janitor |
| Supported operations | Request/extend/destroy/reconcile | Deploy/delete only |

The management channel is immutable. ADE must not adopt or change a GitHub-created environment, and GitHub must not adopt or change an ADE-created environment.

## Runner safety

The runner:

- supports only deploy and delete commands;
- uses managed identity and never expects GitHub OIDC/PAT/static Azure credential;
- selects a reviewed immutable path version;
- treats missing state during delete as an error rather than “success”;
- writes state only to `$ADE_STORAGE/environment.tfstate`;
- uploads only allowlisted endpoint/resource outputs;
- records/deletes AKS node RG and ACR residuals as part of path cleanup;
- is pinned by immutable `@sha256:` image digest in generated catalog definitions.

The derived image retains the Microsoft ADE core image's root operation user because that managed entrypoint owns the mounted runner contract. Trivy's `AVD-DS-0002` exception is the repository's single global ignore; a contract test still requires both application images to run as the non-root `node` user. Do not copy this exception to application containers.

## Catalog publication

Generate the `ade-catalog` branch from a reviewed source commit and render the immutable runner reference into each `environment.yaml`. Do not hand-edit a live catalog definition. Connect the catalog through the Microsoft Dev Center GitHub App and verify sync status.

Breaking runner, input, output, state or module changes create `*-v2`. Retain v1 until all v1 environments have been deleted.

## Expiry behavior

Use ADE native scheduled deletion. The OIDC-authenticated janitor runs every 15 minutes to:

- read the exact ADE `resourceGroupId` and validate the runner-written `platform.created_at` and `platform.expires_at` tags;
- apply the selected 4/8/24/48/72-hour tag as the native expiration when it is missing (24 hours is the catalog default);
- clamp requested expiry to no later than 72 hours from creation;
- fail closed and report identity, timestamp, subscription, or tag mismatches rather than guessing;
- leave ADE as the deletion mechanism rather than creating cross-channel ownership.

## Validation

1. Deploy/redeploy/delete the local runner fixture and verify missing-state failure.
2. Create two Web App environments concurrently and prove isolated state.
3. Create/delete one Container App and verify ACR cleanup.
4. Run AKS only with manual approval/cost awareness; verify node RG absence.
5. Test short scheduled expiry and janitor default/clamp behavior.
6. Test catalog drift and immutable runner reference.
7. Confirm ADE outputs contain no state, token or sensitive metadata.

## Disable and remove

Delete every ADE environment and verify residuals before disconnecting its catalog, removing project/environment-type resources, deleting runner images or destroying shared platform components. ADE maintenance status may evolve; re-check Microsoft guidance when running the exercise. Status note last reviewed **2026-07-11**.
