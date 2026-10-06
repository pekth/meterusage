import "vite-plus/test/config";
import { defineConfig } from "vite-plus";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";

export default defineConfig({
  plugins: [react(), tailwindcss()],
  base: "./",
  publicDir: "Resources",
  build: { outDir: "dist/renderer" },
  test: { include: ["tests/**/*.test.ts"], testTimeout: 15000 },
  pack: [
    { entry: ["src/main/cli.ts", "src/main/electron.ts"], outDir: "dist/main", format: "cjs", deps: { neverBundle: ["electron"] }, outExtensions: () => ({ js: ".cjs" }) },
    { entry: ["src/main/preload.ts"], outDir: "dist/preload", format: "cjs", deps: { neverBundle: ["electron"] }, outExtensions: () => ({ js: ".cjs" }) },
  ],
});
