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

// Floating-local-time single event for an owner-scheduled job appointment
// (Phase 12A). Owner-naive date/time strings carry no zone, so the event is
// emitted WITHOUT Z/TZID and calendar apps render it at face value in the
// viewer's zone — correct for a local-trades appointment. Booked-slot
// appointments keep using buildIcs above (real UTC instants). No start time
// → all-day event (DTEND exclusive per RFC 5545 §3.6.1).

function icsDate(ymd) {
  return String(ymd).replace(/-/g, '');
}

function icsFloating(ymd, hm) {
  return `${icsDate(ymd)}T${String(hm).replace(':', '')}00`;
}

function addMinutesClamped(hm, minutes) {
  const [h, m] = String(hm).split(':').map(Number);
  const total = Math.min(h * 60 + m + minutes, 23 * 60 + 59);
  return `${String(Math.floor(total / 60)).padStart(2, '0')}:${String(total % 60).padStart(2, '0')}`;
}

function nextDate(ymd) {
  const [y, m, d] = String(ymd).split('-').map(Number);
  return new Date(Date.UTC(y, m - 1, d) + 86_400_000).toISOString().slice(0, 10);
}

function buildJobIcs({ businessName, title, date, start, end, uid, stampUtc }) {
  const summary = icsEscape(title ? `${title} — ${businessName}` : `Appointment — ${businessName}`);
  const timing = start
    ? [
        `DTSTART:${icsFloating(date, start)}`,
        `DTEND:${icsFloating(date, end && end > start ? end : addMinutesClamped(start, 60))}`,
      ]
    : [
        `DTSTART;VALUE=DATE:${icsDate(date)}`,
        `DTEND;VALUE=DATE:${icsDate(nextDate(date))}`,
      ];
  const lines = [
    'BEGIN:VCALENDAR',
    'VERSION:2.0',
    'PRODID:-//TradeReady//Portal//EN',
    'CALSCALE:GREGORIAN',
    'METHOD:PUBLISH',
    'BEGIN:VEVENT',
    `UID:${icsEscape(uid)}`,
    `DTSTAMP:${icsTime(stampUtc)}`,
    ...timing,
    `SUMMARY:${summary}`,
    'END:VEVENT',
    'END:VCALENDAR',
  ];
  return lines.join('\r\n') + '\r\n';
}

module.exports = { buildIcs, buildJobIcs };
