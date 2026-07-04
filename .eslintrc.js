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
    ".expo/",
    "dist/",
    "coverage/",
    "babel.config.js",
    "metro.config.js",
  ],
};
