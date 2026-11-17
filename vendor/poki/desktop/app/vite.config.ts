import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Tauri serves the built files; in dev it opens the Vite server.
export default defineConfig({
  plugins: [react()],
  clearScreen: false,
  server: { port: 1420, strictPort: true, watch: { ignored: ["**/src-tauri/**"] } },
  build: { target: ["es2022", "safari15"], outDir: "dist", emptyOutDir: true },
});
