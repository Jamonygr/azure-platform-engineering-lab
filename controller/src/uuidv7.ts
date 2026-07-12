import { randomBytes } from "node:crypto";

const UUID_V7 = /^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export function isUuidV7(value: unknown): value is string {
  if (typeof value !== "string" || !UUID_V7.test(value)) return false;
  const timestamp = uuidV7Timestamp(value);
  return Number.isSafeInteger(timestamp) && timestamp >= 0;
}

export function uuidV7Timestamp(value: string): number {
  if (!UUID_V7.test(value)) throw new TypeError("Value is not an RFC 9562 UUIDv7");
  return Number.parseInt(value.replaceAll("-", "").slice(0, 12), 16);
}

export function createUuidV7(
  now: number = Date.now(),
  random: (size: number) => Uint8Array = randomBytes,
): string {
  if (!Number.isSafeInteger(now) || now < 0 || now > 0xffffffffffff) {
    throw new RangeError("UUIDv7 timestamp must fit in 48 unsigned bits");
  }

  const bytes = new Uint8Array(random(16));
  if (bytes.length !== 16) throw new RangeError("UUIDv7 random source must return 16 bytes");

  let timestamp = BigInt(now);
  for (let index = 5; index >= 0; index -= 1) {
    bytes[index] = Number(timestamp & 0xffn);
    timestamp >>= 8n;
  }

  bytes[6] = 0x70 | ((bytes[6] ?? 0) & 0x0f);
  bytes[8] = 0x80 | ((bytes[8] ?? 0) & 0x3f);
  const hex = Buffer.from(bytes).toString("hex");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}
