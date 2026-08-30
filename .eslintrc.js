module.exports = {
  root: true,
  extends: ["expo"],
  env: {
    browser: false,
    node: true,
    jest: true,
  },
  rules: {
    // Allow console in RN — logging is common and useful on device
    "no-console": "off",
    // Expo native modules use namespace imports (import * as Foo from 'expo-foo')
    // but their exports aren't statically visible to ESLint, producing false positives.
    "import/namespace": "off",
  },
  ignorePatterns: [
    "node_modules/",
    "backend/node_modules/",
    // Separate package with its own deps + toolchain: the repo-root CI never
    // installs backend-workers/node_modules, so its ESM imports (hono, stripe)
    // can't resolve here (import/no-unresolved). Its gate is the wrangler
    // build + the parallel-run request diffs, not the app's eslint config.
    "backend-workers/",
    // Standalone web portal: its own package.json + Vite/React toolchain and
    // its own tsconfig/eslint story. The repo-root CI never installs
    // web/node_modules, so its browser imports (react-dom, react-router-dom)
    // can't resolve here — the app's RN eslint config is not its gate.
    "web/",
    ".expo/",
    ".jest-cache/",
    "dist/",
    "coverage/",
    "babel.config.js",
    "metro.config.js",
  ],
};
