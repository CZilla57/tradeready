// Runs once, before any worker starts, so every test process inherits this TZ.
//
// The suite runs in a west-of-UTC zone on purpose. That is what exposes the FA-039
// class of bugs (`new Date("YYYY-MM-DD")` parses as UTC midnight, then local getters
// read the previous day), and `__tests__/phase10QualificationOracle.test.js` asserts
// this exact zone as a precondition. Without it the oracle failed on CI (no TZ set)
// and on any dev machine that was not already running `TZ=America/Phoenix npm test`.
//
// Setting it in a test file does not work: Jest gives each test file a copy of
// process.env, so the real process timezone would not change.
module.exports = async () => {
  process.env.TZ = "America/Phoenix";
};
