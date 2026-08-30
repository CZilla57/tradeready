import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import { fileURLToPath, URL } from 'node:url';

// Standalone web portal. The `@shared` alias points one level up at the repo
// root so the web app can reuse the mobile app's canonical model types
// (types/models.ts) and its RN-free pure utility helpers (utils/*). Only leaf
// helpers with no react-native/expo imports are imported through it.
export default defineConfig({
  plugins: [react()],
  // The shared files under `@shared` live in the Expo project, whose root
  // tsconfig.json `extends "expo/tsconfig.base"`. esbuild otherwise walks up
  // from each imported ../utils/*.ts and tries to resolve that base config,
  // which isn't installed in this standalone web workspace. An explicit
  // tsconfigRaw stops that lookup; @vitejs/plugin-react handles JSX in src.
  esbuild: {
    // Must be a STRING: Vite only skips its per-file tsconfig lookup when
    // tsconfigRaw is a string (an object still triggers loadTsconfigJsonForFile
    // and the failing extends walk).
    tsconfigRaw: '{"compilerOptions":{"useDefineForClassFields":true}}',
  },
  resolve: {
    alias: {
      '@shared': fileURLToPath(new URL('..', import.meta.url)),
    },
  },
  server: {
    port: 5173,
  },
});
