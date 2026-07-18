// __tests__/PaymentHistoryList.test.js
// Voided payments STAY in the list, struck through — that is the whole point
// of voiding rather than deleting, and the legacy synthesized entry is shown
// plainly labelled so an old invoice's total visibly adds up.
//
// RNTL v14 ships an async render() AND async fireEvent — every call must be
// awaited, or the next line reads state before the update lands. (Same
// pattern as __tests__/RecordPaymentSheet.test.js.)

import React from "react";
import { render, fireEvent } from "@testing-library/react-native";
import { PaymentHistoryList } from "../components/PaymentHistoryList";

const invoice = (over) => ({
  id: "i1", customer: "Acme", number: "INV-1", desc: "", email: "", phone: "",
  amount: 1000, due: "2026-07-01", paid: false, ...over,
});

const noop = () => {};

describe("PaymentHistoryList", () => {
  test("shows an empty state when nothing has been recorded", async () => {
    const { getByText } = await render(<PaymentHistoryList invoice={invoice()} onVoid={noop} />);
    expect(getByText(/No payments recorded/)).toBeTruthy();
  });

  test("renders one row per payment with amount and method", async () => {
    const i = invoice({
      payments: [
        { id: "p1", amount: 400, date: "2026-07-01", method: "cash" },
        { id: "p2", amount: 600, date: "2026-07-20", method: "card" },
      ],
    });
    const { getByText } = await render(<PaymentHistoryList invoice={i} onVoid={noop} />);
    expect(getByText("$400.00")).toBeTruthy();
    expect(getByText("$600.00")).toBeTruthy();
  });

  test("a voided payment stays visible and is labelled with its void date", async () => {
    const i = invoice({
      payments: [{ id: "p1", amount: 400, date: "2026-07-01", method: "cash", voidedAt: "2026-07-22" }],
    });
    const { getByText } = await render(<PaymentHistoryList invoice={i} onVoid={noop} />);
    expect(getByText("$400.00")).toBeTruthy();
    expect(getByText(/voided/i)).toBeTruthy();
  });

  test("the legacy synthesized entry renders with its explanatory label", async () => {
    const i = invoice({ id: "i1", paid: true, amount: 1000, paidAt: "2026-06-15", payments: undefined });
    const { getByText } = await render(<PaymentHistoryList invoice={i} onVoid={noop} />);
    expect(getByText("$1,000.00")).toBeTruthy();
    expect(getByText(/before itemised history/i)).toBeTruthy();
  });

  test("long-press calls onVoid with the payment id", async () => {
    const onVoid = jest.fn();
    const i = invoice({ payments: [{ id: "p1", amount: 400, date: "2026-07-01", method: "cash" }] });
    const { getByLabelText } = await render(<PaymentHistoryList invoice={i} onVoid={onVoid} />);
    await fireEvent(getByLabelText(/Payment of \$400\.00/), "longPress");
    expect(onVoid).toHaveBeenCalledWith("p1");
  });

  test("long-press on an ALREADY voided payment does nothing", async () => {
    const onVoid = jest.fn();
    const i = invoice({
      payments: [{ id: "p1", amount: 400, date: "2026-07-01", method: "cash", voidedAt: "2026-07-22" }],
    });
    const { getByLabelText } = await render(<PaymentHistoryList invoice={i} onVoid={onVoid} />);
    await fireEvent(getByLabelText(/Payment of \$400\.00/), "longPress");
    expect(onVoid).not.toHaveBeenCalled();
  });

  test("a voided row exposes accessibilityState.disabled === true", async () => {
    const i = invoice({
      payments: [{ id: "p1", amount: 400, date: "2026-07-01", method: "cash", voidedAt: "2026-07-22" }],
    });
    const { getByLabelText } = await render(<PaymentHistoryList invoice={i} onVoid={noop} />);
    const voidedRow = getByLabelText(/Payment of \$400\.00.*voided/);
    expect(voidedRow.props.accessibilityState?.disabled).toBe(true);
  });

  test("a live row does not have accessibilityState.disabled === true", async () => {
    const i = invoice({
      payments: [{ id: "p1", amount: 400, date: "2026-07-01", method: "cash" }],
    });
    const { getByLabelText } = await render(<PaymentHistoryList invoice={i} onVoid={noop} />);
    const liveRow = getByLabelText(/Payment of \$400\.00/);
    expect(liveRow.props.accessibilityState?.disabled).not.toBe(true);
  });
});
