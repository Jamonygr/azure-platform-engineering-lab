import { ValidationError } from "./errors.ts";
import {
  EXTENSION_HOURS,
  GOLDEN_PATHS,
  LOCATIONS,
  PHASES,
  TTL_HOURS,
  type EnvironmentRecord,
  type EnvironmentRequest,
  type ExtensionHours,
  type GoldenPath,
  type Location,
  type Phase,
  type RepositoryIdentity,
  type TtlHours,
} from "./types.ts";
import { isUuidV7 } from "./uuidv7.ts";

const SLUG_3_20 = /^[a-z](?:[a-z0-9-]{1,18}[a-z0-9])$/;
const SLUG_3_50 = /^[a-z0-9](?:[a-z0-9-]{1,48}[a-z0-9])$/;
const GITHUB_OWNER = /^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?$/;
const GITHUB_NODE_ID = /^[A-Za-z0-9_=-]{6,200}$/;
const AZURE_RESOURCE_ID = /^\/subscriptions\/([0-9a-f-]{36})\/resourceGroups\/([^/]+)(?:\/providers\/([^/]+)\/(.+))?$/i;

function requiredString(value: unknown, field: string, issues: string[]): string {
  if (typeof value !== "string" || value.trim().length === 0) {
    issues.push(`${field} is required`);
    return "";
  }
  return value.trim();
}

function parseInteger(value: unknown, field: string, issues: string[]): number {
  const parsed = typeof value === "number" ? value : Number(value);
  if (!Number.isSafeInteger(parsed)) {
    issues.push(`${field} must be an integer`);
    return Number.NaN;
  }
  return parsed;
}

function parseBoolean(value: unknown): boolean {
  return value === true || (typeof value === "string" && value.toLowerCase() === "true");
}

export function parseEnvironmentRequest(input: Record<string, unknown>): EnvironmentRequest {
  const issues: string[] = [];
  const goldenPath = requiredString(input.goldenPath ?? input.golden_path, "goldenPath", issues);
  const environmentName = requiredString(input.environmentName ?? input.environment_name, "environmentName", issues);
  const repositoryName = requiredString(input.repositoryName ?? input.repository_name, "repositoryName", issues);
  const location = requiredString(input.location, "location", issues);
  const ttlHours = parseInteger(input.ttlHours ?? input.ttl_hours, "ttlHours", issues);
  const requester = requiredString(input.requester, "requester", issues);
  const acknowledgeAksCost = parseBoolean(input.acknowledgeAksCost ?? input.acknowledge_aks_cost);

  if (!GOLDEN_PATHS.includes(goldenPath as GoldenPath)) issues.push(`goldenPath must be one of ${GOLDEN_PATHS.join(", ")}`);
  if (!SLUG_3_20.test(environmentName)) issues.push("environmentName must be a lowercase 3-20 character slug beginning with a letter and without edge hyphens");
  if (!SLUG_3_50.test(repositoryName)) issues.push("repositoryName must be a lowercase 3-50 character slug without edge hyphens");
  if (!LOCATIONS.includes(location as Location)) issues.push(`location must be one of ${LOCATIONS.join(", ")}`);
  if (!TTL_HOURS.includes(ttlHours as TtlHours)) issues.push(`ttlHours must be one of ${TTL_HOURS.join(", ")}`);
  if (!GITHUB_OWNER.test(requester)) issues.push("requester must be a valid GitHub login");
  if (goldenPath === "aks" && !acknowledgeAksCost) issues.push("acknowledgeAksCost must be true for AKS");
  if (issues.length > 0) throw new ValidationError(issues);

  return {
    goldenPath: goldenPath as GoldenPath,
    environmentName,
    repositoryName,
    location: location as Location,
    ttlHours: ttlHours as TtlHours,
    acknowledgeAksCost,
    requester,
  };
}

export function parseExtensionHours(value: unknown): ExtensionHours {
  const issues: string[] = [];
  const parsed = parseInteger(value, "additionalHours", issues);
  if (!EXTENSION_HOURS.includes(parsed as ExtensionHours)) issues.push(`additionalHours must be one of ${EXTENSION_HOURS.join(", ")}`);
  if (issues.length > 0) throw new ValidationError(issues);
  return parsed as ExtensionHours;
}

export function assertEnvironmentId(value: unknown): asserts value is string {
  if (!isUuidV7(value)) throw new ValidationError(["environmentId must be an RFC 9562 UUIDv7"]);
}

export function parseRepositoryIdentity(value: unknown): RepositoryIdentity {
  const input = (value ?? {}) as Record<string, unknown>;
  const issues: string[] = [];
  const owner = requiredString(input.owner, "repository.owner", issues);
  const name = requiredString(input.name, "repository.name", issues);
  const nodeId = requiredString(input.nodeId ?? input.node_id, "repository.nodeId", issues);
  const htmlUrl = requiredString(input.htmlUrl ?? input.html_url, "repository.htmlUrl", issues);
  const numericId = parseInteger(input.numericId ?? input.id, "repository.numericId", issues);
  if (!GITHUB_OWNER.test(owner)) issues.push("repository.owner is not a valid GitHub owner");
  if (!SLUG_3_50.test(name)) issues.push("repository.name is not a safe slug");
  if (!GITHUB_NODE_ID.test(nodeId)) issues.push("repository.nodeId is malformed");
  if (!Number.isSafeInteger(numericId) || numericId <= 0) issues.push("repository.numericId must be positive");
  try {
    const url = new URL(htmlUrl);
    if (url.protocol !== "https:" || url.hostname.toLowerCase() !== "github.com") issues.push("repository.htmlUrl must be an HTTPS github.com URL");
  } catch {
    issues.push("repository.htmlUrl must be a URL");
  }
  if (issues.length > 0) throw new ValidationError(issues);
  return { owner, name, nodeId, htmlUrl, numericId };
}

export function normalizeAzureResourceId(value: unknown): string {
  if (typeof value !== "string" || !AZURE_RESOURCE_ID.test(value)) {
    throw new ValidationError(["resourceId must be an absolute Azure resource or resource-group ID"]);
  }
  return value.replace(/\/$/, "");
}

export function assertPhase(value: unknown): asserts value is Phase {
  if (typeof value !== "string" || !PHASES.includes(value as Phase)) throw new ValidationError(["phase is invalid"]);
}

export function assertEnvironmentRecord(value: EnvironmentRecord): void {
  const issues: string[] = [];
  if (!isUuidV7(value.environmentId)) issues.push("environmentId is invalid");
  if (value.partitionKey !== "environment") issues.push("partitionKey must be environment");
  if (!PHASES.includes(value.phase)) issues.push("phase is invalid");
  if (value.desiredState !== "ACTIVE" && value.desiredState !== "DELETED") issues.push("desiredState is invalid");
  if (!GOLDEN_PATHS.includes(value.goldenPath)) issues.push("goldenPath is invalid");
  if (value.pathVersion !== "v1") issues.push("pathVersion must be v1");
  if (!SLUG_3_20.test(value.environmentName)) issues.push("environmentName is invalid");
  if (!SLUG_3_50.test(value.requestedRepositoryName)) issues.push("requestedRepositoryName is invalid");
  if (!LOCATIONS.includes(value.location)) issues.push("location is invalid");
  if (!GITHUB_OWNER.test(value.owner)) issues.push("owner is invalid");
  if (Number.isNaN(Date.parse(value.createdAt))) issues.push("createdAt must be RFC3339");
  if (Number.isNaN(Date.parse(value.updatedAt))) issues.push("updatedAt must be RFC3339");
  if (Number.isNaN(Date.parse(value.expiresAt))) issues.push("expiresAt must be RFC3339");
  if (value.nextAttemptAt && Number.isNaN(Date.parse(value.nextAttemptAt))) issues.push("nextAttemptAt must be RFC3339");
  if (value.repositoryObservedAbsentAt !== undefined && (typeof value.repositoryObservedAbsentAt !== "string" || Number.isNaN(Date.parse(value.repositoryObservedAbsentAt)))) {
    issues.push("repositoryObservedAbsentAt must be RFC3339");
  }
  if (value.repositoryDeleteIssuedAt && Number.isNaN(Date.parse(value.repositoryDeleteIssuedAt))) issues.push("repositoryDeleteIssuedAt must be RFC3339");
  if (value.tombstoneRetainedAt && Number.isNaN(Date.parse(value.tombstoneRetainedAt))) issues.push("tombstoneRetainedAt must be RFC3339");
  if (value.tombstoneBlobName && value.tombstoneBlobName !== `${value.environmentId}/tombstone/final.json`) {
    issues.push("tombstoneBlobName must be the deterministic environment tombstone path");
  }
  if (value.tombstoneEvidenceHash && !/^[0-9a-f]{64}$/.test(value.tombstoneEvidenceHash)) issues.push("tombstoneEvidenceHash must be sha256");
  if ((value.tombstoneRetainedAt || value.tombstoneBlobName || value.tombstoneEvidenceHash) &&
      (!value.tombstoneRetainedAt || !value.tombstoneBlobName || !value.tombstoneEvidenceHash || value.phase !== "DELETED")) {
    issues.push("complete tombstone retention metadata is valid only for DELETED records");
  }
  if (!Number.isSafeInteger(value.attempts) || value.attempts < 0) issues.push("attempts must be a non-negative integer");
  if (!Number.isSafeInteger(value.fencingGeneration) || value.fencingGeneration < 1) issues.push("fencingGeneration must be a positive integer");
  if (!Array.isArray(value.resourceIds)) issues.push("resourceIds must be an array");
  if (!Array.isArray(value.resourceGroupNames) || value.resourceGroupNames.some((name) => typeof name !== "string" || !/^[-A-Za-z0-9._()]{1,90}$/.test(name))) {
    issues.push("resourceGroupNames must contain safe Azure resource-group names");
  }
  if (typeof value.stateKey !== "string" || !value.stateKey.startsWith("workloads/github/") || !value.stateKey.endsWith(`/${value.environmentId}.tfstate`)) issues.push("stateKey does not match environmentId");
  if (value.imageRepository && !/^apps\/[0-9]+$/.test(value.imageRepository)) issues.push("imageRepository is invalid");
  if (value.sharedAcrId) {
    try { normalizeAzureResourceId(value.sharedAcrId); } catch { issues.push("sharedAcrId is invalid"); }
  }
  if (value.imageRepository && !value.sharedAcrId) issues.push("imageRepository requires immutable sharedAcrId");
  if (value.expirySyncPending !== undefined && typeof value.expirySyncPending !== "boolean") issues.push("expirySyncPending must be boolean");
  if (value.repositoryObservedAbsentAt !== undefined && !value.repository) issues.push("repositoryObservedAbsentAt requires immutable repository identity");
  if (value.repository) {
    try { parseRepositoryIdentity(value.repository); } catch (error) {
      if (error instanceof ValidationError) issues.push(...error.issues);
      else throw error;
    }
  }
  for (const id of value.resourceIds ?? []) {
    try { normalizeAzureResourceId(id); } catch { issues.push(`invalid tracked resource ID: ${id}`); }
  }
  if (issues.length > 0) throw new ValidationError(issues);
}
