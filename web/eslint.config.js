import js from '@eslint/js';
import globals from 'globals';
import tseslint from 'typescript-eslint';
import reactHooks from 'eslint-plugin-react-hooks';
import reactRefresh from 'eslint-plugin-react-refresh';

// Standalone web-portal ESLint config. The repo root's `.eslintrc.js` ignores
// `web/` (its Expo/React-Native rules don't fit a browser React app), so this
// is the portal's own independent gate: `npm run lint` here, and the web leg of
// the CI workflow. React 19 + TypeScript + the browser + a Node-based build.
export default tseslint.config(
  { ignores: ['dist', 'node_modules', 'coverage'] },
  {
    files: ['**/*.{ts,tsx}'],
    extends: [js.configs.recommended, ...tseslint.configs.recommended],
    languageOptions: {
      ecmaVersion: 2022,
      globals: globals.browser,
      parserOptions: {
        ecmaFeatures: { jsx: true },
      },
    },
    plugins: {
      'react-hooks': reactHooks,
      'react-refresh': reactRefresh,
    },
    rules: {
      ...reactHooks.configs.recommended.rules,
      'react-refresh/only-export-components': [
        'warn',
        { allowConstantExport: true },
      ],
      '@typescript-eslint/no-unused-vars': [
        'error',
        { argsIgnorePattern: '^_', varsIgnorePattern: '^_' },
      ],
    },
  },
  // Context modules deliberately export a Provider component alongside their
  // hook(s) — the canonical React Context pattern. Fast Refresh's
  // component-only rule doesn't fit them, and splitting the hook into a second
  // file to satisfy a dev-only HMR nicety isn't worth it.
  {
    files: ['src/lib/**/*Context.tsx'],
    rules: { 'react-refresh/only-export-components': 'off' },
  },
  // Config files and the build tooling run in Node, not the browser.
  {
    files: ['*.config.{ts,js}'],
    languageOptions: { globals: globals.node },
  },
  // Tests use Vitest globals (describe/it/expect/vi) enabled in vitest.config.
  {
    files: ['**/*.test.{ts,tsx}', 'src/test/**'],
    languageOptions: { globals: { ...globals.browser, ...globals.node } },
  },
);
