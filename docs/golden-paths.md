# Golden paths

A golden path is a supported, opinionated route from a small set of developer inputs to a working, governed application. It is not merely a Terraform module: it includes application scaffold, delivery workflow, identity, policy, observability, cost defaults, tests, and deletion behavior.

## Common contract

All three v1 paths:

- accept only validated EU regions and a UUIDv7 environment ID;
- use required ownership, path/version, expiry, channel, expected-HTTPS, and Terraform-management tags while creation time remains in inventory;
- create or use a supplied resource group according to `create_resource_group`;
- reference shared ACR/Log Analytics/action-group resources without owning them;
- create a resource-group-scoped budget, policy assignments, diagnostics, alerts, and a workload identity;
- return an HTTPS endpoint and complete resource inventory;
- support the GitHub adapter and the optional ADE adapter without cross-adoption;
- are destroyable from their own state without requiring source-repository access.

Default TTL is 24 hours; supported values are 4, 8, 24, 48, and 72 hours. A path may add stricter validation but cannot silently weaken the common contract.

## Web App v1

Best for a first platform review, application teams that want a simple managed runtime, and the cheapest complete vertical slice.

### Composition

- Resource group (GitHub channel) or ADE-provided resource group.
- Linux App Service plan, B1 by default.
- Linux Web App with system-assigned identity.
- Workspace-based Application Insights.
- Diagnostic settings and availability/health alerts.
- Resource-group budget and policy assignments.

### Delivery

The generated repository runs Node.js tests, creates a deployment archive, exchanges GitHub OIDC for Azure access, and ZIP-deploys the application. The deploy job targets the protected `deployment` environment and cannot start until `PLATFORM_READY=true`.

### Acceptance evidence

- Native `https://<app>.azurewebsites.net` endpoint returns 200.
- `/healthz` and `/readyz` pass.
- Application Insights is workspace-linked and receives a request.
- Deployment identity is scoped only to the Web App/resource scope required by the workflow.
- Owner destroy removes the app RG and repository in the safe order.

## Container App v1

Best for teams that want a container contract, revision deployment, and scale-to-zero without cluster operations.

### Composition

- Resource group.
- Workload-profiles-v2 Container Apps managed environment.
- Container App on Consumption with 0–3 replicas.
- Runtime managed identity.
- Shared ACR repository `apps/<repository-id>`.
- Diagnostics, health/revision alerts, budget, and policies.

The managed-environment diagnostic setting remains a small documented AzureRM coverage exception: Azure omits `logAnalyticsDestinationType` for this target, while AVM `0.5.0` defaults it to `Dedicated`. Managing that setting at the golden-path root keeps plans idempotent; a `moved` block preserves existing state until the pinned AVM exposes the provider-default value.

### Delivery and ABAC

The generated workflow tests and builds the image, signs into Azure using OIDC, pushes a commit tag to its repository-scoped ACR path, resolves the resulting manifest digest, and deploys that immutable digest as a new revision. The build identity receives the repository writer role/condition; the runtime identity receives repository reader only. Neither identity should enumerate or pull another generated repository's images. The generated workflow and ADE runner install the exact Container Apps CLI extension wheel pinned in [Reference](reference.md), verify its SHA-256 before installation, and verify the installed version. Terraform's one-time bootstrap image is also digest-pinned and listens on port 80. Container Apps supplies native probes for that ingress target; immediately before the first Node deployment, the generated workflow changes the target to port 3000 so the native probes follow the application port. No mutable container tag participates in provisioning.

### Acceptance evidence

- Native Container Apps HTTPS FQDN is healthy.
- Revision becomes ready and receives traffic.
- Minimum replicas can return to zero after the configured idle period.
- Cross-repository push/pull is denied in an authorization contract test.
- Cleanup removes both Terraform resources and the `apps/<repository-id>` image repository.

## AKS workload v1

Best for demonstrating a Kubernetes platform contract, GitHub approvals, workload identity, policy, and Helm delivery. It is intentionally the most expensive and slowest path.

### Approval gate

The request requires an explicit AKS cost acknowledgement. Provisioning/deployment targets the protected `aks-approval` GitHub environment with required reviewers. A request without both controls must fail before Azure creation.

### Composition

- Dedicated AKS cluster and explicitly named node resource group.
- Free control-plane tier for the lab.
- One `Standard_B2s` node by default; cluster autoscaler range 1–2.
- Azure RBAC with local accounts disabled and no AKS admin groups. Terraform pre-creates the one workload namespace through an allowlisted AKS control-plane run command; the developer group and generated-repository identity then receive Writer only at that namespace scope.
- Azure CNI Overlay and Cilium data plane.
- OIDC issuer and workload identity enabled.
- Azure Policy add-on and Container Insights.
- Managed application routing/default domain for HTTPS.
- Budgets and the same RG-scoped policy assignments on both the workload and managed node resource groups, plus diagnostics, alerts, and explicit node-RG tracking.
- Five deny-mode Kubernetes data-plane assignments constrain the developer-writable namespace to host-qualified HTTPS Ingress, internal-only LoadBalancer services, no explicit external IPs, and the expected service port. Their reviewed built-in version families and review date are recorded in [Reference](reference.md).

### Delivery

The repository builds/pushes an immutable image to its ACR path and deploys the versioned Helm chart into the namespace already created by the platform. It cannot create another namespace or obtain cluster-admin credentials. The chart defines workload identity, probes, resource requests/limits, security context, service, and the managed HTTPS route.

### Preflight and fail-closed behavior

Before repository creation, the platform checks provider registration and selected-region service availability for every path. Web App additionally requires one free App Service regional core and advertised Linux B1 capacity. Container Apps reads the regional `ManagedEnvironmentCount` limit through Microsoft.Quota and compares it with an exact paginated environment count. AKS checks the exact `Microsoft.ContainerService/AppRoutingIstioGatewayAPIPreview` subscription feature state, regional `Standard_B2s` availability and both total/BS-family vCPU quota, supported Kubernetes/network capabilities, and AKS default-domain application routing. It installs the exact `aks-preview` 21.0.0b8 wheel only after verifying its committed SHA-256, and the generated workflow installs kubelogin v0.2.17 for non-interactive Azure CLI authentication to the Azure-RBAC cluster. The feature must be in state `Registered`; CLI command availability alone does not pass preflight. If the preview capability cannot be enabled in the selected subscription/region, preflight fails clearly. The lab does not create an HTTP or self-signed certificate fallback. Terraform immediately merges the immutable ownership and expiry tags onto the AKS-managed node resource group after cluster creation while preserving service-managed tags.

### Acceptance evidence

- Approval audit shows the required reviewer.
- Local accounts are disabled and Azure RBAC is enabled.
- Node count stays within 1–2 and node RG is recorded in inventory.
- Workload service account uses workload identity.
- Managed HTTPS endpoint and probes pass.
- Cleanup proves the cluster RG, node RG, ACR path, state, and generated repository are absent.

## Application scaffold contract

The canonical Node.js 24 LTS application exposes:

| Route | Contract |
| --- | --- |
| `/` | Human-readable path, environment, build and documentation links; no secrets |
| `/healthz` | Liveness response; does not require external dependencies |
| `/readyz` | Readiness response; 200 only when ready for traffic |
| `/metadata` | Allowlisted non-sensitive path/version/build/environment identifiers |

The generated repository includes tests, README, CODEOWNERS, Dependabot, the selected workflow, `.platform/environment.json`, and Docker/Helm assets where needed. The manifest is a lifecycle reference, not an authority that can override central inventory.

## Adding v2 or another path

1. Write the common and path-specific input/output contract.
2. Threat-model identity, shared-resource access, state isolation, and cleanup.
3. Create a new immutable version directory for breaking changes.
4. Add scaffold overlay and inert initial-deployment gate.
5. Add policy/budget/diagnostic defaults.
6. Add mock/contract tests and live create/deploy/destroy validation.
7. Add every non-Terraform residual (image path, node RG, external object) to inventory and cleanup.
8. Document cost, quota, approval, preview, and lab/production differences.
9. Retain the previous version until no live environment depends on it.

## Pinning and AVM policy

The initial lab baseline pins Terraform `1.15.8`, AzureRM `4.80.0`, AzAPI `2.10.0`, AzureAD `3.9.0`, and the reviewed Azure Verified Module versions recorded in each root. Raw AzureRM/AzAPI resources are limited to documented coverage gaps such as ACR ABAC mode, budgets, policy assignments, federated credentials, and Dev Center integration.

Versions and cloud behavior change. Upgrade through a dedicated pull request with lock-file review, static validation, all path contracts, and at least one live create/destroy proof. Baseline last reviewed **2026-07-11**.
