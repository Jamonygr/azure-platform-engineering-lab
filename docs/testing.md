# Testing strategy

Tests build confidence in three different things: the source is valid, each golden-path contract is correct, and the real external lifecycle is safely reversible. Static checks do not prove teardown; live checks must never target valuable resources or repositories.

> [!CAUTION]
> Live tests create billable Azure resources and permanently delete generated public repositories. Use a dedicated subscription and GitHub owner. Start with Web App and a four-hour TTL.

## Test layers

| Layer | Examples | Azure/GitHub writes |
| --- | --- | --- |
| Static | formatting, validation, lint, policy, security, docs | None |
| Unit/contract | Terraform mocks, controller state machine, schema, scaffold rendering | None; emulators/mocks only |
| Adapter integration | Azurite tables/blob leases, mocked GitHub/Azure APIs, ADE runner fixture | Local/test services |
| Live vertical slice | create repo/environment, deploy, smoke, destroy, prove absence | Yes |
| Failure injection | partial apply, races, renamed/transferred repo, throttling/residuals | Usually isolated live or high-fidelity mock |

## Pull-request gates

Run the applicable tools pinned by CI:

```text
terraform fmt -check -recursive
terraform init -backend=false / validate / test
TFLint
Checkov and Trivy
Conftest against plan JSON
Gitleaks
actionlint
ShellCheck
Hadolint
terraform-docs check
Markdown and relative-link checks
npm test
Docker build
Helm lint
kubeconform
optional Infracost
```

Pull-request jobs must not exchange an Azure OIDC token or use the GitHub App private key merely to validate source.

## Terraform contract tests

For every golden path assert:

- allowed location and TTL validation;
- deterministic, Azure-valid names;
- immutable ownership/expiry/channel tags;
- correct budget amount and four notifications;
- diagnostics/alerts and expected policy assignments;
- shared resources are inputs, not destroyable resources;
- exact managed identity/role scope;
- endpoint and tracked-resource outputs;
- `create_resource_group=true` for GitHub and `false` for ADE.

Path-specific assertions include B1/HTTPS for Web App, Consumption/0–3 and ACR scopes for Container App, and AKS Free/`Standard_B2s` 1–2/local-account-disabled/Azure RBAC/OIDC/policy/networking/node-RG output for AKS.

## Controller unit and contract tests

Cover every legal/illegal phase transition, UUIDv7/schema validation, owner/administrator extension rules, 72-hour cap, 15-minute cutoff, expiry, stale creating rollback, idempotency, ETag conflict, lease loss, stale fencing token, transient retry classification, and sanitized evidence hash.

Deletion tests must prove the GitHub DELETE adapter is unreachable unless all Azure-absence predicates and immutable repository identity checks pass.

Test against Azurite where supported and mocked GitHub/Azure APIs for deterministic failure cases. Never weaken the production invariant to accommodate emulator limitations.

## Generated scaffold tests

- Render each overlay into a clean directory.
- Reject invalid/mixed overlays and unresolved placeholders.
- Verify inert behavior when `PLATFORM_READY` is absent/false.
- Run Node tests for `/`, `/healthz`, `/readyz`, and `/metadata` allowlist.
- Build the Web App archive and container image.
- Lint the generated workflow/action files.
- For AKS, run Helm lint and kubeconform and assert probes, resources, non-root context, service account/workload identity, and managed route.
- Scan rendered content for secrets and platform-only files.

## Live path procedure

Run the manual **Live golden-path validation** workflow for one path at a time and type `RUN LIVE VALIDATION`. It fixes TTL at four hours, uses the AKS approval environment when selected, validates the generated repository/OIDC identity plus HTTPS, budgets, policy, diagnostics, and alerts, and always schedules the production destroy transaction before reporting a verdict.

For each path:

1. Record clean subscription/repository baseline.
2. Request a unique name, West Europe, and four-hour TTL.
3. Confirm `REQUESTED` exists before repository/Azure side effects.
4. Validate generated repository IDs, manifest, overlay, variables, environment, and inert gate.
5. Validate saved plan/policy and apply outputs/inventory.
6. Confirm exact OIDC subject and least-privilege role.
7. Confirm generated-repository deployment and immutable artifact/image.
8. Smoke-test trusted HTTPS and all four application routes.
9. Validate diagnostics, alert, budget and policy.
10. Capture path-specific evidence.
11. Trigger owner destroy.
12. Confirm quiesce, OIDC/RBAC revocation, Terraform destroy and external residual cleanup.
13. Confirm two absence checks and `AZURE_ABSENT` precede GitHub DELETE.
14. Confirm state/RGs/node RG/ACR path/repository absence and retained tombstone.

Run AKS only after required approval and explicit cost acknowledgement.

## Failure matrix

| Scenario | Expected result |
| --- | --- |
| Duplicate request or repository collision | Rejected before side effects |
| Unsupported region/SKU/quota | Preflight failure; tracked cleanup if anything was created |
| Terraform partial apply | Normal cleanup state machine; no repo deletion until absence |
| Failed first app deployment | Environment enters cleanup, retains evidence |
| OIDC propagation delay | Bounded retry; no broader credential fallback |
| Repository renamed | Resolve by node ID and validate numeric ID/owner |
| Name reused for another repository | Identity mismatch; never delete by name |
| Repository transferred | Azure cleanup where proven; GitHub deletion blocked/alerted |
| Repository deleted early | Two immutable node-ID null observations are checkpointed; Azure cleanup continues and no GitHub DELETE is issued |
| Controller crashes after side effect | Next run resumes idempotently from checkpoint |
| GitHub/Azure 429/5xx | Bounded backoff and attempt count |
| Azure residual | Stay `AZURE_DELETING`; repository remains |
| GitHub deletion 403 after Azure absence | Retry only GitHub from `REPO_DELETING` |
| Extension races with delete | Lease/ETag/fence yields one winner; deletion phase cannot be reversed |
| Missing heartbeat | Action-group event and deduplicated issue |

## ADE compatibility tests

When ADE is explicitly enabled, test the runner fixture deploy/redeploy/delete, missing-state failure, allowlisted outputs, two concurrent Web Apps with isolated ADE state, Container App lifecycle, manual AKS smoke/delete, scheduled expiry, janitor default/clamp, catalog drift, and AKS node-RG residual detection.

ADE tests are not required for the default GitHub-first path unless their shared versioned Terraform contract changed.

## Acceptance criteria

- No static Azure credential is required or committed.
- AKS cannot provision without acknowledgement and protected-environment approval.
- Failed provisioning follows a tracked rollback/cleanup transaction.
- Repository DELETE never precedes proven `AZURE_ABSENT`.
- Azure state, tracked resources/RGs, node RG, ACR artifacts and repository are absent after each live test.
- Sanitized evidence/tombstone survives completed cleanup.
- A token-expiry simulation proves long AKS/deletion/reconciliation runs refresh the GitHub App installation token without exposing the private key to child processes.
- Renaming an ACTIVE generated repository is detected as OIDC trust drift and starts teardown, while post-absence deletion still follows its immutable node ID/current name.
- ADE catalog drift tests reject added, removed, mode-changed, or byte-changed files anywhere under a published v1 subtree.
- Provisioning-output tests reject a missing predicted RG, a cross-subscription resource ID, or activation output that shrinks recorded cleanup inventory.
- AKS contracts prove there are no admin groups/cluster-admin grants and both human and generated-repository writers remain namespace-scoped after platform namespace creation.
- GitHub App setup/token tests reject any permission set that is missing, weaker than, or broader than the reviewed mode-specific contract.
