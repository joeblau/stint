import { readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { readInput } from "../src/io";
import { normalizeDriver } from "../src/normalize";
import { Replay, integratedFraction, monotoneFraction } from "../src/playback";
import { Route, distance } from "../src/geometry";
import { asOf, quantile, upperBound } from "../src/timeline";
import type { Manifest } from "../src/archive";
const sessionKey = Number(process.argv[2] ?? 11361), root = join(import.meta.dir, `../data/${sessionKey}`);
const manifest: Manifest = JSON.parse(await readFile(join(root, "manifest.json"), "utf8"));
const geometry = JSON.parse(await readFile(join(import.meta.dir, `../geometry/${sessionKey}.experimental.json`), "utf8"));
const track = new Route(geometry.routes[0]);
const summary = (values: number[]) => {const sorted = values.slice().sort((a,b)=>a-b); return {count: values.length, mean: values.reduce((a,b)=>a+b,0)/(values.length||1), p50: quantile(sorted,.5), p95:quantile(sorted,.95), p99:quantile(sorted,.99)};};
const drivers = [];
for (const entry of manifest.entries.filter(e=>e.endpoint === "location")) {
  const loadStart = performance.now(), input = await readInput(root, entry.driverNumber!); const loadMS = performance.now()-loadStart;
  const start = performance.now(), dataset = normalizeDriver(input, geometry), processingMS = performance.now()-start;
  const serializationStart = performance.now(), json = JSON.stringify(dataset), compressed = Bun.gzipSync(json), serializeCompressMS = performance.now()-serializationStart;
  const frames = dataset.keyframes, rawAcceleration:number[] = [], cleanAcceleration:number[] = [], rawJitter:number[] = [], cleanJitter:number[]=[];
  let backwardsRaw=0, backwardsClean=0, teleportRaw=0, teleportClean=0, acceptedEdges=0;
  let lastRawVelocity: number | undefined, lastCleanVelocity: number | undefined;
  for(let i=1;i<frames.length;i++) {
    const a=frames[i-1],b=frames[i],dt=(b.timestamp-a.timestamp)/1e6;
    if(dt<=0)continue;
    const rawTravel=Math.hypot(b.rawX-a.rawX,b.rawY-a.rawY)*geometry.metersPerUnit;
    if(rawTravel>125*dt+10)teleportRaw++;
    if(!a.interpolationAllowed){lastRawVelocity=undefined;lastCleanVelocity=undefined;continue;}
    acceptedEdges++;
    const rawVelocity=rawTravel/dt;
    let cleanTravel=b.routeDistance!-a.routeDistance!; if(cleanTravel < -track.length/2)cleanTravel+=track.length;
    const cleanVelocity=cleanTravel/dt;
    if(cleanTravel < -3)backwardsClean++; if(cleanTravel>125*dt+10)teleportClean++;
    const pa=track.project({x:a.rawX*geometry.metersPerUnit,y:a.rawY*geometry.metersPerUnit,z:0});
    const pb=track.project({x:b.rawX*geometry.metersPerUnit,y:b.rawY*geometry.metersPerUnit,z:0});
    if(pa&&pb){let delta=pb.distance-pa.distance;if(delta < -track.length/2)delta+=track.length;if(delta < -3)backwardsRaw++;rawJitter.push(Math.abs(pb.residual-pa.residual));cleanJitter.push(0);}
    if(lastRawVelocity!==undefined)rawAcceleration.push(Math.abs(rawVelocity-lastRawVelocity)/dt);
    if(lastCleanVelocity!==undefined)cleanAcceleration.push(Math.abs(cleanVelocity-lastCleanVelocity)/dt);
    lastRawVelocity=rawVelocity;lastCleanVelocity=cleanVelocity;
  }
  const linearErrors:number[]=[], hermiteErrors:number[]=[], speedErrors:number[]=[];
  let speedRejected=0;
  for(let i=1;i<frames.length-1;i+=2){
    const a=frames[i-1],m=frames[i],b=frames[i+1];
    if(!a.interpolationAllowed||!m.interpolationAllowed||a.absoluteRaceDistance===null||m.absoluteRaceDistance===null||b.absoluteRaceDistance===null||b.timestamp-a.timestamp>dataset.policy.maximumUS)continue;
    const delta=b.absoluteRaceDistance-a.absoluteRaceDistance,dt=(b.timestamp-a.timestamp)/1e6;if(delta<1||delta/dt>125)continue;
    const f=(m.timestamp-a.timestamp)/(b.timestamp-a.timestamp),truth=m.absoluteRaceDistance-a.absoluteRaceDistance;
    const av=asOf(dataset.events.car_data,a.timestamp,dataset.policy.telemetryMaxAgeUS)?.data.speed;
    const bv=asOf(dataset.events.car_data,b.timestamp,dataset.policy.telemetryMaxAgeUS)?.data.speed;
    if(typeof av!=="number"||typeof bv!=="number")continue;
    const profile=[{time:a.timestamp,speedMPS:av/3.6},...dataset.events.car_data.slice(upperBound(dataset.events.car_data,a.timestamp,e=>e.time),upperBound(dataset.events.car_data,b.timestamp-1,e=>e.time)).map(e=>({time:e.time,speedMPS:Number(e.data.speed)/3.6})),{time:b.timestamp,speedMPS:bv/3.6}];
    let integral=0;for(let j=1;j<profile.length;j++)integral+=(profile[j].time-profile[j-1].time)/1e6*(profile[j].speedMPS+profile[j-1].speedMPS)/2;
    const sf=integratedFraction(profile,m.timestamp), secant=delta/dt;
    const maxSpeed=Math.max(...profile.map(p=>p.speedMPS));
    if(sf===null||integral/delta<.7||integral/delta>1.3||maxSpeed*delta/(integral||1)>125){speedRejected++;continue;}
    // Compare all methods on exactly the same eligible held-out anchors.
    linearErrors.push(Math.abs(delta*f-truth));
    hermiteErrors.push(Math.abs(delta*monotoneFraction(f,av/3.6/secant,bv/3.6/secant)-truth));
    speedErrors.push(Math.abs(delta*sf-truth));
  }
  const replay = new Replay(); replay.add(dataset); let checksum=0;
  const queries=100_000, times=Array.from({length:queries},(_,i)=>Math.round(frames[0].timestamp+(frames.at(-1)!.timestamp-frames[0].timestamp)*((i*7919)%queries)/queries));
  // Warm both paths and use an observable checksum; this is lookup CPU, not map/render frame time.
  for(const t of times.slice(0,1000))replay.getDriverState(sessionKey,entry.driverNumber!,t);
  const lookupStart=performance.now();for(const t of times){const s=replay.getDriverState(sessionKey,entry.driverNumber!,t);checksum+=s.position?.x??0;}const playbackUS=(performance.now()-lookupStart)*1000/queries;
  const baselineStart=performance.now();for(const t of times){const i=Math.max(0,upperBound(frames,t,k=>k.timestamp)-1),a=frames[i],b=frames[Math.min(i+1,frames.length-1)];const f=b.timestamp>a.timestamp?(t-a.timestamp)/(b.timestamp-a.timestamp):0;checksum+=a.rawX+(b.rawX-a.rawX)*f;}const baselineLookupUS=(performance.now()-baselineStart)*1000/queries;
  drivers.push({driver:entry.driverNumber,rows:frames.length,acceptedEdges,coverage:acceptedEdges/Math.max(1,frames.length-1),loadMS,processingMS,serializeCompressMS,jsonBytes:Buffer.byteLength(json),gzipBytes:compressed.byteLength,playbackUS,baselineLookupUS,checksum,
    intervalsUS:dataset.policy.intervals,raw:{accelerationAbsoluteMPS2:summary(rawAcceleration),lateralResidualChangeMeters:summary(rawJitter),backwards:backwardsRaw,teleports:teleportRaw},
    normalized:{accelerationAbsoluteMPS2:summary(cleanAcceleration),lateralResidualChangeMeters:summary(cleanJitter),backwards:backwardsClean,teleports:teleportClean},
    heldOut:{linearMeters:summary(linearErrors),hermiteMeters:summary(hermiteErrors),anchoredSpeedMeters:summary(speedErrors),speedRejected}});
}
const report={sessionKey,runtime:Bun.version,geometryVerified:geometry.verified,notes:["Experimental reference trajectory; error against withheld fixes is not independent ground truth.","Acceleration and backwards comparisons use matched accepted edges. Raw teleport count covers all edges; rejected motion remains unavailable.","Lateral residual change is a jitter proxy; projected residual is zero by construction, not proof of accuracy.","Lookup timing excludes rendering; baseline is raw XY interpolation, matching the existing algorithm, not an instrumented Swift build."],
  totals:{drivers:drivers.length,rows:drivers.reduce((a,d)=>a+d.rows,0),processingMS:drivers.reduce((a,d)=>a+d.processingMS,0),rawBytes:manifest.entries.reduce((a,e)=>a+e.bytes,0),gzipBytes:drivers.reduce((a,d)=>a+d.gzipBytes,0),jsonBytes:drivers.reduce((a,d)=>a+d.jsonBytes,0),serializeCompressMS:drivers.reduce((a,d)=>a+d.serializeCompressMS,0),loadMS:drivers.reduce((a,d)=>a+d.loadMS,0)},drivers};
await writeFile(join(import.meta.dir,`../reports/benchmark-${sessionKey}.json`),JSON.stringify(report,null,2));console.log(JSON.stringify(report.totals));
