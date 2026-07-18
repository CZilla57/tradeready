// __tests__/appointmentSend.test.js
import { sendAppointmentMessage } from "../utils/appointmentSend";
import { composeSMS, composeEmail } from "../utils/messaging";
import { Alert } from "react-native";

jest.mock("../utils/messaging", () => ({
  composeSMS: jest.fn(() => Promise.resolve(true)),
  composeEmail: jest.fn(() => Promise.resolve(true)),
}));
jest.spyOn(Alert, "alert").mockImplementation(() => {});

const job = {
  id: "j1", customerId: "c1", customerName: "Alice", status: "scheduled",
  scheduledDate: "2026-07-19", scheduledStartTime: "09:00", scheduledEndTime: null, address: "12 Oak St",
};
const settings = { businessName: "Bob Plumbing", appointmentConfirmTemplate: "", onMyWayTemplate: "" };

beforeEach(() => jest.clearAllMocks());

test("texts the customer when a phone exists", async () => {
  const ok = await sendAppointmentMessage({
    job, customer: { id: "c1", name: "Alice", phone: "5551234567", email: "a@x.com", address: "" },
    settings, kind: "on_my_way",
  });
  expect(ok).toBe(true);
  expect(composeSMS).toHaveBeenCalledWith(expect.objectContaining({ recipients: ["5551234567"] }));
  expect(composeSMS.mock.calls[0][0].body).toContain("Alice");
  expect(composeEmail).not.toHaveBeenCalled();
});

test("emails when there is no phone", async () => {
  const ok = await sendAppointmentMessage({
    job, customer: { id: "c1", name: "Alice", phone: "", email: "a@x.com", address: "" },
    settings, kind: "confirm",
  });
  expect(ok).toBe(true);
  expect(composeEmail).toHaveBeenCalledWith(expect.objectContaining({ recipients: ["a@x.com"] }));
  expect(composeSMS).not.toHaveBeenCalled();
});

test("alerts and returns false when the customer has no contact info", async () => {
  const ok = await sendAppointmentMessage({
    job, customer: { id: "c1", name: "Alice", phone: "", email: "", address: "" },
    settings, kind: "confirm",
  });
  expect(ok).toBe(false);
  expect(Alert.alert).toHaveBeenCalled();
  expect(composeSMS).not.toHaveBeenCalled();
  expect(composeEmail).not.toHaveBeenCalled();
});
