# STAGED: homepage online-booking section (roadmap W6 — gated)

**Gate: do NOT publish until the calendar/booking client OTA has shipped to
users** (Phase 11 merged 2026-08-07 but rides the next `eas update` — standing
owner call). Publishing before users have the feature violates the claims rule.

When the gate opens: paste this section into `tradeready-legal/index.html`
after the "Sheet 05 — Works where you work" section (before the pricing
section), push, and verify live. Copy below was fact-checked 2026-08-07
against what Phase 11 actually shipped (booking link + slot picker from the
availability engine respecting working hours/buffers/blackout dates,
owner confirm/decline, customer manage page with reschedule/cancel).

```html
<section class="section" aria-labelledby="h-booking">
  <div class="sheet">
    <div class="copy">
      <span class="eyebrow">Sheet 06 — Get booked while you work</span>
      <h2 id="h-booking">Let customers book you online.</h2>
      <ul>
        <li><strong>Your own booking link</strong> — share it by text, or put it anywhere your customers find you</li>
        <li>Customers pick from <strong>real open slots</strong> — your working hours, buffers, and days off are respected automatically</li>
        <li><strong>You stay in control</strong> — confirm or decline every request, and the job lands on your calendar</li>
        <li>Customers can <strong>reschedule or cancel</strong> from their confirmation link — no phone tag</li>
      </ul>
    </div>
  </div>
</section>
```

Notes for the publishing session:
- No new external hosts are introduced, so the CSP allowlist needs no change.
- Consider pairing with a calendar-view screenshot (follow the webp
  regeneration contract in `tradeready-legal/images/README.md`).
- Also consider a matching NEW bullet on `/whats-new.html` for the OTA that
  delivers booking — source the wording from the ASC What's New at that
  submission, not from this file.
