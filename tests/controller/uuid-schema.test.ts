import assert from "node:assert/strict";
import test from "node:test";
import { ValidationError } from "../../controller/src/errors.ts";
import { assertEnvironmentRecord, parseEnvironmentRequest } from "../../controller/src/schema.ts";
import { createUuidV7, isUuidV7, uuidV7Timestamp } from "../../controller/src/uuidv7.ts";
import { environmentFixture } from "./fixtures.ts";

test("UUIDv7 generator writes the timestamp, version, and RFC variant", () => {
  const timestamp = Date.parse("2026-07-11T12:34:56.789Z");
  const id = createUuidV7(timestamp, () => new Uint8Array(16).fill(0xff));
  assert.equal(isUuidV7(id), true);
  assert.equal(id[14], "7");
  assert.match(id[19] ?? "", /[89ab]/i);
  assert.equal(uuidV7Timestamp(id), timestamp);
});

test("request schema normalizes workflow strings", () => {
  assert.deepEqual(parseEnvironmentRequest({
    golden_path: "container-app",
    environment_name: "orders-api",
    repository_name: "orders-api-lab",
    location: "westeurope",
    ttl_hours: "24",
    acknowledge_aks_cost: "false",
    requester: "octocat",
  }), {
    goldenPath: "container-app",
    environmentName: "orders-api",
    repositoryName: "orders-api-lab",
    location: "westeurope",
    ttlHours: 24,
    acknowledgeAksCost: false,
    requester: "octocat",
  });
});

test("AKS request fails unless cost is acknowledged", () => {
  assert.throws(() => parseEnvironmentRequest({
    goldenPath: "aks",
    environmentName: "aks-lab",
    repositoryName: "aks-lab-repo",
    location: "northeurope",
    ttlHours: 4,
    acknowledgeAksCost: false,
    requester: "octocat",
  }), (error) => error instanceof ValidationError && error.issues.includes("acknowledgeAksCost must be true for AKS"));
});

test("request schema rejects injection-shaped slugs and unsupported regions", () => {
  assert.throws(() => parseEnvironmentRequest({
    goldenPath: "web-app",
    environmentName: "demo; rm -rf",
    repositoryName: "owner/repo",
    location: "eastus",
    ttlHours: 7,
    requester: "octocat",
  }), ValidationError);
});

test("repository absence checkpoint requires a valid timestamp and immutable identity", () => {
  const valid = environmentFixture({ repositoryObservedAbsentAt: "2026-07-11T12:00:00.000Z" });
  valid.stateKey = `workloads/github/web-app-v1/${valid.environmentId}.tfstate`;
  assert.doesNotThrow(() => assertEnvironmentRecord(valid));
  assert.throws(() => assertEnvironmentRecord({ ...valid, repositoryObservedAbsentAt: "not-a-date" }), ValidationError);
  const withoutIdentity = { ...valid };
  delete withoutIdentity.repository;
  assert.throws(() => assertEnvironmentRecord(withoutIdentity), ValidationError);
});
