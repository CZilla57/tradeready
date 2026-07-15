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

// Populates AsyncStorage mock so syncNotifications reads the right invoices/settings.
function seedStorage(invoices, settings = { rules: [{ days: 1 }] }) {
  AsyncStorage.getItem.mockImplementation((key) => {
    if (key === "invoices") return Promise.resolve(JSON.stringify(invoices));
    if (key === "settings") return Promise.resolve(JSON.stringify(settings));
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
  test("schedules a notification for an unpaid invoice with a future threshold", async () => {
    seedStorage([
      { id: "i1", customer: "Alice", number: "INV-001", paid: false, due: dateInDays(30) },
    ]);

    await syncNotifications();

    expect(Notifications.scheduleNotificationAsync).toHaveBeenCalledTimes(1);
    const [call] = Notifications.scheduleNotificationAsync.mock.calls;
    expect(call[0].content.title).toContain("Alice");
    expect(call[0].content.body).toContain("INV-001");
  });

  test("skips paid invoices entirely", async () => {
    seedStorage([
      { id: "i1", customer: "Bob", number: "INV-002", paid: true, due: dateInDays(30) },
    ]);

    await syncNotifications();

    expect(Notifications.scheduleNotificationAsync).not.toHaveBeenCalled();
  });

  test("schedules only for unpaid when the list contains a mix", async () => {
    seedStorage([
      { id: "i1", customer: "Alice", number: "INV-001", paid: false, due: dateInDays(30) },
      { id: "i2", customer: "Bob",   number: "INV-002", paid: true,  due: dateInDays(30) },
      { id: "i3", customer: "Carol", number: "INV-003", paid: false, due: dateInDays(30) },
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
});

// ── Threshold date handling ───────────────────────────────────────────────────

describe("threshold date handling", () => {
  test("skips invoices whose fire date is already in the past", async () => {
    // Due 2020-01-01 + 1 day rule → fire date 2020-01-02 9am → already past
    seedStorage([
      { id: "i1", customer: "Alice", number: "INV-001", paid: false, due: "2020-01-01" },
    ]);

    await syncNotifications();

    expect(Notifications.scheduleNotificationAsync).not.toHaveBeenCalled();
  });

  test("schedules one notification per rule when multiple rules apply", async () => {
    seedStorage(
      [{ id: "i1", customer: "Alice", number: "INV-001", paid: false, due: dateInDays(30) }],
      { rules: [{ days: 1 }, { days: 7 }] }
    );

    await syncNotifications();

    // One invoice × two future rules = two notifications
    expect(Notifications.scheduleNotificationAsync).toHaveBeenCalledTimes(2);
  });
});

// ── Notification identifier format ───────────────────────────────────────────

describe("notification identifier", () => {
  test("uses the format inv_{invoiceId}_{days}d", async () => {
    seedStorage(
      [{ id: "i42", customer: "Alice", number: "INV-001", paid: false, due: dateInDays(30) }],
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
      [{ id: "i7", customer: "Alice", number: "INV-007", paid: false, due: dateInDays(30) }],
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
      [{ id: "i7", customer: "Alice", number: "INV-007", paid: false, due: dateInDays(30) }],
      { rules: [{ days: 7 }], autoOutreachEnabled: false }
    );

    await syncNotifications();

    const [call] = Notifications.scheduleNotificationAsync.mock.calls;
    expect(call[0].content.data).toEqual({ invoiceId: "i7" });
    expect(call[0].content.data.type).toBeUndefined();
  });

  test("defaults to the plain reminder when the flag is absent", async () => {
    seedStorage(
      [{ id: "i7", customer: "Alice", number: "INV-007", paid: false, due: dateInDays(30) }],
      { rules: [{ days: 7 }] } // no autoOutreachEnabled key — mirrors a pre-existing user
    );

    await syncNotifications();

    const [call] = Notifications.scheduleNotificationAsync.mock.calls;
    expect(call[0].content.data.type).toBeUndefined();
  });
});
