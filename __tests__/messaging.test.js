import { Alert } from "react-native";
import * as MailComposer from "expo-mail-composer";
import * as SMS from "expo-sms";
import {
  composeEmail,
  composeSMS,
  composeEmailWithOutcome,
  composeSMSWithOutcome,
} from "../utils/messaging";

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

  test("forwards isHtml when set; plain-text callers keep their exact shape", async () => {
    MailComposer.isAvailableAsync.mockResolvedValueOnce(true);
    await composeEmail({ recipients: ["jane@example.com"], subject: "s", body: "<p>hi</p>", isHtml: true });
    expect(MailComposer.composeAsync).toHaveBeenCalledWith({
      recipients: ["jane@example.com"],
      subject: "s",
      body: "<p>hi</p>",
      isHtml: true,
    });
    MailComposer.isAvailableAsync.mockResolvedValueOnce(true);
    await composeEmail({ recipients: [], subject: "s", body: "b" });
    expect(Object.keys(MailComposer.composeAsync.mock.calls[1][0])).toEqual(["recipients", "subject", "body"]);
  });

  test("sends no attachments key when none are given or the list is empty", async () => {
    MailComposer.isAvailableAsync.mockResolvedValueOnce(true);
    await composeEmail({ recipients: [], subject: "s", body: "b", attachments: [] });
    const payload = MailComposer.composeAsync.mock.calls[0][0];
    expect(Object.keys(payload)).toEqual(["recipients", "subject", "body"]);
  });
});

// Outcome semantics: only an explicit user cancel (or a saved-for-later email
// draft) counts as notSent — it must NOT burn one-shot flows like the review
// request. Platforms that can't report (Android) yield unknown, which callers
// treat like sent to preserve the old composer-opened behavior there.
describe("composeEmailWithOutcome", () => {
  beforeEach(() => jest.clearAllMocks());

  test.each([
    ["sent", "sent"],
    ["cancelled", "notSent"],
    ["saved", "notSent"],
    ["undetermined", "unknown"],
  ])("maps composer status %s to outcome %s", async (status, outcome) => {
    MailComposer.isAvailableAsync.mockResolvedValueOnce(true);
    MailComposer.composeAsync.mockResolvedValueOnce({ status });
    const res = await composeEmailWithOutcome({
      recipients: ["jane@example.com"],
      subject: "s",
      body: "b",
    });
    expect(res).toEqual({ opened: true, outcome });
  });

  test("not available → opened false, outcome notSent", async () => {
    MailComposer.isAvailableAsync.mockResolvedValueOnce(false);
    jest.spyOn(Alert, "alert").mockImplementation(() => {});
    const res = await composeEmailWithOutcome({ recipients: [], subject: "s", body: "b" });
    expect(res).toEqual({ opened: false, outcome: "notSent" });
    expect(MailComposer.composeAsync).not.toHaveBeenCalled();
  });
});

describe("composeSMSWithOutcome", () => {
  beforeEach(() => jest.clearAllMocks());

  test.each([
    ["sent", "sent"],
    ["cancelled", "notSent"],
    ["unknown", "unknown"],
  ])("maps SMS result %s to outcome %s", async (result, outcome) => {
    SMS.isAvailableAsync.mockResolvedValueOnce(true);
    SMS.sendSMSAsync.mockResolvedValueOnce({ result });
    const res = await composeSMSWithOutcome({ recipients: ["5551234567"], body: "Hi" });
    expect(res).toEqual({ opened: true, outcome });
  });

  test("not available → opened false, outcome notSent", async () => {
    SMS.isAvailableAsync.mockResolvedValueOnce(false);
    jest.spyOn(Alert, "alert").mockImplementation(() => {});
    const res = await composeSMSWithOutcome({ recipients: [], body: "b" });
    expect(res).toEqual({ opened: false, outcome: "notSent" });
    expect(SMS.sendSMSAsync).not.toHaveBeenCalled();
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
