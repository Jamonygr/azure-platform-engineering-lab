# Contributing

Thank you for helping improve the Azure Platform Engineering Lab. Contributions should preserve its two goals: a runnable learning experience and an auditable destructive-safety contract.

## Before you begin

- Search existing issues and pull requests.
- Use a fork or branch; never test lifecycle changes against repositories or subscriptions containing important data.
- Read [Architecture](docs/architecture.md), [Lifecycle](docs/lifecycle.md), and [Testing](docs/testing.md).
- For a vulnerability or deletion-safety defect, follow [SECURITY.md](SECURITY.md) instead of opening a public issue.

## Development setup

Install the versions pinned by the repository and authenticate locally with Azure CLI only when a live test is necessary. Static validation must work without an Azure login.

```bash
terraform fmt -recursive
terraform -chdir=bootstrap init -backend=false
terraform -chdir=bootstrap validate
terraform -chdir=platform init -backend=false
terraform -chdir=platform validate
npm ci --prefix controller
npm test --prefix controller
npm ci --prefix scaffolds/application
npm test --prefix scaffolds/application
npm run render:check --prefix scaffolds/application
```

Run the checks relevant to your change. The CI workflow remains the canonical list.

## Change expectations

### Terraform

- Keep each golden path self-contained and preserve its documented input/output contract.
- Prefer pinned Azure Verified Modules that follow AVM specifications; document any raw AzureRM/AzAPI coverage gap.
- Do not introduce shared-resource ownership into a disposable environment.
- Add or update Terraform tests for names, required tags, policy assignments, budgets, and outputs.
- Commit provider lock-file changes only when intentionally upgrading dependencies.

### Lifecycle controller

- Treat inventory as authoritative and append lifecycle checkpoints before side effects.
- Preserve concurrency, ETag, lease, and fencing protections.
- Keep operations idempotent and retry-safe.
- Never permit repository deletion before a recorded `AZURE_ABSENT` checkpoint produced by two successful absence checks.
- Never delete a repository by name alone. Numeric ID, GraphQL node ID, and configured owner must agree.
- Add failure tests for every new transition or external call.

### Generated template

- Keep `PLATFORM_READY` fail-closed behavior.
- Request `id-token: write` only in the deployment job.
- Do not add Azure client secrets, publish profiles, registry passwords, or sensitive metadata.
- Keep `/healthz`, `/readyz`, and `/metadata` contracts backward compatible within a v1 path.

### Documentation

- Explain whether guidance is lab-only or production-oriented.
- Add useful alt text to images and `role="img"` plus a title/description to SVGs.
- Date volatile cost, version, preview, and service-status statements.
- Use relative links for repository files and official sources for Azure, Terraform, and GitHub behavior.

## Versioning golden paths

A compatible fix may update `*-v1`. A breaking input, output, state, runner, or workload-delivery change must create `*-v2`. Do not remove v1 until its live environments are gone and migration/cleanup behavior is verified.

## Pull request checklist

- [ ] The scope is small enough to review and the description explains the user outcome.
- [ ] Formatting, validation, security, policy, docs, and relevant application/Helm checks pass.
- [ ] New behavior has unit or contract coverage.
- [ ] Live tests are included or a reason for not running them is documented.
- [ ] No static Azure credential, sensitive state, private key, or generated repository token is committed.
- [ ] Cost, preview, and destructive implications are called out.
- [ ] Cleanup remains idempotent and fails closed.
- [ ] Documentation and examples reflect the change.

## Commit and review guidance

Use clear, imperative commits such as `feat(web-app): add availability alert` or `docs(lifecycle): clarify identity mismatch recovery`. Maintainers may request a threat-model note or live teardown evidence for identity, authorization, state, and deletion changes.

By contributing, you agree that your contribution is licensed under the repository's [MIT License](LICENSE) and that you will follow the [Code of Conduct](CODE_OF_CONDUCT.md).
