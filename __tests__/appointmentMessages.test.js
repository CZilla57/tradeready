// __tests__/appointmentMessages.test.js
// Pure logic for appointment/on-my-way reminders. No Expo/RN imports here, so
// this runs entirely under the app Jest with no mocking.
import {
  DEFAULT_CONFIRM_TEMPLATE,
  renderTemplate,
  resolveChannel,
  formatApptDateTime,
  selectAppointmentReminders,
} from "../utils/appointmentMessages";

// A local date so fireDate math is timezone-independent.
const NOW = new Date(2026, 6, 17, 9, 0, 0); // 2026-07-17 09:00 local

function job(overrides = {}) {
  return {
    id: "j1",
    customerId: "c1",
    customerName: "Alice",
    status: "scheduled",
    scheduledDate: "2026-07-19", // 2 days out
    scheduledStartTime: "09:00",
    scheduledEndTime: "11:00",
    address: "12 Oak St",
    ...overrides,
  };
}
function customer(overrides = {}) {
  return { id: "c1", name: "Alice", email: "a@x.com", phone: "5551234567", address: "12 Oak St", ...overrides };
}
const settings = {
  appointmentRemindersEnabled: true,
  appointmentConfirmTemplate: DEFAULT_CONFIRM_TEMPLATE,
  businessName: "Bob Plumbing",
};

describe("renderTemplate", () => {
  test("replaces every provided placeholder globally", () => {
    const out = renderTemplate("Hi {customerName} from {businessName} on {date}", {
      customerName: "Alice",
      businessName: "Bob Plumbing",
      date: "Sunday, July 19",
    });
    expect(out).toBe("Hi Alice from Bob Plumbing on Sunday, July 19");
  });

  test("leaves unknown placeholders untouched (surfaces typos)", () => {
    expect(renderTemplate("Hi {nope}", { customerName: "Alice" })).toBe("Hi {nope}");
  });

  test("empty var renders as empty string", () => {
    expect(renderTemplate("at {time}!", { time: "" })).toBe("at !");
  });

  test("treats a $ in the value as literal text (no replacement-pattern injection)", () => {
    expect(renderTemplate("Hi {customerName}", { customerName: "Cash$1 Services" })).toBe("Hi Cash$1 Services");
  });
});

describe("resolveChannel", () => {
  test("prefers SMS when a phone exists", () => {
    expect(resolveChannel({ phone: "5551234567", email: "a@x.com" })).toBe("sms");
  });
  test("falls back to email when no phone", () => {
    expect(resolveChannel({ phone: "", email: "a@x.com" })).toBe("email");
  });
  test("blank/whitespace phone is treated as absent", () => {
    expect(resolveChannel({ phone: "   ", email: "a@x.com" })).toBe("email");
  });
  test("none when neither is present", () => {
    expect(resolveChannel({ phone: "", email: "" })).toBe("none");
  });
});

describe("formatApptDateTime", () => {
  test("formats date and a present start time", () => {
    const { date, time } = formatApptDateTime("2026-07-19", "09:00");
    expect(date).toBe("Sunday, July 19");
    expect(time).toBe("9:00 AM");
  });
  test("missing start time falls back to a neutral phrase", () => {
    const { time } = formatApptDateTime("2026-07-19", null);
    expect(time).toBe("the scheduled time");
  });
});

describe("selectAppointmentReminders", () => {
  test("returns a reminder for a qualifying job, firing 5pm the day before", () => {
    const out = selectAppointmentReminders([job()], [customer()], settings, NOW);
    expect(out).toHaveLength(1);
    expect(out[0].jobId).toBe("j1");
    // 5pm local on 2026-07-18 (day before the 07-19 job)
    expect(out[0].fireDate).toEqual(new Date(2026, 6, 18, 17, 0, 0, 0));
    expect(out[0].body).toContain("Alice");
  });

  test("returns [] when the toggle is off", () => {
    expect(selectAppointmentReminders([job()], [customer()], { ...settings, appointmentRemindersEnabled: false }, NOW)).toEqual([]);
  });

  test("excludes terminal statuses", () => {
    expect(selectAppointmentReminders([job({ status: "complete" })], [customer()], settings, NOW)).toEqual([]);
    expect(selectAppointmentReminders([job({ status: "paid" })], [customer()], settings, NOW)).toEqual([]);
  });

  test("excludes jobs whose customer has no contact info", () => {
    expect(selectAppointmentReminders([job()], [customer({ phone: "", email: "" })], settings, NOW)).toEqual([]);
  });

  test("excludes jobs with no scheduledDate", () => {
    expect(selectAppointmentReminders([job({ scheduledDate: null })], [customer()], settings, NOW)).toEqual([]);
  });

  test("excludes a job whose customer can't be resolved at all", () => {
    expect(selectAppointmentReminders([job({ customerId: "missing", customerName: "Nobody" })], [], settings, NOW)).toEqual([]);
  });

  test("drops reminders whose 5pm-day-before is already past", () => {
    // Job is tomorrow (07-18); 5pm the day before is 07-17 17:00, but NOW is 07-17 09:00,
    // so it is still in the future — keep. Make the job today to force a past fireDate.
    const past = selectAppointmentReminders([job({ scheduledDate: "2026-07-17" })], [customer()], settings, NOW);
    expect(past).toEqual([]);
  });

  test("orders results by fireDate (soonest first)", () => {
    const soon = job({ id: "soon", scheduledDate: "2026-07-19" });
    const later = job({ id: "later", scheduledDate: "2026-07-25" });
    const out = selectAppointmentReminders([later, soon], [customer(), customer()], settings, NOW);
    expect(out.map((r) => r.jobId)).toEqual(["soon", "later"]);
  });
});
