const { renameSync } = require("node:fs");
const { join } = require("node:path");
const { execFileSync } = require("node:child_process");

// executableName also changes electron-builder's bundle filename. Keep the
// product bundle name, then rename only its main executable before signing.
function renameExecutable(bundle, command = execFileSync) {
  renameSync(join(bundle, "Contents/MacOS/MeterUsage"), join(bundle, "Contents/MacOS/meterusage"));
  command("/usr/libexec/PlistBuddy", ["-c", "Set :CFBundleExecutable meterusage", join(bundle, "Contents/Info.plist")]);
}
module.exports = async context => {
  if (context.electronPlatformName !== "darwin") throw new Error("Only macOS candidate packaging is enabled");
  renameExecutable(join(context.appOutDir, "MeterUsage.app"));
};
module.exports.renameExecutable = renameExecutable;
