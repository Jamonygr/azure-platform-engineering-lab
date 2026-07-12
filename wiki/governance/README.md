# Governance learning guide

Governance combines product constraints, policy as code, Azure control-plane enforcement, cost awareness, and evidence. No single layer is sufficient.

## Guardrail map

| Developer intent | Request guardrail | Plan/Azure guardrail | Runtime proof |
| --- | --- | --- | --- |
| “Deploy in Europe” | Three-region allowlist | Region policy + service preflight | Resource inventory location |
| “Keep it for one day” | Bounded TTL enum | Required expiry tags | Reconciler cleanup evidence |
| “Deploy from my repository” | Actor/owner validation | Exact OIDC subject + role scope | Azure sign-in/deployment event |
| “Expose a demo” | Supported path only | HTTPS/public-access policy | Probe and TLS endpoint |
| “Keep cost small” | SKU/AKS acknowledgement | Budget/default sizing | Alert and early destroy |

## Policy exercise

Inspect a representative plan and classify controls as deny, audit or deploy/modify. A lab public HTTPS endpoint should be explicitly permitted/audited; a blanket production rule copied without context could make the lab unusable.

Write a narrow exception record with environment ID, policy, reason, approver and expiry. Explain why a manual portal disable is not an acceptable exception workflow.

## RBAC exercise

Create an access matrix for platform workflow, lifecycle controller, generated deployment, workload runtime, ADE identity and human administrator. Mark management-plane versus data-plane operations. Find any subscription-wide role and justify or narrow it.

## Cost exercise

Explain the different jobs of budget thresholds and TTL. Simulate a cost-data delay in which a four-hour AKS environment is destroyed before a forecast alert appears. Which control succeeded? Which evidence still matters?

## Production questions

- How are exceptions approved, expired and audited?
- Which policies belong at management group, subscription, resource group or resource scope?
- How is privileged identity management used for bootstrap/break glass?
- What is the application team's responsibility after provision?
- How are cost allocation, quotas and capacity reservations handled?

See [Governance](../../docs/governance.md) and [Cost model](../../docs/costs.md).
