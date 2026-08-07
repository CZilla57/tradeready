// __tests__/availabilityParity.test.ts
// Phase 11 B3: pins the client engine (utils/scheduleConfig.ts +
// utils/availability.ts) and the Workers twin
// (backend-workers/lib/booking/availability.js) together — shared fixtures,
// deep-equal outputs. Same discipline as the selectInvoicesToRemind /
// isPlausibleEmail parity suites: if one side changes behavior, this suite
// goes red until the twin follows.

import { computeCandidateSlots as clientSlots } from "../utils/availability";
import { resolveSchedule as clientResolve } from "../utils/scheduleConfig";
import type { Job, Settings } from "../types/models";

// eslint-disable-next-line @typescript-eslint/no-require-imports -- CommonJS backend twin, same pattern as the backend suites
const server = require("../backend-workers/lib/booking/availability.js");

function job(overrides: Partial<Job>): Job {
  return {
    id: "j1",
    customerId: "c1",
    customerName: "Dana",
    title: "Job",
    description: "",
    status: "scheduled",
    scheduledDate: "2026-08-10",
    scheduledStartTime: "09:00",
    scheduledEndTime: "11:00",
    address: "",
    estimateTotal: 0,
    laborHours: 2,
    laborRate: 85,
    materials: [],
    materialMarkup: 20,
    overhead: 15,
    margin: 20,
    notes: "",
    invoiceId: null,
    createdAt: "2026-08-01",
    ...overrides,
  };
}

/** Settings.schedule blobs — including hostile shapes — that both
 *  resolvers must sanitize identically. */
const SCHEDULE_BLOBS: { name: string; blob: unknown }[] = [
  { name: "absent", blob: undefined },
  { name: "empty object", blob: {} },
  {
    name: "fully valid",
    blob: {
      timeZone: "America/Chicago",
      workDays: [2, 4, 6],
      workDayStart: "07:30",
      workDayEnd: "16:00",
      defaultDurationMinutes: 90,
      bufferMinutes: 15,
      slotLeadHours: 0,
      slotWindowDays: 7,
      blackouts: [{ id: "b1", start: "2026-08-12", end: "2026-08-13", reason: "off" }],
      bookableSlotsEnabled: true,
    },
  },
  {
    name: "garbage values",
    blob: {
      timeZone: "",
      workDays: [0, 9, 2.5, "3", 5, 5],
      workDayStart: "25:00",
      workDayEnd: "9am",
      defaultDurationMinutes: -10,
      bufferMinutes: "30",
      slotLeadHours: -1,
      slotWindowDays: 0,
      blackouts: [
        { id: "", start: "2026-08-10", end: "2026-08-11" },
        { id: "ok", start: "2026-08-20", end: "2026-08-19" },
        "junk",
        { id: "kept", start: "2026-08-25", end: "2026-08-26" },
      ],
      bookableSlotsEnabled: "yes",
    },
  },
  { name: "inverted window", blob: { workDayStart: "18:00", workDayEnd: "08:00" } },
];

/** Availability scenarios both engines must answer identically. */
const SCENARIOS: {
  name: string;
  scheduleBlob: unknown;
  jobs: Job[];
  extraBusy?: { date: string; start: string; end: string }[];
  fromDate: string;
  days: number;
  now: { date: string; minutes: number };
}[] = [
  {
    name: "empty week on defaults",
    scheduleBlob: { slotLeadHours: 0 },
    jobs: [],
    fromDate: "2026-08-10",
    days: 7,
    now: { date: "2026-08-01", minutes: 0 },
  },
  {
    name: "jobs + buffer + off-grid ends",
    scheduleBlob: { slotLeadHours: 0, bufferMinutes: 30 },
    jobs: [
      job({}),
      job({ id: "j2", scheduledStartTime: "13:05", scheduledEndTime: null, laborHours: 1.5 }),
      job({ id: "j3", status: "paid", scheduledStartTime: "07:00", scheduledEndTime: "18:00" }),
      job({ id: "j4", scheduledDate: "2026-08-11", scheduledStartTime: "08:00", scheduledEndTime: "12:15" }),
    ],
    fromDate: "2026-08-10",
    days: 3,
    now: { date: "2026-08-01", minutes: 0 },
  },
  {
    name: "blackouts, custom window, 90-min duration",
    scheduleBlob: {
      slotLeadHours: 0,
      workDayStart: "07:00",
      workDayEnd: "19:30",
      defaultDurationMinutes: 90,
      workDays: [1, 2, 3, 4, 5, 6, 7],
      blackouts: [{ id: "b1", start: "2026-08-11", end: "2026-08-12" }],
    },
    jobs: [job({ scheduledStartTime: "10:00", scheduledEndTime: "10:20" })],
    fromDate: "2026-08-09",
    days: 5,
    now: { date: "2026-08-01", minutes: 0 },
  },
  {
    name: "lead time crossing days + reservations as extraBusy",
    scheduleBlob: { slotLeadHours: 24 },
    jobs: [job({ scheduledDate: "2026-08-11" })],
    extraBusy: [
      { date: "2026-08-11", start: "13:00", end: "14:00" },
      { date: "2026-08-12", start: "08:00", end: "12:00" },
    ],
    fromDate: "2026-08-10",
    days: 4,
    now: { date: "2026-08-10", minutes: 15 * 60 + 45 },
  },
  {
    name: "garbage schedule blob falls back to defaults in both engines",
    scheduleBlob: SCHEDULE_BLOBS[3].blob,
    jobs: [job({})],
    fromDate: "2026-08-10",
    days: 2,
    now: { date: "2026-08-09", minutes: 0 },
  },
];

describe("resolveSchedule parity", () => {
  for (const { name, blob } of SCHEDULE_BLOBS) {
    test(name, () => {
      const clientResult = clientResolve({ schedule: blob } as unknown as Settings);
      const serverResult = server.resolveSchedule({ schedule: blob });
      expect(serverResult).toEqual(clientResult);
    });
  }
});

describe("computeCandidateSlots parity", () => {
  for (const sc of SCENARIOS) {
    test(sc.name, () => {
      const schedule = clientResolve({ schedule: sc.scheduleBlob } as unknown as Settings);
      const serverSchedule = server.resolveSchedule({ schedule: sc.scheduleBlob });
      const clientResult = clientSlots({
        schedule,
        jobs: sc.jobs,
        extraBusy: sc.extraBusy,
        fromDate: sc.fromDate,
        days: sc.days,
        now: sc.now,
      });
      const serverResult = server.computeCandidateSlots({
        schedule: serverSchedule,
        jobs: sc.jobs,
        extraBusy: sc.extraBusy,
        fromDate: sc.fromDate,
        days: sc.days,
        now: sc.now,
      });
      expect(serverResult).toEqual(clientResult);
      // Sanity: parity of empty-vs-empty proves nothing — at least one
      // scenario-day must actually produce slots.
      if (sc.name === "empty week on defaults") {
        expect(clientResult.length).toBeGreaterThan(0);
      }
    });
  }
});
