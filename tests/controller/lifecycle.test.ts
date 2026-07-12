import assert from "node:assert/strict";
import test from "node:test";
import { ConcurrencyError, SafetyError } from "../../controller/src/errors.ts";
import { InMemoryInventoryStore } from "../../controller/src/inventory.ts";
import { LifecycleController } from "../../controller/src/lifecycle.ts";
import { environmentFixture, fixedNow } from "./fixtures.ts";

const testSubscriptionId = "00000000-0000-0000-0000-000000000000";

test("initialization persists UUIDv7, expiry, and state key before side effects", async () => {
  const store = new InMemoryInventoryStore();
  const controller = new LifecycleController(store, { platformAdmins: new Set(), subscriptionId: testSubscriptionId, clock: { now: () => fixedNow } });
  const record = await controller.initialize({
    goldenPath: "container-app",
    environmentName: "orders-api",
    repositoryName: "orders-repo",
    location: "westeurope",
    ttlHours: 24,
    acknowledgeAksCost: false,
    requester: "octocat",
  });
  assert.equal(record.phase, "REQUESTED");
  assert.equal(record.expiresAt, "2026-07-12T12:00:00.000Z");
  assert.match(record.stateKey, /^workloads\/github\/container-app-v1\/[0-9a-f-]+\.tfstate$/);
  assert.deepEqual(record.resourceGroupNames, [`rg-orders-api-ca-${record.environmentId.replaceAll("-", "").slice(0, 8)}`]);
});

test("extension is bounded to 72 hours from original creation", async () => {
  const store = new InMemoryInventoryStore();
  const record = await store.createEnvironment(environmentFixture({
    expiresAt: new Date(fixedNow.getTime() + 48 * 3_600_000).toISOString(),
  }));
  const controller = new LifecycleController(store, { platformAdmins: new Set(), clock: { now: () => new Date(fixedNow.getTime() + 60_000) } });
  const extended = await controller.extend(record.environmentId, 24, "octocat");
  assert.equal(extended.expiresAt, new Date(fixedNow.getTime() + 72 * 3_600_000).toISOString());
  assert.equal(extended.expirySyncPending, true);
  const synchronized = await controller.completeExpirySync(record.environmentId, "octocat");
  assert.equal(synchronized.expirySyncPending, false);
  await assert.rejects(controller.extend(record.environmentId, 4, "octocat"), (error) => error instanceof SafetyError && error.code === "EXTENSION_MAX_TTL");
});

test("non-owner cannot extend unless configured as an administrator", async () => {
  const store = new InMemoryInventoryStore();
  const record = await store.createEnvironment(environmentFixture());
  const controller = new LifecycleController(store, { platformAdmins: new Set(), clock: { now: () => new Date(fixedNow.getTime() + 60_000) } });
  await assert.rejects(controller.extend(record.environmentId, 4, "intruder"), (error) => error instanceof SafetyError && error.code === "EXTENSION_FORBIDDEN");
});

test("inventory rejects a stale ETag update", async () => {
  const store = new InMemoryInventoryStore();
  const record = await store.createEnvironment(environmentFixture());
  const changed = { ...record, fencingGeneration: record.fencingGeneration + 1 };
  await assert.rejects(store.updateEnvironment(changed, "W/\"stale\""), ConcurrencyError);
});

test("provisioning outputs are inventoried before application deployment", async () => {
  const store = new InMemoryInventoryStore();
  const initial = await store.createEnvironment(environmentFixture({ phase: "AZURE_CREATING" }));
  const controller = new LifecycleController(store, { platformAdmins: new Set(), subscriptionId: testSubscriptionId, clock: { now: () => fixedNow } });
  const saved = await controller.recordProvisioningOutputs(initial.environmentId, {
    endpoint: "https://demo.example.azurecontainerapps.io",
    resourceGroupNames: ["rg-demo-app"],
    resourceIds: initial.resourceIds,
    imageRepository: "apps/123456",
    sharedAcrId: "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-platform/providers/Microsoft.ContainerRegistry/registries/pelabacr",
  });
  assert.equal(saved.phase, "AZURE_CREATING");
  assert.equal(saved.imageRepository, "apps/123456");
  assert.equal(saved.sharedAcrId?.endsWith("/pelabacr"), true);
  const resources = await store.listResources(initial.environmentId);
  assert.equal(resources.length, 2);
  assert.equal(resources.some((resource) =>
    resource.resourceType === "Microsoft.ContainerRegistry/registries/repositories" &&
    resource.resourceId.endsWith("/registries/pelabacr/repositories/apps/123456")
  ), true);
  assert.equal(saved.resourceIds.some((resourceId) => resourceId.includes("/repositories/apps/")), false);
});

test("provisioning outputs cannot remove a resource group inventoried before creation", async () => {
  const store = new InMemoryInventoryStore();
  const initial = await store.createEnvironment(environmentFixture({ phase: "AZURE_CREATING" }));
  const controller = new LifecycleController(store, { platformAdmins: new Set(), subscriptionId: testSubscriptionId, clock: { now: () => fixedNow } });
  await assert.rejects(controller.recordProvisioningOutputs(initial.environmentId, {
    endpoint: "https://demo.example.azurewebsites.net",
    resourceGroupNames: ["rg-output-regression"],
    resourceIds: initial.resourceIds,
  }), (error) => error instanceof SafetyError && error.code === "RESOURCE_GROUP_INVENTORY_MISMATCH");
});

test("provisioning outputs reject disposable IDs from another subscription", async () => {
  const store = new InMemoryInventoryStore();
  const initial = await store.createEnvironment(environmentFixture({ phase: "AZURE_CREATING" }));
  const controller = new LifecycleController(store, { platformAdmins: new Set(), subscriptionId: testSubscriptionId, clock: { now: () => fixedNow } });
  await assert.rejects(controller.recordProvisioningOutputs(initial.environmentId, {
    endpoint: "https://demo.example.azurewebsites.net",
    resourceGroupNames: initial.resourceGroupNames,
    resourceIds: ["/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-demo-app"],
  }), (error) => error instanceof SafetyError && error.code === "RESOURCE_SUBSCRIPTION_MISMATCH");
});

test("activation cannot shrink the resource inventory recorded after apply", async () => {
  const store = new InMemoryInventoryStore();
  const groupId = `/subscriptions/${testSubscriptionId}/resourceGroups/rg-demo-app`;
  const siteId = `${groupId}/providers/Microsoft.Web/sites/demo-app`;
  const initial = await store.createEnvironment(environmentFixture({ phase: "AZURE_CREATING", resourceIds: [groupId, siteId] }));
  const controller = new LifecycleController(store, { platformAdmins: new Set(), subscriptionId: testSubscriptionId, clock: { now: () => fixedNow } });
  await assert.rejects(controller.activate(initial.environmentId, "octocat", {
    endpoint: "https://demo.example.azurewebsites.net",
    resourceGroupNames: initial.resourceGroupNames,
    resourceIds: [groupId],
  }), (error) => error instanceof SafetyError && error.code === "RESOURCE_INVENTORY_MISMATCH");
});

test("repository attachment inventories the immutable ACR repository before provisioning", async () => {
  const previous = process.env.SHARED_ACR_ID;
  process.env.SHARED_ACR_ID = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-platform/providers/Microsoft.ContainerRegistry/registries/pelabacr";
  try {
    const store = new InMemoryInventoryStore();
    const requested = environmentFixture({
      phase: "REQUESTED",
      desiredState: "ACTIVE",
      goldenPath: "container-app",
    });
    delete requested.repository;
    const initial = await store.createEnvironment(requested);
    const controller = new LifecycleController(store, { platformAdmins: new Set(), subscriptionId: testSubscriptionId, clock: { now: () => fixedNow } });
    const repository = environmentFixture().repository!;
    const attached = await controller.attachRepository(initial.environmentId, repository, "octocat");
    assert.equal(attached.phase, "REPO_READY");
    assert.equal(attached.imageRepository, "apps/123456");
    assert.equal(attached.sharedAcrId, process.env.SHARED_ACR_ID);
    const resources = await store.listResources(initial.environmentId);
    assert.equal(resources.some((resource) => resource.resourceId.endsWith("/repositories/apps/123456")), true);
    const repeated = await controller.attachRepository(initial.environmentId, repository, "octocat");
    assert.equal(repeated.etag, attached.etag);
  } finally {
    if (previous === undefined) delete process.env.SHARED_ACR_ID;
    else process.env.SHARED_ACR_ID = previous;
  }
});

test("provisioning refuses an unbound ACR repository residual", async () => {
  const store = new InMemoryInventoryStore();
  const initial = await store.createEnvironment(environmentFixture({ phase: "AZURE_CREATING" }));
  const controller = new LifecycleController(store, { platformAdmins: new Set(), subscriptionId: testSubscriptionId, clock: { now: () => fixedNow } });
  await assert.rejects(controller.recordProvisioningOutputs(initial.environmentId, {
    endpoint: "https://demo.example.azurecontainerapps.io",
    resourceGroupNames: ["rg-demo-app"],
    resourceIds: initial.resourceIds,
    imageRepository: "apps/123456",
  }), (error) => error instanceof SafetyError && error.code === "ACR_INVENTORY_INCOMPLETE");
});

test("failure recording persists attempts, sanitization, and bounded retry time", async () => {
  const store = new InMemoryInventoryStore();
  const initial = await store.createEnvironment(environmentFixture());
  const controller = new LifecycleController(store, { platformAdmins: new Set(), clock: { now: () => fixedNow } });
  const failed = await controller.recordFailure(initial.environmentId, "controller", "GITHUB_503", "Bearer secret-token ghs_example");
  assert.equal(failed.attempts, 1);
  assert.equal(failed.nextAttemptAt, new Date(fixedNow.getTime() + 60_000).toISOString());
  assert.equal(failed.lastErrorSummary?.includes("secret-token"), false);
  assert.equal((await store.listOperations(initial.environmentId))[0]?.status, "FAILED");
});

test("tag-matched resource adoption expands immutable cleanup inventory", async () => {
  const store = new InMemoryInventoryStore();
  const initial = await store.createEnvironment(environmentFixture());
  const controller = new LifecycleController(store, { platformAdmins: new Set(), clock: { now: () => fixedNow } });
  const discovered = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-demo-app/providers/Microsoft.Web/sites/adopted";
  const saved = await controller.adoptResources(initial.environmentId, [discovered], "reconciler");
  assert.equal(saved.resourceIds.includes(discovered), true);
  assert.equal((await store.listResources(initial.environmentId)).length, 1);
  assert.equal((await store.listOperations(initial.environmentId))[0]?.summary.includes("Adopted 1"), true);
});

test("resource adoption refuses a matching tag outside inventoried groups", async () => {
  const store = new InMemoryInventoryStore();
  const initial = await store.createEnvironment(environmentFixture());
  const controller = new LifecycleController(store, { platformAdmins: new Set(), clock: { now: () => fixedNow } });
  const outside = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-shared/providers/Microsoft.Web/sites/spoofed";
  await assert.rejects(controller.adoptResources(initial.environmentId, [outside], "reconciler"), (error) => error instanceof SafetyError && error.code === "ADOPTION_SCOPE");
});

test("immutable repository absence is durably fenced while quiescing", async () => {
  const store = new InMemoryInventoryStore();
  const initial = await store.createEnvironment(environmentFixture({ phase: "QUIESCING", desiredState: "DELETED" }));
  const controller = new LifecycleController(store, { platformAdmins: new Set(), clock: { now: () => fixedNow } });
  const observed = await controller.markRepositoryObservedAbsent(initial.environmentId, "reconciler");
  assert.equal(observed.repositoryObservedAbsentAt, fixedNow.toISOString());
  assert.equal(observed.fencingGeneration, initial.fencingGeneration + 1);
  assert.notEqual(observed.etag, initial.etag);
  const operation = (await store.listOperations(initial.environmentId))[0];
  assert.equal(operation?.fromPhase, "QUIESCING");
  assert.equal(operation?.toPhase, "QUIESCING");
  assert.match(operation?.summary ?? "", /immutable GraphQL node ID/);

  const repeated = await controller.markRepositoryObservedAbsent(initial.environmentId, "reconciler");
  assert.equal(repeated.etag, observed.etag);
  assert.equal((await store.listOperations(initial.environmentId)).length, 1);
});

test("repository absence cannot be recorded outside quiescing", async () => {
  const store = new InMemoryInventoryStore();
  const initial = await store.createEnvironment(environmentFixture());
  const controller = new LifecycleController(store, { platformAdmins: new Set(), clock: { now: () => fixedNow } });
  await assert.rejects(controller.markRepositoryObservedAbsent(initial.environmentId, "reconciler"), (error) => error instanceof SafetyError && error.code === "REPOSITORY_ABSENCE_PHASE");
});

test("retention purge removes terminal Table history only after 90 days", async () => {
  const store = new InMemoryInventoryStore();
  const terminal = await store.createEnvironment(environmentFixture({
    phase: "DELETED",
    desiredState: "DELETED",
    updatedAt: fixedNow.toISOString(),
    tombstoneRetainedAt: fixedNow.toISOString(),
    tombstoneBlobName: `${environmentFixture().environmentId}/tombstone/final.json`,
    tombstoneEvidenceHash: "a".repeat(64),
  }));
  await store.putResources(terminal.environmentId, [{
    environmentId: terminal.environmentId,
    resourceId: terminal.resourceIds[0]!,
    resourceType: "Microsoft.Web/sites",
    discoveredAt: fixedNow.toISOString(),
  }]);
  await store.appendOperation({
    operationId: "018f8f5e-8c4a-7abc-8def-1234567890ab",
    environmentId: terminal.environmentId,
    occurredAt: fixedNow.toISOString(),
    fromPhase: "REPO_DELETING",
    toPhase: "DELETED",
    actor: "reconciler",
    status: "SUCCEEDED",
    summary: "Deletion checkpoint DELETED",
  });

  const earlyController = new LifecycleController(store, {
    platformAdmins: new Set(),
    clock: { now: () => new Date(fixedNow.getTime() + 89 * 86_400_000) },
  });
  await assert.rejects(
    earlyController.purgeRetainedEnvironment(terminal.environmentId),
    (error) => error instanceof SafetyError && error.code === "RETENTION_NOT_EXPIRED",
  );

  const retainedController = new LifecycleController(store, {
    platformAdmins: new Set(),
    clock: { now: () => new Date(fixedNow.getTime() + 90 * 86_400_000) },
  });
  await retainedController.purgeRetainedEnvironment(terminal.environmentId);
  assert.equal(await store.getEnvironment(terminal.environmentId), undefined);
  assert.deepEqual(await store.listResources(terminal.environmentId), []);
  assert.deepEqual(await store.listOperations(terminal.environmentId), []);
});

test("retention purge refuses a non-terminal environment", async () => {
  const store = new InMemoryInventoryStore();
  const active = await store.createEnvironment(environmentFixture());
  const controller = new LifecycleController(store, {
    platformAdmins: new Set(),
    clock: { now: () => new Date(fixedNow.getTime() + 91 * 86_400_000) },
  });
  await assert.rejects(
    controller.purgeRetainedEnvironment(active.environmentId),
    (error) => error instanceof SafetyError && error.code === "RETENTION_PHASE",
  );
});

test("retention purge refuses DELETED inventory without retained tombstone evidence", async () => {
  const store = new InMemoryInventoryStore();
  const terminal = await store.createEnvironment(environmentFixture({ phase: "DELETED", desiredState: "DELETED" }));
  const controller = new LifecycleController(store, {
    platformAdmins: new Set(),
    clock: { now: () => new Date(fixedNow.getTime() + 91 * 86_400_000) },
  });
  await assert.rejects(
    controller.purgeRetainedEnvironment(terminal.environmentId),
    (error) => error instanceof SafetyError && error.code === "TOMBSTONE_NOT_RETAINED",
  );
});

test("DELETED tombstone retention is an idempotent fenced checkpoint", async () => {
  const store = new InMemoryInventoryStore();
  const terminal = await store.createEnvironment(environmentFixture({ phase: "DELETED", desiredState: "DELETED" }));
  const controller = new LifecycleController(store, { platformAdmins: new Set(), clock: { now: () => fixedNow } });
  const blobName = `${terminal.environmentId}/tombstone/final.json`;
  const retained = await controller.markTombstoneRetained(terminal.environmentId, "reconciler", blobName, "b".repeat(64));
  assert.equal(retained.tombstoneBlobName, blobName);
  assert.equal(retained.tombstoneRetainedAt, fixedNow.toISOString());
  const repeated = await controller.markTombstoneRetained(terminal.environmentId, "reconciler", blobName, "b".repeat(64));
  assert.equal(repeated.etag, retained.etag);
  assert.equal((await store.listOperations(terminal.environmentId)).length, 1);
});
