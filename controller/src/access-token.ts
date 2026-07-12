import { execFile } from "node:child_process";
import { promisify } from "node:util";
import type { AccessTokenProvider } from "./inventory.ts";

const execFileAsync = promisify(execFile);

export class AzureCliTokenProvider implements AccessTokenProvider {
  #cached?: { token: string; expiresAt: number };

  async getToken(): Promise<string> {
    if (this.#cached && this.#cached.expiresAt - Date.now() > 5 * 60_000) return this.#cached.token;
    const { stdout } = await execFileAsync("az", [
      "account", "get-access-token",
      "--resource", "https://storage.azure.com/",
      "--query", "{accessToken:accessToken,expires_on:expires_on}",
      "--output", "json",
    ], { windowsHide: true, maxBuffer: 1024 * 1024 });
    const result = JSON.parse(stdout) as { accessToken?: string; expires_on?: number };
    if (!result.accessToken) throw new Error("Azure CLI returned no Storage access token");
    this.#cached = { token: result.accessToken, expiresAt: Number(result.expires_on ?? Math.floor(Date.now() / 1000) + 600) * 1000 };
    return result.accessToken;
  }
}
