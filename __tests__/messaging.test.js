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
