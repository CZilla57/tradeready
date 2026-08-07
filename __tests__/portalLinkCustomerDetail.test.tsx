// __tests__/portalLinkCustomerDetail.test.tsx
// CustomerDetail → Customer portal section: create saves {token, enabled:true}
// through saveCustomers (map-by-id — only this customer, neighbor untouched);
// the toggle flips enabled in place; a mint failure Alerts and saves nothing.
// Mirrors __tests__/bookingLinkSettings.test.tsx's immediate-action precedent,
// adapted for CustomerDetailScreen's loadCustomers/saveCustomers mutation
// pattern (no screen-wide draft/save-all machinery here).

import React from "react";
import { render, fireEvent, waitFor } from "@testing-library/react-native";
import { Alert } from "react-native";
import CustomerDetailScreen from "../screens/CustomerDetailScreen";
import { loadJobs, loadCustomers, saveCustomers } from "../utils/storage";
import { managePortal, buildPortalUrl } from "../utils/portalLink";

// CustomerDetailScreen uses useFocusEffect (from @react-navigation/native) to
// refresh displayCustomer from storage; run it as a mount effect, same as
// __tests__/TodayScreenSettingsGear.test.tsx.
jest.mock("@react-navigation/native", () => ({
  useFocusEffect: (cb: () => void | (() => void)) => {
    const { useEffect } = jest.requireActual("react");
    useEffect(() => cb(), [cb]);
  },
}));

jest.mock("../utils/storage", () => ({
  loadJobs: jest.fn(() => Promise.resolve([])),
  loadCustomers: jest.fn(),
  saveCustomers: jest.fn(() => Promise.resolve()),
  updateCustomerNotes: jest.fn(() => Promise.resolve(null)),
}));

// Only managePortal is faked (Phase 12D: the server-authoritative manage
// call) — buildPortalUrl stays real so the test asserts against the actual
// URL format instead of a duplicated literal.
jest.mock("../utils/portalLink", () => ({
  ...jest.requireActual("../utils/portalLink"),
  managePortal: jest.fn(),
}));

const navigation = {
  setOptions: jest.fn(),
  navigate: jest.fn(),
  goBack: jest.fn(),
} as any;

const TOKEN = "e".repeat(48);

const cust = {
  id: "c1",
  name: "Jane Doe",
  email: "jane@example.com",
  phone: "5551234567",
  invoices: [],
  totalSpent: 0,
  totalOwed: 0,
  isManual: true,
};

const otherCust = {
  id: "c2",
  name: "Other Customer",
  email: "other@example.com",
  phone: "5559876543",
  invoices: [],
  totalSpent: 0,
  totalOwed: 0,
  isManual: true,
};

function renderScreen(customer: any) {
  return render(
    <CustomerDetailScreen navigation={navigation} route={{ params: { customer } } as any} />
  );
}

describe("CustomerDetail customer portal section", () => {
  beforeEach(() => {
    jest.clearAllMocks();
    (loadJobs as jest.Mock).mockResolvedValue([]);
    (loadCustomers as jest.Mock).mockResolvedValue([cust, otherCust]);
    (saveCustomers as jest.Mock).mockResolvedValue(undefined);
  });

  it("renders 'Create portal link' when the customer has no portal", async () => {
    const { findByText } = await renderScreen(cust);
    expect(await findByText("Create portal link")).toBeTruthy();
  });

  it("tapping create calls managePortal('mint') and saves the new portal onto this customer only", async () => {
    (managePortal as jest.Mock).mockResolvedValue({ ok: true, token: TOKEN });

    const { findByText } = await renderScreen(cust);
    const createBtn = await findByText("Create portal link");
    await fireEvent.press(createBtn);

    await waitFor(() => expect(saveCustomers).toHaveBeenCalledTimes(1));
    expect(managePortal).toHaveBeenCalledWith("mint", "c1");
    expect(saveCustomers).toHaveBeenCalledWith([
      { ...cust, portal: { token: TOKEN, enabled: true } },
      otherCust,
    ]);
  });

  it("a 409 already-exists mint shows the sync explanation and saves nothing", async () => {
    (managePortal as jest.Mock).mockResolvedValue({ ok: false, reason: "already-exists", message: "This customer already has a portal link." });
    const alertSpy = jest.spyOn(Alert, "alert").mockImplementation(() => {});

    const { findByText } = await renderScreen(cust);
    await fireEvent.press(await findByText("Create portal link"));

    await waitFor(() => expect(alertSpy).toHaveBeenCalledTimes(1));
    expect(alertSpy.mock.calls[0][0]).toBe("Portal link already exists");
    expect(saveCustomers).not.toHaveBeenCalled();
  });

  it("with a portal present, renders the portal URL and an ON 'Portal enabled' toggle", async () => {
    const custWithPortal = { ...cust, portal: { token: TOKEN, enabled: true } };
    (loadCustomers as jest.Mock).mockResolvedValue([custWithPortal, otherCust]);

    const { findByText, getByLabelText } = await renderScreen(custWithPortal);

    expect(await findByText(buildPortalUrl(TOKEN))).toBeTruthy();
    expect(getByLabelText("Portal enabled").props.value).toBe(true);
  });

  it("flipping the toggle calls the server FIRST, then saves the display copy", async () => {
    (managePortal as jest.Mock).mockResolvedValue({ ok: true, enabled: false });
    const custWithPortal = { ...cust, portal: { token: TOKEN, enabled: true } };
    (loadCustomers as jest.Mock).mockResolvedValue([custWithPortal, otherCust]);

    const { findByLabelText } = await renderScreen(custWithPortal);
    const toggle = await findByLabelText("Portal enabled");
    await fireEvent(toggle, "valueChange", false);

    await waitFor(() => expect(saveCustomers).toHaveBeenCalledTimes(1));
    expect(managePortal).toHaveBeenCalledWith("set_enabled", "c1", false);
    expect(saveCustomers).toHaveBeenCalledWith([
      { ...custWithPortal, portal: { token: TOKEN, enabled: false } },
      otherCust,
    ]);
  });

  it("a failed toggle Alerts and leaves the blob copy untouched (the switch must not lie)", async () => {
    (managePortal as jest.Mock).mockResolvedValue({ ok: false, reason: "network", message: "Please check your connection and try again." });
    const alertSpy = jest.spyOn(Alert, "alert").mockImplementation(() => {});
    const custWithPortal = { ...cust, portal: { token: TOKEN, enabled: true } };
    (loadCustomers as jest.Mock).mockResolvedValue([custWithPortal, otherCust]);

    const { findByLabelText } = await renderScreen(custWithPortal);
    await fireEvent(await findByLabelText("Portal enabled"), "valueChange", false);

    await waitFor(() => expect(alertSpy).toHaveBeenCalledTimes(1));
    expect(saveCustomers).not.toHaveBeenCalled();
  });

  it("rotate confirms, calls managePortal('rotate'), and saves the fresh token", async () => {
    const NEW_TOKEN = "f".repeat(48);
    (managePortal as jest.Mock).mockResolvedValue({ ok: true, token: NEW_TOKEN });
    const alertSpy = jest.spyOn(Alert, "alert").mockImplementation(() => {});
    const custWithPortal = { ...cust, portal: { token: TOKEN, enabled: true } };
    (loadCustomers as jest.Mock).mockResolvedValue([custWithPortal, otherCust]);

    const { findByText } = await renderScreen(custWithPortal);
    await fireEvent.press(await findByText("Get a new link"));

    const buttons = alertSpy.mock.calls[0][2] as { text: string; onPress?: () => void }[];
    buttons.find((b) => b.text === "Get new link")?.onPress?.();

    await waitFor(() => expect(saveCustomers).toHaveBeenCalledTimes(1));
    expect(managePortal).toHaveBeenCalledWith("rotate", "c1");
    expect(saveCustomers).toHaveBeenCalledWith([
      { ...custWithPortal, portal: { token: NEW_TOKEN, enabled: true } },
      otherCust,
    ]);
  });

  it("shows an alert and saves nothing when the customer has no full record yet (derived/dangling entry)", async () => {
    // The record list this customer's id doesn't appear in — a derived
    // (name-keyed) or dangling-id entry reachable from the customer list.
    (loadCustomers as jest.Mock).mockResolvedValue([otherCust]);
    const alertSpy = jest.spyOn(Alert, "alert").mockImplementation(() => {});

    const { findByText } = await renderScreen(cust);
    const createBtn = await findByText("Create portal link");
    await fireEvent.press(createBtn);

    await waitFor(() => expect(alertSpy).toHaveBeenCalledTimes(1));
    expect(alertSpy).toHaveBeenCalledWith(
      "Save this customer first",
      "This customer doesn't have a full record yet. Add or edit one of their details, then create the portal link."
    );
    expect(saveCustomers).not.toHaveBeenCalled();
    expect(managePortal).not.toHaveBeenCalled();
  });

  it("surfaces the existing portal instead of minting a new one during the stale-paint window", async () => {
    const custWithPortal = { ...cust, portal: { token: TOKEN, enabled: true } };
    // The route-param customer (no portal yet) is stale; loadCustomers already
    // has the real record. First call is the mount-time focus-effect refresh
    // (still the stale shape, matching route params); the second is the tap.
    (loadCustomers as jest.Mock)
      .mockResolvedValueOnce([cust, otherCust])
      .mockResolvedValueOnce([custWithPortal, otherCust]);

    const { findByText } = await renderScreen(cust);
    const createBtn = await findByText("Create portal link");
    await fireEvent.press(createBtn);

    expect(await findByText(buildPortalUrl(TOKEN))).toBeTruthy();
    expect(saveCustomers).not.toHaveBeenCalled();
    expect(managePortal).not.toHaveBeenCalled();
  });

  it("a mint failure shows an Alert and saves nothing", async () => {
    (managePortal as jest.Mock).mockResolvedValue({
      ok: false,
      reason: "network",
      message: "Please check your connection and try again.",
    });
    const alertSpy = jest.spyOn(Alert, "alert").mockImplementation(() => {});

    const { findByText } = await renderScreen(cust);
    const createBtn = await findByText("Create portal link");
    await fireEvent.press(createBtn);

    await waitFor(() => expect(alertSpy).toHaveBeenCalledTimes(1));
    expect(alertSpy).toHaveBeenCalledWith(
      "Couldn't create portal link",
      "Please check your connection and try again."
    );
    expect(saveCustomers).not.toHaveBeenCalled();
  });
});
