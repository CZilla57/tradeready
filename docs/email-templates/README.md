# Auth email templates

Drafts for the two Supabase Auth emails that reach real users. They are pasted
into the dashboard, not built by the app — these files exist so the copy is
version-controlled and reviewable.

## Where they go

Supabase Dashboard → **Authentication → Emails → Templates**

| File | Template | Subject line |
|---|---|---|
| `confirm-signup.html` | Confirm signup | `Confirm your email to activate your TradeReady account` |
| `reset-password.html` | Reset password | `Reset your TradeReady password` |

Paste the file body (everything after the leading comment) into **Message body**
and set **Subject heading** to the line above. Changes take effect immediately —
no app rebuild, no OTA update.

## Why they're written this way

Both replace Supabase's stock one-line-plus-bare-link templates, which read as
spam to filters. The deliverability-relevant choices:

- **Real prose, not a lone link.** Link-only HTML is a strong spam signal.
- **No images.** Nothing to block, and no image-only-email penalty.
- **Sender identity in the footer** — product name, support address, links to
  the live Privacy Policy and Terms.
- **A "why you got this" line**, which is what filters look for to distinguish
  transactional mail from unsolicited mail.
- **Visible fallback URL** under the button — better UX, and it means the
  recipient can see the destination rather than only a wrapped button.
- **Inline styles, table layout, 480px max width** for client compatibility.

## Before pasting — two things to check

1. **Link expiry wording.** Both templates say "expires in 1 hour", matching the
   Supabase default of 3600 seconds (set to 1 hour deliberately, 2026-07-30).
   The setting is **Authentication → Sign In / Providers → Auth Providers →
   Email → Email OTP expiration** — it belongs to the Email *provider*, not to
   the Emails/Templates section, which is why it is easy to miss. One value
   governs confirmation, password-recovery, email-change and invite links, not
   just OTP codes. Re-check it after applying a migration: it has been reported
   to reset itself (supabase/supabase#43871). Wrong expiry copy generates
   support email — a user told "24 hours" who clicks at hour two just sees a
   dead link.
2. **Sender identity.** Under SMTP Settings, the sender email must be on
   `gettradereadyapp.com` (the DKIM-signed domain) or DMARC alignment fails no
   matter how good the template is. Confirmed 2026-07-30:
   `no-reply@gettradereadyapp.com`. Set a human sender **display name** too —
   that is separate from the address and is what recipients actually see.

## Known limitation

Supabase templates are a single HTML body — there is no field for a plain-text
alternative part, and multipart text/plain improves deliverability slightly.
Getting both parts requires the Send Email Hook (custom function that calls
Resend's API directly) instead of dashboard templates. Not worth it yet; revisit
only if inbox placement is still poor after DMARC is published.
