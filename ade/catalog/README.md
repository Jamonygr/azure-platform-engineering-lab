# Generated ADE catalog source

> Optional maintenance-mode compatibility: Microsoft has placed Azure Deployment Environments in maintenance mode. GitHub Actions is the primary self-service channel for this lab.

These v1 manifests are source templates. `Publish-AdeCatalog.ps1` copies each matching self-contained Terraform golden path, its dependency lockfile, and the fixed Node.js sample assets beside its manifest. The AKS definition also receives the Helm chart used for managed default-domain HTTPS delivery. The publisher renders shared platform values and an immutable private runner reference, then publishes the result to the generated `ade-catalog` branch.

ADE supports deploy and delete only and does not create an application repository. Do not point ADE at this placeholder-bearing source tree or hand-edit a live v1 definition.
