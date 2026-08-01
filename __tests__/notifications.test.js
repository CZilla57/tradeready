// __tests__/notifications.test.js
// Tests for syncNotifications — the function that schedules local push
// notifications for overdue invoices.
//
// Key invariants:
//   - Only unpaid invoices produce scheduled notifications.
//   - Invoices whose reminder threshold is already past are skipped.
//   - All existing notifications are cancelled before rescheduling.
//   - Permissions denied → nothing is scheduled.

import AsyncStorage from "@react-native-async-storage/async-storage";
import * as Notifications from "expo-notifications";
import { syncNotifications } from "../utils/notifications";

// Helper: returns a YYYY-MM-DD string N days from today.
function dateInDays(offsetDays) {
  const d = new Date();
  d.setDate(d.getDate() + offsetDays);
  return d.toISOString().split("T")[0];
}

// Populates AsyncStorage mock so syncNotifications reads the right invoices/settings/jobs/customers/recurring-invoice rules.
function seedStorage(invoices, settings = { rules: [{ days: 1 }] }, jobs = [], customers = [], recurringInvoices = []) {
  AsyncStorage.getItem.mockImplementation((key) => {
    if (key === "invoices") return Promise.resolve(JSON.stringify(invoices));
    if (key === "settings") return Promise.resolve(JSON.stringify(settings));
    if (key === "jobs") return Promise.resolve(JSON.stringify(jobs));
    if (key === "customers") return Promise.resolve(JSON.stringify(customers));
    if (key === "recurringInvoices") return Promise.resolve(JSON.stringify(recurringInvoices));
    return Promise.resolve(null);
  });
}

beforeEach(() => {
  jest.clearAllMocks();
  // Default: permissions granted. Individual tests can override.
  Notifications.getPermissionsAsync.mockResolvedValue({ status: "granted" });
  AsyncStorage.getItem.mockResolvedValue(null);
});

// ── Permission guard ───────────────────────────────────────────────────────────

describe("permission guard", () => {
  test("does nothing when notification permission is denied", async () => {
    Notifications.getPermissionsAsync.mockResolvedValueOnce({ status: "denied" });

    await syncNotifications();

    expect(Notifications.cancelAllScheduledNotificationsAsync).not.toHaveBeenCalled();
    expect(Notifications.scheduleNotificationAsync).not.toHaveBeenCalled();
  });

  test("cancels then reschedules when permission is granted", async () => {
    seedStorage([]); // no invoices — just verifying the cancel call fires

    await syncNotifications();

    expect(Notifications.cancelAllScheduledNotificationsAsync).toHaveBeenCalledTimes(1);
  });
});

// ── Paid vs unpaid filtering ───────────────────────────────────────────────────

describe("paid vs unpaid invoice filtering", () => {
  // NOTE: `amount` is load-bearing now. Notification scheduling asks whether
  // an invoice is settled, which the ledger answers from the balance — an
  // invoice with no amount owes nothing and is never chased. These tests are
  // about SCHEDULING, so they need invoices that actually owe something.
  test("schedules a notification for an unpaid invoice with a future threshold", async () => {
    seedStorage([
      { id: "i1", customer: "Alice", number: "INV-001", paid: false, amount: 500, due: dateInDays(30) },
    ]);

    await syncNotifications();

    expect(Notifications.scheduleNotificationAsync).toHaveBeenCalledTimes(1);
    const [call] = Notifications.scheduleNotificationAsync.mock.calls;
    expect(call[0].content.title).toContain("Alice");
    expect(call[0].content.body).toContain("INV-001");
  });

  test("skips paid invoices entirely", async () => {
    seedStorage([
      { id: "i1", customer: "Bob", number: "INV-002", paid: true, amount: 500, due: dateInDays(30) },
    ]);

    await syncNotifications();

    expect(Notifications.scheduleNotificationAsync).not.toHaveBeenCalled();
  });

  test("schedules only for unpaid when the list contains a mix", async () => {
    seedStorage([
      { id: "i1", customer: "Alice", number: "INV-001", paid: false, amount: 500, due: dateInDays(30) },
      { id: "i2", customer: "Bob",   number: "INV-002", paid: true,  amount: 500, due: dateInDays(30) },
      { id: "i3", customer: "Carol", number: "INV-003", paid: false, amount: 500, due: dateInDays(30) },
    ]);

    await syncNotifications();

    // Two unpaid (Alice + Carol), one paid (Bob) — expect 2 notifications
    expect(Notifications.scheduleNotificationAsync).toHaveBeenCalledTimes(2);
    const titles = Notifications.scheduleNotificationAsync.mock.calls.map(
      (c) => c[0].content.title
    );
    expect(titles.some((t) => t.includes("Alice"))).toBe(true);
    expect(titles.some((t) => t.includes("Carol"))).toBe(true);
    expect(titles.every((t) => !t.includes("Bob"))).toBe(true);
  });

  test("an invoice with nothing owed is never chased", async () => {
    // Deliberate: the ledger answers "settled?" from the balance, so a $0
    // invoice is never overdue and never reminded. Not reachable in-app —
    // Invoice.amount is required and both creation screens reject amount <= 0.
    seedStorage([
      { id: "i1", customer: "Alice", number: "INV-001", paid: false, amount: 0, due: dateInDays(30) },
    ]);

    await syncNotifications();

    expect(Notifications.scheduleNotificationAsync).not.toHaveBeenCalled();
  });
});

// ── Threshold date handling ───────────────────────────────────────────────────

describe("threshold date handling", () => {
  test("skips invoices whose fire date is already in the past", async () => {
    // Due 2020-01-01 + 1 day rule → fire date 2020-01-02 9am → already past
    seedStorage([
      { id: "i1", customer: "Alice", number: "INV-001", paid: false, amount: 500, due: "2020-01-01" },
    ]);

    await syncNotifications();

    expect(Notifications.scheduleNotificationAsync).not.toHaveBeenCalled();
  });

  test("schedules one notification per rule when multiple rules apply", async () => {
    seedStorage(
      [{ id: "i1", customer: "Alice", number: "INV-001", paid: false, amount: 500, due: dateInDays(30) }],
      { rules: [{ days: 1 }, { days: 7 }] }
    );

    await syncNotifications();

    // One invoice × two future rules = two notifications
    expect(Notifications.scheduleNotificationAsync).toHaveBeenCalledTimes(2);
  });

  // Regression (Fix A, 2026-08-01): the fire date must be parsed in the LOCAL
  // frame (`due + 'T00:00:00'`), not UTC-midnight (`due` alone) — the old
  // parse fired 9am local on the day BEFORE the intended date in every US
  // timezone. Self-consistent + TZ-portable: the expected fire instant is
  // computed here with the exact same formula the source uses, then bracketed
  // around the real "now" captured immediately before/after the call so the
  // assertion can't flake on elapsed test-runner milliseconds.
  test("inv_: fires 9am LOCAL on due+days, not a day earlier (local-frame parse)", async () => {
    const due = dateInDays(5);
    seedStorage(
      [{ id: "iLF", customer: "Alice", number: "INV-LF", paid: false, amount: 500, due }],
      { rules: [{ days: 1 }] }
    );

    const before = Date.now();
    await syncNotifications();
    const after = Date.now();

    const expectedFire = new Date(due + "T00:00:00");
    expectedFire.setDate(expectedFire.getDate() + 1);
    expectedFire.setHours(9, 0, 0, 0);
    const minSeconds = Math.floor((expectedFire.getTime() - after) / 1000);
    const maxSeconds = Math.floor((expectedFire.getTime() - before) / 1000);

    const [call] = Notifications.scheduleNotificationAsync.mock.calls;
    expect(call[0].identifier).toBe("inv_iLF_1d");
    expect(call[0].trigger.seconds).toBeGreaterThanOrEqual(minSeconds);
    expect(call[0].trigger.seconds).toBeLessThanOrEqual(maxSeconds);

    // Frame-independent pin (2026-08-01): the bracket check above only shows
    // the source and this test's mirror formula AGREE — it can't catch a bug
    // shared by both. Pin the semantic directly: 9am local, on due+1 day.
    // due is dateInDays(5), far from a month boundary, so +1 day never rolls
    // the month/year and this can be checked from due's own string digits
    // without going through another Date construction.
    const [, , dueD] = due.split("-").map(Number);
    expect(expectedFire.getHours()).toBe(9);
    expect(expectedFire.getDate()).toBe(dueD + 1);
  });
});

// ── Malformed / non-strict-ISO due dates (Finding 1, 2026-08-01) ────────────
//
// inv.due comes from a free-text Field (AddInvoiceScreen) with no format
// validation. Before this fix, `new Date(inv.due + 'T00:00:00')` produced
// Invalid Date for anything but strict "YYYY-MM-DD"; the resulting NaN
// `secondsUntil` slipped past `if (secondsUntil <= 0) continue` (NaN <= 0 is
// false) and reached scheduleNotificationAsync as `{ seconds: NaN }`. A
// native rejection there was swallowed by the sweep's outer catch — which
// runs AFTER cancelAllScheduledNotificationsAsync(), so one malformed
// invoice could wipe every reminder in the sweep.

describe("malformed / non-strict-ISO due dates", () => {
  test("inv_: a non-ISO due date (M/D/YYYY) still fires 9am local via the parseLocalDate fallback", async () => {
    // Built from dateInDays(5) and reformatted M/D/YYYY (mirrors the
    // "8/15/2026" example from the review finding) so this stays
    // deterministic and never rots with the calendar.
    const isoDue = dateInDays(5);
    const [y, m, d] = isoDue.split("-").map(Number);
    const slashDue = `${m}/${d}/${y}`;
    seedStorage(
      [{ id: "iSlash", customer: "Alice", number: "INV-SLASH", paid: false, amount: 500, due: slashDue }],
      { rules: [{ days: 1 }] }
    );

    const before = Date.now();
    await syncNotifications();
    const after = Date.now();

    // parseLocalDate's fallback for a non-strict-ISO string is `new
    // Date(raw)`, same as here.
    const expectedFire = new Date(slashDue);
    expectedFire.setDate(expectedFire.getDate() + 1);
    expectedFire.setHours(9, 0, 0, 0);
    const minSeconds = Math.floor((expectedFire.getTime() - after) / 1000);
    const maxSeconds = Math.floor((expectedFire.getTime() - before) / 1000);

    expect(Notifications.scheduleNotificationAsync).toHaveBeenCalledTimes(1);
    const [call] = Notifications.scheduleNotificationAsync.mock.calls;
    expect(call[0].identifier).toBe("inv_iSlash_1d");
    expect(call[0].trigger.seconds).toBeGreaterThanOrEqual(minSeconds);
    expect(call[0].trigger.seconds).toBeLessThanOrEqual(maxSeconds);
    expect(expectedFire.getHours()).toBe(9);
    expect(expectedFire.getDate()).toBe(d + 1);
  });

  test("inv_: a garbage due date schedules nothing for itself and does not block a valid invoice in the same sweep", async () => {
    seedStorage(
      [
        { id: "iBad", customer: "Bad", number: "INV-BAD", paid: false, amount: 500, due: "notadate" },
        { id: "iGood", customer: "Good", number: "INV-GOOD", paid: false, amount: 500, due: dateInDays(30) },
      ],
      { rules: [{ days: 1 }] }
    );

    await syncNotifications();

    // The sweep still ran (cancel fired) and the malformed invoice's NaN
    // fire date didn't throw, didn't reach scheduleNotificationAsync, and
    // didn't stop the good invoice from getting its reminder — the
    // wipe-everything scenario is dead.
    expect(Notifications.cancelAllScheduledNotificationsAsync).toHaveBeenCalledTimes(1);
    expect(Notifications.scheduleNotificationAsync).toHaveBeenCalledTimes(1);
    const ids = Notifications.scheduleNotificationAsync.mock.calls.map((c) => c[0].identifier);
    expect(ids).not.toContain("inv_iBad_1d");
    expect(ids).toContain("inv_iGood_1d");
  });
});

// ── Notification identifier format ───────────────────────────────────────────

describe("notification identifier", () => {
  test("uses the format inv_{invoiceId}_{days}d", async () => {
    seedStorage(
      [{ id: "i42", customer: "Alice", number: "INV-001", paid: false, amount: 500, due: dateInDays(30) }],
      { rules: [{ days: 7 }] }
    );

    await syncNotifications();

    expect(Notifications.scheduleNotificationAsync).toHaveBeenCalledWith(
      expect.objectContaining({ identifier: "inv_i42_7d" })
    );
  });
});

// ── Auto-outreach (actionable notifications) ─────────────────────────────────

describe("auto-outreach toggle", () => {
  test("adds overdue_outreach type + daysPastDue to data when enabled", async () => {
    seedStorage(
      [{ id: "i7", customer: "Alice", number: "INV-007", paid: false, amount: 500, due: dateInDays(30) }],
      { rules: [{ days: 7 }], autoOutreachEnabled: true }
    );

    await syncNotifications();

    const [call] = Notifications.scheduleNotificationAsync.mock.calls;
    expect(call[0].content.data).toEqual({
      type: "overdue_outreach",
      invoiceId: "i7",
      daysPastDue: 7,
    });
    expect(call[0].content.body).toContain("INV-007");
  });

  test("keeps the plain reminder (no type) when disabled", async () => {
    seedStorage(
      [{ id: "i7", customer: "Alice", number: "INV-007", paid: false, amount: 500, due: dateInDays(30) }],
      { rules: [{ days: 7 }], autoOutreachEnabled: false }
    );

    await syncNotifications();

    const [call] = Notifications.scheduleNotificationAsync.mock.calls;
    expect(call[0].content.data).toEqual({ invoiceId: "i7" });
    expect(call[0].content.data.type).toBeUndefined();
  });

  test("defaults to the plain reminder when the flag is absent", async () => {
    seedStorage(
      [{ id: "i7", customer: "Alice", number: "INV-007", paid: false, amount: 500, due: dateInDays(30) }],
      { rules: [{ days: 7 }] } // no autoOutreachEnabled key — mirrors a pre-existing user
    );

    await syncNotifications();

    const [call] = Notifications.scheduleNotificationAsync.mock.calls;
    expect(call[0].content.data.type).toBeUndefined();
  });
});

// ── Job-completion gating for pre-work deposit invoices ─────────────────────

describe("job-completion gating (pre-work deposits)", () => {
  test("an unpaid deposit invoice on a job that hasn't started is NOT chased", async () => {
    seedStorage(
      [{ id: "i1", customer: "Alice", number: "INV-001", paid: false, amount: 500, due: dateInDays(30), jobId: "job1" }],
      { rules: [{ days: 1 }] },
      [{ id: "job1", status: "scheduled" }],
    );

    await syncNotifications();

    expect(Notifications.scheduleNotificationAsync).not.toHaveBeenCalled();
  });

  test("the same invoice becomes chaseable once its job is complete", async () => {
    seedStorage(
      [{ id: "i1", customer: "Alice", number: "INV-001", paid: false, amount: 500, due: dateInDays(30), jobId: "job1" }],
      { rules: [{ days: 1 }] },
      [{ id: "job1", status: "complete" }],
    );

    await syncNotifications();

    expect(Notifications.scheduleNotificationAsync).toHaveBeenCalledWith(
      expect.objectContaining({ identifier: "inv_i1_1d" })
    );
  });

  test("an invoice with no linked job is unaffected (unchanged behavior)", async () => {
    seedStorage(
      [{ id: "i1", customer: "Alice", number: "INV-001", paid: false, amount: 500, due: dateInDays(30) }],
      { rules: [{ days: 1 }] },
      [],
    );

    await syncNotifications();

    expect(Notifications.scheduleNotificationAsync).toHaveBeenCalledWith(
      expect.objectContaining({ identifier: "inv_i1_1d" })
    );
  });

  test("an invoice whose linked job can no longer be found is still chased (fail-open)", async () => {
    seedStorage(
      [{ id: "i1", customer: "Alice", number: "INV-001", paid: false, amount: 500, due: dateInDays(30), jobId: "deleted-job" }],
      { rules: [{ days: 1 }] },
      [],
    );

    await syncNotifications();

    expect(Notifications.scheduleNotificationAsync).toHaveBeenCalledWith(
      expect.objectContaining({ identifier: "inv_i1_1d" })
    );
  });
});

// ── Appointment confirmations ────────────────────────────────────────────────

describe("syncNotifications — appointment confirmations", () => {
  function apptJob(overrides = {}) {
    return {
      id: "j1", customerId: "c1", customerName: "Alice", status: "scheduled",
      scheduledDate: dateInDays(3), scheduledStartTime: "09:00", scheduledEndTime: "11:00",
      address: "12 Oak St", ...overrides,
    };
  }
  const cust = { id: "c1", name: "Alice", phone: "5551234567", email: "a@x.com", address: "12 Oak St" };
  const apptSettings = {
    rules: [], appointmentRemindersEnabled: true,
    appointmentConfirmTemplate: "", businessName: "Bob Plumbing",
  };

  test("schedules an appointment_confirm notification for a qualifying job", async () => {
    Notifications.getPermissionsAsync.mockResolvedValue({ status: "granted" });
    seedStorage([], apptSettings, [apptJob()], [cust]);
    await syncNotifications();
    const calls = Notifications.scheduleNotificationAsync.mock.calls.map((c) => c[0]);
    const appt = calls.find((c) => c.identifier === "appt_j1");
    expect(appt).toBeTruthy();
    expect(appt.content.data).toEqual({ type: "appointment_confirm", jobId: "j1" });
  });

  test("schedules nothing when the toggle is off", async () => {
    Notifications.getPermissionsAsync.mockResolvedValue({ status: "granted" });
    seedStorage([], { ...apptSettings, appointmentRemindersEnabled: false }, [apptJob()], [cust]);
    await syncNotifications();
    const ids = Notifications.scheduleNotificationAsync.mock.calls.map((c) => c[0].identifier);
    expect(ids).not.toContain("appt_j1");
  });
});

// ── Recurring-invoice (maintenance plan) reminders ───────────────────────────

describe("syncNotifications — recurring-invoice rules", () => {
  function riRule(overrides = {}) {
    return {
      id: "ri1", customerId: "c1", customerName: "Alice",
      description: "Monthly maintenance", amount: 150, dueDays: 30,
      cadence: "monthly", endCondition: "never",
      occurrenceCount: 0, lastGeneratedDate: null,
      nextDueDate: dateInDays(5), isActive: true, createdAt: dateInDays(-30),
      ...overrides,
    };
  }

  test("schedules one rinv_ notification per active rule with the exact content", async () => {
    seedStorage([], { rules: [] }, [], [], [riRule()]);

    await syncNotifications();

    expect(Notifications.scheduleNotificationAsync).toHaveBeenCalledTimes(1);
    const [call] = Notifications.scheduleNotificationAsync.mock.calls;
    expect(call[0].identifier).toBe("rinv_ri1");
    expect(call[0].content.title).toBe("Maintenance invoice ready — Alice");
    expect(call[0].content.body).toBe("Open to review & send.");
    expect(call[0].content.data).toEqual({ type: "recurring_invoice", ruleId: "ri1" });
  });

  test("paused rules schedule nothing", async () => {
    seedStorage([], { rules: [] }, [], [], [riRule({ isActive: false })]);

    await syncNotifications();

    expect(Notifications.scheduleNotificationAsync).not.toHaveBeenCalled();
  });

  test("a rule whose 9am fire time is already past is skipped", async () => {
    seedStorage([], { rules: [] }, [], [], [riRule({ nextDueDate: dateInDays(-1) })]);

    await syncNotifications();

    expect(Notifications.scheduleNotificationAsync).not.toHaveBeenCalled();
  });

  // Regression (Fix A, 2026-08-01): same local-frame parse fix as inv_ above,
  // applied to rule.nextDueDate. Bracketed against real "now" for the same
  // flake-proofing reason.
  test("rinv_: fires 9am LOCAL on nextDueDate, not a day earlier (local-frame parse)", async () => {
    const nextDueDate = dateInDays(5);
    seedStorage([], { rules: [] }, [], [], [riRule({ nextDueDate })]);

    const before = Date.now();
    await syncNotifications();
    const after = Date.now();

    const expectedFire = new Date(nextDueDate + "T00:00:00");
    expectedFire.setHours(9, 0, 0, 0);
    const minSeconds = Math.floor((expectedFire.getTime() - after) / 1000);
    const maxSeconds = Math.floor((expectedFire.getTime() - before) / 1000);

    const [call] = Notifications.scheduleNotificationAsync.mock.calls;
    expect(call[0].identifier).toBe("rinv_ri1");
    expect(call[0].trigger.seconds).toBeGreaterThanOrEqual(minSeconds);
    expect(call[0].trigger.seconds).toBeLessThanOrEqual(maxSeconds);

    // Frame-independent pin (2026-08-01), same rationale as the inv_ test
    // above: pin 9am local on nextDueDate itself, checked from the string's
    // own digits rather than re-deriving it through another Date object.
    const [, , dueD] = nextDueDate.split("-").map(Number);
    expect(expectedFire.getHours()).toBe(9);
    expect(expectedFire.getDate()).toBe(dueD);
  });

  test("shares the 60-notification cap with invoice reminders", async () => {
    const sixty = Array.from({ length: 60 }, (_, i) => ({
      id: `i${i}`, customer: "A", number: `INV-${i}`, paid: false, amount: 100, due: dateInDays(30),
    }));
    seedStorage(sixty, { rules: [{ days: 1 }] }, [], [], [riRule()]);

    await syncNotifications();

    expect(Notifications.scheduleNotificationAsync).toHaveBeenCalledTimes(60);
    const ids = Notifications.scheduleNotificationAsync.mock.calls.map((c) => c[0].identifier);
    expect(ids.some((id) => id.startsWith("rinv_"))).toBe(false);
  });
});
