import type { EnvironmentRecord } from "../../controller/src/types.ts";
import { createUuidV7 } from "../../controller/src/uuidv7.ts";

export const fixedNow = new Date("2026-07-11T12:00:00.000Z");

export function environmentFixture(overrides: Partial<EnvironmentRecord> = {}): EnvironmentRecord {
  return {
    environmentId: createUuidV7(fixedNow.getTime(), () => new Uint8Array(16).fill(1)),
    partitionKey: "environment",
    phase: "ACTIVE",
    desiredState: "ACTIVE",
    owner: "octocat",
    goldenPath: "web-app",
    pathVersion: "v1",
    environmentName: "demo-app",
    location: "westeurope",
    requestedRepositoryName: "demo-app-repo",
    createdAt: fixedNow.toISOString(),
    updatedAt: fixedNow.toISOString(),
    expiresAt: new Date(fixedNow.getTime() + 24 * 3_600_000).toISOString(),
    stateKey: "workloads/github/web-app-v1/test.tfstate",
    repository: {
      owner: "octocat",
      name: "demo-app-repo",
      numericId: 123456,
      nodeId: "R_kgDOExample",
      htmlUrl: "https://github.com/octocat/demo-app-repo",
    },
    resourceGroupNames: ["rg-demo-app"],
    resourceIds: ["/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-demo-app"],
    attempts: 0,
    fencingGeneration: 4,
    etag: "W/\"test\"",
    ...overrides,
  };
}
