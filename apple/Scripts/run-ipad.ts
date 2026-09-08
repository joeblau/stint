import { $ } from "bun";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

process.chdir(`${import.meta.dir}/..`);

type Device = {
  identifier: string;
  properties?: {
    hardware?: { reality?: string; marketingName?: string; udid?: string };
    state?: { name?: string };
  };
  hardwareProperties?: { reality?: string; marketingName?: string; udid?: string };
  deviceProperties?: { name?: string };
};

async function main() {
  if (process.platform !== "darwin") throw new Error("Stint requires macOS and Xcode.");
  if (!Bun.which("xcodegen")) throw new Error("Install XcodeGen first: brew install xcodegen");

  const requested = process.argv.slice(2).join(" ") || process.env.STINT_DEVICE;
  const temporary = await mkdtemp(join(tmpdir(), "stint-device-"));
  try {
    const deviceList = join(temporary, "devices.json");
    await $`xcrun devicectl list devices --quiet --json-output ${deviceList}`;
    const data = await Bun.file(deviceList).json() as { result: { devices: Device[] } };
    const physical = data.result.devices.map(device => ({
      identifier: device.identifier,
      hardware: device.properties?.hardware ?? device.hardwareProperties,
      name: device.properties?.state?.name ?? device.deviceProperties?.name ?? "iPad",
    })).filter(device => device.hardware?.reality === "physical" && device.hardware.marketingName?.startsWith("iPad"));
    const matches = requested
      ? physical.filter(device => [device.identifier, device.hardware?.udid, device.name].includes(requested))
      : physical.filter(device => device.hardware?.marketingName?.includes("iPad Pro 13-inch"));
    if (matches.length !== 1) {
      throw new Error(matches.length > 1
        ? "Multiple 13-inch iPad Pros are paired. Use bun ipad:stint <UDID> to choose one."
        : "No matching physical 13-inch iPad Pro found. Connect and trust your iPad, then retry. Use bun ipad:stint:sim for a simulator.");
    }
    const device = matches[0];
    const udid = device.hardware!.udid!;
    if (!udid) throw new Error("The iPad did not report a UDID. Pair it in Xcode and retry.");
    console.log(`Deploying Stint to ${device.name} — ${device.hardware!.marketingName}`);
    // Establish the connection before starting a signed build.
    await $`xcrun devicectl device info details --device ${udid} --quiet --timeout 30`;
    await $`xcodegen generate`;
    const configuration = process.env.STINT_CONFIGURATION ?? "Release";
    const signing = process.env.STINT_DEVELOPMENT_TEAM ? [`DEVELOPMENT_TEAM=${process.env.STINT_DEVELOPMENT_TEAM}`] : [];
    await $`xcodebuild -quiet -project Stint.xcodeproj -scheme Stint-iPad -configuration ${configuration} -destination ${`platform=iOS,id=${udid}`} -destination-timeout 30 -derivedDataPath build-device -allowProvisioningUpdates -allowProvisioningDeviceRegistration CODE_SIGN_STYLE=Automatic ${signing} build`;
    await $`xcrun devicectl device install app --device ${udid} ${`build-device/Build/Products/${configuration}-iphoneos/Stint.app`} --timeout 60`;
    await $`xcrun devicectl device process launch --device ${udid} --terminate-existing com.joeblau.stint --timeout 30`;
    console.log("Stint is running on your iPad.");
  } finally {
    await rm(temporary, { recursive: true, force: true });
  }
}

await main().catch(error => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exitCode = 1;
});
