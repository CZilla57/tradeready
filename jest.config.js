module.exports = {
  preset: "jest-expo",
  setupFiles: ["./jest.setup.js"],
  // A component suite's first render pays the one-time Babel transform of the
  // graph's lazily-required RN modules inside that test's timeout budget. On a
  // cold cache (CI always; locally after --no-cache) that exceeds Jest's 5s
  // default — AddExpenseModal's first test measured 6.1s cold on the dev
  // machine, and it failed every CI run once the app's import graph grew past
  // the threshold (2026-08-01). Not a hang: warm it's ~0.8s, later tests ~30ms.
  testTimeout: 15000,
  transformIgnorePatterns: [
    "node_modules/(?!((jest-)?react-native|@react-native(-community)?)|expo(nent)?|@expo(nent)?/.*|@expo-google-fonts/.*|react-navigation|@react-navigation/.*|@unimodules/.*|unimodules|sentry-expo|@sentry/.*|native-base|react-native-svg|posthog-react-native)",
  ],
  moduleFileExtensions: ["ts", "tsx", "js", "jsx", "json"],
  moduleNameMapper: {
    // babel-preset-expo@12's bundled hermes-parser can't handle the Flow
    // `const` type-parameter constraint introduced in react-native@0.81.
    // The mapper intercepts the raw require string (which is a relative
    // "./ViewConfigIgnore" inside react-native itself), so we match by
    // filename substring rather than full package path.
    "ViewConfigIgnore": "<rootDir>/__mocks__/rn-ViewConfigIgnore.js",
  },
  collectCoverageFrom: [
    "utils/**/*.{js,ts}",
    "components/**/*.{js,jsx,ts,tsx}",
    "screens/**/*.{js,jsx,ts,tsx}",
    "context/**/*.{js,jsx,ts,tsx}",
    "hooks/**/*.{js,ts}",
    "!**/__tests__/**",
    "!**/node_modules/**",
  ],
};
