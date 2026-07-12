# Governance, identity, and policy

Governance in this lab is intentionally visible to developers. Guardrails are part of each golden path and are evaluated before, during, and after deployment.

## Governance layers

| Layer | Mechanism | Result |
| --- | --- | --- |
| Request | Typed inputs and actor authorization | Only known paths, TTLs, regions, owners, and names enter the platform |
| Plan | Terraform tests, Checkov, Conftest | Unsafe or incomplete plans fail before apply |
| Azure | Policy assignments and RBAC | Required posture is audited/enforced at environment scope |
| Cost | Budget alerts and bounded TTL | Owners are warned; expiry triggers cleanup |
| Operations | Inventory/reconciliation/evidence | Drift and cleanup failures are observable and attributable |

## Required tags

Every disposable Azure resource that supports tags should carry:

| Tag | Meaning |
| --- | --- |
| `platform.environment_id` | Immutable UUIDv7; primary ownership proof |
| `platform.environment` | Human-readable request slug |
| `platform.owner` | Requesting GitHub actor |
| `platform.golden_path` | `web-app-v1`, `container-app-v1`, or `aks-workload-v1` |
| `platform.expires_at` | Desired UTC cleanup time |
| `platform.channel` | `github` or `ade`; prevents cross-adoption |
| `platform.public_https` | `expected`; documents the lab's intentional endpoint posture |
| `platform.managed` | `terraform` |

Immutable creation time remains in central inventory rather than a required resource tag. Inventory also remains authoritative when Azure services cannot carry tags. A matching tag helps prove ownership but is not, by itself, authorization to adopt or delete a resource.

## Region and public access policy

Allowed regions are West Europe, North Europe, and Germany West Central, subject to live service/SKU/quota preflight. West Europe is the default. Policy should deny unapproved regions where the service honors location and audit expected global resources.

Public access is not universally denied because working public HTTPS endpoints are a lab acceptance requirement. Policy instead verifies:

- TLS/HTTPS-only configuration;
- no unintended HTTP fallback;
- platform-defined public services only;
- AKS local accounts disabled and Azure RBAC/policy enabled;
- diagnostics sent to the same-region shared workspace selected from the platform map;
- required tags and managed identity.

This is a lab exception, not a production recommendation.

## Role design

- Bootstrap runs as subscription Owner only for initial state/policy/RBAC setup.
- The platform workflow identity receives only the scope needed for shared platform lifecycle.
- The lifecycle identity operates workload resources/inventory but cannot broaden repository identity checks.
- Each generated repository identity is scoped only to its own application/resource group or exact deployable resource set.
- Runtime identities do not receive contributor roles.
- ACR image permissions are constrained to `apps/<repository-id>` with RBAC-plus-ABAC conditions.
- ADE, when enabled, uses a managed identity distinct from GitHub OIDC.

Review Azure role definitions and ABAC conditions as code. Avoid subscription-wide Contributor for generated repositories.

## OIDC controls

Federated credentials use exact issuer, audience, owner, repository, and environment values:

```text
repo:<owner>/<generated-repository>:environment:deployment
```

Branch-wide wildcards and owner-wide subjects are not allowed. The platform creates trust only after immutable repository IDs are recorded, then sets variables and activates the first deployment. Cleanup revokes federated credentials before destroying workload resources.

## Budget controls

Default budget amounts are 10/15/75 in subscription currency for Web App/Container App/AKS. Notifications occur at 50%, 80%, 100% actual and 100% forecast to the action group/administrator.

Azure budgets do not stop resources. Cost data can be delayed, and a short-lived resource may be deleted before its usage appears. TTL/reconciliation is the enforcing control. See [Cost model](costs.md).

## Policy exceptions and changes

An exception must be explicit, narrow, time-bounded, tied to an environment/path version, and visible in evidence. Do not disable a policy assignment manually to make a live test pass. Change the policy/test contract through review or use a dedicated approved exception parameter.

Policy changes require:

1. tests against representative plan JSON;
2. documented deny/audit effect;
3. upgrade impact for active versioned paths;
4. live proof for high-risk identity/network changes;
5. rollback or new path version when compatibility breaks.

## Evidence and audit

Keep sanitized lifecycle evidence/tombstones for 90 days. Evidence connects actor, request, reviewed path, plan/apply/deploy/health, budget/policy, cleanup verification, and final repository disposition without retaining source code or secrets.

AKS has no Entra admin group and grants no generated-repository cluster-admin role. After the lifecycle/ADE deployment identity pre-creates `golden-path` or `ade-node-sample` through the tracked AKS run-command action, the developer group and GitHub deployment identity receive Azure Kubernetes Service RBAC Writer only at that namespace scope. Five tracked deny-mode `Microsoft.Kubernetes.Data` built-ins cover the writable namespace: HTTPS-only and host-qualified Ingress, internal-only LoadBalancer services, no explicit service external IPs, and service port 80. The app-routing and system namespaces are excluded from Gatekeeper evaluation but remain outside both workload principals' Azure RBAC scope.

This lab is not a regulated evidence system. Production implementations need immutability, access review, retention policy, legal hold, regional/data controls, and independent audit design.
