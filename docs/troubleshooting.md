# Troubleshooting

Start with the immutable environment ID and central inventory. Avoid changing Azure/GitHub resources manually until you understand which phase owns the next action.

## First response

1. Pause repeated manual workflow dispatches; scheduled reconciliation is idempotent but noise hides the first failure.
2. Find the `PlatformEnvironments` row and latest `PlatformOperations` entries.
3. Confirm current phase, desired state, attempt, ETag, fencing generation, expiry and recorded path version.
4. Inspect the corresponding GitHub run and sanitized Log Analytics event.
5. Determine whether the error is input, authorization, quota/capability, transient external API, Terraform state, Azure residual, or repository identity.
6. Let the normal reconciler retry transient failures. Never force the phase forward.

## Request failures

### Invalid name, location or TTL

Names must be lowercase slugs within the documented lengths. TTL must be 4, 8, 24, 48 or 72. The region allowlist is West Europe, North Europe, and Germany West Central, but preflight may still reject unavailable services/SKUs.

### Requester is unauthorized

The actor is always `github.actor`. In personal mode it must match the configured owner. In organization mode verify membership lookup, GitHub App installation scope and any configured team policy. Do not add a free-form requester input.

### Repository already exists

Choose a new name. If inventory indicates a prior environment with the same requested name, reconcile that environment first. Never adopt a repository on name match alone.

## OIDC and deployment

### Azure login says no matching federated identity

Compare all fields exactly:

```text
issuer    https://token.actions.githubusercontent.com
audience  api://AzureADTokenExchange
subject   repo:<owner>/<repo>:environment:deployment
```

Confirm the job references the `deployment` GitHub environment and has `permissions: id-token: write`. Check case/rename/owner differences and propagation time. Do not create a client secret fallback.

### Workflow is inert

This is expected until the platform has recorded the repository IDs, applied Azure, created OIDC/RBAC, populated variables and set `PLATFORM_READY=true`. If the environment is already `ACTIVE`, compare the generated repository variables and controller checkpoint.

### ACR push/pull denied

Confirm the image path is exactly `apps/<repository-id>`, the builder has repository writer, runtime has repository reader, and the registry is in RBAC-plus-ABAC mode. Test that cross-repository access remains denied; do not solve it with registry-wide roles.

## Terraform and Azure

### Backend lease or ETag conflict

Another worker may be active. Inspect lease owner/generation and GitHub concurrency. A stale worker must stop; do not break a lease unless the approved break-glass process proves no worker can continue.

### Region/SKU/quota preflight fails

Check provider registration, subscription offer, regional service/SKU availability, vCPU quota, policy and preview registration. Choose another allowed region or request quota. Do not bypass AKS HTTPS/default-domain preflight.

### Budget creation fails

Confirm Cost Management permission, scope, billing support, contact/action group values and valid start/end dates. Budgets can have provider/API propagation behavior. A budget failure should remain visible; do not represent the environment as fully governed.

### Diagnostics show no data

Check diagnostic setting destination/category, workspace access and ingestion delay. Generate a health request. For Application Insights, verify workspace linkage. For AKS, verify monitoring agent/managed identity and node/pod health.

## Cleanup

### Stuck at `QUIESCING`

Check GitHub App permission to disable Actions/cancel runs/archive, and whether a deployment is still active. The controller may proceed with proven Azure cleanup if the source repository was deleted early, but it records the exception.

### Stuck at `AZURE_DELETING`

Inspect, in order:

1. Terraform destroy result and state list;
2. every `PlatformResources` ID;
3. workload and AKS node resource groups;
4. exact ACR image repository;
5. Resource Graph query by immutable environment tag.

Any residual correctly blocks repository deletion. Retry transient deletion/consistency failures. If state is irrecoverable, use the [break-glass runbook](runbooks/break-glass.md); automatic direct RG deletion is prohibited.

### Stuck at `AZURE_ABSENT` or `REPO_DELETING`

Azure is already proven absent. Resolve repository using stored GraphQL node ID and compare numeric ID and configured owner. A transfer/mismatch fails closed. For 403, verify GitHub App installation/Administration permission. For 429/5xx, retry only the GitHub step with backoff.

### Repository disappeared early

Do not abandon Azure resources. Inventory and immutable Azure ownership tags/state still drive cleanup. Record GitHub absence, revoke OIDC/RBAC, destroy/verify Azure, then finalize the tombstone.

## Missing reconciler heartbeat

Check schedule enablement, workflow permission, OIDC, package build, concurrency backlog and Azure Table/Blob access. Treat two missing 15-minute intervals as actionable. Restore the reconciler before creating new environments.

## Safe operator boundaries

Safe read-only actions include inspecting inventory, state list, Azure Resource Graph, repository IDs, runs, audit logs, endpoint health and Log Analytics. Mutations such as phase edits, lease breaks, state surgery, direct RG deletion, role deletion or repository deletion require the break-glass runbook and approval.

When opening an incident, include environment ID, phase, operation ID, timestamps, path/version, safe error code, checks already performed and links to sanitized evidence. Do not paste tokens, private keys, state, plans or kubeconfigs.
