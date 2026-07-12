# Golden paths learning guide

The three paths share one developer envelope but make different product tradeoffs.

| Dimension | Web App | Container App | AKS workload |
| --- | --- | --- | --- |
| Abstraction | Managed code runtime | Managed container runtime | Managed Kubernetes control plane plus cluster operations |
| Delivery | ZIP | OCI image/revision | OCI image + Helm |
| Scale | App Service plan | 0–3 replicas | 1–2 nodes plus pod replicas |
| Identity focus | Resource-scoped deploy | ACR writer/reader ABAC | Deploy identity + workload identity |
| HTTPS | Native App Service | Native Container Apps | Managed app routing/default domain |
| Approval | Automatic | Automatic | Required reviewer + cost acknowledgement |
| Special residual | None beyond tracked Terraform resources | ACR image repository | ACR path + node resource group |

## Web App scenario

Request Web App with four-hour TTL. Find the App Service plan, Web App, Application Insights, diagnostics, alert, budget and policy assignments in plan/inventory. Explain why Application Insights may be disposable while the Log Analytics workspace is shared.

Evidence:

- healthy native HTTPS URL and three machine endpoints;
- OIDC subject and resource scope;
- telemetry request in workspace;
- budget/policy/tags;
- full teardown timeline.

## Container App scenario

Compare build identity and runtime identity. Attempt an authorized push/pull under its own `apps/<repository-id>` and a denied cross-repository operation. Observe revision readiness and scale-to-zero.

Evidence:

- immutable image tag/digest;
- ABAC condition and denied cross-path test;
- revision/probe/replica signals;
- ACR path absence after cleanup.

## AKS scenario

Before requesting, document the incremental value over Container Apps and why it justifies cost/approval. Verify quota and managed HTTPS capability. After approval, inspect Azure RBAC, local account setting, CNI/Cilium, policy, OIDC/workload identity and monitoring.

Evidence:

- request acknowledgement and reviewer audit;
- cluster/network/identity configuration;
- Helm-rendered workload and trusted HTTPS;
- node RG in inventory and absent after cleanup.

## Design a fourth path

Without implementing it, write a contract for an Azure Functions or Static Web Apps path:

1. developer inputs and defaults;
2. application scaffold and delivery artifact;
3. OIDC and runtime permissions;
4. shared services and isolation;
5. policy, monitoring and budget;
6. non-Terraform residuals;
7. failure/cleanup tests;
8. v1 compatibility promise.

Review your contract against [Golden paths](../../docs/golden-paths.md#adding-v2-or-another-path).
