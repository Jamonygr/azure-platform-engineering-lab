# Certification learning hub

This lab supports hands-on evidence for AZ-305 architecture design and AZ-400 DevOps engineering. It is a study aid, not an official exam objective list or guarantee. Always compare with the current Microsoft study guides.

<p align="center">
  <img src="../images/certifications-lab-workbook.svg" alt="AZ-305 and AZ-400 learning paths connected by the Azure Platform Engineering Lab workbook" width="1200" />
</p>

## Paths

| Path | Focus in this lab | Guide |
| --- | --- | --- |
| AZ-305 | Identity/governance design, compute choices, monitoring, cost, reliability, migration from lab to production | [AZ-305](az-305.md) |
| AZ-400 | Source/branch/review, CI quality, OIDC delivery, IaC/policy, observability, feedback, lifecycle automation | [AZ-400](az-400.md) |
| Combined | Request all paths, collect evidence, explain tradeoffs and verify cleanup | [Lab workbook](lab-workbook.md) |

## Evidence rules

- Capture your own plans, diagrams, queries, workflow results and explanations.
- Remove subscription/tenant IDs, tokens, private keys, state, kubeconfig and personal data.
- Record source commit and UTC date because versions/cloud behavior change.
- Explain why—not only what you clicked.
- Include failed tests and recovery; platform engineering is operational work.

## Suggested sequence

1. Read architecture and write a trust-boundary diagram.
2. Validate source and explain each CI quality gate.
3. Create/destroy Web App and trace OIDC.
4. Compare Web App, Container Apps and AKS compute decisions.
5. Inspect policy/budget/monitoring and propose production changes.
6. Demonstrate one failure/reconciliation case.
7. Prove Azure absence-before-repository-delete invariant.
8. Present a short architecture/DevOps review using your workbook.

Certification mappings last reviewed **2026-07-11**. Check the official [Microsoft Credentials documentation](https://learn.microsoft.com/credentials/) for current exam scopes.
