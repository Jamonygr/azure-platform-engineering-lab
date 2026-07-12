export const GOLDEN_PATHS = ["web-app", "container-app", "aks"] as const;
export type GoldenPath = (typeof GOLDEN_PATHS)[number];

export const LOCATIONS = ["westeurope", "northeurope", "germanywestcentral"] as const;
export type Location = (typeof LOCATIONS)[number];

export const TTL_HOURS = [4, 8, 24, 48, 72] as const;
export type TtlHours = (typeof TTL_HOURS)[number];

export const EXTENSION_HOURS = [4, 8, 24] as const;
export type ExtensionHours = (typeof EXTENSION_HOURS)[number];

export const PHASES = [
  "REQUESTED",
  "REPO_READY",
  "AZURE_CREATING",
  "ACTIVE",
  "QUIESCING",
  "AZURE_DELETING",
  "AZURE_ABSENT",
  "REPO_DELETING",
  "DELETED",
] as const;
export type Phase = (typeof PHASES)[number];

export type DesiredState = "ACTIVE" | "DELETED";

export interface EnvironmentRequest {
  goldenPath: GoldenPath;
  environmentName: string;
  repositoryName: string;
  location: Location;
  ttlHours: TtlHours;
  acknowledgeAksCost: boolean;
  requester: string;
}

export interface RepositoryIdentity {
  owner: string;
  name: string;
  numericId: number;
  nodeId: string;
  htmlUrl: string;
}

export interface AzureAbsenceEvidence {
  verifiedAt: string;
  consecutivePasses: number;
  remainingStateResources: number;
  resourceGraphMatchCount: number;
  checkedResourceIds: string[];
  checkedResourceGroupNames: string[];
  checkedImageRepository?: string;
  imageRepositoryAbsent?: boolean;
}

export interface EnvironmentRecord {
  environmentId: string;
  partitionKey: "environment";
  phase: Phase;
  desiredState: DesiredState;
  owner: string;
  goldenPath: GoldenPath;
  pathVersion: "v1";
  environmentName: string;
  location: Location;
  requestedRepositoryName: string;
  createdAt: string;
  updatedAt: string;
  expiresAt: string;
  stateKey: string;
  repository?: RepositoryIdentity;
  resourceGroupNames: string[];
  resourceIds: string[];
  imageRepository?: string;
  sharedAcrId?: string;
  endpoint?: string;
  attempts: number;
  fencingGeneration: number;
  evidenceHash?: string;
  azureAbsence?: AzureAbsenceEvidence;
  lastErrorCode?: string;
  lastErrorSummary?: string;
  nextAttemptAt?: string;
  repositoryObservedAbsentAt?: string;
  repositoryDeleteIssuedAt?: string;
  tombstoneRetainedAt?: string;
  tombstoneBlobName?: string;
  tombstoneEvidenceHash?: string;
  expirySyncPending?: boolean;
  etag?: string;
}

export interface ResourceRecord {
  environmentId: string;
  resourceId: string;
  resourceType: string;
  discoveredAt: string;
  deletedAt?: string;
}

export interface OperationRecord {
  operationId: string;
  environmentId: string;
  occurredAt: string;
  fromPhase: Phase;
  toPhase: Phase;
  actor: string;
  status: "SUCCEEDED" | "FAILED" | "DRY_RUN";
  summary: string;
  evidenceHash?: string;
}

export interface Clock {
  now(): Date;
}

export const systemClock: Clock = { now: () => new Date() };
