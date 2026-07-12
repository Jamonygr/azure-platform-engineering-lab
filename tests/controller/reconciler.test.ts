import assert from "node:assert/strict";
import test from "node:test";
import { decideReconcileAction, matchesActiveRepositoryTrustBinding, reconcileAll } from "../../controller/src/reconciler.ts";
import { environmentFixture, fixedNow } from "./fixtures.ts";

test("expired active environment is selected for teardown", () => {
  const record = environmentFixture({ expiresAt: new Date(fixedNow.getTime() - 1).toISOString() });
  assert.deepEqual(decideReconcileAction(record, { now: fixedNow }), {
    kind: "DESTROY",
    environmentId: record.environmentId,
    reason: "EXPIRED",
  });
});

test("early repository deletion triggers Azure cleanup", () => {
  const record = environmentFixture();
  assert.equal(decideReconcileAction(record, { now: fixedNow, repositoryExists: false }).kind, "DESTROY");
});

test("an in-owner rename breaks the ACTIVE OIDC trust binding and triggers teardown", () => {
  const record = environmentFixture();
  assert.ok(record.repository);
  const renamed = {
    nodeId: record.repository.nodeId,
    numericId: record.repository.numericId,
    owner: record.repository.owner,
    name: "renamed-generated-repository",
  };
  assert.equal(matchesActiveRepositoryTrustBinding(record.repository, renamed), false);
  assert.deepEqual(decideReconcileAction(record, { now: fixedNow, repositoryExists: true, repositoryIdentityMatches: false }), {
    kind: "DESTROY",
    environmentId: record.environmentId,
    reason: "REPOSITORY_IDENTITY_MISMATCH",
  });
});

test("dry-run executor receives planned action without changing the decision", async () => {
  const record = environmentFixture({ expiresAt: new Date(fixedNow.getTime() - 1).toISOString() });
  const calls: Array<{ kind: string; dryRun: boolean }> = [];
  const actions = await reconcileAll([record], {
    execute: async (action, dryRun) => { calls.push({ kind: action.kind, dryRun }); },
  }, { now: fixedNow, dryRun: true });
  assert.equal(actions[0]?.kind, "DESTROY");
  assert.deepEqual(calls, [{ kind: "DESTROY", dryRun: true }]);
});

test("persisted transient backoff suppresses reconciliation until nextAttemptAt", () => {
  const record = environmentFixture({
    expiresAt: new Date(fixedNow.getTime() - 1).toISOString(),
    nextAttemptAt: new Date(fixedNow.getTime() + 60_000).toISOString(),
  });
  assert.equal(decideReconcileAction(record, { now: fixedNow }).kind, "NONE");
  assert.equal(decideReconcileAction(record, { now: new Date(fixedNow.getTime() + 60_001) }).kind, "DESTROY");
});

test("incomplete expiry propagation is reconciled", () => {
  const record = environmentFixture({ expirySyncPending: true });
  assert.equal(decideReconcileAction(record, { now: fixedNow }).kind, "SYNC_EXPIRY");
});
