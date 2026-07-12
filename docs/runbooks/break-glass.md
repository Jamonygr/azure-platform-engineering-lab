# Break-glass cleanup runbook

Use this runbook only when the normal reconciler has repeatedly failed and state/inventory recovery cannot make meaningful progress. It is an approved, human-reviewed exception—not an automatic fallback.

> [!CAUTION]
> Direct cloud or repository deletion is irreversible. Never delete a repository while any Azure absence check is incomplete. Never infer ownership from a name alone.

## Entry criteria

- Normal retries and safe diagnostics are exhausted.
- The same blocking condition is understood and recorded.
- A platform administrator approves the operation.
- The environment's immutable ID, GitHub numeric ID/node ID, owner, path version, state key and complete resource inventory are available.
- New requests are paused if the fault could affect multiple environments.

## Preserve evidence

Record UTC time, operator/approver, reason, phase, current ETag/fencing generation, state backup version, inventory/resource rows, saved plan/destroy errors, Resource Graph results, repository identity results and intended actions. Sanitize secrets and application data.

## Establish exclusive control

1. Disable the environment's scheduled/manual lifecycle jobs or acquire the official maintenance lock.
2. Prove no controller worker can continue.
3. Acquire/break the blob lease only after recording its previous owner/generation and approval.
4. Advance the fencing generation through the supported inventory operation; do not directly overwrite arbitrary rows.

## Recover state first

Prefer, in order:

1. restore a valid versioned state backup;
2. repair backend access/lock and rerun the pinned path-version destroy;
3. import a proven, immutable-ID-matching resource into an isolated recovered state, then destroy;
4. remove a state entry only after Azure proves the resource absent.

Do not restore a backup across environment IDs or path versions.

## Manual Azure cleanup exception

If direct deletion is the only approved route:

- compare every target's full Azure resource ID and immutable environment tag to inventory;
- include the AKS node resource group and exact ACR repository path;
- exclude shared state, ACR, workspace, action group, identity and policy definitions;
- revoke environment OIDC and scoped roles;
- execute one resource at a time with recorded result;
- run state, resource-ID, RG/node-RG and Resource Graph tag checks twice afterwards.

Only a successful double check permits recording `AZURE_ABSENT`.

## Repository disposition

After `AZURE_ABSENT` only:

1. resolve the current repository from its stored GraphQL node ID;
2. compare numeric ID and configured owner;
3. stop and alert on transfer/mismatch/uncertainty;
4. issue deletion using the resolved current repository;
5. verify absence and record the final tombstone.

Never use a typed repository name as the sole deletion target.

## Exit

- Restore reconciler/schedules and clear maintenance lock.
- Verify heartbeat and inventory consistency.
- Retain sanitized evidence and state backup according to policy.
- Open a corrective action for the controller/path/test gap.
- Run a Web App live create/destroy test before resuming requests if shared lifecycle code changed.
