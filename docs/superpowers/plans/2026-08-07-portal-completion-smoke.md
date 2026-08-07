# Portal Completion (Phase 12) — Owner Smoke Script

**Date:** 2026-08-07 · **Pre-reqs (all DONE per owner):** portal_access_log +
portal_tokens migrations applied; PORTAL_URL_SIGNING_SECRET set; Worker
deployed (must include Phase D — redeploy after the D merge if the last
deploy predates it). **Publish step 0 below before smoking.**

Feature may be CLAIMED (listing/marketing) only after this script passes
(claims discipline, tradeready-launch-readiness).

## 0. Publish the page
Push tradeready-legal `main` (commit `cb0329d`, held unpushed) → CF Pages
deploys. Verify https://gettradereadyapp.com/portal.html loads (shows "This
link is missing information…" with no `?p=`).

## 1. Existing link still works (legacy fallback + lazy backfill)
Open your existing customer's portal link (pre-Phase-D token).
- [ ] Page renders; Estimates + Invoices look unchanged.
- [ ] NEW: any scheduled job for this customer shows under "Upcoming
      appointments"; unpaid invoice with partial payment shows "$X paid ·
      $Y due of $Z".
- [ ] Supabase → portal_tokens: a row now EXISTS for this customer (the
      lazy backfill from your page view). portal_access_log has `view` rows.

## 2. Add to calendar
- [ ] Appointment card → "Add to calendar" downloads appointment.ics; it
      imports at the right local date/time (floating time — no zone shift).

## 3. Photos (visibility + signed URLs + expiry)
In the app: JobDetail of that customer's job → photo strip → tap the eye
badge on ONE photo (turns green).
- [ ] Reload portal: that photo (and ONLY that one) appears under Photos.
- [ ] Tap it — full size opens.
- [ ] Copy the photo's URL, wait >15 min (or edit `e=` param −1000), open →
      `{"error":"This link is invalid."}`.
- [ ] Toggle the eye off → reload portal → photo gone.

## 4. Change order from the portal
Create a CO on the customer's job, send its link (this stamps approval.token).
- [ ] Portal "Changes" section lists it as "Awaiting your approval" with the
      signed +/− amount; "Review & approve" opens change.html; approve →
      portal reloads to "Approved".

## 5. Request follow-up work (the write path)
Portal → "Need something else?" → keep "Request follow-up work", type a note,
Send.
- [ ] Green "Request sent" confirmation.
- [ ] Owner push notification arrives; a new LEAD job appears for the SAME
      customer record (no duplicate customer).
- [ ] Send again immediately with the same note → a SECOND lead (new
      requestKey per send — expected). Refresh-and-resend of a FAILED send
      would not duplicate (idempotency) — skip unless curious.
- [ ] Send 5+ requests → 6th shows "Too many requests today." (durable cap;
      portal_access_log has a `denied` row).

## 6. Reschedule request on an owner-scheduled appointment
Pick the select option "Reschedule: <job> (<date>)", add a note, Send.
- [ ] NO new lead is created.
- [ ] Today tab shows "<customer> asked to reschedule an appointment" →
      tapping it shows the templated detail + your note → "View job" lands
      on the job WITH a back button → "Done" dismisses; row stays gone
      after app restart (synced handledAt).

## 7. Instant revocation (the Phase D feature)
CustomerDetail → portal section:
- [ ] Toggle "Portal enabled" OFF → portal reloads to "This link is
      invalid." IMMEDIATELY (no sync wait). Toggle ON → works again.
- [ ] "Get a new link" (confirm) → OLD link is dead immediately; NEW link
      works. (portal_tokens: old row has revoked_at set.)
- [ ] Second-device guard (optional): from a device that hasn't synced,
      "Create portal link" on the same customer → "Portal link already
      exists" alert, existing link unharmed.

## 8. Booked-appointment manage handoff
If a booking-originated appointment exists: its card shows "Confirm or
change" → lands on booking.html manage (Phase 11 flow, unchanged).

**Any failure:** stop, note the step + exact on-screen text, and report —
don't retry destructive steps (rotate) repeatedly.
