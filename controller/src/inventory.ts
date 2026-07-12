import { createHash } from "node:crypto";
import { ConcurrencyError } from "./errors.ts";
import { assertEnvironmentRecord } from "./schema.ts";
import type { EnvironmentRecord, OperationRecord, ResourceRecord } from "./types.ts";

export interface InventoryStore {
  createEnvironment(record: EnvironmentRecord): Promise<EnvironmentRecord>;
  getEnvironment(environmentId: string): Promise<EnvironmentRecord | undefined>;
  updateEnvironment(record: EnvironmentRecord, expectedEtag: string): Promise<EnvironmentRecord>;
  listEnvironments(includeDeleted?: boolean): Promise<EnvironmentRecord[]>;
  putResources(environmentId: string, resources: ResourceRecord[]): Promise<void>;
  listResources(environmentId: string): Promise<ResourceRecord[]>;
  appendOperation(operation: OperationRecord): Promise<void>;
  listOperations(environmentId: string): Promise<OperationRecord[]>;
  purgeEnvironmentHistory(environmentId: string, expectedEtag: string): Promise<void>;
}

function clone<T>(value: T): T {
  return structuredClone(value);
}

export class InMemoryInventoryStore implements InventoryStore {
  readonly #environments = new Map<string, EnvironmentRecord>();
  readonly #resources = new Map<string, ResourceRecord[]>();
  readonly #operations = new Map<string, OperationRecord[]>();
  #etag = 0;

  async createEnvironment(record: EnvironmentRecord): Promise<EnvironmentRecord> {
    if (this.#environments.has(record.environmentId)) throw new ConcurrencyError("Environment already exists");
    const saved = { ...clone(record), etag: this.#nextEtag() };
    this.#environments.set(record.environmentId, saved);
    return clone(saved);
  }

  async getEnvironment(environmentId: string): Promise<EnvironmentRecord | undefined> {
    const record = this.#environments.get(environmentId);
    return record ? clone(record) : undefined;
  }

  async updateEnvironment(record: EnvironmentRecord, expectedEtag: string): Promise<EnvironmentRecord> {
    const current = this.#environments.get(record.environmentId);
    if (!current) throw new ConcurrencyError("Environment does not exist");
    if (current.etag !== expectedEtag) throw new ConcurrencyError("Inventory ETag changed; refusing stale write");
    if (record.fencingGeneration <= current.fencingGeneration) throw new ConcurrencyError("Fencing generation did not advance");
    const saved = { ...clone(record), etag: this.#nextEtag() };
    this.#environments.set(record.environmentId, saved);
    return clone(saved);
  }

  async listEnvironments(includeDeleted = false): Promise<EnvironmentRecord[]> {
    return [...this.#environments.values()]
      .filter((record) => includeDeleted || record.phase !== "DELETED")
      .map(clone);
  }

  async putResources(environmentId: string, resources: ResourceRecord[]): Promise<void> {
    const merged = new Map((this.#resources.get(environmentId) ?? []).map((resource) => [resource.resourceId.toLowerCase(), resource]));
    for (const resource of resources) merged.set(resource.resourceId.toLowerCase(), clone(resource));
    this.#resources.set(environmentId, [...merged.values()]);
  }

  async listResources(environmentId: string): Promise<ResourceRecord[]> {
    return clone(this.#resources.get(environmentId) ?? []);
  }

  async appendOperation(operation: OperationRecord): Promise<void> {
    const operations = this.#operations.get(operation.environmentId) ?? [];
    operations.push(clone(operation));
    this.#operations.set(operation.environmentId, operations);
  }

  async listOperations(environmentId: string): Promise<OperationRecord[]> {
    return clone(this.#operations.get(environmentId) ?? []);
  }

  async purgeEnvironmentHistory(environmentId: string, expectedEtag: string): Promise<void> {
    const current = this.#environments.get(environmentId);
    if (!current) return;
    if (current.etag !== expectedEtag) throw new ConcurrencyError("Inventory ETag changed; refusing stale retention purge");
    this.#resources.delete(environmentId);
    this.#operations.delete(environmentId);
    this.#environments.delete(environmentId);
  }

  #nextEtag(): string {
    this.#etag += 1;
    return `W/\"memory-${this.#etag}\"`;
  }
}

interface TableEntity {
  PartitionKey: string;
  RowKey: string;
  payload: string;
  "odata.etag"?: string;
}

export interface AccessTokenProvider {
  getToken(): Promise<string>;
}

export interface AzureTableStoreOptions {
  accountName: string;
  environmentsTable?: string;
  resourcesTable?: string;
  operationsTable?: string;
  tokenProvider: AccessTokenProvider;
  fetchImplementation?: typeof fetch;
}

export class AzureTableInventoryStore implements InventoryStore {
  readonly #baseUrl: string;
  readonly #environments: string;
  readonly #resources: string;
  readonly #operations: string;
  readonly #tokenProvider: AccessTokenProvider;
  readonly #fetch: typeof fetch;

  constructor(options: AzureTableStoreOptions) {
    if (!/^[a-z0-9]{3,24}$/.test(options.accountName)) throw new TypeError("Invalid Azure Storage account name");
    this.#baseUrl = `https://${options.accountName}.table.core.windows.net`;
    this.#environments = validateTableName(options.environmentsTable ?? "PlatformEnvironments");
    this.#resources = validateTableName(options.resourcesTable ?? "PlatformResources");
    this.#operations = validateTableName(options.operationsTable ?? "PlatformOperations");
    this.#tokenProvider = options.tokenProvider;
    this.#fetch = options.fetchImplementation ?? fetch;
  }

  async createEnvironment(record: EnvironmentRecord): Promise<EnvironmentRecord> {
    await this.#insert(this.#environments, toEntity("environment", record.environmentId, record));
    const created = await this.getEnvironment(record.environmentId);
    if (!created) throw new Error("Inventory insert did not become readable");
    return created;
  }

  async getEnvironment(environmentId: string): Promise<EnvironmentRecord | undefined> {
    const entity = await this.#get(this.#environments, "environment", environmentId);
    if (!entity) return undefined;
    const record = fromEntity<EnvironmentRecord>(entity);
    assertEnvironmentRecord(record);
    return record;
  }

  async updateEnvironment(record: EnvironmentRecord, expectedEtag: string): Promise<EnvironmentRecord> {
    await this.#replace(this.#environments, toEntity("environment", record.environmentId, record), expectedEtag);
    const updated = await this.getEnvironment(record.environmentId);
    if (!updated) throw new Error("Inventory update did not become readable");
    return updated;
  }

  async listEnvironments(includeDeleted = false): Promise<EnvironmentRecord[]> {
    const entities = await this.#query(this.#environments, "PartitionKey eq 'environment'");
    const records = entities.map(fromEntity<EnvironmentRecord>);
    records.forEach(assertEnvironmentRecord);
    return records.filter((record) => includeDeleted || record.phase !== "DELETED");
  }

  async putResources(environmentId: string, resources: ResourceRecord[]): Promise<void> {
    for (const resource of resources) {
      const key = createHash("sha256").update(resource.resourceId.toLowerCase()).digest("hex");
      const existing = await this.#get(this.#resources, environmentId, key);
      const entity = toEntity(environmentId, key, resource);
      if (existing?.["odata.etag"]) await this.#replace(this.#resources, entity, existing["odata.etag"]);
      else await this.#insert(this.#resources, entity);
    }
  }

  async listResources(environmentId: string): Promise<ResourceRecord[]> {
    const safeId = odataLiteral(environmentId);
    const entities = await this.#query(this.#resources, `PartitionKey eq '${safeId}'`);
    return entities.map(fromEntity<ResourceRecord>);
  }

  async appendOperation(operation: OperationRecord): Promise<void> {
    await this.#insert(this.#operations, toEntity(operation.environmentId, operation.operationId, operation));
  }

  async listOperations(environmentId: string): Promise<OperationRecord[]> {
    const safeId = odataLiteral(environmentId);
    const entities = await this.#query(this.#operations, `PartitionKey eq '${safeId}'`);
    return entities.map(fromEntity<OperationRecord>).sort((left, right) => left.occurredAt.localeCompare(right.occurredAt));
  }

  async purgeEnvironmentHistory(environmentId: string, expectedEtag: string): Promise<void> {
    const current = await this.#get(this.#environments, "environment", environmentId);
    if (!current) return;
    if (current["odata.etag"] !== expectedEtag) {
      throw new ConcurrencyError("Azure Table ETag changed; refusing stale retention purge");
    }

    // Child history is immutable after DELETED. Remove it first so a crash can be
    // retried safely; the authoritative environment row is always deleted last.
    for (const table of [this.#resources, this.#operations]) {
      const safeId = odataLiteral(environmentId);
      const entities = await this.#query(table, `PartitionKey eq '${safeId}'`);
      for (const entity of entities) {
        await this.#delete(table, entity.PartitionKey, entity.RowKey, "*");
      }
    }
    await this.#delete(this.#environments, "environment", environmentId, expectedEtag);
  }

  async #request(path: string, init: RequestInit = {}): Promise<Response> {
    const token = await this.#tokenProvider.getToken();
    return this.#fetch(`${this.#baseUrl}/${path}`, {
      ...init,
      headers: {
        Accept: "application/json;odata=nometadata",
        Authorization: `Bearer ${token}`,
        "Content-Type": "application/json",
        "x-ms-date": new Date().toUTCString(),
        "x-ms-version": "2019-02-02",
        ...(init.headers ?? {}),
      },
    });
  }

  async #insert(table: string, entity: TableEntity): Promise<void> {
    const response = await this.#request(table, { method: "POST", body: JSON.stringify(entity) });
    if (response.status === 409) throw new ConcurrencyError("Azure Table entity already exists");
    await assertOk(response, "insert inventory entity");
  }

  async #replace(table: string, entity: TableEntity, etag: string): Promise<void> {
    const key = entityPath(table, entity.PartitionKey, entity.RowKey);
    const response = await this.#request(key, { method: "PUT", body: JSON.stringify(entity), headers: { "If-Match": etag } });
    if (response.status === 412) throw new ConcurrencyError("Azure Table ETag changed; refusing stale write");
    await assertOk(response, "replace inventory entity");
  }

  async #get(table: string, partitionKey: string, rowKey: string): Promise<TableEntity | undefined> {
    const response = await this.#request(entityPath(table, partitionKey, rowKey));
    if (response.status === 404) return undefined;
    await assertOk(response, "read inventory entity");
    const entity = await response.json() as TableEntity;
    const etag = response.headers.get("etag");
    return etag ? { ...entity, "odata.etag": etag } : entity;
  }

  async #delete(table: string, partitionKey: string, rowKey: string, etag: string): Promise<void> {
    const response = await this.#request(entityPath(table, partitionKey, rowKey), {
      method: "DELETE",
      headers: { "If-Match": etag },
    });
    if (response.status === 404) return;
    if (response.status === 412) throw new ConcurrencyError("Azure Table ETag changed; refusing stale retention purge");
    await assertOk(response, "delete retained inventory entity");
  }

  async #query(table: string, filter: string): Promise<TableEntity[]> {
    const entities: TableEntity[] = [];
    let path: string | undefined = `${table}?$filter=${encodeURIComponent(filter)}`;
    while (path) {
      const response = await this.#request(path);
      await assertOk(response, "query inventory entities");
      const body = await response.json() as { value: TableEntity[] };
      entities.push(...body.value);
      const nextPartition = response.headers.get("x-ms-continuation-nextpartitionkey");
      const nextRow = response.headers.get("x-ms-continuation-nextrowkey");
      path = nextPartition
        ? `${table}?$filter=${encodeURIComponent(filter)}&NextPartitionKey=${encodeURIComponent(nextPartition)}&NextRowKey=${encodeURIComponent(nextRow ?? "")}`
        : undefined;
    }
    return entities;
  }
}

function validateTableName(value: string): string {
  if (!/^[A-Za-z][A-Za-z0-9]{2,62}$/.test(value)) throw new TypeError(`Invalid Azure Table name: ${value}`);
  return value;
}

function toEntity<T>(partitionKey: string, rowKey: string, value: T): TableEntity {
  const payloadValue = typeof value === "object" && value !== null
    ? Object.fromEntries(Object.entries(value).filter(([key]) => key !== "etag"))
    : value;
  return { PartitionKey: partitionKey, RowKey: rowKey, payload: JSON.stringify(payloadValue) };
}

function fromEntity<T>(entity: TableEntity): T {
  const parsed = JSON.parse(entity.payload) as T;
  return entity["odata.etag"] && typeof parsed === "object" && parsed !== null
    ? { ...parsed, etag: entity["odata.etag"] }
    : parsed;
}

function odataLiteral(value: string): string {
  return value.replaceAll("'", "''");
}

function entityPath(table: string, partitionKey: string, rowKey: string): string {
  return `${table}(PartitionKey='${odataLiteral(partitionKey)}',RowKey='${odataLiteral(rowKey)}')`;
}

async function assertOk(response: Response, operation: string): Promise<void> {
  if (response.ok) return;
  const detail = (await response.text()).slice(0, 1000);
  throw new Error(`Failed to ${operation}: HTTP ${response.status} ${detail}`);
}
