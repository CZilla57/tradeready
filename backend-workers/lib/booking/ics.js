// backend-workers/lib/booking/ics.js
// Minimal RFC 5545 single-event calendar for a booked slot (Phase 11 D1).
// Served by GET /api/booking/manage?format=ics so "Add to calendar" is a
// plain link — no client-side generation, works in iOS Safari and Gmail.
// Times come from the slot's stored UTC instants (Z-form), so every
// calendar app localizes correctly regardless of the viewer's zone.

function icsTime(isoUtc) {
  return String(isoUtc).replace(/[-:]/g, '').replace(/\.\d{3}Z$/, 'Z');
}

// RFC 5545 §3.3.11 TEXT escaping: backslash, semicolon, comma, newline.
function icsEscape(s) {
  return String(s)
    .replace(/\\/g, '\\\\')
    .replace(/;/g, '\\;')
    .replace(/,/g, '\\,')
    .replace(/\r?\n/g, '\\n');
}

function buildIcs({ businessName, slot, uid }) {
  const lines = [
    'BEGIN:VCALENDAR',
    'VERSION:2.0',
    'PRODID:-//TradeReady//Booking//EN',
    'CALSCALE:GREGORIAN',
    'METHOD:PUBLISH',
    'BEGIN:VEVENT',
    `UID:${icsEscape(uid)}`,
    `DTSTAMP:${icsTime(slot.startUtc)}`,
    `DTSTART:${icsTime(slot.startUtc)}`,
    `DTEND:${icsTime(slot.endUtc)}`,
    `SUMMARY:Appointment — ${icsEscape(businessName)}`,
    'END:VEVENT',
    'END:VCALENDAR',
  ];
  return lines.join('\r\n') + '\r\n';
}

module.exports = { buildIcs };
