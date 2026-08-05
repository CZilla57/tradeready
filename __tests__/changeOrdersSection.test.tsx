// __tests__/changeOrdersSection.test.tsx
// JobDetail's change-orders block: one row per CO with a derived-status
// badge, the "Add change order" entry point gated on job status, and a null
// render for a job with nothing to show. The send/decide/cancel/delete side
// effects (storage writes, link creation, composers) aren't exercised here —
// none of these three cases press a row action — utils/changeOrders*.test.js
// already pins that logic in isolation.
//
// No ThemeProvider wrapper: ThemeContext carries a default value and no other
// component test in this repo wraps with it (see bookingLinkSettings.test.tsx,
// RecordPaymentSheet.test.js, TaxSetAsideCard.test.js). RNTL v14 ships an
// async render()/rerender() — every call must be awaited.

import React from "react";
import { render, fireEvent, act } from "@testing-library/react-native";
import { Alert } from "react-native";
import ChangeOrdersSection from "../components/ChangeOrdersSection";
import type { Job } from "../types/models";

const job = {
  id: "j1", customerId: "c1", customerName: "Dana", title: "Bath", description: "",
  status: "in_progress", scheduledDate: null, scheduledStartTime: null,
  scheduledEndTime: null, address: "", estimateTotal: 2400, laborHours: 0,
  laborRate: 0, materials: [], materialMarkup: 0, overhead: 0, margin: 0,
  notes: "", invoiceId: null, createdAt: "2026-08-01",
  changeOrders: [
    { id: "coA", title: "Rotted subfloor", amount: 850, createdAt: "d",
      manualDecision: { decision: "approved", decidedAt: "d" } },
    { id: "coB", title: "Extra outlet", amount: 200, createdAt: "d",
      approval: { token: "T", sentAt: "s", snapshot: {} as never } },
    { id: "coC", title: "Descope tile", amount: -100, createdAt: "d" },
  ],
} as unknown as Job;

function renderSection(j: Job) {
  return render(
    <ChangeOrdersSection job={j} onChanged={jest.fn()} onAdd={jest.fn()} onEdit={jest.fn()} />,
  );
}

// The row-action menu is a native Alert.alert(title, message, buttons) — press
// a button by invoking the captured onPress, same convention as
// AddExpenseModal.test.js / ReviewRequestScreen.test.tsx.
async function pressAlertButton(text: string) {
  const calls = jest.mocked(Alert.alert).mock.calls;
  const buttons = calls[calls.length - 1]?.[2] as { text: string; onPress?: () => void }[] | undefined;
  const button = buttons?.find((b) => b.text === text);
  // RNTL v14's act() is async — flush the (synchronous) setState inside it
  // so the Modal's `visible` prop, and the Field it gates, are up to date
  // before the next query.
  await act(async () => {
    button?.onPress?.();
  });
}

describe("ChangeOrdersSection", () => {
  beforeEach(() => {
    jest.spyOn(Alert, "alert").mockImplementation(() => {});
  });

  afterEach(() => {
    jest.mocked(Alert.alert).mockRestore();
  });

  it("renders one row per CO with derived status labels", async () => {
    const { findByText, getByText } = await renderSection(job);
    await findByText("Rotted subfloor");
    expect(getByText("Approved")).toBeTruthy();
    expect(getByText("Awaiting")).toBeTruthy();
    expect(getByText("Pending")).toBeTruthy();
    expect(getByText("$850")).toBeTruthy();
    expect(getByText("-$100")).toBeTruthy();
  });

  it("shows the add button only when the job status allows it", async () => {
    const { findByText, queryByText, rerender } = await renderSection(job);
    await findByText("Add change order");
    await rerender(
      <ChangeOrdersSection
        job={{ ...job, status: "paid" } as Job}
        onChanged={jest.fn()}
        onAdd={jest.fn()}
        onEdit={jest.fn()}
      />,
    );
    expect(queryByText("Add change order")).toBeNull();
  });

  it("renders nothing at all for a legacy job with no COs at a pre-approval status", async () => {
    const bare = { ...job, changeOrders: undefined, status: "lead" } as Job;
    const { toJSON } = await renderSection(bare);
    expect(toJSON()).toBeNull();
  });

  // Regression for the leak fixed by closeDecisionModal(): a note typed for
  // one CO must not survive into the modal for a different CO opened next.
  // Drives the fix through the Cancel button rather than a simulated Android
  // back-gesture — Cancel calls the exact same closeDecisionModal() that
  // onRequestClose does, and RNTL has no clean way to fire a native
  // hardware-back event through Modal without reaching into its internals,
  // which would make the test brittle for no extra coverage.
  it("does not leak a decision note into the modal for a different change order", async () => {
    const { getByText, getByLabelText } = await renderSection(job);

    // Open the decision modal for the pending CO ("Descope tile") and type a note.
    await fireEvent.press(getByText("Descope tile"));
    await pressAlertButton("Mark approved (on site)");
    await fireEvent.changeText(getByLabelText("Note (optional)"), "wrong note");
    expect(getByLabelText("Note (optional)").props.value).toBe("wrong note");

    // Dismiss without confirming.
    await fireEvent.press(getByText("Cancel"));

    // Open the decision modal for a DIFFERENT change order ("Extra outlet").
    await fireEvent.press(getByText("Extra outlet"));
    await pressAlertButton("Mark declined");

    expect(getByLabelText("Note (optional)").props.value).toBe("");
  });
});
