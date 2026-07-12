# Setup guide

This guide bootstraps the lab in the order required by its trust model. Use a dedicated disposable Azure subscription and a dedicated GitHub owner boundary. The procedure creates billable resources and authorizes automation to create and permanently delete public repositories.

> [!CAUTION]
> Install the GitHub App only on a dedicated lab owner. The App needs **All repositories** access so it can manage repositories created later, and generated repositories are deleted without a grace period after the controller proves Azure absence.

## 1. Required access and tooling

### Azure

- Subscription **Owner** for bootstrap, policy assignment, budgets, and RBAC.
- An existing Microsoft Entra developer group object ID; the lab does not create tenant groups.
- Access to Cost Management budgets for the subscription.
- Permission to create federated credentials and user-assigned managed identities.
- For AKS: enough `Standard_B2s` regional quota, access to the default-domain application-routing capability, and permission to register the Gateway API preview feature.

Use Azure Cloud Shell or install:

- Azure CLI;
- Terraform `1.15.8`;
- Conftest `0.68.2` when invoking lifecycle scripts directly (Actions installs the checksum-pinned binary);
- terraform-docs `0.20.0` when changing a Terraform root or its generated reference;
- Git;
- PowerShell 7 or Bash;
- Node.js 24 LTS for controller/scaffold development;
- Docker, Helm, and kubectl for container/AKS validation.

### GitHub

- Administration permission for a dedicated organization or personal account.
- Permission to create/install a GitHub App and create public repositories.
- GitHub Actions and environments enabled.
- Branch protection with code-owner review, last-push approval, and environment required-reviewer/custom-branch-policy support for this public repository.

Personal mode accepts requests only from the configured account owner. Organization mode checks membership and may assign a configured team/base permission.

## 2. Record inputs

Prepare these non-secret values:

| Value | Example | Purpose |
| --- | --- | --- |
| Azure subscription ID | UUID | Target disposable subscription |
| Microsoft Entra tenant ID | UUID | OIDC tenant |
| Developer group object ID | UUID | Existing AKS/ADE developer access boundary; the lab does not create it |
| Platform administrator email | `owner@example.com` | Alerts and budgets |
| GitHub owner | `contoso-platform-lab` | Main/template/generated repository owner |
| Main repository | `azure-platform-engineering-lab` | Platform OIDC subject |
| Template repository | `azure-platform-node-template` | Source for generated repositories |
| Platform admins | `alice,bob` | Two to six users with repository Administration permission |
| Default location | `westeurope` | Default request region |

The GitHub App private key is secret. Subscription, tenant, and client IDs are identifiers, not passwords, but apply your organization's data-classification policy.

## 3. Bootstrap Azure state

Authenticate interactively and verify the target subscription:

```bash
az login
az account set --subscription <subscription-id>
az account show --query '{name:name,id:id,tenantId:tenantId}' --output table
```

Run bootstrap with local state:

```bash
cd bootstrap
terraform init
terraform fmt -check
terraform validate
terraform plan -out bootstrap.tfplan \
  -var storage_account_name=<globally-unique-name> \
  -var github_owner=<owner> \
  -var github_repository=azure-platform-engineering-lab \
  -var github_environment=platform-operations
terraform apply bootstrap.tfplan
```

Bootstrap creates the platform-owned resource group, versioned/soft-deleted state storage, state/lock containers, and inventory, resource, operation, and evidence tables. Shared-key authentication and anonymous container access are disabled; all automation uses Entra/OIDC authorization.

The lab leaves the storage service's public endpoint reachable because GitHub-hosted runner egress is not stable enough for a firewall allowlist. The containers remain private and inaccessible without Entra authorization. A production adaptation should use private endpoints with self-hosted runners, which is intentionally outside this lab's v1 scope.

Capture outputs without committing them:

```bash
terraform output
```

Grant the signed-in migration identity `Storage Blob Data Contributor` on the new storage account. Subscription `Owner` permits the role assignment but does not itself grant blob data-plane access. Then migrate the bootstrap state from the repository root:

```powershell
$storageScope = terraform -chdir=bootstrap output -raw storage_account_id
$operatorId = az ad signed-in-user show --query id --output tsv
az role assignment create --assignee-object-id $operatorId `
  --assignee-principal-type User `
  --role 'Storage Blob Data Contributor' `
  --scope $storageScope

./scripts/Migrate-BootstrapState.ps1
```

Allow a new role assignment to propagate before retrying if the first blob-access check receives `403`. The helper uses Azure AD authentication and the fixed key `bootstrap/bootstrap.tfstate`. It creates a timestamped local backup, refuses to overwrite a remote state with a different lineage or an older serial, and verifies the remote state after `terraform init -migrate-state`. It is idempotent and supports `-WhatIf`; it never requests or prints a storage key or client secret.

Use the emitted Azure Storage backend values to initialize the shared platform. State keys follow the documented namespaces:

```text
bootstrap/bootstrap.tfstate
platform/platform.tfstate
workloads/github/<golden-path>/<environment-id>.tfstate
```

State backups are restricted and retained for seven days. Never upload a plan/state artifact to a public workflow artifact store.

## 4. Create the platform OIDC trust

Create the platform deployment identity and federated credential using the exact GitHub subject:

```text
issuer:   https://token.actions.githubusercontent.com
audience: api://AzureADTokenExchange
subject:  repo:<owner>/azure-platform-engineering-lab:environment:platform-operations
```

Set the GitHub workflow/job permission `id-token: write`; do not create `AZURE_CLIENT_SECRET`. Configure these repository variables:

```text
AZURE_PLATFORM_CLIENT_ID
AZURE_LIFECYCLE_CLIENT_ID
AZURE_TENANT_ID
AZURE_SUBSCRIPTION_ID
INVENTORY_STORAGE_ACCOUNT
TF_STATE_RESOURCE_GROUP
TF_STATE_STORAGE_ACCOUNT
TF_STATE_CONTAINER
GENERATED_REPOSITORY_OWNER
GENERATED_OWNER_MODE
ORGANIZATION_REQUESTERS
TEMPLATE_REPOSITORY_OWNER
TEMPLATE_REPOSITORY_NAME
PLATFORM_GITHUB_APP_ID
PLATFORM_LOG_ANALYTICS_WORKSPACE_ID
PLATFORM_LOG_ANALYTICS_WORKSPACE_IDS_JSON
PLATFORM_ACTION_GROUP_ID
PLATFORM_LOGS_INGESTION_ENDPOINT
PLATFORM_DCR_IMMUTABLE_ID
PLATFORM_DCR_STREAM
PLATFORM_ADMIN_EMAIL
PLATFORM_ADMINS
SHARED_ACR_ID
DEVELOPER_GROUP_OBJECT_ID
```

Create the protected `platform-operations` GitHub environment and add appropriate reviewers for shared platform changes. The shared platform later creates lifecycle-identity credentials for the exact `lifecycle`, `aks-approval`, and `destructive-operations` subjects; create matching GitHub environments before running those jobs.

| Job class | GitHub environment/FIC subject suffix | Client variable |
| --- | --- | --- |
| Shared platform plan/apply/destroy | `environment:platform-operations` | `AZURE_PLATFORM_CLIENT_ID` |
| Automatic request, extend and scheduled reconcile | `environment:lifecycle` | `AZURE_LIFECYCLE_CLIENT_ID` |
| AKS request after reviewer approval | `environment:aks-approval` | `AZURE_LIFECYCLE_CLIENT_ID` |
| Manual workload destroy | `environment:destructive-operations` | `AZURE_LIFECYCLE_CLIENT_ID` |

Do not replace these exact credentials with a branch wildcard to make login succeed. A mismatch means the workflow/environment/FIC configuration must be corrected.

## 5. Register the GitHub App

Create a GitHub App owned by the dedicated account/organization. Request only the repository permissions required by the controller:

| Permission | Access | Why |
| --- | --- | --- |
| Administration | Read/write | Create/configure/archive/delete generated repositories |
| Contents | Read/write | Render scaffold and environment manifest |
| Actions | Read/write | Enable/disable workflows, dispatch, inspect and cancel runs |
| Variables | Read/write | Populate non-secret generated-repository variables |
| Metadata | Read | Resolve immutable repository identity |
| Members (organization permission) | Read, organization mode only | Prove the requester is still a current organization member |

Do not add organization-wide permissions in personal mode. Organization mode requires only `Members: read` in addition to the listed repository permissions so the request transaction can fail closed on stale membership. The setup helper compares the installation's complete permission map with this table and rejects missing, weaker, or additional permissions. Install the App on the dedicated owner with **All repositories** access: selected-repository installations cannot preselect repositories that the platform will create later, so scaffold/configuration/deletion would fail. Record its App and installation IDs, and generate a private key.

In organization mode, pass `-OrganizationRequesters 'alice,bob'` with a reviewed list of members who may request environments and `-PlatformAdmins 'platform-admin-one,platform-admin-two'` with two to six trusted users. Last-push approval and prevent-self-review deliberately require separation of duties. Every listed platform admin must be a current organization member with explicit repository **Administration** permission; the setup helper resolves each immutable user ID and fails closed on a missing, outside-organization, underprivileged, or single-person owner set. Teams are intentionally not accepted because the lifecycle controller authorizes exact actor logins and must not rely on a stale team-membership snapshot. The controller requires all three requester checks: current membership proven through conditional `Members: read`, membership in the fail-closed requester allowlist, and write-equivalent access to the platform repository. Requesters are not platform administrators unless they are separately included in the validated admin list.

Store separate copies of the private key as the environment Actions secret `PLATFORM_GITHUB_APP_PRIVATE_KEY` in `lifecycle`, `aks-approval`, and `destructive-operations`. Never create a repository- or organization-level copy accessible to this repository: either scope would let a job read the key without crossing the intended environment approval boundary. The setup helper enumerates repository secrets and, in organization mode, every organization secret accessible to the repository; it fails closed if it finds that name or cannot inspect either scope. The automatic `lifecycle` environment intentionally has no reviewer, while `aks-approval` and `destructive-operations` require validated platform-admin review. Store the App ID as the non-secret `PLATFORM_GITHUB_APP_ID` variable. Installation tokens are short-lived, created by the permission-validating provider, refreshed on demand before later GitHub phases, checked for the same exact permission map, and never persisted. The lifecycle process removes the private key from its environment immediately after loading it into process memory so Terraform, Azure CLI, npm, and other child processes cannot inherit it. Rotate the private key periodically and immediately after suspected exposure.

## 6. Publish the companion template

Publish one public repository named `azure-platform-node-template` from the canonical `scaffolds/application/base/` content and mark it as a template repository. From the lab repository root, run:

```powershell
./scripts/Publish-TemplateRepository.ps1 `
  -Owner '<dedicated-owner>' `
  -Name 'azure-platform-node-template' `
  -OwnerMode organization
```

Use `-OwnerMode personal` only when the dedicated owner is a personal account. The publisher refuses to expose an existing private repository, normalizes the public template's default branch to exact `main`, and creates one atomic canonical tree, so deleted or renamed scaffold files cannot remain stale. The template contains the Node.js application, tests, Dockerfile, Dependabot, CODEOWNERS, and the single inert universal deployment workflow. That workflow remains fail-closed until `PLATFORM_READY=true`.

The request workflow uses GitHub's [template generation API](https://docs.github.com/rest/repos/repos#create-a-repository-using-a-template). After generation, the controller's later configuration commit is restricted to non-workflow scaffold and selected-overlay assets plus rendered `.platform` configuration. It never creates, replaces, or edits `.github/workflows/*`; the inert universal workflow came from the template itself. The controller also restricts the generated repository's `deployment` environment to the exact `main` branch before setting `PLATFORM_READY=true`, matching the environment-scoped OIDC subject.

Verify:

- the template contains no subscription/tenant IDs or credentials;
- workflow jobs fail closed while `PLATFORM_READY` is not `true`;
- generated repositories are public by explicit lab design;
- personal/organization authorization mode matches the configured owner.

## 7. Apply the shared platform

From `platform/`, initialize the remote backend and review the saved plan:

```bash
terraform init \
  -backend-config="resource_group_name=<state-rg>" \
  -backend-config="storage_account_name=<state-account>" \
  -backend-config="container_name=<state-container>" \
  -backend-config="key=platform/platform.tfstate" \
  -backend-config="use_azuread_auth=true"

terraform plan -out platform.tfplan \
  -var unique_suffix=<stable-unique-suffix> \
  -var platform_admin_email=<email> \
  -var github_owner=<owner> \
  -var github_repository=azure-platform-engineering-lab \
  -var bootstrap_storage_account_id=<bootstrap-storage-resource-id>
terraform apply platform.tfplan
```

Review the resulting shared ACR, three location-keyed Log Analytics workspaces, action group, lifecycle identity, OIDC credentials, policy definitions, and controller configuration. The primary platform workspace follows `platform.location`; workloads select the workspace matching their requested EU region so AKS Container Insights remains supported. A disposable workload must reference these resources and must not include them in its destroy plan.

Return to the repository root and export the applied bootstrap/platform outputs into GitHub repository variables and create the four environment names:

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
  -OrganizationRequesters 'alice,bob'
```

For personal mode, use `-OwnerMode personal`, omit `-OrganizationRequesters`, and pass the owner plus at least one trusted push-equivalent collaborator in `-PlatformAdmins 'owner,reviewer'`. Personal repositories have one repository administrator, so the helper requires that owner to read back as `admin` and validates the second explicitly trusted user as `push`, `write`, `maintain`, or `admin`. That collaborator serves as code owner/environment reviewer and the lab also treats the login as a platform operator. A single-user configuration cannot satisfy last-push approval or prevent-self-review and is rejected. The helper verifies that the matching App is installed on the exact target account with **All repositories** access and that required GitHub plan features actually read back. It also:

- commits a generated `* <validated-admin-owners>` catch-all `.github/CODEOWNERS` before protection is enabled;
- protects `main` with required pull request and code-owner approval, stale-review dismissal, last-push approval, administrator enforcement, empty bypass allowances, conversation resolution, and no force push or deletion;
- requires all ten `CI` workflow job contexts (`controller`, `scaffold`, `runner`, `terraform`, `terraform-docs`, `terraform-lint`, `supply-chain`, `shell-container-helm`, `documentation-links`, and `workflow-policy`) on an up-to-date branch;
- restricts organization pushes to the validated platform admins;
- configures the exact custom `main` deployment branch policy on all four privileged environments;
- requires platform-admin reviewers for `platform-operations`, `aks-approval`, and `destructive-operations`, while deliberately leaving `lifecycle` reviewer-free for automatic reconciliation and cleanup.

The helper fails closed instead of silently weakening controls when the repository plan or API does not support one of those features. If it creates CODEOWNERS on the remote default branch, run `git pull --ff-only` before creating another local branch. If `main` is already protected and its CODEOWNERS list differs, change CODEOWNERS through an administrator-reviewed pull request and rerun the helper. It never accepts the private key as an argument. Set the three environment-scoped copies separately:

The CI job IDs are part of the branch-protection API contract. If a job is intentionally renamed, update `PlatformRequiredStatusChecks` and `Test-GitHubTrustContracts.ps1` in the same reviewed pull request, then rerun the configuration helper after the renamed check has executed.

```powershell
$privateKey = Get-Content -LiteralPath ./github-app-private-key.pem -Raw
foreach ($environment in @('lifecycle', 'aks-approval', 'destructive-operations')) {
  $privateKey | gh secret set PLATFORM_GITHUB_APP_PRIVATE_KEY `
    --repo '<owner>/azure-platform-engineering-lab' `
    --env $environment
}
Remove-Variable privateKey
```

Confirm each environment lists the secret, **Repository secrets** does not list it, and no organization secret with that name grants this repository access. Delete the local key file securely after retaining the approved recovery copy in your secret manager.

## 8. Configure approvals and schedules

Do not hand-create looser environment rules. `Set-GitHubPlatformConfiguration.ps1` creates and verifies `platform-operations`, `lifecycle`, `aks-approval`, and `destructive-operations`, each limited to the exact `main` branch. It installs required platform-admin reviewers on the three privileged/manual mutation environments and no reviewer on `lifecycle`. The AKS path must use `aks-approval` and require the request's cost acknowledgement. Web App and Container App use `lifecycle` and remain automatic.

Enable the reconciler schedule at 15-minute intervals. Confirm it can acquire the blob lease, read/write Table entities with ETags, emit a heartbeat, and open/update one deduplicated central issue on persistent failure.

The controller retains a final fail-closed repository-deletion switch and configures `ENABLE_REPOSITORY_DELETE=true` by default, so verified teardown is followed immediately by repository deletion. For the first Web App canary only, pass `-DisableRepositoryDeletion`; after manually validating its two Azure-absence checks and immutable repository identity checks, restore the default. The switch never removes the controller's invariant checks.

## 9. Run preflight

The AKS root enables Gateway API Standard, which has a subscription feature gate separate from the default-domain CLI. Register it once before accepting AKS requests, wait until the state is exactly `Registered`, and then refresh the Container Service provider registration:

```bash
az feature register \
  --namespace Microsoft.ContainerService \
  --name AppRoutingIstioGatewayAPIPreview

az feature show \
  --namespace Microsoft.ContainerService \
  --name AppRoutingIstioGatewayAPIPreview \
  --query properties.state \
  --output tsv

az provider register --namespace Microsoft.ContainerService --wait
az provider register --namespace Microsoft.Quota --wait
```

The request and ADE preflights fail closed unless the feature query returns `Registered`; having a CLI command available is not sufficient evidence.

Before the first request, verify:

- allowed region: West Europe, North Europe, or Germany West Central;
- required Azure resource providers are registered;
- App Service, Container Apps, ACR, Log Analytics, budget, and policy APIs are available;
- AKS SKU/quota, `AppRoutingIstioGatewayAPIPreview` registration, and default-domain application-routing capability are available when testing AKS;
- GitHub App installation can see the template and create a disposable test repository;
- OIDC issuer, audience, and subjects are exact;
- all CI static checks pass.

The AKS HTTPS requirement fails closed if the preview default-domain capability is unavailable. Do not silently fall back to HTTP or a self-signed certificate.

## 10. Prove the Web App vertical slice

Request:

```text
golden_path:     web-app
environment:     hello-web
repository:      hello-web-lab
location:        westeurope
ttl:             4
```

Capture evidence that:

1. a UUIDv7 inventory row exists before side effects;
2. the generated repository IDs are recorded;
3. the repository's `deployment` environment has an exact OIDC federated credential;
4. the initial deployment waits for `PLATFORM_READY=true`;
5. `/healthz`, `/readyz`, and diagnostics work over HTTPS;
6. budget, alerts, tags, and policy assignments exist;
7. owner destroy reaches `AZURE_ABSENT` after two checks;
8. only then is the generated repository deleted;
9. a sanitized tombstone remains.

See [Testing](testing.md) for Container App, AKS, and failure cases.

## 11. Optional ADE activation

> [!IMPORTANT]
> Azure Deployment Environments is an **optional maintenance-mode compatibility track**, disabled by default. Microsoft states that ADE is in maintenance mode and no additional features are planned. Do not make ADE a prerequisite for the GitHub-first lab. Review the current [Microsoft maintenance notice](https://learn.microsoft.com/azure/deployment-environments/maintenance-mode) before enabling it.

If you intentionally enable it, follow [ADE compatibility](ade-compatibility.md). The live prerequisites include Dev Center/project permissions, a managed deployment identity, the Microsoft Dev Center GitHub App catalog connection, a private immutable runner image in ACR, and native scheduled deletion. No PAT is introduced by default.

## 12. Before leaving the lab

- Confirm no environment is `ACTIVE`, creating, or deleting.
- Review inventory and Resource Graph for expired-tag residuals.
- Confirm generated test repositories are gone.
- Disable the reconciler only after the inventory is empty.
- Use the platform destroy guard; never bypass it while workloads exist.
- Review charges after Azure Cost Management data has caught up.
