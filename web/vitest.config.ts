import { mergeConfig, defineConfig } from 'vitest/config';
import viteConfig from './vite.config';

// Reuse the app's Vite config (notably the `@shared` alias and the esbuild
// tsconfigRaw workaround) so tests resolve modules exactly as the app does,
// then layer the jsdom + Testing Library setup on top.
export default mergeConfig(
  viteConfig,
  defineConfig({
    test: {
      globals: true,
      environment: 'jsdom',
      setupFiles: ['./src/test/setup.ts'],
      css: false,
      include: ['src/**/*.test.{ts,tsx}'],
    },
  }),
);
