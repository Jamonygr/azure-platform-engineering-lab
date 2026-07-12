# Learning reference

## Key terms

| Term | Meaning in this lab |
| --- | --- |
| Golden path | Versioned infrastructure, application, delivery, governance, monitoring and lifecycle contract |
| Environment | One disposable requested workload, its repo identity/state/resources/evidence |
| Platform | Longer-lived shared control-plane resources and automation |
| Inventory | Authoritative lifecycle/ownership record outside Terraform state |
| Residual | Environment-owned object not removed by the main Terraform destroy, such as ACR path or AKS node RG |
| Fence | Generation preventing a stale worker from committing after lease loss |
| Tombstone | Sanitized final lifecycle/evidence record retained after deletion |
| Management channel | Immutable `github` or `ade` ownership boundary |

## Defaults at a glance

- Region: `westeurope`; alternatives `northeurope`, `germanywestcentral` after preflight.
- TTL: 24 hours; choices 4/8/24/48/72.
- Extension: +4/+8/+24; maximum 72 hours from creation; cutoff 15 minutes.
- Reconcile: every 15 minutes.
- Repositories/endpoints: public by lab design; HTTPS required.
- Budget amounts: Web App 10, Container App 15, AKS 75 in billing currency.
- Evidence: 90 days; restricted state backups: seven days; source archive: none.

## Common OIDC subject

```text
repo:<owner>/<generated-repository>:environment:deployment
```

Issuer is GitHub Actions; audience is Azure AD token exchange. Subject and Azure role scope together define the workload identity boundary.

## Phase quick reference

```text
REQUESTED → REPO_READY → AZURE_CREATING → ACTIVE → QUIESCING
→ AZURE_DELETING → AZURE_ABSENT → REPO_DELETING → DELETED
```

## Operator references

- [Setup](../../docs/setup.md)
- [Architecture](../../docs/architecture.md)
- [Golden paths](../../docs/golden-paths.md)
- [Lifecycle](../../docs/lifecycle.md)
- [Governance](../../docs/governance.md)
- [Monitoring](../../docs/monitoring.md)
- [Cost model](../../docs/costs.md)
- [Testing](../../docs/testing.md)
- [Troubleshooting](../../docs/troubleshooting.md)
- [Compact defaults/version reference](../../docs/reference.md)
- [ADE compatibility](../../docs/ade-compatibility.md)

Version/status/cost references were last reviewed **2026-07-11**. Repository constraints and current official service documentation remain authoritative.
