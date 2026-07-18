// __tests__/RecordPaymentSheet.test.js
// The record-payment form. The money math it sits on is already covered by
// invoicePayments.test.js — these pin the UI contract: what it pre-fills, what
// it rejects, and the exact shape it hands up.
//
// RNTL v14 ships an async render() AND async fireEvent — every call must be
// awaited, or the next line reads state before the update lands.

import React from "react";
import { render, fireEvent } from "@testing-library/react-native";
import { RecordPaymentSheet } from "../components/RecordPaymentSheet";

const invoice = (over) => ({
  id: "i1", customer: "Acme", number: "INV-1", desc: "", email: "", phone: "",
  amount: 1000, due: "2026-07-01", paid: false, ...over,
});

const noop = () => {};

describe("RecordPaymentSheet", () => {
  test("renders nothing when not visible", async () => {
    const { queryByLabelText } = await render(
      <RecordPaymentSheet visible={false} invoice={invoice()} onSave={noop} onClose={noop} />
    );
    expect(queryByLabelText("Amount")).toBeNull();
  });

  test("pre-fills the amount with the outstanding balance", async () => {
    const partly = invoice({ payments: [{ id: "p1", amount: 400, date: "2026-07-01", method: "cash" }] });
    const { getByLabelText } = await render(
      <RecordPaymentSheet visible invoice={partly} onSave={noop} onClose={noop} />
    );
    expect(getByLabelText("Amount").props.value).toBe("600.00");
  });

  test("does not call onSave for a zero amount", async () => {
    const onSave = jest.fn();
    const { getByLabelText, getByText } = await render(
      <RecordPaymentSheet visible invoice={invoice()} onSave={onSave} onClose={noop} />
    );
    await fireEvent.changeText(getByLabelText("Amount"), "0");
    await fireEvent.press(getByText("Record payment"));
    expect(onSave).not.toHaveBeenCalled();
  });

  test("shows a hint for a zero amount instead of silently doing nothing", async () => {
    const onSave = jest.fn();
    const { getByLabelText, getByText, queryByText } = await render(
      <RecordPaymentSheet visible invoice={invoice()} onSave={onSave} onClose={noop} />
    );
    await fireEvent.changeText(getByLabelText("Amount"), "0");
    expect(queryByText(/Enter an amount greater than zero/)).not.toBeNull();
    await fireEvent.press(getByText("Record payment"));
    expect(onSave).not.toHaveBeenCalled();
  });

  test("does not call onSave for a negative amount", async () => {
    const onSave = jest.fn();
    const { getByLabelText, getByText } = await render(
      <RecordPaymentSheet visible invoice={invoice()} onSave={onSave} onClose={noop} />
    );
    await fireEvent.changeText(getByLabelText("Amount"), "-5");
    await fireEvent.press(getByText("Record payment"));
    expect(onSave).not.toHaveBeenCalled();
  });

  test("shows a hint when the amount exceeds the balance but still allows saving", async () => {
    const onSave = jest.fn();
    const { getByLabelText, getByText, queryByText } = await render(
      <RecordPaymentSheet visible invoice={invoice()} onSave={onSave} onClose={noop} />
    );
    await fireEvent.changeText(getByLabelText("Amount"), "1500");
    expect(queryByText(/More than the/)).not.toBeNull();
    await fireEvent.press(getByText("Record payment"));
    expect(onSave).toHaveBeenCalled();
  });

  test("hands up the exact draft shape", async () => {
    const onSave = jest.fn();
    const { getByLabelText, getByText } = await render(
      <RecordPaymentSheet visible invoice={invoice()} onSave={onSave} onClose={noop} />
    );
    await fireEvent.changeText(getByLabelText("Amount"), "250.50");
    await fireEvent.press(getByText("Cheque"));
    await fireEvent.changeText(getByLabelText("Note (optional)"), "deposit");
    await fireEvent.press(getByText("Record payment"));

    const draft = onSave.mock.calls[0][0];
    expect(draft.amount).toBe(250.5);
    expect(draft.method).toBe("check");
    expect(draft.note).toBe("deposit");
    expect(draft.date).toMatch(/^\d{4}-\d{2}-\d{2}$/);
    // The form must never be able to produce these.
    expect(draft.id).toBeUndefined();
    expect(draft.voidedAt).toBeUndefined();
  });

  test("offers no Stripe method — that origin is webhook-only", async () => {
    const { queryByText } = await render(
      <RecordPaymentSheet visible invoice={invoice()} onSave={noop} onClose={noop} />
    );
    expect(queryByText(/stripe/i)).toBeNull();
  });
});
