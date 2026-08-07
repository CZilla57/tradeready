// Tests for utils/bookingAttention.ts (Phase 11 D4): which bookings need
// the owner's eyes on Today. Reschedule requests always do (until the
// owner responds); cancellations only while the converted job STILL holds
// the slot on the calendar — clearing or moving the job self-dismisses the
// row, so nothing lingers. Phase 12C adds portal change requests
// (status portal_change_requested), surfaced until the owner stamps
// handledAt via markBookingRequestHandled.

import AsyncStorage from "@react-native-async-storage/async-storage";
import { selectBookingAttention } from "../utils/bookingAttention";
import { markBookingRequestHandled } from "../utils/storage/bookingRequests";
import type { BookingRequest, Job } from "../types/models";

jest.mock("../utils/sync", () => ({
  enqueue: jest.fn(),
  enqueueCollectionChanges: jest.fn(),
  trySync: jest.fn(),
  pruneQueueRecords: jest.fn(),
}));
jest.mock("../utils/notifications", () => ({ syncNotifications: jest.fn() }));

const slot = {
  date: "2026-08-12",
  start: "09:00",
  end: "10:00",
  timeZone: "America/Phoenix",
  startUtc: "2026-08-12T16:00:00.000Z",
  endUtc: "2026-08-12T17:00:00.000Z",
};

const req = (over: Partial<BookingRequest>): BookingRequest => ({
  id: "bk1",
  status: "booked",
  kind: "booked",
  name: "Dana Fox",
  phone: "",
  email: "",
  address: "",
  details: "Water heater",
  preferredTiming: "",
  createdAt: "2026-08-07T15:00:00.000Z",
  convertedJobId: "jbk_bk1",
  slot,
  ...over,
});

const job = (over: Partial<Job>): Job =>
  ({
    id: "jbk_bk1",
    customerId: "c1",
    customerName: "Dana Fox",
    title: "Booked appointment",
    description: "",
    status: "lead",
    scheduledDate: slot.date,
    scheduledStartTime: slot.start,
    scheduledEndTime: slot.end,
    address: "",
    estimateTotal: 0,
    laborHours: 0,
    laborRate: 85,
    materials: [],
    materialMarkup: 20,
    overhead: 15,
    margin: 20,
    notes: "",
    invoiceId: null,
    createdAt: "2026-08-07",
    ...over,
  } as Job);

describe("selectBookingAttention", () => {
  test("reschedule requests surface with the customer's note", () => {
    const rows = selectBookingAttention(
      [
        req({
          status: "reschedule_requested",
          history: [
            { at: "2026-08-07T15:00:00.000Z", actor: "customer", event: "booked" },
            { at: "2026-08-08T10:00:00.000Z", actor: "customer", event: "request_reschedule", note: "Afternoons only" },
          ],
        }),
      ],
      [job({})]
    );
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({
      kind: "reschedule_requested",
      jobId: "jbk_bk1",
      note: "Afternoons only",
    });
  });

  test("a cancellation surfaces only while the job still holds the slot", () => {
    const cancelled = req({ status: "cancelled" });
    expect(selectBookingAttention([cancelled], [job({})])).toHaveLength(1);
    // Owner cleared the schedule → self-dismissed
    expect(
      selectBookingAttention([cancelled], [job({ scheduledDate: null, scheduledStartTime: null, scheduledEndTime: null })])
    ).toHaveLength(0);
    // Owner moved the job to a new time → self-dismissed
    expect(
      selectBookingAttention([cancelled], [job({ scheduledDate: "2026-08-14", scheduledStartTime: "11:00" })])
    ).toHaveLength(0);
    // Job archived or terminal → self-dismissed
    expect(selectBookingAttention([cancelled], [job({ archivedAt: "2026-08-09" })])).toHaveLength(0);
    expect(selectBookingAttention([cancelled], [job({ status: "declined" })])).toHaveLength(0);
  });

  test("owner-declined bookings behave like cancellations (job still scheduled)", () => {
    expect(selectBookingAttention([req({ status: "declined" })], [job({})])).toHaveLength(1);
  });

  test("quiet states produce no rows", () => {
    const rows = selectBookingAttention(
      [
        req({ status: "booked" }),
        req({ id: "bk2", status: "confirmed" }),
        req({ id: "bk3", status: "new", kind: undefined, slot: undefined }),
      ],
      [job({})]
    );
    expect(rows).toHaveLength(0);
  });

  test("reschedule rows sort before cancellations, then by slot date", () => {
    const rows = selectBookingAttention(
      [
        req({ id: "c1", status: "cancelled", slot: { ...slot, date: "2026-08-11" }, convertedJobId: "j1" }),
        req({ id: "r2", status: "reschedule_requested", slot: { ...slot, date: "2026-08-20" }, convertedJobId: "j2" }),
        req({ id: "r1", status: "reschedule_requested", slot: { ...slot, date: "2026-08-13" }, convertedJobId: "j3" }),
      ],
      [
        job({ id: "j1", scheduledDate: "2026-08-11" }),
        job({ id: "j2", scheduledDate: "2026-08-20" }),
        job({ id: "j3", scheduledDate: "2026-08-13" }),
      ]
    );
    expect(rows.map((r) => r.request.id)).toEqual(["r1", "r2", "c1"]);
  });
});

describe("portal change requests (Phase 12C)", () => {
  const change = (over: Partial<BookingRequest> = {}): BookingRequest => ({
    id: "bkpr_aabbccddeeff00112233",
    status: "portal_change_requested",
    name: "Dana Fox",
    phone: "",
    email: "",
    address: "",
    details: 'Reschedule requested for "Water heater swap" (2026-08-12) — Tuesday works better',
    preferredTiming: "",
    createdAt: "2026-08-10T12:00:00.000Z",
    source: "portal",
    sourceCustomerId: "c1",
    jobRef: "j1",
    portalKind: "reschedule",
    ...over,
  });

  test("surfaced with jobRef and the templated details while unhandled", () => {
    const rows = selectBookingAttention([change()], []);
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({
      kind: "portal_change",
      jobId: "j1",
      note: 'Reschedule requested for "Water heater swap" (2026-08-12) — Tuesday works better',
    });
  });

  test("hidden once handledAt is stamped", () => {
    expect(selectBookingAttention([change({ handledAt: "2026-08-10T13:00:00.000Z" })], [])).toHaveLength(0);
  });

  test("sorts after reschedule requests, before cancellations", () => {
    const rows = selectBookingAttention(
      [
        req({ id: "c1", status: "cancelled", convertedJobId: "j1" }),
        change(),
        req({ id: "r1", status: "reschedule_requested", convertedJobId: "j3" }),
      ],
      [job({ id: "j1" }), job({ id: "j3" })]
    );
    expect(rows.map((r) => r.kind)).toEqual(["reschedule_requested", "portal_change", "cancelled"]);
  });
});

describe("markBookingRequestHandled", () => {
  beforeEach(() => {
    (AsyncStorage.getItem as jest.Mock).mockReset();
    (AsyncStorage.setItem as jest.Mock).mockReset().mockResolvedValue(undefined);
  });

  test("stamps handledAt through the normal synced save path", async () => {
    const row = { id: "bkpr_x", status: "portal_change_requested", name: "D" };
    (AsyncStorage.getItem as jest.Mock).mockResolvedValue(JSON.stringify([row]));
    await markBookingRequestHandled("bkpr_x", "2026-08-10T13:00:00.000Z");
    const written = JSON.parse((AsyncStorage.setItem as jest.Mock).mock.calls[0][1]);
    expect(written[0].handledAt).toBe("2026-08-10T13:00:00.000Z");
  });

  test("unknown id or already-handled row writes nothing", async () => {
    (AsyncStorage.getItem as jest.Mock).mockResolvedValue(
      JSON.stringify([{ id: "bkpr_x", handledAt: "2026-08-09T00:00:00.000Z" }])
    );
    await markBookingRequestHandled("bkpr_x", "2026-08-10T13:00:00.000Z");
    await markBookingRequestHandled("bkpr_nope", "2026-08-10T13:00:00.000Z");
    expect(AsyncStorage.setItem).not.toHaveBeenCalled();
  });
});
