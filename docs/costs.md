# Cost model

This lab uses small defaults, but it is not free. Azure prices, free grants, taxes, exchange rates, region availability, and billing-account behavior change. Use the [Azure Pricing Calculator](https://azure.microsoft.com/pricing/calculator/) with your subscription agreement before deployment. Notes last reviewed **2026-07-11**.

## Controls, not guarantees

| Control | What it does | What it does not do |
| --- | --- | --- |
| Small default SKU | Reduces steady-state lab footprint | Guarantee SKU availability or a fixed price |
| Consumption/scale-to-zero | Reduces idle Container Apps compute | Remove logging, networking, registry, or request charges |
| Budget | Sends actual/forecast notifications | Stop, throttle, or delete resources |
| TTL | Requests cleanup after 4–72 hours | Make cost data immediate or guarantee a failed reconciler runs |
| Reconciler | Retries and proves cleanup | Recall public forks/caches or erase historical billing |

TTL plus a monitored reconciler is the actual enforcement design. Budgets provide awareness.

## Default budget amounts

Amounts are numeric thresholds in the subscription billing currency, not quoted monthly prices.

| Path | Amount | Cost drivers |
| --- | ---: | --- |
| Web App | 10 | B1 App Service plan, logs/Application Insights |
| Container App | 15 | vCPU/memory requests, executions, Log Analytics ingestion, ACR storage/operations |
| AKS | 75 | VM node(s), disks, networking/routing, logs, ACR; cluster control-plane tier choice |

Notify at 50%, 80%, and 100% actual plus 100% forecast. Route notifications to the shared action group and platform administrator.

## Shared platform costs

Even with no active environment, the shared platform may incur charges for Storage transactions/capacity, ACR tier/storage, Log Analytics ingestion/retention, Azure Monitor alerts, Resource Graph/query traffic where applicable, and optional ADE/Dev Center resources. Inventory/evidence payloads are intentionally small.

## Cost-safe learning order

1. Validate statically with no Azure resources.
2. Bootstrap and inspect shared platform costs.
3. Run one Web App with a four-hour TTL, then destroy early.
4. Run Container App and allow scale-to-zero.
5. Run AKS only after approval/quota preflight and destroy immediately after evidence capture.
6. Enable ADE only for the compatibility exercise; disable/delete its optional resources afterwards.

## Before and after a live test

Before:

- inspect the saved plan and expected SKUs;
- choose four hours unless the exercise needs longer;
- ensure reconciler heartbeat/alerts are healthy;
- set the administrator email/action group;
- confirm no accidental additional region or node count.

After:

- use owner destroy rather than waiting for TTL;
- wait for `DELETED` evidence;
- query Resource Graph for the environment ID and AKS node RG;
- confirm the ACR image repository is gone;
- review Cost Management again after data becomes available.

Never assume deletion means all charges are already visible or finalized.
