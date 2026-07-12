# Security policy

## Supported version

This learning repository supports the current default branch. Versioned golden-path directories remain available for lifecycle compatibility, but they are not independently supported products.

## Reporting a vulnerability

Do not open a public issue for a suspected vulnerability. Use GitHub's **Security → Report a vulnerability** private reporting flow for this repository. If private reporting is unavailable, contact the repository owner through the private contact method listed on the GitHub profile and include `Azure Platform Engineering Lab security report` in the subject.

Include:

- affected commit and component;
- impact and realistic attack path;
- safe reproduction steps using disposable resources;
- whether credentials, resource ownership, OIDC trust, inventory integrity, or deletion safety is involved;
- suggested mitigation, if known.

Do not include live credentials, GitHub App private keys, Terraform state, installation tokens, or tenant data. Allow maintainers reasonable time to validate and remediate before disclosure.

## High-priority findings

The following are especially sensitive:

- an OIDC subject that can be used by another repository, branch, or environment;
- excessive platform or generated-repository Azure permissions;
- GitHub App permission or token leakage;
- cross-environment state or ACR repository access;
- inventory mutation without fencing/ETag protection;
- a route that can delete a GitHub repository before verified Azure absence;
- name-only or owner-unvalidated repository deletion;
- secrets exposed in logs, evidence, outputs, `/metadata`, artifacts, or public repositories;
- a cleanup path that can target resources outside its immutable environment ID.

## Security model summary

- Azure automation uses GitHub Actions OIDC, not client secrets.
- Generated-repository trusts use the exact `repo:<owner>/<repo>:environment:deployment` subject.
- The platform's GitHub App private key is the sole intended long-lived automation secret.
- Copies of that key exist only as environment secrets in `lifecycle`, `aks-approval`, and `destructive-operations`; repository- and organization-level copies accessible to this repository are forbidden.
- Long lifecycle runs mint replacement installation tokens before GitHub phases; the private key is removed from the process environment before any child tool starts, and tokens are never persisted.
- Protected `main` requires validated catch-all code owners, approval of the last push, stale-review dismissal, all ten CI job contexts, administrator enforcement, and no bypass/force-push/delete path.
- Shared platform resources and disposable workload resources have separate ownership boundaries.
- ACR access is repository-scoped under `apps/<repository-id>` where ABAC is supported.
- Lifecycle mutations are serialized by GitHub concurrency, a blob lease, Table ETags, and a fencing generation.
- Repository deletion requires immutable identity checks and a recorded `AZURE_ABSENT` checkpoint.

Read [Architecture](docs/architecture.md), [Governance](docs/governance.md), and [Lifecycle](docs/lifecycle.md) for the full trust and safety design.

## Secrets and evidence handling

- Never commit `.env` files, Terraform state/plan files, private keys, access tokens, kubeconfigs, publish profiles, or registry credentials.
- Never store `PLATFORM_GITHUB_APP_PRIVATE_KEY` as a repository Actions secret or an organization secret accessible to this repository. Use separate environment-secret copies only in `lifecycle`, `aks-approval`, and `destructive-operations`; keep automatic `lifecycle` reviewer-free so expiry cleanup remains operable.
- Treat resource IDs, tenant IDs, subscription IDs, and generated-repository metadata according to your organization's data-classification policy even when they are not authentication secrets.
- Retain sanitized lifecycle evidence/tombstones for 90 days and restricted state backups for seven days.
- Evidence must not contain source archives, tokens, claims containing sensitive identifiers, or raw provider responses.
- Rotate the GitHub App private key immediately if exposure is suspected, revoke installation tokens, review audit logs, and pause request/reconcile workflows.

## Lab disclaimer

The repository intentionally uses public sample endpoints and public generated repositories. It is not suitable for confidential code or data and does not claim production hardening. Use a dedicated disposable Azure subscription and a dedicated GitHub owner boundary.
