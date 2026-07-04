// Stub for react-native/Libraries/NativeComponent/ViewConfigIgnore.
// The real file uses a Flow `const` generic type constraint that
// babel-preset-expo@12's bundled hermes-parser cannot parse.
// All three functions are identity/pass-through in the test environment.
module.exports = {
  DynamicallyInjectedByGestureHandler: (obj) => obj,
  ConditionallyIgnoredEventHandlers: (value) => value,
  isIgnored: () => false,
};
