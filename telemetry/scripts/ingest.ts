import { mkdir, readFile, writeFile, rename, open, unlink } from "node:fs/promises";
import { join } from "node:path";
import { OpenF1Client, archiveResponse, type Endpoint, type Manifest, sha256 } from "../src/archive";
const sessionKey = Number(process.argv[2]);
if (!Number.isSafeInteger(sessionKey) || sessionKey <= 0) throw new Error("Usage: bun ingest <sessionKey> [driver,driver,...|all]");
const root = join(import.meta.dir, "../data", String(sessionKey));
await mkdir(root, { recursive: true });
let manifest: Manifest = { version: 1, sessionKey, entries: [], complete: false };
try { manifest = JSON.parse(await readFile(join(root, "manifest.json"), "utf8")); } catch (e) { if ((e as NodeJS.ErrnoException).code !== "ENOENT") throw e; }
if (manifest.sessionKey !== sessionKey) throw new Error("Archive session identity mismatch");
const lockPath = join(root, ".ingest.lock");
const lock = await open(lockPath, "wx"); await lock.writeFile(String(process.pid));
process.on("exit", () => { try { require("node:fs").unlinkSync(lockPath); } catch {} });
const client = new OpenF1Client();
async function save() { await writeFile(join(root, "manifest.tmp"), JSON.stringify(manifest, null, 2)); await rename(join(root, "manifest.tmp"), join(root, "manifest.json")); }
async function fetchEndpoint(endpoint: Endpoint, driverNumber?: number) {
  const existing = manifest.entries.find(e => e.endpoint === endpoint && e.driverNumber === driverNumber);
  if (existing) {
    if (sha256(await readFile(join(root, existing.path))) !== existing.sha256) throw new Error("Raw archive integrity failure");
    return;
  }
  const response = await client.get(endpoint, { session_key: sessionKey, ...(driverNumber === undefined ? {} : {driver_number: driverNumber}) });
  const entry = await archiveResponse(root, endpoint, response.url, response.body, driverNumber);
  manifest.entries.push(entry); await save(); console.log(sessionKey, endpoint, driverNumber ?? "all", entry.records, entry.bytes);
}
manifest.complete = false; await save();
await fetchEndpoint("sessions"); await fetchEndpoint("drivers");
const requested = process.argv[3] ?? "all";
const drivers = requested === "all" ? JSON.parse(await readFile(join(root, manifest.entries.find(e => e.endpoint === "drivers")!.path), "utf8")).map((x: {driver_number: number}) => x.driver_number) as number[] : requested.split(",").map(Number);
for (const endpoint of ["laps", "pit", "position", "intervals", "stints", "race_control"] as Endpoint[]) await fetchEndpoint(endpoint);
for (const driver of drivers) {
  if (!Number.isSafeInteger(driver) || driver <= 0) throw new Error("Invalid driver number");
  await fetchEndpoint("location", driver); await fetchEndpoint("car_data", driver);
}
manifest.coverage = {driverNumbers: manifest.entries.filter(e => e.endpoint === "location").map(e => e.driverNumber!), scope: requested === "all" ? "all-drivers" : "selected-drivers"};
manifest.complete = true; await save(); await lock.close(); await unlink(lockPath);
