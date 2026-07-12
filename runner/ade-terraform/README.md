# ADE Terraform runner

This runner is an optional compatibility component for Azure Deployment Environments, which is in maintenance mode. Publish the built image to the private shared ACR and reference it by SHA-256 digest; movable tags are forbidden in a live catalog.

The ADE core entrypoint calls only `/scripts/deploy.sh` or `/scripts/delete.sh`. Both initialize Terraform with `-backend=false`, use ADE's persistent `environment.tfstate`, authenticate with the project environment type's managed identity, and force `create_resource_group=false`. Delete fails if state is missing. Deploy emits only the explicit non-sensitive output allowlist in `common.sh`.

After Terraform succeeds, the runner delivers the same fixed Node.js 24 sample to all three definitions:

- Web App receives a clean ZIP deployment.
- Container App receives an ACR-built image and a new revision.
- AKS receives the ACR-built image through Helm over `az aks command invoke`. The runner enables the managed App Routing default domain and accepts only its signed HTTPS endpoint; it never falls back to HTTP or a self-signed certificate.

`sample-delivery.json` is written to `ADE_STORAGE` before an external application artifact is created. Delete quiesces the workload, uninstalls the AKS release when present, runs Terraform destroy, and purges the exact `apps/<repository-id>` ACR repository. It then verifies that Terraform state is empty, the image repository is absent, and the AKS node resource group is absent. ADE remains responsible for deleting its own primary environment resource group after the runner succeeds. The fixed sample and Helm chart are copied into generated catalog definitions as well as baked into the runner image.

After validating persisted metadata, deploy merge-tags the ADE-owned resource group with the immutable environment identity, golden path, channel, owner, creation time, and selected expiry. The OIDC janitor uses these tags to set a missing native ADE expiration. The runner deliberately does not call Dev Center expiration APIs.

Build locally with:

```bash
docker build --tag ade-terraform-runner:1.1.0 runner/ade-terraform
```

The ADE managed identity needs Repository Reader on the runner-image repository. Fixed-sample builds and cleanup additionally require Repository Catalog Lister plus an ABAC-conditioned Repository Contributor grant for `apps/*`; Contributor and User Access Administrator alone do not grant repository data-plane access. Quick builds and purge runs authenticate with `--source-acr-auth-id [caller]`.

The image pins the AKS preview CLI extension needed for default-domain discovery. A live test is still required because the feature can be unavailable for a subscription, region, or cluster.

The ADE core, Alpine download stage, and Node sample base are pinned by digest. Those base digests were resolved and reviewed on **2026-07-11**; update them only through a reviewed runner release after rebuilding and rescanning the image.
