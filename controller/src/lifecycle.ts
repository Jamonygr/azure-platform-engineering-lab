import { SafetyError } from "./errors.ts";
import type { InventoryStore } from "./inventory.ts";
import { assertEnvironmentId, normalizeAzureResourceId, parseExtensionHours } from "./schema.ts";
import { recordFailure as applyFailure, transitionEnvironment } from "./state-machine.ts";
import type { AzureAbsenceEvidence, Clock, EnvironmentRecord, EnvironmentRequest, ExtensionHours, Phase, RepositoryIdentity } from "./types.ts";
import { systemClock } from "./types.ts";
import { createUuidV7 } from "./uuidv7.ts";

export interface LifecycleOptions {
  platformAdmins: ReadonlySet<string>;
  subscriptionId?: string;
  clock?: Clock;
}

export class LifecycleController {
  readonly #store: InventoryStore;
  readonly #admins: ReadonlySet<string>;
  readonly #subscriptionId: string | undefined;
  readonly #clock: Clock;

  constructor(store: InventoryStore, options: LifecycleOptions) {
    this.#store = store;
    this.#admins = new Set([...options.platformAdmins].map((admin) => admin.toLowerCase()));
    const subscriptionId = options.subscriptionId ?? process.env.AZURE_SUBSCRIPTION_ID;
    if (subscriptionId && !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(subscriptionId)) {
      throw new SafetyError("SUBSCRIPTION_CONFIG_INVALID", "Configured Azure subscription ID is malformed");
    }
    this.#subscriptionId = subscriptionId?.toLowerCase();
    this.#clock = options.clock ?? systemClock;
  }

  async initialize(request: EnvironmentRequest): Promise<EnvironmentRecord> {
    const now = this.#clock.now();
    const environmentId = createUuidV7(now.getTime());
    const shortId = environmentId.replaceAll("-", "").slice(0, 8);
    const resourceGroupNames = predictedResourceGroupNames(request.goldenPath, request.environmentName, shortId);
    const record: EnvironmentRecord = {
      environmentId,
      partitionKey: "environment",
      phase: "REQUESTED",
      desiredState: "ACTIVE",
      owner: request.requester,
      goldenPath: request.goldenPath,
      pathVersion: "v1",
      environmentName: request.environmentName,
      location: request.location,
      requestedRepositoryName: request.repositoryName,
      createdAt: now.toISOString(),
      updatedAt: now.toISOString(),
      expiresAt: new Date(now.getTime() + request.ttlHours * 3_600_000).toISOString(),
      stateKey: `workloads/github/${terraformPath(request.goldenPath)}/${environmentId}.tfstate`,
      resourceGroupNames,
      resourceIds: [],
      attempts: 0,
      fencingGeneration: 1,
    };
    return this.#store.createEnvironment(record);
  }

  async attachRepository(environmentId: string, repository: RepositoryIdentity, actor: string): Promise<EnvironmentRecord> {
    const record = await this.#required(environmentId);
    const usesRegistry = record.goldenPath === "container-app" || record.goldenPath === "aks";
    const configuredSharedAcrId = usesRegistry ? process.env.SHARED_ACR_ID : undefined;
    const sharedAcrId = configuredSharedAcrId ? normalizeAzureResourceId(configuredSharedAcrId) : undefined;
    if (usesRegistry && !sharedAcrId) {
      throw new SafetyError("ACR_INVENTORY_INCOMPLETE", "SHARED_ACR_ID is required before attaching a Container App or AKS repository");
    }
    if (sharedAcrId) assertResourceSubscription(sharedAcrId, this.#requiredSubscriptionId());
    const imageRepository = usesRegistry ? `apps/${repository.numericId}` : undefined;

    if (record.phase === "REPO_READY") {
      if (!record.repository || !sameRepository(record.repository, repository) ||
          record.imageRepository !== imageRepository || record.sharedAcrId !== sharedAcrId) {
        throw new SafetyError("REPOSITORY_ATTACH_CONFLICT", "REPO_READY inventory differs from the immutable repository or ACR identity being attached");
      }
      if (imageRepository && sharedAcrId) {
        await this.#store.putResources(environmentId, [acrRepositoryRecord(environmentId, sharedAcrId, imageRepository, record.updatedAt)]);
      }
      return record;
    }

    const changed: EnvironmentRecord = {
      ...record,
      repository,
      ...(imageRepository ? { imageRepository } : {}),
      ...(sharedAcrId ? { sharedAcrId } : {}),
    };
    const result = transitionEnvironment(changed, "REPO_READY", actor, this.#clock.now(), { summary: "Generated repository identity recorded" });
    const saved = await this.#commit(record, result.record, result.operation);
    if (imageRepository && sharedAcrId) {
      await this.#store.putResources(environmentId, [acrRepositoryRecord(environmentId, sharedAcrId, imageRepository, saved.updatedAt)]);
    }
    return saved;
  }

  async beginAzureProvisioning(environmentId: string, actor: string): Promise<EnvironmentRecord> {
    return this.#move(environmentId, "AZURE_CREATING", actor, "Terraform apply started");
  }

  async activate(
    environmentId: string,
    actor: string,
    outputs: { endpoint: string; resourceGroupNames: string[]; resourceIds: string[]; imageRepository?: string; sharedAcrId?: string },
  ): Promise<EnvironmentRecord> {
    const record = await this.#required(environmentId);
    if (!outputs.endpoint.startsWith("https://")) throw new SafetyError("ENDPOINT_NOT_HTTPS", "Golden path endpoint must use trusted HTTPS");
    assertResidualInventoryPair(outputs.imageRepository, outputs.sharedAcrId);
    assertResidualInventoryIdentity(record, outputs);
    const inventory = validateProvisioningInventory(record, outputs, this.#requiredSubscriptionId());
    assertExactCaseInsensitiveSet(record.resourceIds, inventory.resourceIds, "RESOURCE_INVENTORY_MISMATCH", "Activation outputs changed the previously recorded disposable resource inventory");
    const changed: EnvironmentRecord = {
      ...record,
      endpoint: outputs.endpoint,
      resourceGroupNames: record.resourceGroupNames,
      resourceIds: record.resourceIds,
      ...(outputs.imageRepository ? { imageRepository: outputs.imageRepository } : {}),
      ...(outputs.sharedAcrId ? { sharedAcrId: outputs.sharedAcrId } : {}),
    };
    const result = transitionEnvironment(changed, "ACTIVE", actor, this.#clock.now(), { summary: "Terraform apply and endpoint smoke test succeeded" });
    return this.#commit(record, result.record, result.operation);
  }

  async recordProvisioningOutputs(
    environmentId: string,
    outputs: { endpoint: string; resourceGroupNames: string[]; resourceIds: string[]; imageRepository?: string; sharedAcrId?: string },
  ): Promise<EnvironmentRecord> {
    const record = await this.#required(environmentId);
    if (record.phase !== "AZURE_CREATING") throw new SafetyError("OUTPUT_PHASE", "Provisioning outputs may only be recorded during AZURE_CREATING");
    if (!outputs.endpoint.startsWith("https://")) throw new SafetyError("ENDPOINT_NOT_HTTPS", "Golden path endpoint must use trusted HTTPS");
    assertResidualInventoryPair(outputs.imageRepository, outputs.sharedAcrId);
    assertResidualInventoryIdentity(record, outputs);
    const inventory = validateProvisioningInventory(record, outputs, this.#requiredSubscriptionId());
    if (!record.etag) throw new SafetyError("ETAG_MISSING", "Inventory record has no ETag");
    const now = this.#clock.now().toISOString();
    const changed: EnvironmentRecord = {
      ...record,
      endpoint: outputs.endpoint,
      resourceGroupNames: record.resourceGroupNames,
      resourceIds: inventory.resourceIds,
      ...(outputs.imageRepository ? { imageRepository: outputs.imageRepository } : {}),
      ...(outputs.sharedAcrId ? { sharedAcrId: outputs.sharedAcrId } : {}),
      updatedAt: now,
      fencingGeneration: record.fencingGeneration + 1,
    };
    const saved = await this.#store.updateEnvironment(changed, record.etag);
    const resourceRecords = changed.resourceIds.map((resourceId) => ({
      environmentId,
      resourceId,
      resourceType: resourceTypeFromId(resourceId),
      discoveredAt: now,
    }));
    if (changed.imageRepository && changed.sharedAcrId) {
      resourceRecords.push({
        environmentId,
        resourceId: acrRepositoryInventoryId(changed.sharedAcrId, changed.imageRepository),
        resourceType: "Microsoft.ContainerRegistry/registries/repositories",
        discoveredAt: now,
      });
    }
    await this.#store.putResources(environmentId, resourceRecords);
    return saved;
  }

  async requestDestroy(environmentId: string, actor: string): Promise<EnvironmentRecord> {
    const record = await this.#required(environmentId);
    if (record.phase === "QUIESCING" || record.phase === "AZURE_DELETING" || record.phase === "AZURE_ABSENT" || record.phase === "REPO_DELETING" || record.phase === "DELETED") return record;
    return this.#move(environmentId, "QUIESCING", actor, "Environment deletion requested");
  }

  #requiredSubscriptionId(): string {
    if (!this.#subscriptionId) {
      throw new SafetyError("SUBSCRIPTION_CONFIG_MISSING", "AZURE_SUBSCRIPTION_ID is required before accepting disposable resource inventory");
    }
    return this.#subscriptionId;
  }

  async get(environmentId: string): Promise<EnvironmentRecord> {
    return this.#required(environmentId);
  }

  async advanceDeletion(
    environmentId: string,
    to: Extract<Phase, "AZURE_DELETING" | "AZURE_ABSENT" | "REPO_DELETING" | "DELETED">,
    actor: string,
    azureAbsence?: AzureAbsenceEvidence,
  ): Promise<EnvironmentRecord> {
    const record = await this.#required(environmentId);
    const result = transitionEnvironment(record, to, actor, this.#clock.now(), {
      summary: `Deletion checkpoint ${to}`,
      ...(azureAbsence ? { azureAbsence } : {}),
    });
    return this.#commit(record, result.record, result.operation);
  }

  async extend(environmentId: string, rawHours: unknown, actor: string): Promise<EnvironmentRecord> {
    const additionalHours: ExtensionHours = parseExtensionHours(rawHours);
    const record = await this.#required(environmentId);
    const now = this.#clock.now();
    if (record.phase !== "ACTIVE") throw new SafetyError("EXTENSION_PHASE", "Only an ACTIVE environment may be extended");
    if (record.expirySyncPending) throw new SafetyError("EXTENSION_SYNC_PENDING", "The previous expiry extension has not finished synchronizing");
    if (record.owner.toLowerCase() !== actor.toLowerCase() && !this.#admins.has(actor.toLowerCase())) {
      throw new SafetyError("EXTENSION_FORBIDDEN", "Only the owner or a platform administrator may extend this environment");
    }
    if (Date.parse(record.expiresAt) - now.getTime() <= 15 * 60_000) {
      throw new SafetyError("EXTENSION_TOO_LATE", "Extensions are forbidden within 15 minutes of expiry");
    }
    const absoluteMaximum = Date.parse(record.createdAt) + 72 * 3_600_000;
    const proposed = Date.parse(record.expiresAt) + additionalHours * 3_600_000;
    if (proposed > absoluteMaximum) throw new SafetyError("EXTENSION_MAX_TTL", "Extension would exceed 72 hours from creation");
    const updated: EnvironmentRecord = {
      ...record,
      expiresAt: new Date(proposed).toISOString(),
      expirySyncPending: true,
      updatedAt: now.toISOString(),
      fencingGeneration: record.fencingGeneration + 1,
    };
    if (!record.etag) throw new SafetyError("ETAG_MISSING", "Inventory record has no ETag");
    return this.#store.updateEnvironment(updated, record.etag);
  }

  async completeExpirySync(environmentId: string, actor: string): Promise<EnvironmentRecord> {
    const record = await this.#required(environmentId);
    if (record.phase !== "ACTIVE") throw new SafetyError("EXPIRY_SYNC_PHASE", "Expiry synchronization is valid only for ACTIVE environments");
    if (!record.expirySyncPending) return record;
    if (!record.etag) throw new SafetyError("ETAG_MISSING", "Inventory record has no ETag");
    const now = this.#clock.now();
    const updated: EnvironmentRecord = {
      ...record,
      expirySyncPending: false,
      updatedAt: now.toISOString(),
      fencingGeneration: record.fencingGeneration + 1,
    };
    const saved = await this.#store.updateEnvironment(updated, record.etag);
    await this.#store.appendOperation({
      operationId: createUuidV7(now.getTime()),
      environmentId,
      occurredAt: now.toISOString(),
      fromPhase: "ACTIVE",
      toPhase: "ACTIVE",
      actor,
      status: "SUCCEEDED",
      summary: "Expiry synchronized to Azure tags and generated-repository metadata",
    });
    return saved;
  }

  async adoptResources(environmentId: string, resourceIds: string[], actor: string): Promise<EnvironmentRecord> {
    const record = await this.#required(environmentId);
    if (record.phase !== "ACTIVE") throw new SafetyError("ADOPTION_PHASE", "Resource adoption is allowed only for ACTIVE environments");
    const allowedGroups = new Set(record.resourceGroupNames.map((name) => name.toLowerCase()));
    for (const resourceId of resourceIds) {
      const group = resourceId.match(/\/resourceGroups\/([^/]+)/i)?.[1]?.toLowerCase();
      if (!group || !allowedGroups.has(group)) throw new SafetyError("ADOPTION_SCOPE", "Discovered resource is outside inventoried environment resource groups");
    }
    const merged = [...new Set([...record.resourceIds, ...resourceIds])];
    if (merged.length === record.resourceIds.length) return record;
    if (!record.etag) throw new SafetyError("ETAG_MISSING", "Inventory record has no ETag");
    const now = this.#clock.now();
    const updated: EnvironmentRecord = {
      ...record,
      resourceIds: merged,
      updatedAt: now.toISOString(),
      fencingGeneration: record.fencingGeneration + 1,
    };
    const saved = await this.#store.updateEnvironment(updated, record.etag);
    await this.#store.putResources(environmentId, resourceIds.map((resourceId) => ({
      environmentId,
      resourceId,
      resourceType: resourceTypeFromId(resourceId),
      discoveredAt: now.toISOString(),
    })));
    await this.#store.appendOperation({
      operationId: createUuidV7(now.getTime()),
      environmentId,
      occurredAt: now.toISOString(),
      fromPhase: "ACTIVE",
      toPhase: "ACTIVE",
      actor,
      status: "SUCCEEDED",
      summary: `Adopted ${merged.length - record.resourceIds.length} immutable-tag-matched Azure resource(s)`,
    });
    return saved;
  }

  async markRepositoryDeleteIssued(environmentId: string, actor: string): Promise<EnvironmentRecord> {
    const record = await this.#required(environmentId);
    if (record.phase !== "REPO_DELETING") throw new SafetyError("DELETE_ISSUED_PHASE", "Repository DELETE may only be issued from REPO_DELETING");
    if (!record.repository) throw new SafetyError("REPOSITORY_IDENTITY_MISSING", "Repository DELETE intent requires immutable repository identity");
    if (record.repositoryDeleteIssuedAt) return record;
    if (!record.etag) throw new SafetyError("ETAG_MISSING", "Inventory record has no ETag");
    const now = this.#clock.now();
    const issued: EnvironmentRecord = {
      ...record,
      repositoryDeleteIssuedAt: now.toISOString(),
      updatedAt: now.toISOString(),
      fencingGeneration: record.fencingGeneration + 1,
    };
    const saved = await this.#store.updateEnvironment(issued, record.etag);
    await this.#store.appendOperation({
      operationId: createUuidV7(now.getTime()),
      environmentId,
      occurredAt: now.toISOString(),
      fromPhase: "REPO_DELETING",
      toPhase: "REPO_DELETING",
      actor,
      status: "SUCCEEDED",
      summary: "DELETE_ISSUED after immutable repository identity validation",
      ...(record.evidenceHash ? { evidenceHash: record.evidenceHash } : {}),
    });
    return saved;
  }

  async markRepositoryObservedAbsent(environmentId: string, actor: string): Promise<EnvironmentRecord> {
    const record = await this.#required(environmentId);
    if (record.phase !== "QUIESCING") {
      throw new SafetyError("REPOSITORY_ABSENCE_PHASE", "Early repository absence may only be recorded while QUIESCING");
    }
    if (!record.repository) {
      throw new SafetyError("REPOSITORY_IDENTITY_MISSING", "Immutable repository identity is required to record node-based absence");
    }
    if (record.repositoryObservedAbsentAt) return record;
    if (!record.etag) throw new SafetyError("ETAG_MISSING", "Inventory record has no ETag");
    const now = this.#clock.now();
    const observed: EnvironmentRecord = {
      ...record,
      repositoryObservedAbsentAt: now.toISOString(),
      updatedAt: now.toISOString(),
      fencingGeneration: record.fencingGeneration + 1,
    };
    const saved = await this.#store.updateEnvironment(observed, record.etag);
    await this.#store.appendOperation({
      operationId: createUuidV7(now.getTime()),
      environmentId,
      occurredAt: now.toISOString(),
      fromPhase: "QUIESCING",
      toPhase: "QUIESCING",
      actor,
      status: "SUCCEEDED",
      summary: "Repository absence observed through immutable GraphQL node ID before Azure deletion",
    });
    return saved;
  }

  async recordFailure(environmentId: string, actor: string, code: string, summary: string): Promise<EnvironmentRecord> {
    const record = await this.#required(environmentId);
    if (!record.etag) throw new SafetyError("ETAG_MISSING", "Inventory record has no ETag");
    const now = this.#clock.now();
    const failed = applyFailure(record, code, summary, now);
    const saved = await this.#store.updateEnvironment(failed, record.etag);
    await this.#store.appendOperation({
      operationId: createUuidV7(now.getTime()),
      environmentId,
      occurredAt: now.toISOString(),
      fromPhase: record.phase,
      toPhase: record.phase,
      actor,
      status: "FAILED",
      summary: failed.lastErrorSummary ?? "Lifecycle operation failed",
      ...(record.evidenceHash ? { evidenceHash: record.evidenceHash } : {}),
    });
    return saved;
  }

  async markTombstoneRetained(environmentId: string, actor: string, blobName: string, evidenceHash: string): Promise<EnvironmentRecord> {
    const record = await this.#required(environmentId);
    if (record.phase !== "DELETED") throw new SafetyError("TOMBSTONE_PHASE", "Final tombstone evidence may only be recorded for DELETED environments");
    const expectedBlobName = `${environmentId}/tombstone/final.json`;
    if (blobName !== expectedBlobName) throw new SafetyError("TOMBSTONE_PATH", "Final tombstone must use the deterministic environment evidence path");
    if (!/^[0-9a-f]{64}$/.test(evidenceHash)) throw new SafetyError("TOMBSTONE_HASH", "Final tombstone evidence hash must be lowercase sha256");
    if (record.tombstoneRetainedAt) {
      if (record.tombstoneBlobName !== blobName || record.tombstoneEvidenceHash !== evidenceHash) {
        throw new SafetyError("TOMBSTONE_CONFLICT", "Retained tombstone metadata differs from the existing immutable checkpoint");
      }
      return record;
    }
    if (!record.etag) throw new SafetyError("ETAG_MISSING", "Inventory record has no ETag");
    const now = this.#clock.now();
    const retained: EnvironmentRecord = {
      ...record,
      tombstoneRetainedAt: now.toISOString(),
      tombstoneBlobName: blobName,
      tombstoneEvidenceHash: evidenceHash,
      updatedAt: now.toISOString(),
      fencingGeneration: record.fencingGeneration + 1,
    };
    const saved = await this.#store.updateEnvironment(retained, record.etag);
    await this.#store.appendOperation({
      operationId: createUuidV7(now.getTime()),
      environmentId,
      occurredAt: now.toISOString(),
      fromPhase: "DELETED",
      toPhase: "DELETED",
      actor,
      status: "SUCCEEDED",
      summary: "Final sanitized tombstone retained and hash checkpointed",
      evidenceHash,
    });
    return saved;
  }

  async purgeRetainedEnvironment(environmentId: string, retentionDays = 90): Promise<EnvironmentRecord> {
    const record = await this.#required(environmentId);
    if (record.phase !== "DELETED") {
      throw new SafetyError("RETENTION_PHASE", "Only a DELETED environment may be purged from retained inventory");
    }
    if (!record.tombstoneRetainedAt || !record.tombstoneBlobName || !record.tombstoneEvidenceHash) {
      throw new SafetyError("TOMBSTONE_NOT_RETAINED", "Terminal inventory cannot be purged before final tombstone retention is checkpointed");
    }
    if (!Number.isInteger(retentionDays) || retentionDays < 90) {
      throw new SafetyError("RETENTION_PERIOD", "Lifecycle history must be retained for at least 90 days");
    }
    const updatedAt = Date.parse(record.updatedAt);
    if (!Number.isFinite(updatedAt) || this.#clock.now().getTime() - updatedAt < retentionDays * 86_400_000) {
      throw new SafetyError("RETENTION_NOT_EXPIRED", `Lifecycle history is retained for ${retentionDays} days after its final update`);
    }
    if (!record.etag) throw new SafetyError("ETAG_MISSING", "Inventory record has no ETag");
    await this.#store.purgeEnvironmentHistory(environmentId, record.etag);
    return record;
  }

  async #move(environmentId: string, phase: Parameters<typeof transitionEnvironment>[1], actor: string, summary: string): Promise<EnvironmentRecord> {
    const record = await this.#required(environmentId);
    const result = transitionEnvironment(record, phase, actor, this.#clock.now(), { summary });
    return this.#commit(record, result.record, result.operation);
  }

  async #required(environmentId: string): Promise<EnvironmentRecord> {
    assertEnvironmentId(environmentId);
    const record = await this.#store.getEnvironment(environmentId);
    if (!record) throw new SafetyError("ENVIRONMENT_NOT_FOUND", `Environment ${environmentId} is not present in authoritative inventory`);
    return record;
  }

  async #commit(previous: EnvironmentRecord, next: EnvironmentRecord, operation: Parameters<InventoryStore["appendOperation"]>[0]): Promise<EnvironmentRecord> {
    if (!previous.etag) throw new SafetyError("ETAG_MISSING", "Inventory record has no ETag");
    const saved = await this.#store.updateEnvironment(next, previous.etag);
    await this.#store.appendOperation(operation);
    return saved;
  }
}

export function terraformPath(path: EnvironmentRequest["goldenPath"]): string {
  return path === "aks" ? "aks-workload-v1" : `${path}-v1`;
}

function resourceTypeFromId(resourceId: string): string {
  const marker = "/providers/";
  const index = resourceId.toLowerCase().indexOf(marker);
  if (index < 0) return "Microsoft.Resources/resourceGroups";
  const parts = resourceId.slice(index + marker.length).split("/");
  return parts.length >= 2 ? `${parts[0]}/${parts[1]}` : "unknown";
}

function assertResidualInventoryPair(imageRepository?: string, sharedAcrId?: string): void {
  if (imageRepository && !sharedAcrId) {
    throw new SafetyError("ACR_INVENTORY_INCOMPLETE", "An image repository requires its immutable shared ACR resource ID");
  }
}

function acrRepositoryInventoryId(sharedAcrId: string, imageRepository: string): string {
  return `${sharedAcrId.replace(/\/$/, "")}/repositories/${imageRepository}`;
}

function acrRepositoryRecord(environmentId: string, sharedAcrId: string, imageRepository: string, discoveredAt: string) {
  return {
    environmentId,
    resourceId: acrRepositoryInventoryId(sharedAcrId, imageRepository),
    resourceType: "Microsoft.ContainerRegistry/registries/repositories",
    discoveredAt,
  };
}

function sameRepository(left: RepositoryIdentity, right: RepositoryIdentity): boolean {
  return left.nodeId === right.nodeId && left.numericId === right.numericId &&
    left.owner.toLowerCase() === right.owner.toLowerCase() && left.name === right.name && left.htmlUrl === right.htmlUrl;
}

function assertResidualInventoryIdentity(
  record: EnvironmentRecord,
  outputs: { imageRepository?: string; sharedAcrId?: string },
): void {
  if (record.imageRepository && outputs.imageRepository !== record.imageRepository) {
    throw new SafetyError("ACR_INVENTORY_MISMATCH", "Terraform output changed the image repository recorded before provisioning");
  }
  if (record.sharedAcrId) {
    const outputAcrId = outputs.sharedAcrId ? normalizeAzureResourceId(outputs.sharedAcrId) : undefined;
    if (!outputAcrId || outputAcrId.toLowerCase() !== record.sharedAcrId.toLowerCase()) {
      throw new SafetyError("ACR_INVENTORY_MISMATCH", "Terraform output changed the shared ACR identity recorded before provisioning");
    }
  }
}

function validateProvisioningInventory(
  record: EnvironmentRecord,
  outputs: { resourceGroupNames: string[]; resourceIds: string[] },
  subscriptionId: string,
): { resourceIds: string[] } {
  assertExactCaseInsensitiveSet(
    record.resourceGroupNames,
    outputs.resourceGroupNames,
    "RESOURCE_GROUP_INVENTORY_MISMATCH",
    "Terraform outputs must exactly preserve the resource groups inventoried before repository creation",
  );
  const resourceIds = [...new Map(outputs.resourceIds.map((value) => {
    const normalized = normalizeAzureResourceId(value);
    assertResourceSubscription(normalized, subscriptionId);
    return [normalized.toLowerCase(), normalized] as const;
  })).values()];
  if (resourceIds.length === 0) {
    throw new SafetyError("RESOURCE_INVENTORY_EMPTY", "Terraform outputs must inventory disposable Azure resources");
  }
  for (const groupName of record.resourceGroupNames) {
    const expectedGroupId = `/subscriptions/${subscriptionId}/resourceGroups/${groupName}`.toLowerCase();
    if (!resourceIds.some((resourceId) => resourceId.toLowerCase() === expectedGroupId)) {
      throw new SafetyError("RESOURCE_GROUP_ID_MISSING", `Terraform outputs omitted the pre-inventoried resource group ID ${groupName}`);
    }
  }
  return { resourceIds };
}

function assertResourceSubscription(resourceId: string, subscriptionId: string): void {
  const actual = resourceId.match(/^\/subscriptions\/([^/]+)/i)?.[1]?.toLowerCase();
  if (actual !== subscriptionId.toLowerCase()) {
    throw new SafetyError("RESOURCE_SUBSCRIPTION_MISMATCH", "Disposable inventory contains a resource outside the configured Azure subscription");
  }
}

function assertExactCaseInsensitiveSet(
  expected: string[],
  actual: string[],
  code: string,
  message: string,
): void {
  const expectedSet = new Set(expected.map((value) => value.toLowerCase()));
  const actualSet = new Set(actual.map((value) => value.toLowerCase()));
  if (expectedSet.size !== actualSet.size || [...expectedSet].some((value) => !actualSet.has(value))) {
    throw new SafetyError(code, message);
  }
}

function predictedResourceGroupNames(path: EnvironmentRequest["goldenPath"], name: string, shortId: string): string[] {
  if (path === "web-app") return [`rg-${name}-web-${shortId}`];
  if (path === "container-app") return [`rg-${name}-ca-${shortId}`];
  return [`rg-${name}-aks-${shortId}`, `rg-${name}-aksnodes-${shortId}`];
}
