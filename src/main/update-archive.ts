import { fromBuffer, type Entry } from "yauzl";
import { posix } from "node:path";

// Inspect central-directory entries and link payloads before any extraction.
// No archive entry may write through another entry's symlink.
export function inspectUpdateArchive(data: Buffer): Promise<void> {
  return new Promise((resolve, reject) => fromBuffer(data, { lazyEntries: true, strictFileNames: true }, (error, zip) => {
    if (error || !zip) { reject(new Error("Invalid update archive")); return; }
    const names = new Set<string>(), links = new Set<string>(); let size = 0, finished = false;
    const fail = () => { if (!finished) { finished = true; zip.close(); reject(new Error("Invalid update archive")); } };
    zip.on("error", fail);
    zip.on("entry", (entry: Entry) => {
      if (finished) return;
      const path = entry.fileName.replace(/\/$/, ""), parts = path.split("/"), type = (entry.externalFileAttributes >>> 16) & 0xf000;
      size += entry.uncompressedSize;
      if (!path.startsWith("MeterUsage.app/") && path !== "MeterUsage.app" || parts.some(p => !p || p === "." || p === "..") || /[\\\x00-\x1f\x7f]/.test(path) || names.has(path) || entry.isEncrypted() || size > 2 * 1024 ** 3 || names.size >= 100000 || ![0, 0x4000, 0x8000, 0xa000].includes(type)) { fail(); return; }
      names.add(path);
      if (type !== 0xa000) { zip.readEntry(); return; }
      if (entry.uncompressedSize > 4096) { fail(); return; }
      links.add(path);
      zip.openReadStream(entry, (error, stream) => {
        if (error || !stream) { fail(); return; }
        const chunks: Buffer[] = []; let length = 0;
        stream.on("error", fail);
        stream.on("data", (chunk: Buffer) => { length += chunk.length; if (length > 4096) { stream.destroy(); fail(); } else chunks.push(chunk); });
        stream.on("end", () => {
          if (finished) return;
          const target = Buffer.concat(chunks).toString("utf8"), resolved = posix.normalize(posix.join(posix.dirname(path), target));
          if (!target || posix.isAbsolute(target) || /[\\\x00-\x1f\x7f]/.test(target) || resolved !== "MeterUsage.app" && !resolved.startsWith("MeterUsage.app/")) { fail(); return; }
          zip.readEntry();
        });
      });
    });
    zip.on("end", () => {
      if (finished) return;
      if (!names.has("MeterUsage.app/Contents/Info.plist") || !names.has("MeterUsage.app/Contents/MacOS/meterusage")) { fail(); return; }
      for (const name of names) {
        let parent = posix.dirname(name);
        while (parent !== ".") { if (links.has(parent)) { fail(); return; } parent = posix.dirname(parent); }
      }
      finished = true; resolve();
    });
    zip.readEntry();
  }));
}
