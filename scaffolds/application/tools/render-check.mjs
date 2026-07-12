import assert from "node:assert/strict";
import { readdir, readFile } from "node:fs/promises";
import { join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("..", import.meta.url));
const allowedTokens = new Set([
  "__ENVIRONMENT_ID__",
  "__ENVIRONMENT_NAME__",
  "__GOLDEN_PATH__",
  "__EXPIRES_AT__",
  "__PLATFORM_REPOSITORY__",
  "__OWNER__",
]);

async function files(directory) {
  const entries = await readdir(directory, { withFileTypes: true });
  const result = [];
  for (const entry of entries) {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) result.push(...await files(path));
    else result.push(path);
  }
  return result;
}

const baseFiles = await files(join(root, "base"));
for (const file of baseFiles) {
  const content = await readFile(file, "utf8");
  for (const token of content.match(/__[A-Z0-9_]+__/g) ?? []) {
    assert.ok(allowedTokens.has(token), `Unknown render token ${token} in ${relative(root, file)}`);
  }
}
const workflow = await readFile(join(root, "base", ".github", "workflows", "deploy.yml"), "utf8");
const readiness = await readFile(join(root, "base", ".platform", "wait-azure-readiness.sh"), "utf8");
assert.match(workflow, /PLATFORM_READY/);
assert.match(workflow, /id-token:\s*write/);
assert.match(workflow, /platform_dispatch_id/);
assert.match(workflow, /run-name:\s*Deploy.*platform_dispatch_id/);
assert.match(workflow, /azure\/use-kubelogin@0ce7c36141aa27d4934872cf00b0120804c98a29\s+# v1\.3/);
assert.match(workflow, /kubelogin-version:\s*v0\.2\.17/);
assert.match(workflow, /kubelogin convert-kubeconfig -l azurecli/);
assert.equal((workflow.match(/RepoDigests/g) ?? []).length, 2);
assert.equal((workflow.match(/name: Authenticate to Azure over OIDC/g) ?? []).length, 3);
assert.equal((workflow.match(/name: Wait for Azure role readiness/g) ?? []).length, 3);
const jobStarts = ["web-app", "container-app", "aks"].map((job) => workflow.indexOf(`\n  ${job}:`));
for (const [index, mutation] of [
  [0, "Deploy ZIP over OIDC session"],
  [1, "Build and push ABAC-scoped image"],
  [2, "Build and push ABAC-scoped image"],
]) {
  const section = workflow.slice(jobStarts[index], jobStarts[index + 1] ?? workflow.length);
  const job = ["web-app", "container-app", "aks"][index];
  assert.ok(section.indexOf("Wait for Azure role readiness") < section.indexOf(mutation), `${job} readiness must precede its first Azure mutation`);
}
assert.match(readiness, /readiness_attempts="\$\{AZURE_READINESS_ATTEMPTS:-12\}"/);
assert.match(readiness, /probe_acr_repository_role/);
assert.match(readiness, /kubectl auth can-i create namespaces/);
assert.match(readiness, /kubelogin convert-kubeconfig -l azurecli/);
assert.doesNotMatch(readiness, /\baz\s+\S+\s+(?:create|delete|update)\b|\bdocker\s+push\b|\bhelm\s+upgrade\b/);
for (const path of ["web-app", "container-app", "aks"]) {
  assert.match(workflow, new RegExp(`GOLDEN_PATH.*${path.replace("-", "\\-")}`));
  await readFile(join(root, "overlays", path, ".platform", "delivery.json"), "utf8");
}
assert.match(workflow, /az containerapp ingress update[\s\S]*--target-port 3000 --transport auto --allow-insecure false/);
assert.doesNotMatch(workflow, /client-secret|AZURE_CREDENTIALS/i);
process.stdout.write(`Validated ${baseFiles.length} base files, one inert OIDC workflow with bounded readiness, and three selected overlays.\n`);
