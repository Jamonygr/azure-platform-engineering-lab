import { SafetyError } from "./errors.ts";
import { parseRepositoryIdentity } from "./schema.ts";
import { verifyAzureAbsenceEvidence } from "./state-machine.ts";
import type { EnvironmentRecord, RepositoryIdentity } from "./types.ts";

export interface ResolvedRepository {
  owner: string;
  name: string;
  numericId: number;
  nodeId: string;
  htmlUrl: string;
  isArchived: boolean;
}

export interface GitHubRepositoryClient {
  resolveRepositoryByNodeId(nodeId: string): Promise<ResolvedRepository | undefined>;
  deleteRepository(owner: string, name: string): Promise<void>;
}

export interface RepositoryDeletionPolicy {
  enabled: boolean;
  expectedOwner: string;
  dryRun: boolean;
}

export interface RepositoryDeletionResult {
  deleted: boolean;
  owner: string;
  name: string;
  reason: "DELETED" | "DRY_RUN" | "ALREADY_ABSENT_AFTER_ISSUED_DELETE" | "ALREADY_ABSENT_AFTER_IMMUTABLE_OBSERVATION";
}

export async function deleteRepositoryFailClosed(
  record: EnvironmentRecord,
  client: GitHubRepositoryClient,
  policy: RepositoryDeletionPolicy,
  onDeleteIssued?: (repository: ResolvedRepository) => Promise<void>,
): Promise<RepositoryDeletionResult> {
  if (!policy.enabled) throw new SafetyError("REPOSITORY_DELETE_DISABLED", "Repository deletion is disabled; set the explicit platform opt-in only after review");
  if (record.phase !== "AZURE_ABSENT" && record.phase !== "REPO_DELETING") {
    throw new SafetyError("AZURE_NOT_PROVEN_ABSENT", "Repository deletion is forbidden before the AZURE_ABSENT checkpoint");
  }
  if (!record.azureAbsence) throw new SafetyError("ABSENCE_EVIDENCE_MISSING", "Repository deletion requires retained Azure absence evidence");
  verifyAzureAbsenceEvidence(record.azureAbsence, record.resourceIds, record.resourceGroupNames, record.imageRepository);
  if (!record.repository) throw new SafetyError("REPOSITORY_IDENTITY_MISSING", "Name-only repository deletion is forbidden");

  const expected = parseRepositoryIdentity(record.repository);
  if (expected.owner.toLowerCase() !== policy.expectedOwner.toLowerCase()) {
    throw new SafetyError("OWNER_POLICY_MISMATCH", "Inventory owner does not match the configured generated-repository owner");
  }

  const hasImmutableAbsenceCheckpoint = record.repositoryObservedAbsentAt !== undefined;
  const resolved = await client.resolveRepositoryByNodeId(expected.nodeId);
  if (!resolved) {
    if (hasImmutableAbsenceCheckpoint) {
      const observedAt = Date.parse(record.repositoryObservedAbsentAt!);
      if (Number.isNaN(observedAt) || observedAt > Date.parse(record.azureAbsence.verifiedAt)) {
        throw new SafetyError("REPOSITORY_ABSENCE_CHECKPOINT_INVALID", "Immutable repository absence must be a valid checkpoint recorded before Azure absence verification");
      }
      if (policy.dryRun) return { deleted: false, owner: expected.owner, name: expected.name, reason: "DRY_RUN" };
      return { deleted: true, owner: expected.owner, name: expected.name, reason: "ALREADY_ABSENT_AFTER_IMMUTABLE_OBSERVATION" };
    }
    if (record.repositoryDeleteIssuedAt && !policy.dryRun) {
      return { deleted: true, owner: expected.owner, name: expected.name, reason: "ALREADY_ABSENT_AFTER_ISSUED_DELETE" };
    }
    throw new SafetyError("REPOSITORY_UNRESOLVABLE", "The repository node ID cannot be resolved and neither immutable absence nor DELETE_ISSUED was durably checkpointed; failing closed");
  }
  assertSameRepository(expected, resolved, policy.expectedOwner);
  if (hasImmutableAbsenceCheckpoint) {
    throw new SafetyError("REPOSITORY_ABSENCE_CONTRADICTION", "A repository previously observed absent by immutable node ID now resolves; automatic deletion is forbidden");
  }

  if (policy.dryRun) return { deleted: false, owner: resolved.owner, name: resolved.name, reason: "DRY_RUN" };
  if (!record.repositoryDeleteIssuedAt) await onDeleteIssued?.(resolved);
  await client.deleteRepository(resolved.owner, resolved.name);
  return { deleted: true, owner: resolved.owner, name: resolved.name, reason: "DELETED" };
}

function assertSameRepository(expected: RepositoryIdentity, actual: ResolvedRepository, configuredOwner: string): void {
  if (actual.nodeId !== expected.nodeId) throw new SafetyError("NODE_ID_MISMATCH", "Resolved repository node ID does not match inventory");
  if (actual.numericId !== expected.numericId) throw new SafetyError("NUMERIC_ID_MISMATCH", "Resolved repository numeric ID does not match inventory");
  if (actual.owner.toLowerCase() !== expected.owner.toLowerCase()) throw new SafetyError("REPOSITORY_TRANSFERRED", "Repository owner changed; deletion is forbidden");
  if (actual.owner.toLowerCase() !== configuredOwner.toLowerCase()) throw new SafetyError("OWNER_POLICY_MISMATCH", "Resolved repository is outside the configured owner");
}

export class GitHubRestClient implements GitHubRepositoryClient {
  readonly #token: string;
  readonly #apiUrl: string;
  readonly #fetch: typeof fetch;
  readonly #beforeRequest: (() => Promise<void>) | undefined;

  constructor(token: string, apiUrl = "https://api.github.com", fetchImplementation: typeof fetch = fetch, beforeRequest?: () => Promise<void>) {
    if (!token) throw new TypeError("GitHub token is required");
    this.#token = token;
    this.#apiUrl = apiUrl.replace(/\/$/, "");
    this.#fetch = fetchImplementation;
    this.#beforeRequest = beforeRequest;
  }

  async resolveRepositoryByNodeId(nodeId: string): Promise<ResolvedRepository | undefined> {
    const response = await this.#request("/graphql", {
      method: "POST",
      body: JSON.stringify({
        query: "query RepositoryByNodeId($id: ID!) { node(id: $id) { ... on Repository { id databaseId name url isArchived owner { login } } } }",
        variables: { id: nodeId },
      }),
    });
    const result = await response.json() as {
      data?: { node?: { id: string; databaseId: number; name: string; url: string; isArchived: boolean; owner: { login: string } } };
      errors?: unknown[];
    };
    if (result.errors?.length) throw new Error("GitHub GraphQL repository lookup failed");
    if (!result.data?.node) return undefined;
    const repository = result.data.node;
    return {
      nodeId: repository.id,
      numericId: repository.databaseId,
      name: repository.name,
      owner: repository.owner.login,
      htmlUrl: repository.url,
      isArchived: repository.isArchived,
    };
  }

  async deleteRepository(owner: string, name: string): Promise<void> {
    await this.#request(`/repos/${encodeURIComponent(owner)}/${encodeURIComponent(name)}`, { method: "DELETE" });
  }

  async #request(path: string, init: RequestInit): Promise<Response> {
    const attempts = 5;
    for (let attempt = 0; attempt < attempts; attempt += 1) {
      await this.#beforeRequest?.();
      let response: Response;
      try {
        response = await this.#fetch(`${this.#apiUrl}${path}`, {
          ...init,
          headers: {
            Accept: "application/vnd.github+json",
            Authorization: `Bearer ${this.#token}`,
            "Content-Type": "application/json",
            "X-GitHub-Api-Version": "2026-03-10",
            "User-Agent": "azure-platform-engineering-lab-controller",
          },
        });
      } catch (error) {
        if (attempt === attempts - 1) throw error;
        await delay(Math.min(10_000, 500 * 2 ** attempt));
        continue;
      }
      if (response.ok) return response;
      const transient = response.status === 429 || response.status >= 500;
      if (transient && attempt < attempts - 1) {
        const retryAfter = Number(response.headers.get("retry-after"));
        const wait = Number.isFinite(retryAfter) && retryAfter >= 0
          ? Math.min(30_000, retryAfter * 1000)
          : Math.min(10_000, 500 * 2 ** attempt);
        await response.arrayBuffer().catch(() => undefined);
        await delay(wait);
        continue;
      }
      const requestId = response.headers.get("x-github-request-id") ?? "unknown";
      throw new Error(`GitHub API request failed: HTTP ${response.status}, request ${requestId}`);
    }
    throw new Error("GitHub API request exhausted bounded retries");
  }
}

function delay(milliseconds: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}
