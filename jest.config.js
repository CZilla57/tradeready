module.exports = {
  preset: "jest-expo",
  setupFiles: ["./jest.setup.js"],
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
