import { defineConfig } from "vite";

// Tauri serves the built files itself; the dev server is only for `tauri dev` and browser previews.
export default defineConfig({
  clearScreen: false,
  server: { port: 1420, strictPort: true },
  envPrefix: ["VITE_", "TAURI_ENV_"],
  build: { target: "es2022", outDir: "dist", sourcemap: false },
});
