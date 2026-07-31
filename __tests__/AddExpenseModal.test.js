/**
 * AddExpenseModal receipt-scan behavior: attaching a photo pre-fills only
 * untouched fields, failures leave manual entry alone, and saving always
 * carries the user-reviewed values. RNTL v14 ships an async render() — every
 * test must await it. attachReceipt awaits the whole scan chain, so after
 * attachPhoto() resolves inside act() the UI state is settled — no waitFor.
 */
import React from "react";
import { render, fireEvent, act } from "@testing-library/react-native";
import { Alert } from "react-native";
import { AddExpenseModal } from "../components/money/AddExpenseModal";

jest.mock("expo-image-picker", () => ({
  requestCameraPermissionsAsync: jest.fn(() => Promise.resolve({ status: "granted" })),
  requestMediaLibraryPermissionsAsync: jest.fn(() => Promise.resolve({ status: "granted" })),
  launchCameraAsync: jest.fn(),
  launchImageLibraryAsync: jest.fn(() =>
    Promise.resolve({ canceled: false, assets: [{ uri: "tmp://picked.jpg" }] })
  ),
}));
jest.mock("../utils/photoStorage", () => ({
  persistPhotoSafe: jest.fn(() => Promise.resolve("file:///persisted/receipt.jpg")),
  readPhotoAsDataUri: jest.fn(() => Promise.resolve("data:image/jpeg;base64,IMG")),
}));
jest.mock("../utils/receiptOCR", () => ({
  extractReceipt: jest.fn(),
}));
jest.mock("../utils/analytics", () => ({
  track: jest.fn(),
}));

const { extractReceipt } = require("../utils/receiptOCR");
const { readPhotoAsDataUri } = require("../utils/photoStorage");
const { track } = require("../utils/analytics");

const EXTRACTION = {
  merchant: "Home Depot",
  amount: 84.17,
  date: "2026-07-18",
  category: "fuel",
  confidence: "high",
};

const DESCRIPTION_PLACEHOLDER = "e.g. PVC fittings from Home Depot";
const AMOUNT_PLACEHOLDER = "0.00";

beforeEach(() => {
  jest.clearAllMocks();
  jest.spyOn(Alert, "alert").mockImplementation(() => {});
});

afterEach(() => {
  Alert.alert.mockRestore();
});

/**
 * Press "Add receipt photo" and choose the library option from the Alert.
 * Every fireEvent that precedes an explicit act() must itself be wrapped in
 * an awaited act — a bare press followed by an explicit act() produces
 * React 19's "overlapping act() calls" and corrupts every later render in
 * the file (found empirically building this suite).
 */
async function attachPhoto(screen) {
  await act(async () => {
    fireEvent.press(screen.getByText("Add receipt photo"));
  });
  const buttons = Alert.alert.mock.calls[0][2];
  const library = buttons.find((b) => b.text === "Choose from Library");
  await act(async () => {
    await library.onPress();
  });
}

async function renderModal(onSave = jest.fn()) {
  const screen = await render(
    <AddExpenseModal visible onClose={jest.fn()} onSave={onSave} />
  );
  return { screen, onSave };
}

describe("AddExpenseModal receipt scan", () => {
  test("pre-fills untouched fields from the extraction and reports 'filled'", async () => {
    extractReceipt.mockResolvedValue({ extraction: EXTRACTION, route: "backend" });
    const { screen } = await renderModal();

    await attachPhoto(screen);

    expect(screen.getByText(/Filled from receipt — double-check/)).toBeTruthy();
    expect(screen.getByPlaceholderText(DESCRIPTION_PLACEHOLDER).props.value).toBe("Home Depot");
    expect(screen.getByPlaceholderText(AMOUNT_PLACEHOLDER).props.value).toBe("84.17");
    expect(extractReceipt).toHaveBeenCalledWith("data:image/jpeg;base64,IMG");
    expect(track).toHaveBeenCalledWith("receipt_scanned", {
      outcome: "filled",
      route: "backend",
    });
  });

  test("saving after a scan hands the reviewed values to onSave", async () => {
    extractReceipt.mockResolvedValue({ extraction: EXTRACTION, route: "backend" });
    const { screen, onSave } = await renderModal();

    await attachPhoto(screen);
    expect(screen.getByText(/Filled from receipt/)).toBeTruthy();

    await act(async () => {
      fireEvent.press(screen.getByText("Save Expense"));
    });
    expect(onSave).toHaveBeenCalledWith({
      description: "Home Depot",
      amount: 84.17,
      category: "fuel",
      date: "2026-07-18",
      notes: "",
      receiptUri: "file:///persisted/receipt.jpg",
    });
  });

  test("never clobbers a field the user already typed in", async () => {
    extractReceipt.mockResolvedValue({ extraction: EXTRACTION, route: "user_key" });
    const { screen } = await renderModal();

    await act(async () => {
      fireEvent.changeText(
        screen.getByPlaceholderText(DESCRIPTION_PLACEHOLDER),
        "Copper pipe run"
      );
    });

    await attachPhoto(screen);
    expect(screen.getByText(/Filled from receipt/)).toBeTruthy();

    expect(screen.getByPlaceholderText(DESCRIPTION_PLACEHOLDER).props.value).toBe(
      "Copper pipe run"
    );
    expect(screen.getByPlaceholderText(AMOUNT_PLACEHOLDER).props.value).toBe("84.17");
  });

  test("reports 'empty' when every extractable field was already touched", async () => {
    extractReceipt.mockResolvedValue({
      extraction: { ...EXTRACTION, date: null },
      route: "backend",
    });
    const { screen } = await renderModal();

    await act(async () => {
      fireEvent.changeText(screen.getByPlaceholderText(DESCRIPTION_PLACEHOLDER), "Fuel stop");
      fireEvent.changeText(screen.getByPlaceholderText(AMOUNT_PLACEHOLDER), "40");
      fireEvent.press(screen.getByText("Fuel & Transport"));
    });

    await attachPhoto(screen);

    expect(screen.getByText("Receipt read — nothing new to fill in")).toBeTruthy();
    expect(screen.getByPlaceholderText(DESCRIPTION_PLACEHOLDER).props.value).toBe("Fuel stop");
    expect(screen.getByPlaceholderText(AMOUNT_PLACEHOLDER).props.value).toBe("40");
    expect(track).toHaveBeenCalledWith("receipt_scanned", {
      outcome: "empty",
      route: "backend",
    });
  });

  test("failed extraction leaves the form untouched and says so", async () => {
    extractReceipt.mockResolvedValue(null);
    const { screen } = await renderModal();

    await attachPhoto(screen);

    expect(
      screen.getByText("Couldn't read the receipt — enter the details manually")
    ).toBeTruthy();
    expect(screen.getByPlaceholderText(DESCRIPTION_PLACEHOLDER).props.value).toBe("");
    expect(screen.getByPlaceholderText(AMOUNT_PLACEHOLDER).props.value).toBe("");
    expect(track).toHaveBeenCalledWith("receipt_scanned", { outcome: "failed" });
  });

  test("unreadable photo file fails gracefully too", async () => {
    readPhotoAsDataUri.mockResolvedValueOnce(null);
    const { screen } = await renderModal();

    await attachPhoto(screen);

    expect(
      screen.getByText("Couldn't read the receipt — enter the details manually")
    ).toBeTruthy();
    expect(extractReceipt).not.toHaveBeenCalled();
  });

  test("flags a blurry receipt on the filled banner", async () => {
    extractReceipt.mockResolvedValue({
      extraction: { ...EXTRACTION, confidence: "low" },
      route: "backend",
    });
    const { screen } = await renderModal();

    await attachPhoto(screen);

    expect(screen.getByText(/the photo looks blurry, double-check/)).toBeTruthy();
  });

  test("removing the photo clears the scan banner", async () => {
    extractReceipt.mockResolvedValue({ extraction: EXTRACTION, route: "backend" });
    const { screen } = await renderModal();

    await attachPhoto(screen);
    expect(screen.getByText(/Filled from receipt/)).toBeTruthy();

    await act(async () => {
      fireEvent.press(screen.getByText("Remove photo"));
    });

    expect(screen.queryByText(/Filled from receipt/)).toBeNull();
    expect(screen.getByText("Add receipt photo")).toBeTruthy();
  });
});
