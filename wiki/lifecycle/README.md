# Lifecycle learning guide

The lifecycle controller is a reconciler, not a linear deployment script. It can resume after a crash and make progress from current evidence.

![Environment lifecycle with Azure absence before repository deletion](../../docs/images/lifecycle-flow.svg)

## Read the state machine

For each phase, answer:

- What must already be true?
- Which side effect is allowed?
- What evidence is written before/after it?
- What happens if the process stops immediately afterwards?
- Which next run can safely repeat the action?

Use the transition table in [Lifecycle](../../docs/lifecycle.md#state-machine).

## Race scenario: extend versus expire

An owner requests +24 hours at 12:46 while expiry is 13:00 and the reconciler begins cleanup. The extension is within 15 minutes and must be rejected. Now move the request to 12:40: lease/ETag/fence determine one winner; once the phase reaches `QUIESCING`, it cannot return to `ACTIVE`.

Capture a sequence diagram explaining the decision.

## Identity mismatch scenario

The source repository is renamed, then another repository is created under its old name. Explain why:

- node ID resolves the renamed original;
- numeric ID confirms identity;
- configured owner confirms deletion authority;
- the old name can never authorize deletion.

Now transfer the original to another owner. Azure cleanup may continue where immutable Azure ownership is proven, but repository deletion fails closed and alerts.

## Absence proof exercise

Build an evidence table with two rows/check passes and these columns:

- Terraform managed-resource count;
- tracked resource IDs found;
- workload RG found;
- AKS node RG found;
- Resource Graph environment-tag matches;
- time and fencing generation.

Explain why a successful Terraform destroy is not enough, and why one Azure Resource Graph result alone is not enough.

## Failure injection ideas

- crash after repository generation but before IDs are checkpointed/read back;
- crash after Terraform apply but before `ACTIVE`;
- revoke App access during quiesce;
- inject Azure 429 during destroy;
- leave one ACR path or node RG residual;
- lose the Blob lease before GitHub DELETE;
- return a different owner from repository identity lookup.

For each, identify expected phase, retry/action, alert and forbidden side effect.
