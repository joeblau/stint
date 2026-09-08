import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { readRecords, type Manifest } from "./archive";
import type { DriverInput } from "./normalize";
export async function readInput(root: string, driverNumber: number): Promise<DriverInput> {
  const manifest: Manifest = JSON.parse(await readFile(join(root, "manifest.json"), "utf8"));
  const session = (await readRecords(root, manifest, "sessions"))[0];
  if (!session || session.session_key !== manifest.sessionKey) throw new Error("Session identity mismatch");
  const result = {sessionKey: manifest.sessionKey, driverNumber, origin: String(session.date_start), end: String(session.date_end)} as DriverInput;
  for (const endpoint of ["location", "car_data", "laps", "pit", "position", "intervals", "stints", "race_control"] as const)
    result[endpoint] = await readRecords(root, manifest, endpoint, endpoint === "race_control" ? undefined : driverNumber);
  return result;
}
