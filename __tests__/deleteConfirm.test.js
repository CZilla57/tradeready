// Typed confirmation gate for the permanent account wipe.

const { DELETE_CONFIRM_PHRASE, deleteConfirmMatches } = require("../utils/deleteConfirm");

describe("deleteConfirmMatches", () => {
  test("phrase is DELETE", () => {
    expect(DELETE_CONFIRM_PHRASE).toBe("DELETE");
  });

  test("accepts the exact phrase", () => {
    expect(deleteConfirmMatches("DELETE")).toBe(true);
  });

  test("is forgiving about case and surrounding whitespace", () => {
    expect(deleteConfirmMatches("delete")).toBe(true);
    expect(deleteConfirmMatches("  DELETE  ")).toBe(true);
    expect(deleteConfirmMatches("Delete")).toBe(true);
  });

  test("rejects empty and partial input", () => {
    expect(deleteConfirmMatches("")).toBe(false);
    expect(deleteConfirmMatches("DELET")).toBe(false);
    expect(deleteConfirmMatches("D")).toBe(false);
  });

  test("rejects input that merely contains the phrase", () => {
    expect(deleteConfirmMatches("DELETED")).toBe(false);
    expect(deleteConfirmMatches("please DELETE")).toBe(false);
  });
});
