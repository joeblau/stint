import { createHash, randomUUID } from "node:crypto";
import { mkdir, readFile, writeFile, link, unlink } from "node:fs/promises";
import { join } from "node:path";

export type Endpoint = "sessions" | "drivers" | "location" | "car_data" | "laps" | "pit" | "position" | "intervals" | "stints" | "race_control";
export type RawRecord = Record<string, unknown>;
export interface ArchiveEntry { endpoint: Endpoint; url: string; sha256: string; bytes: number; records: number; fetchedAt: string; path: string; driverNumber?: number }
export interface Manifest { version: 1; sessionKey: number; entries: ArchiveEntry[]; complete: boolean; coverage?: { driverNumbers: number[]; scope: "selected-drivers" | "all-drivers" } }
export const sha256 = (bytes: Uint8Array | string) => createHash("sha256").update(bytes).digest("hex");

/** Content addressed, create-only raw response bodies. JSON is never reserialized. */
export async function archiveResponse(root: string, endpoint: Endpoint, url: string, body: Uint8Array, driverNumber?: number): Promise<ArchiveEntry> {
  const parsed: unknown = JSON.parse(new TextDecoder().decode(body));
  if (!Array.isArray(parsed)) throw new Error(`${endpoint}: expected an array, not an error envelope`);
  const hash = sha256(body);
  const directory = endpoint === "location" ? "raw_position" : "raw_events";
  await mkdir(join(root, directory), { recursive: true });
  const path = `${directory}/${hash}.json`;
  const temporary = join(root, directory, `.${hash}.${randomUUID()}.tmp`);
  await writeFile(temporary, body, {flag: "wx"});
  try { await link(temporary, join(root, path)); }
  catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error;
    if (sha256(await readFile(join(root, path))) !== hash) throw new Error(`Raw archive integrity failure: ${path}`);
  } finally { await unlink(temporary); }
  return { endpoint, url, sha256: hash, bytes: body.byteLength, records: parsed.length, fetchedAt: new Date().toISOString(), path, driverNumber };
}

export async function readRecords(root: string, manifest: Manifest, endpoint: Endpoint, driverNumber?: number): Promise<RawRecord[]> {
  const records: RawRecord[] = [];
  for (const entry of manifest.entries) {
    if (entry.endpoint !== endpoint || (driverNumber !== undefined && entry.driverNumber !== undefined && entry.driverNumber !== driverNumber)) continue;
    if (!/^[a-f0-9]{64}$/.test(entry.sha256) || !["raw_position", "raw_events"].some(d => entry.path === `${d}/${entry.sha256}.json`)) throw new Error("Invalid archive path");
    const body = await readFile(join(root, entry.path));
    if (sha256(body) !== entry.sha256) throw new Error(`Raw archive integrity failure: ${entry.path}`);
    const rows: RawRecord[] = JSON.parse(body.toString());
    for (const row of rows) if (driverNumber === undefined || row.driver_number === driverNumber) records.push(row);
  }
  return records;
}

export class OpenF1Client {
  private nextRequest = 0;
  constructor(private readonly base = "https://api.openf1.org/v1", private readonly maxBytes = 100_000_000) {}
  async get(endpoint: Endpoint, filters: Record<string, string | number>): Promise<{ url: string; body: Uint8Array }> {
    const url = new URL(`${this.base}/${endpoint}`);
    for (const [key, value] of Object.entries(filters)) url.searchParams.set(key, String(value));
    for (let attempt = 0; attempt < 5; attempt++) {
      await Bun.sleep(Math.max(0, this.nextRequest - Date.now()));
      this.nextRequest = Date.now() + 2_100; // Public tier: at most 30 requests/minute.
      let response: Response;
      try { response = await fetch(url, { signal: AbortSignal.timeout(90_000) }); }
      catch (error) {
        if (attempt === 4) throw error;
        this.nextRequest = Date.now() + Math.min(60_000, 2_100 * 2 ** attempt); continue;
      }
      if (response.status === 429 || response.status >= 500) {
        const retry = response.headers.get("retry-after");
        const seconds = retry && Number.isFinite(Number(retry)) ? Number(retry) : 0;
        const retryDate = retry ? Date.parse(retry) : NaN;
        this.nextRequest = Date.now() + Math.min(60_000, Math.max(2_100 * 2 ** attempt, seconds * 1000, Number.isFinite(retryDate) ? retryDate - Date.now() : 0));
        await response.body?.cancel();
        continue;
      }
      if (!response.ok) { await response.body?.cancel(); throw new Error(`${endpoint}: HTTP ${response.status}`); }
      if (Number(response.headers.get("content-length")) > this.maxBytes) { await response.body?.cancel(); throw new Error(`${endpoint}: response too large; fetch smaller time windows`); }
      const reader = response.body?.getReader();
      if (!reader) throw new Error(`${endpoint}: missing response body`);
      const chunks: Uint8Array[] = []; let size = 0;
      for (;;) {
        const chunk = await reader.read(); if (chunk.done) break;
        size += chunk.value.length;
        if (size > this.maxBytes) { await reader.cancel(); throw new Error(`${endpoint}: response too large; fetch smaller time windows`); }
        chunks.push(chunk.value);
      }
      const body = new Uint8Array(size); let offset = 0;
      for (const chunk of chunks) { body.set(chunk, offset); offset += chunk.length; }
      return { url: url.toString(), body };
    }
    throw new Error(`${endpoint}: retry budget exhausted; raw archive remains resumable`);
  }
}
