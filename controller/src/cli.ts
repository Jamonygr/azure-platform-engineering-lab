#!/usr/bin/env node
import { appendFile } from "node:fs/promises";
import { readFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { AzureCliTokenProvider } from "./access-token.ts";
import { SafetyError, ValidationError } from "./errors.ts";
import { deleteRepositoryFailClosed, GitHubRestClient } from "./github.ts";
import { AzureTableInventoryStore, type InventoryStore } from "./inventory.ts";
import { LifecycleController } from "./lifecycle.ts";
import { decideReconcileAction, matchesActiveRepositoryTrustBinding, type ReconcileAction } from "./reconciler.ts";
import { assertEnvironmentId, normalizeAzureResourceId, parseEnvironmentRequest, parseRepositoryIdentity } from "./schema.ts";
import type { AzureAbsenceEvidence, EnvironmentRecord } from "./types.ts";
import { createUuidV7 } from "./uuidv7.ts";

const args = parseArgs(process.argv.slice(2));
const command = args._[0] ?? "help";

try {
  await main(command, args);
} catch (error) {
  const output = error instanceof ValidationError
    ? { error: "VALIDATION_FAILED", issues: error.issues }
    : error instanceof SafetyError
      ? { error: error.code, message: error.message }
      : { error: "UNEXPECTED", message: sanitize(error instanceof Error ? error.message : String(error)) };
  process.stderr.write(`${JSON.stringify(output)}\n`);
  process.exitCode = 1;
}

async function main(commandName: string, values: Arguments): Promise<void> {
  if (commandName === "help") {
    process.stdout.write("Commands: validate, initialize, get, list, attach-repository, begin-provision, record-outputs, activate, request-destroy, advance-deletion, extend, complete-expiry-sync, adopt-resources, record-repository-absence, record-failure, delete-repository, complete-tombstone-retention, purge-retained-environment, reconcile, heartbeat, heartbeat-status\n");
    return;
  }

  if (commandName === "validate") {
    const request = parseEnvironmentRequest(requestFromEnvironment());
    await emit({ request }, { request_json: JSON.stringify(request) });
    return;
  }

  const store = createStore();
  const lifecycle = new LifecycleController(store, {
    platformAdmins: new Set((process.env.PLATFORM_ADMINS ?? "").split(",").map((value) => value.trim()).filter(Boolean)),
    subscriptionId: requiredEnvironment("AZURE_SUBSCRIPTION_ID"),
  });

  switch (commandName) {
    case "heartbeat": {
      const now = new Date();
      const heartbeat = {
        operationId: createUuidV7(now.getTime()),
        environmentId: "platform-reconciler",
        occurredAt: now.toISOString(),
        fromPhase: "ACTIVE" as const,
        toPhase: "ACTIVE" as const,
        actor: actor(),
        status: "SUCCEEDED" as const,
        summary: `Reconciler heartbeat run ${process.env.GITHUB_RUN_ID ?? "local"}`,
      };
      await store.appendOperation(heartbeat);
      await emit(heartbeat, { heartbeat_at: heartbeat.occurredAt });
      return;
    }
    case "heartbeat-status": {
      const operations = await store.listOperations("platform-reconciler");
      const latest = operations.at(-1);
      const maximumAgeMinutes = Number(process.env.HEARTBEAT_MAX_AGE_MINUTES ?? "35");
      if (!latest || !Number.isFinite(maximumAgeMinutes) || Date.now() - Date.parse(latest.occurredAt) > maximumAgeMinutes * 60_000) {
        throw new SafetyError("RECONCILER_HEARTBEAT_MISSING", `No successful reconciler heartbeat was recorded within ${maximumAgeMinutes} minutes`);
      }
      await emit({ healthy: true, latest });
      return;
    }
    case "list": {
      const records = await store.listEnvironments(values["include-deleted"] === true);
      await emit(records, { environments_json: JSON.stringify(records) });
      return;
    }
    case "initialize": {
      const request = parseEnvironmentRequest(requestFromEnvironment());
      const record = await lifecycle.initialize(request);
      await emit(record, recordOutputs(record));
      return;
    }
    case "get": {
      const record = await lifecycle.get(requiredEnvironmentId(values));
      await emit(record, recordOutputs(record));
      return;
    }
    case "attach-repository": {
      const repository = parseRepositoryIdentity(readJsonInput(values, "repository-json", "REPOSITORY_JSON"));
      const record = await lifecycle.attachRepository(requiredEnvironmentId(values), repository, actor());
      await emit(record, recordOutputs(record));
      return;
    }
    case "begin-provision": {
      const record = await lifecycle.beginAzureProvisioning(requiredEnvironmentId(values), actor());
      await emit(record, recordOutputs(record));
      return;
    }
    case "activate": {
      const raw = readJsonInput(values, "terraform-output", "TERRAFORM_OUTPUT_JSON") as Record<string, unknown>;
      const outputs = normalizeTerraformOutputs(raw);
      const record = await lifecycle.activate(requiredEnvironmentId(values), actor(), outputs);
      await emit(record, recordOutputs(record));
      return;
    }
    case "record-outputs": {
      const raw = readJsonInput(values, "terraform-output", "TERRAFORM_OUTPUT_JSON") as Record<string, unknown>;
      const outputs = normalizeTerraformOutputs(raw);
      const record = await lifecycle.recordProvisioningOutputs(requiredEnvironmentId(values), outputs);
      await emit(record, recordOutputs(record));
      return;
    }
    case "request-destroy": {
      const record = await lifecycle.requestDestroy(requiredEnvironmentId(values), actor());
      await emit(record, recordOutputs(record));
      return;
    }
    case "advance-deletion": {
      const to = String(values.to ?? "");
      if (to !== "AZURE_DELETING" && to !== "AZURE_ABSENT" && to !== "REPO_DELETING" && to !== "DELETED") {
        throw new ValidationError(["--to must be AZURE_DELETING, AZURE_ABSENT, REPO_DELETING, or DELETED"]);
      }
      const evidence = to === "AZURE_ABSENT"
        ? readJsonInput(values, "evidence", "AZURE_ABSENCE_EVIDENCE") as AzureAbsenceEvidence
        : undefined;
      const record = await lifecycle.advanceDeletion(requiredEnvironmentId(values), to, actor(), evidence);
      await emit(record, recordOutputs(record));
      return;
    }
    case "extend": {
      const hours = values.hours ?? process.env.ADDITIONAL_HOURS;
      const record = await lifecycle.extend(requiredEnvironmentId(values), hours, actor());
      await emit(record, recordOutputs(record));
      return;
    }
    case "complete-expiry-sync": {
      const record = await lifecycle.completeExpirySync(requiredEnvironmentId(values), actor());
      await emit(record, recordOutputs(record));
      return;
    }
    case "adopt-resources": {
      const raw = readJsonInput(values, "resource-ids", "RESOURCE_IDS_JSON");
      if (!Array.isArray(raw)) throw new ValidationError(["resource-ids must be a JSON array"]);
      const resourceIds = raw.map(normalizeAzureResourceId);
      const subscriptionPrefix = `/subscriptions/${requiredEnvironment("AZURE_SUBSCRIPTION_ID")}/`;
      if (resourceIds.some((resourceId) => !resourceId.toLowerCase().startsWith(subscriptionPrefix.toLowerCase()))) {
        throw new ValidationError(["adopted resources must belong to AZURE_SUBSCRIPTION_ID"]);
      }
      const record = await lifecycle.adoptResources(requiredEnvironmentId(values), resourceIds, actor());
      await emit(record, recordOutputs(record));
      return;
    }
    case "record-failure": {
      const code = String(values.code ?? "UNEXPECTED");
      const summary = String(values.summary ?? "Lifecycle operation failed");
      const record = await lifecycle.recordFailure(requiredEnvironmentId(values), actor(), code, summary);
      await emit(record, recordOutputs(record));
      return;
    }
    case "record-repository-absence": {
      const environmentId = requiredEnvironmentId(values);
      const expectedRecord = await lifecycle.get(environmentId);
      if (expectedRecord.phase !== "QUIESCING") {
        throw new SafetyError("REPOSITORY_ABSENCE_PHASE", "Early repository absence may only be observed while QUIESCING");
      }
      if (!expectedRecord.repository) {
        throw new SafetyError("REPOSITORY_IDENTITY_MISSING", "Name-only repository absence is forbidden");
      }
      const github = new GitHubRestClient(requiredEnvironment("GITHUB_TOKEN"), "https://api.github.com", fetch, async () => {
        await assertActiveLease(lifecycle, expectedRecord);
      });
      const resolved = await github.resolveRepositoryByNodeId(expectedRecord.repository.nodeId);
      if (resolved) {
        throw new SafetyError("REPOSITORY_STILL_RESOLVES", "The immutable repository node ID still resolves; absence is not recorded");
      }
      const record = await lifecycle.markRepositoryObservedAbsent(environmentId, actor());
      await emit(record, recordOutputs(record));
      return;
    }
    case "delete-repository": {
      const environmentId = requiredEnvironmentId(values);
      let record = await lifecycle.get(environmentId);
      if (!record.repository) {
        if (record.phase !== "AZURE_ABSENT") throw new SafetyError("AZURE_NOT_PROVEN_ABSENT", "Repository-free tombstone requires AZURE_ABSENT");
        record = await lifecycle.advanceDeletion(environmentId, "DELETED", actor());
        await emit(record, recordOutputs(record));
        return;
      }
      if (record.phase === "AZURE_ABSENT") record = await lifecycle.advanceDeletion(environmentId, "REPO_DELETING", actor());
      const token = process.env.GITHUB_TOKEN ?? "";
      const github = new GitHubRestClient(token, "https://api.github.com", fetch, async () => {
        await assertActiveLease(lifecycle, record);
      });
      const result = await deleteRepositoryFailClosed(record, github, {
        enabled: booleanEnvironment("ENABLE_REPOSITORY_DELETE"),
        expectedOwner: requiredEnvironment("GENERATED_REPOSITORY_OWNER"),
        dryRun: booleanEnvironment("CONTROLLER_DRY_RUN"),
      }, async () => {
        record = await lifecycle.markRepositoryDeleteIssued(environmentId, actor());
      });
      if (result.deleted) record = await lifecycle.advanceDeletion(environmentId, "DELETED", actor());
      await emit({ record, deletion: result }, recordOutputs(record));
      return;
    }
    case "complete-tombstone-retention": {
      const blobName = String(values["blob-name"] ?? process.env.TOMBSTONE_BLOB_NAME ?? "");
      const evidenceHash = String(values["evidence-hash"] ?? process.env.TOMBSTONE_EVIDENCE_HASH ?? "");
      const record = await lifecycle.markTombstoneRetained(requiredEnvironmentId(values), actor(), blobName, evidenceHash);
      await emit(record, recordOutputs(record));
      return;
    }
    case "purge-retained-environment": {
      const record = await lifecycle.purgeRetainedEnvironment(requiredEnvironmentId(values));
      await emit({ purged: true, environmentId: record.environmentId, retainedThrough: record.updatedAt });
      return;
    }
    case "reconcile": {
      const records = await store.listEnvironments();
      const github = process.env.GITHUB_TOKEN ? new GitHubRestClient(process.env.GITHUB_TOKEN) : undefined;
      const actions: ReconcileAction[] = [];
      for (const record of records) {
        let repositoryExists: boolean | undefined;
        let repositoryIdentityMatches: boolean | undefined;
        if (record.repository && github) {
          try {
            const resolved = await github.resolveRepositoryByNodeId(record.repository.nodeId);
            repositoryExists = resolved !== undefined;
            repositoryIdentityMatches = resolved === undefined
              ? undefined
              : matchesActiveRepositoryTrustBinding(record.repository, resolved);
          } catch (error) {
            actions.push({
              kind: "OBSERVATION_ERROR",
              environmentId: record.environmentId,
              reason: sanitize(error instanceof Error ? error.message : String(error)),
            });
            continue;
          }
        }
        actions.push(decideReconcileAction(record, {
          now: new Date(),
          ...(repositoryExists !== undefined ? { repositoryExists } : {}),
          ...(repositoryIdentityMatches !== undefined ? { repositoryIdentityMatches } : {}),
        }));
      }
      const actionable = actions.filter((action) => action.kind !== "NONE");
      await emit({ actions, planned: actionable, dryRun: booleanEnvironment("RECONCILE_DRY_RUN", true) }, { reconcile_json: JSON.stringify(actions) });
      return;
    }
    default:
      throw new ValidationError([`Unknown command: ${commandName}`]);
  }
}

async function assertActiveLease(lifecycle: LifecycleController, expectedRecord: EnvironmentRecord): Promise<void> {
  const required = ["TF_STATE_STORAGE_ACCOUNT", "PLATFORM_LEASE_CONTAINER", "PLATFORM_LEASE_BLOB", "PLATFORM_LEASE_ID", "PLATFORM_LEASE_ENVIRONMENT_ID"] as const;
  for (const name of required) {
    if (!process.env[name]) throw new SafetyError("LEASE_CONTEXT_MISSING", `${name} is required before a GitHub mutation`);
  }
  if (process.env.PLATFORM_LEASE_ENVIRONMENT_ID !== expectedRecord.environmentId) {
    throw new SafetyError("LEASE_ENVIRONMENT_MISMATCH", "The active Blob lease belongs to a different environment");
  }
  const renewed = spawnSync("az", [
    "storage", "blob", "lease", "renew",
    "--auth-mode", "login",
    "--account-name", process.env.TF_STATE_STORAGE_ACCOUNT!,
    "--container-name", process.env.PLATFORM_LEASE_CONTAINER!,
    "--blob-name", process.env.PLATFORM_LEASE_BLOB!,
    "--lease-id", process.env.PLATFORM_LEASE_ID!,
    "--output", "none",
  ], { encoding: "utf8", windowsHide: true });
  if (renewed.status !== 0) throw new SafetyError("LEASE_LOST", "The Azure Blob lease could not be synchronously renewed before a GitHub request");
  const current = await lifecycle.get(expectedRecord.environmentId);
  if (current.fencingGeneration !== expectedRecord.fencingGeneration || current.etag !== expectedRecord.etag) {
    throw new SafetyError("FENCE_STALE", "Authoritative inventory advanced beyond this repository-deletion process");
  }
}

interface Arguments {
  _: string[];
  [key: string]: string | boolean | string[] | undefined;
}

function parseArgs(input: string[]): Arguments {
  const result: Arguments = { _: [] };
  for (let index = 0; index < input.length; index += 1) {
    const token = input[index];
    if (!token) continue;
    if (!token.startsWith("--")) {
      result._.push(token);
      continue;
    }
    const [rawKey, inline] = token.slice(2).split("=", 2);
    if (!rawKey) continue;
    const next = input[index + 1];
    if (inline !== undefined) result[rawKey] = inline;
    else if (next && !next.startsWith("--")) {
      result[rawKey] = next;
      index += 1;
    } else result[rawKey] = true;
  }
  return result;
}

function requestFromEnvironment(): Record<string, unknown> {
  return {
    goldenPath: process.env.GOLDEN_PATH,
    environmentName: process.env.ENVIRONMENT_NAME,
    repositoryName: process.env.REPOSITORY_NAME,
    location: process.env.LOCATION,
    ttlHours: process.env.TTL_HOURS,
    acknowledgeAksCost: process.env.ACKNOWLEDGE_AKS_COST,
    requester: process.env.REQUESTER ?? process.env.GITHUB_ACTOR,
  };
}

function createStore(): InventoryStore {
  return new AzureTableInventoryStore({
    accountName: requiredEnvironment("INVENTORY_STORAGE_ACCOUNT"),
    environmentsTable: process.env.INVENTORY_ENVIRONMENTS_TABLE ?? "PlatformEnvironments",
    resourcesTable: process.env.INVENTORY_RESOURCES_TABLE ?? "PlatformResources",
    operationsTable: process.env.INVENTORY_OPERATIONS_TABLE ?? "PlatformOperations",
    tokenProvider: new AzureCliTokenProvider(),
  });
}

function requiredEnvironmentId(values: Arguments): string {
  const value = values["environment-id"] ?? process.env.ENVIRONMENT_ID;
  assertEnvironmentId(value);
  return value;
}

function actor(): string {
  return process.env.REQUESTER ?? process.env.GITHUB_ACTOR ?? "platform-controller";
}

function requiredEnvironment(name: string): string {
  const value = process.env[name];
  if (!value) throw new ValidationError([`${name} is required`]);
  return value;
}

function booleanEnvironment(name: string, fallback = false): boolean {
  const value = process.env[name];
  if (value === undefined) return fallback;
  return value.toLowerCase() === "true";
}

function readJsonInput(values: Arguments, argument: string, environment: string): unknown {
  const filename = values[argument];
  const raw = typeof filename === "string" ? readFileSync(filename, "utf8") : process.env[environment];
  if (!raw) throw new ValidationError([`--${argument} or ${environment} is required`]);
  try { return JSON.parse(raw); }
  catch { throw new ValidationError([`${argument} must contain valid JSON`]); }
}

function normalizeTerraformOutputs(input: Record<string, unknown>): {
  endpoint: string;
  resourceGroupNames: string[];
  resourceIds: string[];
  imageRepository?: string;
  sharedAcrId?: string;
} {
  const unwrap = <T>(name: string): T | undefined => {
    const entry = input[name];
    if (entry && typeof entry === "object" && "value" in entry) return (entry as { value: T }).value;
    return entry as T | undefined;
  };
  const endpoint = unwrap<string>("endpoint");
  const resourceGroupNames = unwrap<string[]>("resource_group_names");
  const resourceIds = unwrap<string[]>("resource_ids");
  const imageRepository = unwrap<string>("image_repository");
  const sharedAcrId = unwrap<string>("shared_acr_id");
  if (typeof endpoint !== "string" || !Array.isArray(resourceGroupNames) || !Array.isArray(resourceIds)) {
    throw new ValidationError(["Terraform outputs must contain endpoint, resource_group_names, and resource_ids"]);
  }
  return { endpoint, resourceGroupNames, resourceIds, ...(imageRepository ? { imageRepository } : {}), ...(sharedAcrId ? { sharedAcrId } : {}) };
}

async function emit(value: unknown, githubOutputs: Record<string, string> = {}): Promise<void> {
  process.stdout.write(`${JSON.stringify(value, null, 2)}\n`);
  const filename = process.env.GITHUB_OUTPUT;
  if (!filename) return;
  const delimiter = `CONTROLLER_${Date.now()}_${Math.random().toString(16).slice(2)}`;
  const content = Object.entries(githubOutputs)
    .map(([key, output]) => `${key}<<${delimiter}\n${output}\n${delimiter}\n`)
    .join("");
  await appendFile(filename, content, "utf8");
}

function recordOutputs(record: EnvironmentRecord): Record<string, string> {
  return {
    environment_id: record.environmentId,
    phase: record.phase,
    expires_at: record.expiresAt,
    state_key: record.stateKey,
    record_json: JSON.stringify(record),
  };
}

function sanitize(value: string): string {
  return value.replace(/(?:ghp|github_pat|ghs|ghu|gho)_[A-Za-z0-9_]+/g, "[REDACTED]").slice(0, 1000);
}
