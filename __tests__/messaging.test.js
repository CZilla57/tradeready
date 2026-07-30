import { Alert } from "react-native";
import * as MailComposer from "expo-mail-composer";
import * as SMS from "expo-sms";
import { composeEmail, composeSMS } from "../utils/messaging";

// expo-mail-composer / expo-sms are mocked in jest.setup.js (available by default).

describe("composeEmail", () => {
  beforeEach(() => jest.clearAllMocks());

  test("opens the mail composer with the given fields when available", async () => {
    MailComposer.isAvailableAsync.mockResolvedValueOnce(true);
    const opened = await composeEmail({
      recipients: ["jane@example.com"],
      subject: "Estimate",
      body: "Here you go",
    });
    expect(opened).toBe(true);
    expect(MailComposer.composeAsync).toHaveBeenCalledWith({
      recipients: ["jane@example.com"],
      subject: "Estimate",
      body: "Here you go",
    });
  });

  test("alerts and skips compose when Mail isn't set up", async () => {
    MailComposer.isAvailableAsync.mockResolvedValueOnce(false);
    const alertSpy = jest.spyOn(Alert, "alert").mockImplementation(() => {});
    const opened = await composeEmail({ recipients: [], subject: "s", body: "b" });
    expect(opened).toBe(false);
    expect(MailComposer.composeAsync).not.toHaveBeenCalled();
    expect(alertSpy).toHaveBeenCalledWith("Mail not available", expect.any(String));
  });

  test("forwards attachments to the composer when provided", async () => {
    MailComposer.isAvailableAsync.mockResolvedValueOnce(true);
    await composeEmail({
      recipients: ["jane@example.com"],
      subject: "Invoice INV-0001",
      body: "Attached.",
      attachments: ["file:///mock/cache/Invoice-INV-0001-Jane-Smith.pdf"],
    });
    expect(MailComposer.composeAsync).toHaveBeenCalledWith({
      recipients: ["jane@example.com"],
      subject: "Invoice INV-0001",
      body: "Attached.",
      attachments: ["file:///mock/cache/Invoice-INV-0001-Jane-Smith.pdf"],
    });
  });

  test("sends no attachments key when none are given or the list is empty", async () => {
    MailComposer.isAvailableAsync.mockResolvedValueOnce(true);
    await composeEmail({ recipients: [], subject: "s", body: "b", attachments: [] });
    const payload = MailComposer.composeAsync.mock.calls[0][0];
    expect(Object.keys(payload)).toEqual(["recipients", "subject", "body"]);
  });
});

describe("composeSMS", () => {
  beforeEach(() => jest.clearAllMocks());

  test("opens the SMS composer with recipients + body when available", async () => {
    SMS.isAvailableAsync.mockResolvedValueOnce(true);
    const opened = await composeSMS({ recipients: ["5551234567"], body: "Hi" });
    expect(opened).toBe(true);
    expect(SMS.sendSMSAsync).toHaveBeenCalledWith(["5551234567"], "Hi");
  });

  test("alerts and skips send when the device can't text", async () => {
    SMS.isAvailableAsync.mockResolvedValueOnce(false);
    const alertSpy = jest.spyOn(Alert, "alert").mockImplementation(() => {});
    const opened = await composeSMS({ recipients: [], body: "b" });
    expect(opened).toBe(false);
    expect(SMS.sendSMSAsync).not.toHaveBeenCalled();
    expect(alertSpy).toHaveBeenCalledWith("SMS not available", expect.any(String));
  });
});
