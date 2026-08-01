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
  readAsStringAsync: jest.fn(),
  EncodingType: { Base64: "base64" },
}));

jest.mock("../utils/analytics", () => ({ reportError: jest.fn() }));

const FileSystem = require("expo-file-system/legacy");
const ImageManipulator = require("expo-image-manipulator");
const { reportError } = require("../utils/analytics");
const {
  persistPhotoSafe,
  logoResizeActions,
  readLogoForPdf,
} = require("../utils/photoStorage");

const TEMP = "file:///tmp/picked-image.jpg";
const BOOM = new Error("copy failed");
const LOGO = "file:///mock/logos/1700000000000_abc.png";

beforeEach(() => {
  jest.clearAllMocks();
  FileSystem.getInfoAsync.mockResolvedValue({ exists: true });
  FileSystem.makeDirectoryAsync.mockResolvedValue(undefined);
  FileSystem.copyAsync.mockResolvedValue(undefined);
  FileSystem.readAsStringAsync.mockResolvedValue("RAWBYTES");
  // mockReset (not mockClear) so a leftover mockResolvedValueOnce from a
  // previous test can never bleed into the next one.
  ImageManipulator.manipulateAsync.mockReset();
  ImageManipulator.manipulateAsync.mockResolvedValue({
    uri: "file:///mock/manipulated.png",
    width: 512,
    height: 512,
    base64: "PNGDATA",
  });
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

  test("stores under the requested extension so the file name matches its bytes", async () => {
    // A resized logo is PNG. readPhotoAsDataUri derives the data-URI mime type
    // from the extension, so a .jpg name on PNG bytes would mislabel it.
    const uri = await persistPhotoSafe(TEMP, "logos", "png");
    expect(uri).toMatch(/^file:\/\/\/mock\/logos\/.+\.png$/);
  });

  test("defaults to .jpg, so existing callers are unchanged", async () => {
    const uri = await persistPhotoSafe(TEMP, "job-photos");
    expect(uri).toMatch(/^file:\/\/\/mock\/job-photos\/.+\.jpg$/);
  });
});

describe("logoResizeActions", () => {
  test("caps a landscape image on its width", () => {
    expect(logoResizeActions(4032, 3024)).toEqual([{ resize: { width: 512 } }]);
  });

  test("caps a portrait image on its height", () => {
    expect(logoResizeActions(3024, 4032)).toEqual([{ resize: { height: 512 } }]);
  });

  test("caps a square image on its width", () => {
    expect(logoResizeActions(2000, 2000)).toEqual([{ resize: { width: 512 } }]);
  });

  test("leaves an image that is already within the cap alone", () => {
    expect(logoResizeActions(300, 120)).toEqual([]);
  });

  test("treats exactly 512 as within the cap", () => {
    expect(logoResizeActions(512, 200)).toEqual([]);
  });

  test("returns no actions for unreported dimensions, so nothing is upscaled", () => {
    // ImagePickerAsset documents width/height as "can be 0"; a naive
    // resize-to-512 would blow a 0x0 or unknown image up instead of down.
    expect(logoResizeActions(0, 0)).toEqual([]);
    expect(logoResizeActions(NaN, NaN)).toEqual([]);
  });
});

describe("readLogoForPdf", () => {
  test("returns a png data uri built from the manipulator's base64", async () => {
    await expect(readLogoForPdf(LOGO)).resolves.toBe("data:image/png;base64,PNGDATA");
    expect(reportError).not.toHaveBeenCalled();
  });

  test("caps an oversized landscape logo at 512 on its longest side", async () => {
    ImageManipulator.manipulateAsync.mockResolvedValueOnce({
      uri: "file:///mock/probe.jpg",
      width: 4032,
      height: 3024,
    });
    await readLogoForPdf(LOGO);
    expect(ImageManipulator.manipulateAsync).toHaveBeenNthCalledWith(1, LOGO);
    expect(ImageManipulator.manipulateAsync).toHaveBeenNthCalledWith(
      2,
      LOGO,
      [{ resize: { width: 512 } }],
      { compress: 0.8, format: "png", base64: true }
    );
  });

  test("caps an oversized portrait logo on its height", async () => {
    ImageManipulator.manipulateAsync.mockResolvedValueOnce({
      uri: "file:///mock/probe.jpg",
      width: 3024,
      height: 4032,
    });
    await readLogoForPdf(LOGO);
    expect(ImageManipulator.manipulateAsync).toHaveBeenNthCalledWith(
      2,
      LOGO,
      [{ resize: { height: 512 } }],
      { compress: 0.8, format: "png", base64: true }
    );
  });

  test("re-encodes a logo that is already small with no resize action", async () => {
    ImageManipulator.manipulateAsync.mockResolvedValueOnce({
      uri: "file:///mock/probe.jpg",
      width: 280,
      height: 112,
    });
    await readLogoForPdf(LOGO);
    expect(ImageManipulator.manipulateAsync).toHaveBeenNthCalledWith(2, LOGO, [], {
      compress: 0.8,
      format: "png",
      base64: true,
    });
  });

  test("never rewrites the stored logo file", async () => {
    // The Settings draft keeps a logo file alive until Save, and the orphan
    // sweep matches on exact paths — an in-place rewrite would break both.
    await readLogoForPdf(LOGO);
    expect(FileSystem.copyAsync).not.toHaveBeenCalled();
  });

  test("falls back to the raw file and reports when the manipulator throws", async () => {
    const boom = new Error("decode failed");
    ImageManipulator.manipulateAsync.mockRejectedValueOnce(boom);
    await expect(readLogoForPdf(LOGO)).resolves.toBe("data:image/png;base64,RAWBYTES");
    expect(reportError).toHaveBeenCalledWith(boom, { context: "readLogoForPdf" });
  });

  test("falls back and reports when the manipulator returns no base64", async () => {
    ImageManipulator.manipulateAsync
      .mockResolvedValueOnce({ uri: "file:///mock/probe.jpg", width: 4032, height: 3024 })
      .mockResolvedValueOnce({ uri: "file:///mock/out.png", width: 512, height: 384 });
    await expect(readLogoForPdf(LOGO)).resolves.toBe("data:image/png;base64,RAWBYTES");
    expect(reportError).toHaveBeenCalledTimes(1);
  });

  test("returns null without calling the manipulator when the logo file is gone", async () => {
    // A logo path does not survive a reinstall (see photoExists). That is not
    // an error and must not page anyone.
    FileSystem.getInfoAsync.mockResolvedValue({ exists: false });
    await expect(readLogoForPdf(LOGO)).resolves.toBeNull();
    expect(ImageManipulator.manipulateAsync).not.toHaveBeenCalled();
    expect(reportError).not.toHaveBeenCalled();
  });
});
