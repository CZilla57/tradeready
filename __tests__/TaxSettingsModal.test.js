// __tests__/TaxSettingsModal.test.js
// The tax settings sheet. The tax math is covered by taxEstimate.test.js —
// these pin the UI contract: what it pre-fills, what it rejects, and the
// exact draft shape it hands up.
//
// RNTL v14 ships an async render() AND async fireEvent — every call must be
// awaited, or the next line reads state before the update lands.

import React from "react";
import { Alert } from "react-native";
import { render, fireEvent } from "@testing-library/react-native";
import { TaxSettingsModal } from "../components/money/TaxSettingsModal";

const noop = () => {};

describe("TaxSettingsModal", () => {
  afterEach(() => {
    jest.restoreAllMocks();
  });

  test("pre-fills the stored rate and method", async () => {
    const { getByLabelText } = await render(
      <TaxSettingsModal
        visible
        settings={{ taxIncomeRate: 18, vehicleDeductionMethod: "mileage" }}
        onClose={noop}
        onSave={noop}
      />
    );
    expect(getByLabelText("Income-tax rate percent").props.value).toBe("18");
    expect(getByLabelText("Standard mileage").props.accessibilityState.selected).toBe(true);
  });

  test("saving hands up the parsed rate and chosen method", async () => {
    const onSave = jest.fn();
    const { getByLabelText } = await render(
      <TaxSettingsModal visible settings={{}} onClose={noop} onSave={onSave} />
    );
    await fireEvent.changeText(getByLabelText("Income-tax rate percent"), "15");
    await fireEvent.press(getByLabelText("Actual fuel costs"));
    await fireEvent.press(getByLabelText("Save tax settings"));
    expect(onSave).toHaveBeenCalledWith({ taxIncomeRate: 15, vehicleDeductionMethod: "actual" });
  });

  test("a blank rate and no method save an empty draft (nothing invented)", async () => {
    const onSave = jest.fn();
    const { getByLabelText } = await render(
      <TaxSettingsModal visible settings={{}} onClose={noop} onSave={onSave} />
    );
    await fireEvent.press(getByLabelText("Save tax settings"));
    expect(onSave).toHaveBeenCalledWith({});
  });

  test("an implausible rate is rejected with an alert, not saved", async () => {
    const alertSpy = jest.spyOn(Alert, "alert").mockImplementation(() => {});
    const onSave = jest.fn();
    const { getByLabelText } = await render(
      <TaxSettingsModal visible settings={{}} onClose={noop} onSave={onSave} />
    );
    await fireEvent.changeText(getByLabelText("Income-tax rate percent"), "75");
    await fireEvent.press(getByLabelText("Save tax settings"));
    expect(alertSpy).toHaveBeenCalled();
    expect(onSave).not.toHaveBeenCalled();
  });

  test("a non-numeric rate is rejected too", async () => {
    const alertSpy = jest.spyOn(Alert, "alert").mockImplementation(() => {});
    const onSave = jest.fn();
    const { getByLabelText } = await render(
      <TaxSettingsModal visible settings={{}} onClose={noop} onSave={onSave} />
    );
    await fireEvent.changeText(getByLabelText("Income-tax rate percent"), "abc");
    await fireEvent.press(getByLabelText("Save tax settings"));
    expect(alertSpy).toHaveBeenCalled();
    expect(onSave).not.toHaveBeenCalled();
  });

  test("explains the either/or rule before the user elects a method", async () => {
    const { getByText } = await render(
      <TaxSettingsModal visible settings={{}} onClose={noop} onSave={noop} />
    );
    expect(getByText(/never both/)).toBeTruthy();
    expect(getByText(/No method chosen yet/)).toBeTruthy();
  });
});
