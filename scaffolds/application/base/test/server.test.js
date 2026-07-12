import assert from "node:assert/strict";
import { once } from "node:events";
import test from "node:test";
import { createAppServer, setReadiness } from "../src/server.js";

async function withServer(run) {
  setReadiness(true);
  const server = createAppServer({
    APP_NAME: "test-service",
    ENVIRONMENT_ID: "test-environment",
    ENVIRONMENT_NAME: "test",
    GOLDEN_PATH: "web-app",
    AZURE_REGION: "westeurope",
    APP_VERSION: "test-sha",
  });
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  const address = server.address();
  assert.ok(address && typeof address !== "string");
  try { await run(`http://127.0.0.1:${address.port}`); }
  finally { server.close(); await once(server, "close"); }
}

test("root reports the selected golden path without secrets", () => withServer(async (url) => {
  const response = await fetch(url);
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("x-content-type-options"), "nosniff");
  const body = await response.json();
  assert.equal(body.goldenPath, "web-app");
  assert.equal(JSON.stringify(body).includes("token"), false);
}));

test("health, readiness, and metadata contracts", () => withServer(async (url) => {
  assert.deepEqual((await (await fetch(`${url}/healthz`)).json()).status, "healthy");
  assert.deepEqual((await (await fetch(`${url}/readyz`)).json()).status, "ready");
  const metadata = await (await fetch(`${url}/metadata`)).json();
  assert.equal(metadata.environmentId, "test-environment");
  assert.equal(metadata.region, "westeurope");
}));

test("draining readiness is a 503", () => withServer(async (url) => {
  setReadiness(false);
  const response = await fetch(`${url}/readyz`);
  assert.equal(response.status, 503);
}));

test("unknown routes and unsafe methods fail predictably", () => withServer(async (url) => {
  assert.equal((await fetch(`${url}/missing`)).status, 404);
  const response = await fetch(url, { method: "POST" });
  assert.equal(response.status, 405);
  assert.equal(response.headers.get("allow"), "GET, HEAD");
}));
