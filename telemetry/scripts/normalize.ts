import { mkdir, readFile, writeFile, rename, readdir } from "node:fs/promises";
import { join } from "node:path";
import { sha256, type Manifest } from "../src/archive";
import type { GeometryDefinition } from "../src/geometry";
import { readInput } from "../src/io";
import { normalizeDriver } from "../src/normalize";
const sessionKey = Number(process.argv[2]), geometryPath = process.argv[3];
if (!sessionKey || !geometryPath) throw new Error("Usage: normalize <sessionKey> <geometry.json> [--experimental]");
const root = join(import.meta.dir, "../data", String(sessionKey));
const manifest: Manifest = JSON.parse(await readFile(join(root, "manifest.json"), "utf8"));
const geometry: GeometryDefinition = JSON.parse(await readFile(geometryPath, "utf8"));
if (!geometry.verified && !process.argv.includes("--experimental")) throw new Error("Unverified geometry; use --experimental only for evaluation, not app deployment");
const sourceNames = (await readdir(join(import.meta.dir, "../src"))).filter(p => p.endsWith(".ts")).sort();
const pipelineHash = sha256((await Promise.all(sourceNames.map(async p => `${p}\n${await readFile(join(import.meta.dir, "../src", p), "utf8")}`))).join("\n"));
const revision = sha256(JSON.stringify({pipelineVersion: 1, pipelineHash, entries: manifest.entries.map(e => e.sha256), geometry}));
const output = join(root, "normalized_position", revision); await mkdir(output, {recursive: true});
const summary = [];
for (const entry of manifest.entries.filter(e => e.endpoint === "location")) {
  const input = await readInput(root, entry.driverNumber!);
  const start = performance.now(); const dataset = normalizeDriver(input, geometry); const processingMS = performance.now() - start;
  const body = Bun.gzipSync(JSON.stringify(dataset)); const name = `${entry.driverNumber}.json.gz`;
  await writeFile(join(output, `${name}.${process.pid}.tmp`), body); await rename(join(output, `${name}.${process.pid}.tmp`), join(output, name));
  summary.push({driver: entry.driverNumber, processingMS, bytes: body.byteLength, sha256: sha256(body), keyframes: dataset.keyframes.length,
    accepted: dataset.keyframes.filter(k => k.confidence > 0).length, interpolationEdges: dataset.keyframes.filter(k => k.interpolationAllowed).length, policy: dataset.policy});
}
await writeFile(join(output, "manifest.json"), JSON.stringify({version: 1, sessionKey, revision, pipelineHash, encoding: "json+gzip", experimental: !geometry.verified, rawManifest: manifest, geometry, drivers: summary}, null, 2));
console.log(JSON.stringify({output, processingMS: summary.reduce((a, b) => a + b.processingMS, 0), bytes: summary.reduce((a, b) => a + b.bytes, 0), drivers: summary.length}));
