// persistPhotoSafe — the failure path that never runs in normal use.
//
// Every caller runs inside an async Alert button handler, where a rejection
// becomes an unhandled promise rejection: the user picks an image and nothing
// happens, with no error and no telemetry. These tests pin the contract that
// replaced that — return null, report once, never throw.

jest.mock("expo-file-system/legacy", () => ({
  documentDirectory: "file:///mock/",
  getInfoAsync: jest.fn(),
  makeDirectoryAsync: jest.fn(),
  copyAsync: jest.fn(),
}));

jest.mock("../utils/analytics", () => ({ reportError: jest.fn() }));

const FileSystem = require("expo-file-system/legacy");
const { reportError } = require("../utils/analytics");
const { persistPhotoSafe } = require("../utils/photoStorage");

const TEMP = "file:///tmp/picked-image.jpg";
const BOOM = new Error("copy failed");

beforeEach(() => {
  jest.clearAllMocks();
  FileSystem.getInfoAsync.mockResolvedValue({ exists: true });
  FileSystem.makeDirectoryAsync.mockResolvedValue(undefined);
  FileSystem.copyAsync.mockResolvedValue(undefined);
});

describe("persistPhotoSafe", () => {
  test("returns the persisted path in the requested folder on success", async () => {
    const uri = await persistPhotoSafe(TEMP, "logos");
    expect(uri).toMatch(/^file:\/\/\/mock\/logos\/.+\.jpg$/);
    expect(FileSystem.copyAsync).toHaveBeenCalledWith({ from: TEMP, to: uri });
  });

  test("does not report anything on success", async () => {
    await persistPhotoSafe(TEMP, "logos");
    expect(reportError).not.toHaveBeenCalled();
  });

  test("creates the folder first when it does not exist yet", async () => {
    FileSystem.getInfoAsync.mockResolvedValue({ exists: false });
    const uri = await persistPhotoSafe(TEMP, "receipts");
    expect(FileSystem.makeDirectoryAsync).toHaveBeenCalledWith("file:///mock/receipts/", {
      intermediates: true,
    });
    expect(uri).toMatch(/^file:\/\/\/mock\/receipts\//);
  });

  test("a failed copy resolves to null instead of rejecting", async () => {
    FileSystem.copyAsync.mockRejectedValue(BOOM);
    await expect(persistPhotoSafe(TEMP, "job-photos")).resolves.toBeNull();
  });

  test("a failed copy is reported once, with the folder for context", async () => {
    FileSystem.copyAsync.mockRejectedValue(BOOM);
    await persistPhotoSafe(TEMP, "job-photos");
    expect(reportError).toHaveBeenCalledTimes(1);
    expect(reportError).toHaveBeenCalledWith(BOOM, {
      context: "persistPhoto",
      folder: "job-photos",
    });
  });

  test("a failed folder stat is handled too", async () => {
    FileSystem.getInfoAsync.mockRejectedValue(BOOM);
    await expect(persistPhotoSafe(TEMP, "logos")).resolves.toBeNull();
    expect(reportError).toHaveBeenCalledTimes(1);
  });

  test("a failed folder creation is handled too", async () => {
    FileSystem.getInfoAsync.mockResolvedValue({ exists: false });
    FileSystem.makeDirectoryAsync.mockRejectedValue(BOOM);
    await expect(persistPhotoSafe(TEMP, "logos")).resolves.toBeNull();
    expect(reportError).toHaveBeenCalledTimes(1);
  });

  test("nothing is written when the copy fails", async () => {
    FileSystem.copyAsync.mockRejectedValue(BOOM);
    const uri = await persistPhotoSafe(TEMP, "receipts");
    // The caller must not be handed a path to a file that was never created.
    expect(uri).toBeNull();
  });
});
