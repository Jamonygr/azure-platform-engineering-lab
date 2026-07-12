# Hands-on lab testing guide

This guide turns the platform contract into observable evidence. Complete static validation first, then run Web App, then Container App, and run AKS only when you can approve and immediately clean its cost.

> [!CAUTION]
> Use a disposable subscription and GitHub owner. Generated repositories are public and are permanently deleted after verified Azure teardown. Do not put sensitive or valuable code in them.

## Lab record

| Field | Your value |
| --- | --- |
| Date/time (UTC) | |
| Source commit | |
| Azure subscription alias | |
| GitHub owner | |
| Tester | |
| Reconciler heartbeat | |
| Baseline Resource Graph result | |

Never paste secrets, tenant data, Terraform state/plan contents, tokens, private keys or kubeconfig into this record.

## Stage 1 — Static quality

- [ ] Terraform formatting, init without backend, validate and tests pass.
- [ ] Provider/module versions and lock files match the reviewed baseline.
- [ ] TFLint, Checkov, Trivy, Conftest and Gitleaks pass.
- [ ] actionlint, ShellCheck and Hadolint pass.
- [ ] Markdown/link and terraform-docs checks pass.
- [ ] Node tests and each scaffold overlay render pass.
- [ ] Container image builds; Helm lint and kubeconform pass.
- [ ] Pull-request jobs do not request Azure OIDC or GitHub App secrets.

Evidence: CI run URL and source commit.

## Stage 2 — Bootstrap/control plane

- [ ] Dedicated subscription/account boundary confirmed.
- [ ] State storage has versioning, soft delete and Azure AD auth.
- [ ] Separate state/lock/inventory/resource/operation/evidence stores exist.
- [ ] Shared ACR, workspace, action group, lifecycle identity and policy definitions exist.
- [ ] Platform OIDC exact subject and protected environment exist.
- [ ] GitHub App has only documented permissions and restricted installation.
- [ ] Template repository is public, contains no secrets, and workflow is inert.
- [ ] Reconciler has a recent heartbeat and deduplicated alert route.

Evidence: sanitized configuration table and heartbeat query.

## Stage 3 — Web App vertical slice

Request `web-app`, unique slugs, `westeurope`, four-hour TTL.

- [ ] `REQUESTED` row with UUIDv7 appears before external side effects.
- [ ] Generated repository numeric/node IDs, owner and source commit are recorded.
- [ ] Selected scaffold contains Node routes/tests and no container/AKS-only delivery mix.
- [ ] First deployment remains inert until `PLATFORM_READY=true`.
- [ ] Saved plan passes policy; shared platform resources are data/inputs, not owned.
- [ ] Exact generated-repository `deployment` OIDC subject exists.
- [ ] Native Web App HTTPS `/`, `/healthz`, `/readyz`, `/metadata` pass.
- [ ] Application Insights/diagnostics receives a request.
- [ ] Tags, budget notifications, alert and policy assignment match contract.
- [ ] Run summary contains environment ID, repo, endpoint, RG, expiry, budget, state and commands.

Trigger owner destroy:

- [ ] Actions disabled/cancelled and repository archived before Azure destroy.
- [ ] OIDC/RBAC revoked.
- [ ] Terraform state and tracked resources/RG absent.
- [ ] Resource Graph environment-tag query empty twice.
- [ ] `AZURE_ABSENT` timestamp precedes GitHub DELETE.
- [ ] Node/numeric ID/owner checks pass before deletion.
- [ ] Repository absent and sanitized tombstone retained.

## Stage 4 — Container App

Repeat the lifecycle with `container-app`.

- [ ] Image pushed only to `apps/<repository-id>` with immutable tag/digest.
- [ ] Builder writer and runtime reader ABAC conditions are exact.
- [ ] Cross-repository push/pull test is denied.
- [ ] Revision becomes ready, HTTPS routes pass, and idle scale can reach zero.
- [ ] Diagnostics/alerts/budget/policy pass.
- [ ] Cleanup removes Container Apps resources and exact ACR repository path.
- [ ] Azure absence still precedes repository deletion.

## Stage 5 — AKS workload

Confirm cost/quota and choose four-hour TTL.

- [ ] Missing acknowledgement test fails before Azure creation.
- [ ] Required reviewer approval is captured.
- [ ] Default-domain application-routing capability preflight succeeds; otherwise test ends safely without HTTP fallback.
- [ ] Free tier, B2s, autoscaler 1–2, local accounts disabled, Azure RBAC, CNI Overlay/Cilium, policy, OIDC/workload identity and Container Insights match contract.
- [ ] Node resource group is captured in inventory.
- [ ] Image and Helm workload deploy; probes and trusted HTTPS pass.
- [ ] Workload service account uses workload identity and security/resource settings.
- [ ] Cleanup removes cluster RG, node RG and ACR path.
- [ ] Double absence verification precedes repository deletion.

Destroy immediately after capturing evidence; do not wait for TTL.

## Stage 6 — Failure and recovery

Use mocks/high-fidelity test harnesses unless a live failure is necessary.

- [ ] Duplicate request/name collision has no side effects.
- [ ] Partial apply enters normal cleanup.
- [ ] OIDC propagation retries without client secret fallback.
- [ ] Renamed repository resolves by node ID.
- [ ] Reused name cannot redirect deletion.
- [ ] Transferred repository blocks GitHub deletion.
- [ ] Azure residual blocks repository deletion.
- [ ] GitHub 429 after Azure absence retries only GitHub.
- [ ] Stale fencing worker cannot mutate/delete.
- [ ] Extension/delete race has one winner and no transition out of deletion.
- [ ] Missing heartbeat creates one actionable alert/issue.

## Stage 7 — Optional ADE compatibility

Complete only when ADE is intentionally enabled after reading its maintenance notice.

- [ ] Runner deploy/redeploy/delete fixture passes and missing state fails.
- [ ] Two Web Apps keep isolated ADE state.
- [ ] Container App and manual AKS cleanup include external residuals.
- [ ] Native scheduled deletion and 24-hour default/72-hour clamp work.
- [ ] Catalog uses reviewed source and immutable private runner image.
- [ ] No PAT/static credential or application repository is created.
- [ ] GitHub/ADE channels cannot adopt each other.

## Final acceptance

- [ ] Zero static Azure credentials.
- [ ] All paths have trusted HTTPS.
- [ ] AKS approval is enforced.
- [ ] Transactional failure cleanup is demonstrated.
- [ ] No repository DELETE occurs before proven Azure absence.
- [ ] No live workload/state/RG/node RG/ACR residual/repository remains.
- [ ] Sanitized evidence remains for each lifecycle.
- [ ] Cost Management is reviewed after data arrives.
