# Monitoring learning guide

Platform SRE begins with the control loop. If workloads look healthy but the reconciler is silent, expired resources and repositories can accumulate.

## Build a service view

Create five panels:

1. last successful reconciler heartbeat;
2. active/expiring/expired environments by path;
3. time in each lifecycle phase and retry count;
4. endpoint/revision/pod health;
5. budget notifications and cleanup residuals.

Use structured allowlisted lifecycle events. Never ingest credentials, raw OIDC claims, state/plan, kubeconfigs or source code into evidence.

## Alert design exercise

For each signal choose threshold, evaluation window, severity, owner and runbook:

- heartbeat missing for two intervals;
- environment creating for more than a path-specific threshold;
- expired environment still `ACTIVE`;
- residual after Terraform destroy;
- repository owner/ID mismatch;
- three cleanup retries;
- endpoint availability failures;
- budget 80% actual.

Explain which alerts should create/update one deduplicated central issue and which require immediate human escalation.

## Query practice

Adapt the KQL examples in [Monitoring](../../docs/monitoring.md#useful-kql-patterns) to answer:

- Which path has the highest median time to active?
- Which phase has most retry attempts?
- Which owners have environments expiring in four hours?
- Did any repository deletion start without a prior Azure-absence event?
- Is the heartbeat older than 30 minutes?

Capture query text, result and interpretation. A zero-row safety query can be strong evidence when the expected result is “no invariant violation.”

## SLO thought experiment

Propose separate objectives for request-to-healthy latency, active endpoint availability and cleanup timeliness. Explain why cleanup correctness should not be traded for deletion speed, and why AKS needs a different latency target from Web App.
