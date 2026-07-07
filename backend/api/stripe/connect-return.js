// GET — landing page Stripe redirects to after the Connect onboarding form.
// ?status=complete  — user finished onboarding
// ?status=refresh   — onboarding link expired; user needs to start over in the app
//
// The mobile app uses AppState to detect the return-to-foreground event and
// re-checks connect-status — no deep link or callback token needed.

module.exports = function handler(req, res) {
  const status = req.query?.status;
  const isComplete = status === 'complete';

  const title = isComplete ? 'Stripe account connected!' : 'Session expired';
  const message = isComplete
    ? 'Your Stripe account is connected. Return to the TradeReady app — you\'re ready to accept payments.'
    : 'Your onboarding session has expired. Return to the TradeReady app and tap "Connect Stripe account" to try again.';

  res.setHeader('Content-Type', 'text/html; charset=utf-8');
  return res.status(200).send(`<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${title} — TradeReady</title>
  <style>
    *, *::before, *::after { box-sizing: border-box; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
      display: flex; flex-direction: column; align-items: center;
      justify-content: center; min-height: 100vh; margin: 0;
      background: #f5f5f7; color: #1d1d1f; text-align: center; padding: 24px;
    }
    .icon { font-size: 48px; margin-bottom: 16px; }
    h1 { font-size: 22px; font-weight: 700; margin: 0 0 10px; }
    p { font-size: 15px; color: #6e6e73; max-width: 300px; line-height: 1.6; margin: 0; }
  </style>
</head>
<body>
  <div class="icon">${isComplete ? '✅' : '⏱️'}</div>
  <h1>${title}</h1>
  <p>${message}</p>
</body>
</html>`);
};
