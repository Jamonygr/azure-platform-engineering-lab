import assert from "node:assert/strict";
import test from "node:test";
import { SafetyError } from "../../controller/src/errors.ts";
import { canTransition, transitionEnvironment } from "../../controller/src/state-machine.ts";
import { environmentFixture, fixedNow } from "./fixtures.ts";

test("lifecycle graph allows the documented happy path only", () => {
  assert.equal(canTransition("REQUESTED", "REPO_READY"), true);
  assert.equal(canTransition("ACTIVE", "QUIESCING"), true);
  assert.equal(canTransition("ACTIVE", "DELETED"), false);
  assert.equal(canTransition("DELETED", "ACTIVE"), false);
});

test("Azure absence rejects a single verification pass", () => {
  const record = environmentFixture({ phase: "AZURE_DELETING", desiredState: "DELETED" });
  assert.throws(() => transitionEnvironment(record, "AZURE_ABSENT", "controller", fixedNow, {
    azureAbsence: {
      verifiedAt: fixedNow.toISOString(),
      consecutivePasses: 1,
      remainingStateResources: 0,
      resourceGraphMatchCount: 0,
      checkedResourceIds: record.resourceIds,
      checkedResourceGroupNames: record.resourceGroupNames,
    },
  }), (error) => error instanceof SafetyError && error.code === "ABSENCE_NOT_REPEATED");
});

test("Azure absence accepts two clean passes and hashes evidence", () => {
  const record = environmentFixture({ phase: "AZURE_DELETING", desiredState: "DELETED" });
  const result = transitionEnvironment(record, "AZURE_ABSENT", "controller", fixedNow, {
    azureAbsence: {
      verifiedAt: fixedNow.toISOString(),
      consecutivePasses: 2,
      remainingStateResources: 0,
      resourceGraphMatchCount: 0,
      checkedResourceIds: record.resourceIds,
      checkedResourceGroupNames: record.resourceGroupNames,
    },
  });
  assert.equal(result.record.phase, "AZURE_ABSENT");
  assert.match(result.record.evidenceHash ?? "", /^[a-f0-9]{64}$/);
  assert.equal(result.operation.evidenceHash, result.record.evidenceHash);
});

test("Azure absence evidence must cover every predicted resource group", () => {
  const record = environmentFixture({ phase: "AZURE_DELETING", desiredState: "DELETED" });
  assert.throws(() => transitionEnvironment(record, "AZURE_ABSENT", "controller", fixedNow, {
    azureAbsence: {
      verifiedAt: fixedNow.toISOString(),
      consecutivePasses: 2,
      remainingStateResources: 0,
      resourceGraphMatchCount: 0,
      checkedResourceIds: record.resourceIds,
      checkedResourceGroupNames: [],
    },
  }), (error) => error instanceof SafetyError && error.code === "ABSENCE_GROUP_COVERAGE");
});

test("repository deletion checkpoint requires immutable repository identity", () => {
  const record = environmentFixture({
    phase: "AZURE_ABSENT",
    desiredState: "DELETED",
  });
  delete record.repository;
  assert.throws(() => transitionEnvironment(record, "REPO_DELETING", "controller", fixedNow), (error) => error instanceof SafetyError && error.code === "REPOSITORY_IDENTITY_MISSING");
});
