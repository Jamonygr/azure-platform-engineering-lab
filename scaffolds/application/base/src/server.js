import { createServer } from "node:http";
import { randomUUID } from "node:crypto";
import { fileURLToPath } from "node:url";

const startedAt = new Date();
let ready = true;

function json(response, status, payload, requestId, method = "GET") {
  const body = JSON.stringify(payload);
  response.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "content-length": Buffer.byteLength(body),
    "cache-control": "no-store",
    "x-content-type-options": "nosniff",
    "x-frame-options": "DENY",
    "referrer-policy": "no-referrer",
    "x-request-id": requestId,
  });
  response.end(method === "HEAD" ? undefined : body);
}

export function createAppServer(environment = process.env) {
  return createServer((request, response) => {
    const requestId = typeof request.headers["x-request-id"] === "string" ? request.headers["x-request-id"].slice(0, 100) : randomUUID();
    const method = request.method ?? "GET";
    if (method !== "GET" && method !== "HEAD") {
      response.setHeader("allow", "GET, HEAD");
      json(response, 405, { error: "method_not_allowed", requestId }, requestId, method);
      return;
    }
    const path = new URL(request.url ?? "/", "http://localhost").pathname;
    if (path === "/") {
      json(response, 200, {
        service: environment.APP_NAME ?? "golden-path-node-service",
        message: "Azure golden path is ready",
        goldenPath: environment.GOLDEN_PATH ?? "unknown",
        requestId,
      }, requestId, method);
      return;
    }
    if (path === "/healthz") {
      json(response, 200, { status: "healthy", requestId }, requestId, method);
      return;
    }
    if (path === "/readyz") {
      json(response, ready ? 200 : 503, { status: ready ? "ready" : "draining", requestId }, requestId, method);
      return;
    }
    if (path === "/metadata") {
      json(response, 200, {
        environmentId: environment.ENVIRONMENT_ID ?? "local",
        environmentName: environment.ENVIRONMENT_NAME ?? "local",
        goldenPath: environment.GOLDEN_PATH ?? "local",
        region: environment.REGION_NAME ?? environment.AZURE_REGION ?? "local",
        version: environment.APP_VERSION ?? "development",
        startedAt: startedAt.toISOString(),
        requestId,
      }, requestId, method);
      return;
    }
    json(response, 404, { error: "not_found", requestId }, requestId, method);
  });
}

export function setReadiness(value) {
  ready = Boolean(value);
}

export function start(environment = process.env) {
  const port = Number(environment.PORT ?? 3000);
  if (!Number.isInteger(port) || port < 0 || port > 65535) throw new RangeError("PORT must be an integer from 0 to 65535");
  const server = createAppServer(environment);
  server.listen(port, "0.0.0.0", () => process.stdout.write(`server listening on ${port}\n`));
  const shutdown = () => {
    setReadiness(false);
    server.close((error) => {
      if (error) process.stderr.write(`${error.message}\n`);
      process.exitCode = error ? 1 : 0;
    });
  };
  process.once("SIGTERM", shutdown);
  process.once("SIGINT", shutdown);
  return server;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) start();
