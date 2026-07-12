import { createHash } from "node:crypto";
import { SafetyError } from "./errors.ts";
import type { AzureAbsenceEvidence, EnvironmentRecord, OperationRecord, Phase } from "./types.ts";
import { createUuidV7 } from "./uuidv7.ts";

const transitions: Readonly<Record<Phase, readonly Phase[]>> = {
  REQUESTED: ["REPO_READY", "QUIESCING"],
  REPO_READY: ["AZURE_CREATING", "QUIESCING"],
  AZURE_CREATING: ["ACTIVE", "QUIESCING"],
  ACTIVE: ["QUIESCING"],
  QUIESCING: ["AZURE_DELETING"],
  AZURE_DELETING: ["AZURE_ABSENT"],
  AZURE_ABSENT: ["REPO_DELETING", "DELETED"],
  REPO_DELETING: ["DELETED"],
  DELETED: [],
};

export function canTransition(from: Phase, to: Phase): boolean {
  return transitions[from].includes(to);
}

export function verifyAzureAbsenceEvidence(
  evidence: AzureAbsenceEvidence | undefined,
  expectedResourceIds: readonly string[] = [],
  expectedResourceGroupNames: readonly string[] = [],
  expectedImageRepository?: string,
): void {
  if (!evidence) throw new SafetyError("ABSENCE_EVIDENCE_MISSING", "Azure absence evidence is required");
  if (evidence.consecutivePasses < 2) throw new SafetyError("ABSENCE_NOT_REPEATED", "Azure absence must be verified in two consecutive passes");
  if (evidence.remainingStateResources !== 0) throw new SafetyError("STATE_NOT_EMPTY", "Terraform state still contains resources");
  if (evidence.resourceGraphMatchCount !== 0) throw new SafetyError("AZURE_RESIDUALS", "Azure Resource Graph still finds environment resources");
  if (Number.isNaN(Date.parse(evidence.verifiedAt))) throw new SafetyError("ABSENCE_TIME_INVALID", "Azure absence verification time is invalid");
  if (!Array.isArray(evidence.checkedResourceIds) || !Array.isArray(evidence.checkedResourceGroupNames)) {
    throw new SafetyError("ABSENCE_COVERAGE_MALFORMED", "Azure absence coverage lists are required");
  }
  const checkedIds = new Set(evidence.checkedResourceIds.map((value) => value.toLowerCase()));
  const missingIds = expectedResourceIds.filter((value) => !checkedIds.has(value.toLowerCase()));
  if (missingIds.length > 0) throw new SafetyError("ABSENCE_RESOURCE_COVERAGE", `Absence evidence omits ${missingIds.length} inventoried resource ID(s)`);
  const checkedGroups = new Set(evidence.checkedResourceGroupNames.map((value) => value.toLowerCase()));
  const missingGroups = expectedResourceGroupNames.filter((value) => !checkedGroups.has(value.toLowerCase()));
  if (missingGroups.length > 0) throw new SafetyError("ABSENCE_GROUP_COVERAGE", `Absence evidence omits ${missingGroups.length} inventoried resource group(s)`);
  if (expectedImageRepository && (evidence.checkedImageRepository !== expectedImageRepository || evidence.imageRepositoryAbsent !== true)) {
    throw new SafetyError("ABSENCE_IMAGE_COVERAGE", "Absence evidence does not prove the tracked ACR image repository is absent");
  }
}

export function transitionEnvironment(
  record: EnvironmentRecord,
  to: Phase,
  actor: string,
  now: Date,
  options: { summary?: string; azureAbsence?: AzureAbsenceEvidence } = {},
): { record: EnvironmentRecord; operation: OperationRecord } {
  if (!canTransition(record.phase, to)) {
    throw new SafetyError("INVALID_TRANSITION", `Lifecycle transition ${record.phase} -> ${to} is not allowed`);
  }
  if (to === "AZURE_ABSENT") verifyAzureAbsenceEvidence(options.azureAbsence, record.resourceIds, record.resourceGroupNames, record.imageRepository);
  if (to === "REPO_DELETING" && !record.repository) {
    throw new SafetyError("REPOSITORY_IDENTITY_MISSING", "Cannot delete a repository without immutable inventory identity");
  }

  const occurredAt = now.toISOString();
  const absence = to === "AZURE_ABSENT" ? options.azureAbsence : record.azureAbsence;
  const evidenceHash = absence
    ? createHash("sha256").update(JSON.stringify(absence)).digest("hex")
    : record.evidenceHash;
  const next: EnvironmentRecord = {
    ...record,
    phase: to,
    desiredState: to === "QUIESCING" || to === "AZURE_DELETING" || to === "AZURE_ABSENT" || to === "REPO_DELETING" || to === "DELETED"
      ? "DELETED"
      : record.desiredState,
    updatedAt: occurredAt,
    fencingGeneration: record.fencingGeneration + 1,
    ...(absence ? { azureAbsence: absence, evidenceHash } : {}),
    ...(to === "QUIESCING" || to === "AZURE_DELETING" || to === "AZURE_ABSENT" || to === "REPO_DELETING" || to === "DELETED"
      ? { expirySyncPending: false }
      : {}),
  };

  const operation: OperationRecord = {
    operationId: createUuidV7(now.getTime()),
    environmentId: record.environmentId,
    occurredAt,
    fromPhase: record.phase,
    toPhase: to,
    actor,
    status: "SUCCEEDED",
    summary: options.summary ?? `${record.phase} -> ${to}`,
    ...(evidenceHash ? { evidenceHash } : {}),
  };
  return { record: next, operation };
}

export function recordFailure(record: EnvironmentRecord, code: string, summary: string, now: Date): EnvironmentRecord {
  const attempts = record.attempts + 1;
  const backoffSeconds = Math.min(3600, 60 * 2 ** Math.min(attempts - 1, 6));
  return {
    ...record,
    attempts,
    updatedAt: now.toISOString(),
    fencingGeneration: record.fencingGeneration + 1,
    lastErrorCode: code.slice(0, 80),
    lastErrorSummary: sanitizeSummary(summary),
    nextAttemptAt: new Date(now.getTime() + backoffSeconds * 1000).toISOString(),
  };
}

function sanitizeSummary(value: string): string {
  return value
    .replace(/(?:ghp|github_pat|ghs|ghu|gho)_[A-Za-z0-9_]+/g, "[REDACTED_GITHUB_TOKEN]")
    .replace(/Bearer\s+[A-Za-z0-9._~-]+/gi, "Bearer [REDACTED]")
    .slice(0, 1000);
}
