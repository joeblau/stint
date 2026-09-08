import { readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { distribution, upperBound } from "../src/timeline";
const path=join(import.meta.dir,"../../apple/races/2026-09-06-monza.json");
const bytes=await readFile(path);const start=performance.now();const source=JSON.parse(bytes.toString());const decodeMS=performance.now()-start;
const drivers=[];
for(const recording of source.recordings){
  const samples=recording.samples as {time:number;latitude:number;longitude:number;speedKPH?:number}[];
  let checksum=0;const queries=100000,start=performance.now();
  for(let j=0;j<queries;j++){const t=samples.at(-1)!.time*((j*7919)%queries)/queries;const i=Math.max(0,upperBound(samples,t,s=>s.time)-1),a=samples[i],b=samples[Math.min(i+1,samples.length-1)];const f=b.time>a.time?(t-a.time)/(b.time-a.time):0;checksum+=a.latitude+(b.latitude-a.latitude)*f;}
  drivers.push({driver:recording.driver.number??recording.driver.id,samples:samples.length,intervalsUS:distribution(samples.map(s=>Math.round(s.time*1e6))),missingSpeed:samples.filter(s=>s.speedKPH===undefined).length,lookupUS:(performance.now()-start)*1000/queries,checksum});
}
const result={path:"apple/races/2026-09-06-monza.json",bytes:bytes.length,decodeMS,notes:["Version-1 geographic replay has no original timestamps, XYZ or source provenance; it cannot recover the lost original samples.","Lookup mirrors DriverRecording.position(at:) coordinate interpolation; timing is Bun, not Swift or render-thread profiling."],drivers};
await writeFile(join(import.meta.dir,"../reports/baseline-legacy.json"),JSON.stringify(result,null,2));console.log(result.bytes,drivers.length,drivers[0]);
