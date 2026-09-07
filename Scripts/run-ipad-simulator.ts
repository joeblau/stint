import { $ } from "bun";
import { existsSync } from "node:fs";
import { resolve } from "node:path";

process.chdir(`${import.meta.dir}/..`);

if (process.platform !== "darwin") {
  console.error("Stint requires macOS and Xcode.");
  process.exit(1);
}
if (!Bun.which("xcodegen")) {
  console.error("Install XcodeGen first: brew install xcodegen");
  process.exit(1);
}

type Device = { name: string; udid: string; state: string; isAvailable: boolean };
const requested = process.argv.slice(2).join(" ") || process.env.STINT_SIMULATOR;
const { devices } = await $`xcrun simctl list devices available -j`.json() as {
  devices: Record<string, Device[]>;
};
const candidates = Object.entries(devices)
  .filter(([runtime]) => runtime.includes(".iOS-") && Number(runtime.split(".iOS-")[1].split("-")[0]) >= 18)
  .sort(([a], [b]) => b.localeCompare(a, undefined, { numeric: true }))
  .flatMap(([, devices]) => devices)
  .filter(device => device.isAvailable && device.name.startsWith("iPad"));
const device = requested
  ? candidates.find(device => device.udid === requested || device.name === requested)
  : candidates.find(device => device.state === "Booted") ?? candidates[0];

if (!device) {
  console.error(requested
    ? `No available iPad simulator matches "${requested}". Run xcrun simctl list devices available.`
    : "Install an iPadOS 18+ simulator in Xcode Settings > Components, then try again.");
  process.exit(1);
}

console.log(`Building Stint for ${device.name} (${device.udid})`);
await $`xcodegen generate`;
await $`xcodebuild -quiet -project Stint.xcodeproj -scheme Stint-iPad -configuration Debug -destination ${`platform=iOS Simulator,id=${device.udid}`} -derivedDataPath build-ipad CODE_SIGNING_ALLOWED=NO build`;
await $`xcrun simctl bootstatus ${device.udid} -b`;
const developerDirectory = (await $`xcode-select -p`.text()).trim();
const deviceHub = resolve(developerDirectory, "../Applications/DeviceHub.app");
if (existsSync(deviceHub)) {
  await $`open -a ${deviceHub}`;
} else {
  await $`open -a ${`${developerDirectory}/Applications/Simulator.app`} --args -CurrentDeviceUDID ${device.udid}`;
}
await $`xcrun simctl install ${device.udid} build-ipad/Build/Products/Debug-iphonesimulator/Stint.app`;
await $`xcrun simctl launch --terminate-running-process ${device.udid} com.joeblau.stint`;
