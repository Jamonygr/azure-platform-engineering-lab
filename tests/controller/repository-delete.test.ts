import assert from "node:assert/strict";
import test from "node:test";
import { SafetyError } from "../../controller/src/errors.ts";
import { deleteRepositoryFailClosed, type GitHubRepositoryClient, type ResolvedRepository } from "../../controller/src/github.ts";
import { environmentFixture, fixedNow } from "./fixtures.ts";

class FakeGitHub implements GitHubRepositoryClient {
  deleted: string[] = [];
  readonly resolved: ResolvedRepository | undefined;
  constructor(resolved: ResolvedRepository | undefined) { this.resolved = resolved; }
  async resolveRepositoryByNodeId(): Promise<ResolvedRepository | undefined> { return this.resolved; }
  async deleteRepository(owner: string, name: string): Promise<void> { this.deleted.push(`${owner}/${name}`); }
}

const evidence = {
  verifiedAt: fixedNow.toISOString(),
  consecutivePasses: 2,
  remainingStateResources: 0,
  resourceGraphMatchCount: 0,
  checkedResourceIds: ["/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-demo-app"],
  checkedResourceGroupNames: ["rg-demo-app"],
};

function matchingRepository(): ResolvedRepository {
  return {
    owner: "octocat",
    name: "renamed-repo",
    numericId: 123456,
    nodeId: "R_kgDOExample",
    htmlUrl: "https://github.com/octocat/renamed-repo",
    isArchived: true,
  };
}

test("deletion follows immutable node identity across an in-owner rename", async () => {
  const client = new FakeGitHub(matchingRepository());
  const result = await deleteRepositoryFailClosed(environmentFixture({ phase: "AZURE_ABSENT", azureAbsence: evidence }), client, {
    enabled: true,
    expectedOwner: "octocat",
    dryRun: false,
  });
  assert.equal(result.deleted, true);
  assert.deepEqual(client.deleted, ["octocat/renamed-repo"]);
});

test("deletion is opt-in even after Azure absence", async () => {
  await assert.rejects(deleteRepositoryFailClosed(environmentFixture({ phase: "AZURE_ABSENT", azureAbsence: evidence }), new FakeGitHub(matchingRepository()), {
    enabled: false,
    expectedOwner: "octocat",
    dryRun: false,
  }), (error) => error instanceof SafetyError && error.code === "REPOSITORY_DELETE_DISABLED");
});

test("deletion fails before Azure absence", async () => {
  await assert.rejects(deleteRepositoryFailClosed(environmentFixture(), new FakeGitHub(matchingRepository()), {
    enabled: true,
    expectedOwner: "octocat",
    dryRun: false,
  }), (error) => error instanceof SafetyError && error.code === "AZURE_NOT_PROVEN_ABSENT");
});

test("numeric ID mismatch fails closed without DELETE", async () => {
  const client = new FakeGitHub({ ...matchingRepository(), numericId: 999999 });
  await assert.rejects(deleteRepositoryFailClosed(environmentFixture({ phase: "AZURE_ABSENT", azureAbsence: evidence }), client, {
    enabled: true,
    expectedOwner: "octocat",
    dryRun: false,
  }), (error) => error instanceof SafetyError && error.code === "NUMERIC_ID_MISMATCH");
  assert.deepEqual(client.deleted, []);
});

test("repository transfer fails closed without DELETE", async () => {
  const client = new FakeGitHub({ ...matchingRepository(), owner: "unexpected-owner" });
  await assert.rejects(deleteRepositoryFailClosed(environmentFixture({ phase: "AZURE_ABSENT", azureAbsence: evidence }), client, {
    enabled: true,
    expectedOwner: "octocat",
    dryRun: false,
  }), (error) => error instanceof SafetyError && error.code === "REPOSITORY_TRANSFERRED");
  assert.deepEqual(client.deleted, []);
});

test("unresolvable repository is accepted only after a durable DELETE_ISSUED checkpoint", async () => {
  const result = await deleteRepositoryFailClosed(environmentFixture({
    phase: "REPO_DELETING",
    azureAbsence: evidence,
    repositoryDeleteIssuedAt: fixedNow.toISOString(),
  }), new FakeGitHub(undefined), {
    enabled: true,
    expectedOwner: "octocat",
    dryRun: false,
  });
  assert.equal(result.reason, "ALREADY_ABSENT_AFTER_ISSUED_DELETE");
  assert.equal(result.deleted, true);
});

test("early immutable-node absence completes after Azure absence without issuing DELETE", async () => {
  const client = new FakeGitHub(undefined);
  let deleteIssued = false;
  const result = await deleteRepositoryFailClosed(environmentFixture({
    phase: "AZURE_ABSENT",
    azureAbsence: evidence,
    repositoryObservedAbsentAt: fixedNow.toISOString(),
  }), client, {
    enabled: true,
    expectedOwner: "octocat",
    dryRun: false,
  }, async () => { deleteIssued = true; });
  assert.equal(result.reason, "ALREADY_ABSENT_AFTER_IMMUTABLE_OBSERVATION");
  assert.equal(result.deleted, true);
  assert.equal(deleteIssued, false);
  assert.deepEqual(client.deleted, []);
});

test("unresolvable repository without a durable checkpoint remains fail-closed", async () => {
  await assert.rejects(deleteRepositoryFailClosed(environmentFixture({
    phase: "AZURE_ABSENT",
    azureAbsence: evidence,
  }), new FakeGitHub(undefined), {
    enabled: true,
    expectedOwner: "octocat",
    dryRun: false,
  }), (error) => error instanceof SafetyError && error.code === "REPOSITORY_UNRESOLVABLE");
});

test("a repository resolving after an early-absence checkpoint fails closed", async () => {
  const client = new FakeGitHub(matchingRepository());
  await assert.rejects(deleteRepositoryFailClosed(environmentFixture({
    phase: "AZURE_ABSENT",
    azureAbsence: evidence,
    repositoryObservedAbsentAt: fixedNow.toISOString(),
  }), client, {
    enabled: true,
    expectedOwner: "octocat",
    dryRun: false,
  }), (error) => error instanceof SafetyError && error.code === "REPOSITORY_ABSENCE_CONTRADICTION");
  assert.deepEqual(client.deleted, []);
});

test("GraphQL errors are never converted into immutable absence", async () => {
  const client: GitHubRepositoryClient = {
    resolveRepositoryByNodeId: async () => { throw new Error("GitHub GraphQL repository lookup failed"); },
    deleteRepository: async () => { assert.fail("DELETE must not run after an observation error"); },
  };
  await assert.rejects(deleteRepositoryFailClosed(environmentFixture({
    phase: "AZURE_ABSENT",
    azureAbsence: evidence,
    repositoryObservedAbsentAt: fixedNow.toISOString(),
  }), client, {
    enabled: true,
    expectedOwner: "octocat",
    dryRun: false,
  }), /GraphQL repository lookup failed/);
});

test("DELETE_ISSUED callback runs after immutable validation and before DELETE", async () => {
  const events: string[] = [];
  const client: GitHubRepositoryClient = {
    resolveRepositoryByNodeId: async () => { events.push("resolved"); return matchingRepository(); },
    deleteRepository: async () => { events.push("deleted"); },
  };
  await deleteRepositoryFailClosed(environmentFixture({ phase: "REPO_DELETING", azureAbsence: evidence }), client, {
    enabled: true,
    expectedOwner: "octocat",
    dryRun: false,
  }, async () => { events.push("issued"); });
  assert.deepEqual(events, ["resolved", "issued", "deleted"]);
});
