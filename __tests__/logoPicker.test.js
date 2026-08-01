// promptForLogo — the pick path, exercised through the Alert buttons it puts up.
//
// Both pick branches (camera, library) share persistPicked, so driving the
// library button covers the resize for both. The resize is the point: the
// picker's `quality: 0.8` tunes JPEG compression only and caps no dimension, so
// a phone photo used as a logo arrived at full resolution and was stored
// byte-for-byte — the origin of the ~40MB invoice PDFs.

import { Alert } from "react-native";

jest.mock("expo-file-system/legacy", () => ({
  documentDirectory: "file:///mock/",
  getInfoAsync: jest.fn(),
  makeDirectoryAsync: jest.fn(),
  copyAsync: jest.fn(),
}));

jest.mock("../utils/analytics", () => ({ reportError: jest.fn() }));

const FileSystem = require("expo-file-system/legacy");
const ImagePicker = require("expo-image-picker");
const ImageManipulator = require("expo-image-manipulator");
const { reportError } = require("../utils/analytics");
const { promptForLogo } = require("../utils/logoPicker");

const PICKED = "file:///tmp/DCIM/IMG_0001.jpg";
const SHRUNK = "file:///mock/manipulated.png";

let onPicked;
let alertSpy;

// Buttons: [0] Take Photo, [1] Choose from Library, [2] Cancel.
async function chooseFromLibrary() {
  promptForLogo(onPicked);
  const buttons = alertSpy.mock.calls[0][2];
  await buttons[1].onPress();
}

beforeEach(() => {
  jest.clearAllMocks();
  onPicked = jest.fn();
  alertSpy = jest.spyOn(Alert, "alert").mockImplementation(() => {});
  FileSystem.getInfoAsync.mockResolvedValue({ exists: true });
  FileSystem.makeDirectoryAsync.mockResolvedValue(undefined);
  FileSystem.copyAsync.mockResolvedValue(undefined);
  ImagePicker.requestMediaLibraryPermissionsAsync.mockResolvedValue({ status: "granted" });
  ImageManipulator.manipulateAsync.mockReset();
  ImageManipulator.manipulateAsync.mockResolvedValue({
    uri: SHRUNK,
    width: 512,
    height: 384,
  });
});

afterEach(() => alertSpy.mockRestore());

describe("promptForLogo", () => {
  test("resizes an oversized pick before storing it", async () => {
    ImagePicker.launchImageLibraryAsync.mockResolvedValueOnce({
      canceled: false,
      assets: [{ uri: PICKED, width: 4032, height: 3024 }],
    });
    await chooseFromLibrary();
    expect(ImageManipulator.manipulateAsync).toHaveBeenCalledWith(
      PICKED,
      [{ resize: { width: 512 } }],
      { compress: 0.8, format: "png" }
    );
  });

  test("caps a portrait pick on its height", async () => {
    ImagePicker.launchImageLibraryAsync.mockResolvedValueOnce({
      canceled: false,
      assets: [{ uri: PICKED, width: 3024, height: 4032 }],
    });
    await chooseFromLibrary();
    expect(ImageManipulator.manipulateAsync).toHaveBeenCalledWith(
      PICKED,
      [{ resize: { height: 512 } }],
      { compress: 0.8, format: "png" }
    );
  });

  test("re-encodes an already-small pick with no resize action", async () => {
    ImagePicker.launchImageLibraryAsync.mockResolvedValueOnce({
      canceled: false,
      assets: [{ uri: PICKED, width: 300, height: 120 }],
    });
    await chooseFromLibrary();
    expect(ImageManipulator.manipulateAsync).toHaveBeenCalledWith(PICKED, [], {
      compress: 0.8,
      format: "png",
    });
  });

  test("persists the manipulated file under a .png name, never the original", async () => {
    ImagePicker.launchImageLibraryAsync.mockResolvedValueOnce({
      canceled: false,
      assets: [{ uri: PICKED, width: 4032, height: 3024 }],
    });
    await chooseFromLibrary();
    const stored = onPicked.mock.calls[0][0];
    expect(stored).toMatch(/^file:\/\/\/mock\/logos\/.+\.png$/);
    expect(FileSystem.copyAsync).toHaveBeenCalledWith({ from: SHRUNK, to: stored });
  });

  test("probes the file when the picker reports no dimensions", async () => {
    // ImagePickerAsset documents width/height as "can be 0".
    ImagePicker.launchImageLibraryAsync.mockResolvedValueOnce({
      canceled: false,
      assets: [{ uri: PICKED, width: 0, height: 0 }],
    });
    ImageManipulator.manipulateAsync.mockResolvedValueOnce({
      uri: "file:///mock/probe.jpg",
      width: 4032,
      height: 3024,
    });
    await chooseFromLibrary();
    expect(ImageManipulator.manipulateAsync).toHaveBeenNthCalledWith(1, PICKED);
    expect(ImageManipulator.manipulateAsync).toHaveBeenNthCalledWith(
      2,
      PICKED,
      [{ resize: { width: 512 } }],
      { compress: 0.8, format: "png" }
    );
  });

  test("a manipulator failure stores the original and still reports the pick", async () => {
    const boom = new Error("out of memory");
    ImagePicker.launchImageLibraryAsync.mockResolvedValueOnce({
      canceled: false,
      assets: [{ uri: PICKED, width: 4032, height: 3024 }],
    });
    ImageManipulator.manipulateAsync.mockRejectedValueOnce(boom);
    await chooseFromLibrary();
    const stored = onPicked.mock.calls[0][0];
    expect(stored).toMatch(/^file:\/\/\/mock\/logos\/.+\.jpg$/);
    expect(FileSystem.copyAsync).toHaveBeenCalledWith({ from: PICKED, to: stored });
    expect(reportError).toHaveBeenCalledWith(boom, { context: "shrinkLogoOnPick" });
  });

  test("a cancelled pick manipulates and stores nothing", async () => {
    ImagePicker.launchImageLibraryAsync.mockResolvedValueOnce({ canceled: true });
    await chooseFromLibrary();
    expect(ImageManipulator.manipulateAsync).not.toHaveBeenCalled();
    expect(FileSystem.copyAsync).not.toHaveBeenCalled();
    expect(onPicked).not.toHaveBeenCalled();
  });

  test("a failed save alerts and never calls onPicked", async () => {
    ImagePicker.launchImageLibraryAsync.mockResolvedValueOnce({
      canceled: false,
      assets: [{ uri: PICKED, width: 4032, height: 3024 }],
    });
    FileSystem.copyAsync.mockRejectedValueOnce(new Error("disk full"));
    await chooseFromLibrary();
    expect(onPicked).not.toHaveBeenCalled();
    expect(alertSpy).toHaveBeenNthCalledWith(
      2,
      "Couldn't save that image",
      "Your logo wasn't changed. Please try again."
    );
  });
});
