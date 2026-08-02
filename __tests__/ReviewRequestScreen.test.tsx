/**
 * ReviewRequestScreen send-outcome behavior — review requests are one-shot,
 * so a cancelled composer must NOT burn the shot: the screen marks a request
 * sent only when the composer opened AND the outcome wasn't "notSent"
 * (an "unknown" outcome deliberately counts as sent — some platforms can't
 * report, e.g. Android mail always claims "sent"; see utils/messaging.ts).
 * The outcome MAPPING (native result → sent/notSent/unknown) is covered by
 * messaging.test.js; this suite pins what the screen DOES with each outcome,
 * which until now was only verified by owner device smoke.
 */
import React from "react";
import { Alert } from "react-native";
import { render, fireEvent, act } from "@testing-library/react-native";
import ReviewRequestScreen from "../screens/ReviewRequestScreen";
import { composeEmailWithOutcome, composeSMSWithOutcome } from "../utils/messaging";
import { getReviewRequestRecord, markReviewRequestSent } from "../utils/reviewRequest";
import { loadSettings, loadJobs, loadCustomers, resolveCustomer } from "../utils/storage";

jest.mock("react-native-safe-area-context", () => ({
  SafeAreaView: ({ children }: { children: React.ReactNode }) => children,
}));

jest.mock("../utils/messaging", () => ({
  composeEmailWithOutcome: jest.fn(),
  composeSMSWithOutcome: jest.fn(),
}));

// Partial mock: the message builders stay REAL so the preview the screen
// renders is the real product; only the record I/O is stubbed.
jest.mock("../utils/reviewRequest", () => ({
  ...jest.requireActual("../utils/reviewRequest"),
  getReviewRequestRecord: jest.fn(),
  markReviewRequestSent: jest.fn(),
}));

jest.mock("../utils/storage", () => ({
  loadSettings: jest.fn(),
  loadJobs: jest.fn(),
  loadCustomers: jest.fn(),
  resolveCustomer: jest.fn(),
}));

const SETTINGS = {
  businessName: "Acme Plumbing",
  reviewRequestTemplate:
    "Hi {customerName}, thanks for choosing {businessName}!\n\n{googleReviewLink}",
  googleReviewLink: "https://g.page/r/abc/review",
};
const JOB = { id: "j1", customerId: "c1", customerName: "Sam", title: "Faucet swap" };
const CUSTOMER = { id: "c1", name: "Sam", phone: "5550100", email: "sam@example.com" };

beforeEach(() => {
  jest.clearAllMocks();
  jest.spyOn(Alert, "alert").mockImplementation(() => {});
  jest.mocked(loadSettings).mockResolvedValue(SETTINGS as never);
  jest.mocked(loadJobs).mockResolvedValue([JOB] as never);
  jest.mocked(loadCustomers).mockResolvedValue([CUSTOMER] as never);
  jest.mocked(resolveCustomer).mockReturnValue(CUSTOMER as never);
  // No record yet — the auto-nudge path never scheduled one, so sending
  // upserts via the live-customer fallback snapshot.
  jest.mocked(getReviewRequestRecord).mockResolvedValue(null);
  jest.mocked(markReviewRequestSent).mockResolvedValue(undefined);
});

async function renderScreen() {
  const result = await render(
    <ReviewRequestScreen
      route={{ params: { jobId: "j1", source: "job_detail" } } as never}
      navigation={{ navigate: jest.fn(), goBack: jest.fn() } as never}
    />
  );
  // The load effect is async — the send buttons appearing means it settled.
  await result.findByText("Send via SMS");
  return result;
}

// The press handlers are async (composer promise → mark sent → setState), so
// the press is flushed inside act; afterwards every assertion is synchronous.
async function press(element: Parameters<typeof fireEvent.press>[0]) {
  await act(async () => {
    fireEvent.press(element);
  });
}

describe("ReviewRequestScreen — cancel does not burn the one-shot", () => {
  test("cancelling the SMS composer marks nothing sent", async () => {
    jest.mocked(composeSMSWithOutcome).mockResolvedValue({ opened: true, outcome: "notSent" });
    const { getByText, queryByText } = await renderScreen();

    await press(getByText("Send via SMS"));

    expect(composeSMSWithOutcome).toHaveBeenCalledTimes(1);
    expect(markReviewRequestSent).not.toHaveBeenCalled();
    expect(queryByText("Review request sent")).toBeNull();
    expect(Alert.alert).not.toHaveBeenCalled();
  });

  test("cancelling (or draft-saving) the email composer marks nothing sent", async () => {
    jest.mocked(composeEmailWithOutcome).mockResolvedValue({ opened: true, outcome: "notSent" });
    const { getByText, queryByText } = await renderScreen();

    await press(getByText("Send via Email"));

    expect(composeEmailWithOutcome).toHaveBeenCalledTimes(1);
    expect(markReviewRequestSent).not.toHaveBeenCalled();
    expect(queryByText("Review request sent")).toBeNull();
  });

  test("a composer that never opened marks nothing sent", async () => {
    jest.mocked(composeSMSWithOutcome).mockResolvedValue({ opened: false, outcome: "notSent" });
    const { getByText } = await renderScreen();

    await press(getByText("Send via SMS"));

    expect(composeSMSWithOutcome).toHaveBeenCalledTimes(1);
    expect(markReviewRequestSent).not.toHaveBeenCalled();
  });
});

describe("ReviewRequestScreen — real sends burn the one-shot", () => {
  test("a sent SMS marks the request sent with the live-customer fallback snapshot", async () => {
    jest.mocked(composeSMSWithOutcome).mockResolvedValue({ opened: true, outcome: "sent" });
    const { getByText } = await renderScreen();

    await press(getByText("Send via SMS"));

    getByText("Review request sent");
    expect(markReviewRequestSent).toHaveBeenCalledWith("j1", {
      customerId: "c1",
      customerName: "Sam",
      customerPhone: "5550100",
      customerEmail: "sam@example.com",
    });
  });

  test("an unreportable outcome still counts as sent (platforms that can't report, e.g. Android mail)", async () => {
    jest.mocked(composeEmailWithOutcome).mockResolvedValue({ opened: true, outcome: "unknown" });
    const { getByText } = await renderScreen();

    await press(getByText("Send via Email"));

    getByText("Review request sent");
    expect(markReviewRequestSent).toHaveBeenCalledTimes(1);
  });
});
