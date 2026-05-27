import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  server: {
    proxy: {
      // Backend routes proxied to FastAPI on :8000. Keep this in sync with
      // the routes FastAPI actually serves — anything else falls through to
      // the React app.
      "/api": { target: "http://localhost:8000", changeOrigin: true },
      "/docs": { target: "http://localhost:8000", changeOrigin: true },
      "/redoc": { target: "http://localhost:8000", changeOrigin: true },
      "/openapi.json": { target: "http://localhost:8000", changeOrigin: true },
    },
  },
});
