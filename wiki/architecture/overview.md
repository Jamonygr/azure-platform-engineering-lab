# Architecture learning guide

The platform separates experience, control and workload planes so each has a clear owner, credential and lifecycle. The two diagrams below should be read together: the first documents what this repository defines today, while the second shows how the same product model could evolve into a production landing-zone design.

## Current state — runnable lab architecture

![Current-state Azure Platform Engineering Lab architecture](../../docs/images/platform-architecture-current-state.svg)

The current state is intentionally optimized for learning and repeatable teardown. GitHub provides the self-service entry point, Microsoft Entra ID exchanges exact-subject OIDC tokens without an Azure client secret, and one dedicated disposable subscription contains bootstrap, shared-platform, governance and workload resources. Each request selects exactly one golden path—Web App, Container Apps or AKS—and the controller must prove Azure absence twice before it may delete the generated repository.

## Target state — conceptual production architecture

![Target-state Azure Platform Engineering architecture](../../docs/images/platform-architecture-target-state.svg)

The target state keeps the same repository-driven vending and exact-subject identity model, but introduces enterprise separation and private networking. Platform capabilities are placed in dedicated identity, management and connectivity subscriptions beneath a platform management group. Production and nonproduction workloads receive vended subscriptions and private spokes, while regional hub stamps provide private DNS, WAF ingress, firewall egress, DDoS protection and recovery placement. This diagram is a proposed design, not a claim that the repository deploys these production controls.

## Trace the boundaries

| Boundary | Question to answer during review |
| --- | --- |
| GitHub request → controller | How is actor authorization derived and input constrained? |
| Controller → GitHub App | Which repository permissions are actually required? |
| GitHub workflow → Azure | What exact OIDC subject and Azure role is trusted? |
| Environment → shared ACR/workspace | Can one environment read/write/destroy another's data? |
| Terraform state → inventory | Which lifecycle facts exist outside Terraform? |
| Azure absence → GitHub DELETE | What proof makes the irreversible action safe? |

## Ownership exercise

Classify each object as **shared platform**, **disposable environment**, or **external control**:

- state storage account;
- generated application repository;
- workload resource group;
- shared ACR;
- `apps/<repository-id>` image path;
- GitHub App private key;
- AKS node resource group;
- Log Analytics workspace;
- workload diagnostic setting;
- inventory tombstone.

Then compare with [the operator architecture guide](../../docs/architecture.md#shared-versus-disposable-ownership). Explain why the ACR is shared but an image path is an environment residual.

## Trust exercise

Draw the four values that make GitHub-to-Azure federation safe: issuer, audience, subject and Azure role scope. Change one value in a thought experiment and describe the failure or risk. In particular, compare an exact environment subject with an owner-wide wildcard.

## Distributed-system exercise

Assume two scheduled runs start simultaneously, one process pauses for five minutes, and its Blob lease expires while the other process acquires a new lease. Explain what GitHub concurrency, ETags and the fencing generation each prevent. Why is the lease alone insufficient?

## Production design questions

- Which planes live in separate subscriptions/management groups?
- Who owns the platform API/catalog and support SLO?
- Would generated repositories be public, internal, or private?
- How would private networking, DNS, certificates and egress work?
- Which evidence needs immutable retention or legal hold?
- Can a platform administrator delete source code, and what approvals are required?
- Which resource types require bespoke cleanup beyond Terraform?

Capture a one-page context/container diagram and a trust-boundary table as architecture evidence.