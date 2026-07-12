import assert from "node:assert/strict";
import test from "node:test";
import { ConcurrencyError } from "../../controller/src/errors.ts";
import { AzureTableInventoryStore, type AccessTokenProvider } from "../../controller/src/inventory.ts";
import type { EnvironmentRecord } from "../../controller/src/types.ts";
import { environmentFixture } from "./fixtures.ts";

const tokenProvider: AccessTokenProvider = { getToken: async () => "table-test-token" };

function persistedRecord(overrides: Partial<EnvironmentRecord> = {}): EnvironmentRecord {
  const fixture = environmentFixture(overrides);
  return {
    ...fixture,
    stateKey: `workloads/github/web-app-v1/${fixture.environmentId}.tfstate`,
    ...overrides,
  };
}

function entity(record: EnvironmentRecord): string {
  const { etag: _etag, ...payload } = record;
  return JSON.stringify({
    PartitionKey: "environment",
    RowKey: record.environmentId,
    payload: JSON.stringify(payload),
  });
}

test("Azure Table adapter uses OAuth headers and preserves the service ETag", async () => {
  const record = persistedRecord();
  const requests: Array<{ url: string; init: RequestInit }> = [];
  const fetchImplementation: typeof fetch = async (input, init = {}) => {
    const url = String(input);
    requests.push({ url, init });
    if (init.method === "POST" && url.endsWith("/PlatformEnvironments")) {
      return new Response(null, { status: 204 });
    }
    if ((!init.method || init.method === "GET") && url.includes("PlatformEnvironments(")) {
      return new Response(entity(record), {
        status: 200,
        headers: { "Content-Type": "application/json", ETag: 'W/"service-1"' },
      });
    }
    throw new Error(`Unexpected Azure Table request: ${init.method ?? "GET"} ${url}`);
  };
  const store = new AzureTableInventoryStore({ accountName: "pelabinventory", tokenProvider, fetchImplementation });

  const saved = await store.createEnvironment(record);
  assert.equal(saved.etag, 'W/"service-1"');
  assert.equal(saved.environmentId, record.environmentId);
  assert.equal(requests.length, 2);
  for (const request of requests) {
    const headers = new Headers(request.init.headers);
    assert.equal(headers.get("authorization"), "Bearer table-test-token");
    assert.equal(headers.get("x-ms-version"), "2019-02-02");
  }
});

test("Azure Table adapter maps a stale conditional write to ConcurrencyError", async () => {
  const record = persistedRecord({ fencingGeneration: 5 });
  const fetchImplementation: typeof fetch = async (_input, init = {}) => {
    assert.equal(init.method, "PUT");
    assert.equal(new Headers(init.headers).get("if-match"), 'W/"stale"');
    return new Response(null, { status: 412 });
  };
  const store = new AzureTableInventoryStore({ accountName: "pelabinventory", tokenProvider, fetchImplementation });
  await assert.rejects(store.updateEnvironment(record, 'W/"stale"'), ConcurrencyError);
});

test("retention purge deletes child history before the ETag-guarded environment row", async () => {
  const record = persistedRecord({ phase: "DELETED", desiredState: "DELETED" });
  const deletes: Array<{ url: string; ifMatch: string | null }> = [];
  const fetchImplementation: typeof fetch = async (input, init = {}) => {
    const url = String(input);
    if ((!init.method || init.method === "GET") && url.includes("PlatformEnvironments(")) {
      return new Response(entity(record), {
        status: 200,
        headers: { "Content-Type": "application/json", ETag: 'W/"terminal"' },
      });
    }
    if ((!init.method || init.method === "GET") && url.includes("PlatformResources?")) {
      return Response.json({ value: [{ PartitionKey: record.environmentId, RowKey: "resource-hash", payload: "{}" }] });
    }
    if ((!init.method || init.method === "GET") && url.includes("PlatformOperations?")) {
      return Response.json({ value: [{ PartitionKey: record.environmentId, RowKey: "operation-id", payload: "{}" }] });
    }
    if (init.method === "DELETE") {
      deletes.push({ url, ifMatch: new Headers(init.headers).get("if-match") });
      return new Response(null, { status: 204 });
    }
    throw new Error(`Unexpected Azure Table request: ${init.method ?? "GET"} ${url}`);
  };
  const store = new AzureTableInventoryStore({ accountName: "pelabinventory", tokenProvider, fetchImplementation });

  await store.purgeEnvironmentHistory(record.environmentId, 'W/"terminal"');
  assert.equal(deletes.length, 3);
  assert.match(deletes[0]!.url, /PlatformResources\(/);
  assert.match(deletes[1]!.url, /PlatformOperations\(/);
  assert.match(deletes[2]!.url, /PlatformEnvironments\(/);
  assert.equal(deletes[0]!.ifMatch, "*");
  assert.equal(deletes[1]!.ifMatch, "*");
  assert.equal(deletes[2]!.ifMatch, 'W/"terminal"');
});
