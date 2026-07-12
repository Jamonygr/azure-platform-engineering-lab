import type { EnvironmentRecord, Phase, RepositoryIdentity } from "./types.ts";

export interface ObservedRepositoryIdentity {
  nodeId: string;
  numericId: number;
  owner: string;
  name: string;
}

export function matchesActiveRepositoryTrustBinding(expected: RepositoryIdentity, actual: ObservedRepositoryIdentity): boolean {
  return actual.nodeId === expected.nodeId &&
    actual.numericId === expected.numericId &&
    actual.owner.toLowerCase() === expected.owner.toLowerCase() &&
    actual.name.toLowerCase() === expected.name.toLowerCase();
}

export type ReconcileAction =
  | { kind: "DESTROY"; environmentId: string; reason: "EXPIRED" | "STALE_PROVISION" | "REPOSITORY_MISSING" | "REPOSITORY_IDENTITY_MISMATCH" }
  | { kind: "RETRY_AZURE_DELETE"; environmentId: string }
  | { kind: "RETRY_REPOSITORY_DELETE"; environmentId: string }
  | { kind: "SYNC_EXPIRY"; environmentId: string }
  | { kind: "OBSERVATION_ERROR"; environmentId: string; reason: string }
  | { kind: "NONE"; environmentId: string };

export interface ReconcileObservation {
  now: Date;
  repositoryExists?: boolean;
  repositoryIdentityMatches?: boolean;
  staleProvisionAfterMinutes?: number;
}

export function decideReconcileAction(record: EnvironmentRecord, observation: ReconcileObservation): ReconcileAction {
  if (record.phase === "DELETED") return { kind: "NONE", environmentId: record.environmentId };
  if (record.nextAttemptAt && observation.now.getTime() < Date.parse(record.nextAttemptAt)) {
    return { kind: "NONE", environmentId: record.environmentId };
  }
  if (record.phase === "AZURE_DELETING" || record.phase === "QUIESCING") return { kind: "RETRY_AZURE_DELETE", environmentId: record.environmentId };
  if (record.phase === "AZURE_ABSENT" || record.phase === "REPO_DELETING") return { kind: "RETRY_REPOSITORY_DELETE", environmentId: record.environmentId };
  if (observation.repositoryIdentityMatches === false && record.repository) return { kind: "DESTROY", environmentId: record.environmentId, reason: "REPOSITORY_IDENTITY_MISMATCH" };
  if (observation.repositoryExists === false && record.repository) return { kind: "DESTROY", environmentId: record.environmentId, reason: "REPOSITORY_MISSING" };
  if (observation.now.getTime() >= Date.parse(record.expiresAt)) return { kind: "DESTROY", environmentId: record.environmentId, reason: "EXPIRED" };
  if (record.phase === "ACTIVE" && record.expirySyncPending) return { kind: "SYNC_EXPIRY", environmentId: record.environmentId };
  const pending: Phase[] = ["REQUESTED", "REPO_READY", "AZURE_CREATING"];
  const staleAfter = (observation.staleProvisionAfterMinutes ?? 60) * 60_000;
  if (pending.includes(record.phase) && observation.now.getTime() - Date.parse(record.updatedAt) >= staleAfter) {
    return { kind: "DESTROY", environmentId: record.environmentId, reason: "STALE_PROVISION" };
  }
  return { kind: "NONE", environmentId: record.environmentId };
}

export interface ReconcileExecutor {
  execute(action: Exclude<ReconcileAction, { kind: "NONE" }>, dryRun: boolean): Promise<void>;
}

export async function reconcileAll(
  records: EnvironmentRecord[],
  executor: ReconcileExecutor,
  options: { now: Date; dryRun: boolean },
): Promise<ReconcileAction[]> {
  const actions = records.map((record) => decideReconcileAction(record, { now: options.now }));
  for (const action of actions) {
    if (action.kind !== "NONE") await executor.execute(action, options.dryRun);
  }
  return actions;
}
