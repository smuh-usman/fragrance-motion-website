import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  build: {
    // Static output for Cloudflare Pages. No SSR, no server functions.
    outDir: "dist",
    assetsInlineLimit: 0,
  },
  assetsInclude: ["**/*.glsl"],
});
