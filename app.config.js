/* eslint-disable @typescript-eslint/no-require-imports */
const appJson = require("./app.json");

module.exports = {
  ...appJson.expo,
  extra: {
    ...appJson.expo.extra,
    posthogProjectToken: process.env.POSTHOG_PROJECT_TOKEN,
    posthogHost: process.env.POSTHOG_HOST || "https://us.i.posthog.com",
  },
};
