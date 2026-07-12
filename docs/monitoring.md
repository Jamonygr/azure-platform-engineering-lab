# Monitoring and operations

Monitoring covers both the application and the platform that creates/deletes it. A healthy endpoint is not enough if the reconciler has stopped or an expired environment remains billable.

The platform creates a shared Log Analytics workspace in each allowed EU workload region. Platform lifecycle ingestion uses the primary workspace in `platform.location`; each golden path selects its requested region's workspace, and preflight proves that ID/location pairing before any repository is created. This is required for AKS Container Insights and keeps the three advertised regions runnable.

## Signals

| Area | Signal | Expected use |
| --- | --- | --- |
| Platform | Reconciler heartbeat every 15 minutes | Detect a disabled/broken scheduler |
| Lifecycle | Phase transition, duration, attempt and sanitized error | Find stuck or slow operations |
| Inventory | Active/expiring/expired counts by path | Capacity and cleanup view |
| Cleanup | State/resource/RG/tag absence check outcomes | Prove deletion safety |
| Identity | OIDC/RBAC create/revoke and mismatch events | Detect trust drift |
| Web App | HTTP availability, response time, application exceptions | Golden-path health |
| Container App | Revision readiness, replicas, restarts, ingress health | Container delivery/scale health |
| AKS | Node readiness, pod readiness/restarts, routing health, policy | Cluster/workload health |
| Cost | 50/80/100% actual and 100% forecast notifications | Cost awareness, not shutdown |

## Lifecycle event shape

Emit allowlisted structured fields so queries do not parse free-form logs:

```json
{
  "TimeGenerated": "<utc>",
  "Operation": "reconciler",
  "EnvironmentId": "<uuidv7-or-empty>",
  "Phase": "AZURE_DELETING",
  "Outcome": "retry",
  "FencingGeneration": 7,
  "Message": "sanitized allowlisted summary",
  "RunUrl": "https://github.com/<owner>/<repo>/actions/runs/<id>"
}
```

Do not log tokens, raw OIDC claims, GitHub App keys, state, plans, kubeconfigs, source content, sensitive provider responses, or arbitrary exception bodies.

## Useful KQL patterns

The platform provisions `PlatformLifecycle_CL`, a direct-ingestion DCR, OIDC/RBAC ingestion access, and an Azure Monitor scheduled-query alert. This alert remains out of band if GitHub schedules stop.

### Environments stuck by phase

```kusto
PlatformLifecycle_CL
| summarize arg_max(TimeGenerated, *) by EnvironmentId
| where Phase !in ("ACTIVE", "DELETED")
| where TimeGenerated < ago(30m)
| project TimeGenerated, EnvironmentId, Phase, Outcome, Message, RunUrl
| order by TimeGenerated asc
```

### Missing heartbeat

```kusto
PlatformLifecycle_CL
| where Operation == "heartbeat" and Outcome == "success"
| summarize LastHeartbeat=max(TimeGenerated)
| extend MinutesAgo=datetime_diff("minute", now(), LastHeartbeat)
| where MinutesAgo > 30
```

### Cleanup retries

```kusto
PlatformLifecycle_CL
| where Phase in ("AZURE_DELETING", "REPO_DELETING") and Outcome in ("failure", "retry")
| summarize Retries=count(), LastSeen=max(TimeGenerated) by EnvironmentId, Phase
| where Retries >= 3
```

### Phase duration

```kusto
PlatformLifecycle_CL
| where Operation == "transition"
| summarize First=min(TimeGenerated), Last=max(TimeGenerated) by EnvironmentId, Phase
| extend DurationMinutes=datetime_diff("minute", Last, First)
| order by DurationMinutes desc
```

## Alerts

Alert centrally when:

- no successful heartbeat appears for more than two schedule intervals;
- an environment remains creating/quiescing/deleting beyond its path-specific threshold;
- Azure absence verification finds a residual after Terraform destroy;
- repository numeric ID/node ID/owner validation fails;
- a budget threshold fires;
- the active endpoint fails consecutive availability tests;
- a controller operation reaches its retry limit.

Every request, destroy, extension, live-validation, reconciliation, and heartbeat failure routes through one reusable alert action. It creates one open central GitHub issue per stable alert title and appends later workflow-run links instead of producing one issue per retry. Alerts include only sanitized context and evidence/operation links, never credentials, application source, or Terraform state.

## Operator rhythm

### Every lab session

- Check scheduler heartbeat and active/expired inventory.
- Review failed/retrying lifecycle operations.
- Confirm the environment you are testing has a valid expiry.
- Review cost alerts and current Azure resources before leaving.

### Before platform changes

- Confirm no environment is in a transitional phase.
- Save reviewed platform plan/evidence.
- Verify controller schema/state compatibility.
- Run one Web App create/destroy slice after identity/lifecycle changes.

### Before platform destroy

- Inventory must contain no live environment.
- ADE `environmentCount` must be zero and the project environment type must be closed to new admissions.
- The global platform-admission lease must remain renewable through the final pre-apply recheck.
- Resource Graph must find no platform environment tags outside shared platform resources.
- Generated repository list must be reconciled.
- Evidence/backups must meet the desired retention boundary.

## Dashboard/workbook suggestions

Build a workbook with tiles for active by path/owner, expiring in 4/12/24 hours, stuck transitions, endpoint availability, cleanup duration, residual checks, AKS nodes, Container App revisions, Web App exceptions, budget notifications, and last heartbeat. Link each row to central evidence rather than exposing state.

## Retention

- Workload/platform diagnostic retention is configurable for the lab and should be cost-reviewed.
- Sanitized lifecycle evidence/tombstones: 90 days. Blob lifecycle rules expire evidence, and the reconciler removes terminal Azure Table history only after the same boundary and only when the deterministic final tombstone name/hash has been checkpointed in authoritative inventory.
- Restricted Terraform state backups: seven days.
- Generated source-code archive: none.

Production retention requires a separate security/compliance decision.
