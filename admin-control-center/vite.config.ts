import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Served at https://<GT Termin web app>/admin/ from the existing Vercel project.
// `npm run build` writes the static bundle to ../admin (repo root), which Vercel serves as-is.
export default defineConfig({
  base: "/admin/",
  plugins: [react()],
  build: {
    outDir: "../admin",
    emptyOutDir: true,
  },
  server: {
    port: 5173,
    strictPort: true,
  },
  preview: {
    port: 4173,
  },
});
