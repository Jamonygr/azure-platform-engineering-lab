# Reference

## Defaults

| Setting | Value |
| --- | --- |
| Default region | `westeurope` |
| Other allowed regions | `northeurope`, `germanywestcentral` |
| Default TTL | 24 hours |
| TTL choices | 4, 8, 24, 48, 72 hours |
| Extension choices | +4, +8, +24 hours |
| Maximum age | 72 hours from creation |
| Extension cutoff | 15 minutes before expiry |
| Reconciliation interval | 15 minutes |
| Evidence/tombstone retention | 90 days |
| Restricted state backup retention | 7 days |
| GitHub REST API version | `2026-03-10` |
| Generated repository visibility | Public |
| Endpoint posture | Public trusted HTTPS |

## Version baseline

| Dependency | Pinned baseline |
| --- | ---: |
| Terraform | 1.15.8 |
| AzureRM | 4.80.0 |
| AzAPI | 2.10.0 |
| AzureAD | 3.9.0 |
| AVM Web Site | 0.22.0 |
| AVM Server Farm | 2.0.7 |
| AVM Container Apps environment | 0.5.0 |
| AVM Container App | 0.9.0 |
| AVM AKS | 0.6.7 |
| Azure CLI Container Apps extension | 1.3.0b4, SHA-256 `8f9bd1ab0cceb683dad4cef73ba26344d0a40e528da920134a5a86c4feda4577` |
| Azure CLI AKS preview extension | 21.0.0b8, checksum pinned in the installer |
| kubelogin | 0.2.17 |
| Conftest | 0.68.2 |
| terraform-docs | 0.20.0 |
| Node.js | 24.18.0 LTS |

The repository lock files and module source constraints are authoritative. Review versions through CI/live tests rather than editing this table alone. Baseline date: **2026-07-11**.

The AKS namespace guardrails use the reviewed built-in definition families shown in Terraform: HTTPS Ingress `9.0.*`, required Ingress host `1.1.*` preview, internal LoadBalancer `8.2.*`, no explicit external IPs `5.2.*`, and allowed service port `8.2.*`. Azure can publish newer built-in versions without changing the definition IDs, so re-check the [AKS policy reference](https://learn.microsoft.com/azure/aks/policy-reference) during an upgrade. Policy review date: **2026-07-11**.

## Request validation

- Environment: lowercase slug, 3–20 characters.
- Repository: lowercase slug, 3–50 characters.
- Golden path: `web-app`, `container-app`, or `aks`.
- AKS acknowledgement: required for `aks` and ignored as authorization for other paths.
- Requester: derived from `github.actor`.
- Environment ID: controller-generated UUIDv7, immutable.

## Lifecycle phases

`REQUESTED → REPO_READY → AZURE_CREATING → ACTIVE → QUIESCING → AZURE_DELETING → AZURE_ABSENT → REPO_DELETING → DELETED`

See [Lifecycle](lifecycle.md) for transition guards.

## Core inventory tables

- `PlatformEnvironments` — authoritative desired/current lifecycle record.
- `PlatformResources` — all disposable Azure IDs plus a canonical `<acr-id>/repositories/apps/<repository-id>` row for the ACR data-plane residual; the shared ACR itself is never disposable.
- `PlatformOperations` — append-only checkpoint/error history.

## Helpful sources

- [Azure Login with GitHub OIDC](https://learn.microsoft.com/azure/developer/github/connect-from-azure-openid-connect)
- [Azure Verified Modules specifications](https://azure.github.io/Azure-Verified-Modules/specs/module-specs/)
- [ACR repository permissions with ABAC](https://learn.microsoft.com/azure/container-registry/container-registry-rbac-abac-repository-permissions)
- [GitHub template generation API](https://docs.github.com/rest/repos/repos#create-a-repository-using-a-template)
- [Azure budget tutorial](https://learn.microsoft.com/azure/cost-management-billing/costs/tutorial-acm-create-budgets)
- [AKS application-routing default-domain CLI](https://learn.microsoft.com/cli/azure/aks/approuting/defaultdomain)
- [ADE maintenance mode](https://learn.microsoft.com/azure/deployment-environments/maintenance-mode)
- [ADE scheduled deletion](https://learn.microsoft.com/azure/deployment-environments/how-to-schedule-environment-deletion)
