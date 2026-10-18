const { copyFileSync, mkdirSync, readFileSync, writeFileSync } = require("node:fs");
const { join, resolve } = require("node:path");

function exportAssets(root) {
  const resources = join(root, "Resources");
  for (const provider of ["openRouter", "cursor", "copilot", "gemini"]) {
    copyFileSync(join(__dirname, "assets", `${provider}-symbol.png`), join(resources, `${provider}-symbol.png`));
  }
  // Reuse the original icon's 256px PNG without image conversion tools.
  const icns = readFileSync(join(resources, "AppIcon.icns"));
  if (icns.toString("ascii", 0, 4) !== "icns" || icns.readUInt32BE(4) !== icns.length) throw new Error("Invalid app icon");
  let png;
  for (let offset = 8; offset < icns.length;) {
    const size = icns.readUInt32BE(offset + 4);
    if (size < 8 || offset + size > icns.length) throw new Error("Invalid app icon entry");
    if (icns.toString("ascii", offset, offset + 4) === "ic08") png = icns.subarray(offset + 8, offset + size);
    offset += size;
  }
  if (!png || png.readUInt32BE(16) !== 256 || png.readUInt32BE(20) !== 256) throw new Error("Missing 256px app icon");
  const header = Buffer.alloc(22);
  header.writeUInt16LE(1, 2); header.writeUInt16LE(1, 4);
  header.writeUInt16LE(1, 10); header.writeUInt16LE(32, 12);
  header.writeUInt32LE(png.length, 14); header.writeUInt32LE(22, 18);
  mkdirSync(join(root, "build"), { recursive: true });
  writeFileSync(join(root, "build", "AppIcon.ico"), Buffer.concat([header, png]));
}

if (require.main === module) exportAssets(resolve(__dirname, "../.."));
module.exports = { exportAssets };
