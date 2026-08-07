// utils/photoSync.ts — job-photo capture/upload/delete + legacy adoption
// migration (2026-08-06 R2 sync spec). expo-constants (jest.setup) reports a
// ready backend, so backendReady() is true here. jest.mock calls are hoisted
// above these imports by babel-plugin-jest-hoist (repo convention: imports
// first, mocks after).

import * as FileSystem from "expo-file-system/legacy";
import {
  newPhotoId,
  attachJobPhoto,
  uploadPendingPhotos,
  deleteJobPhoto,
  migrateLegacyJobPhotos,
} from "../utils/photoSync";
import { loadJobs, saveJobs, loadJobPhotos, saveJobPhotos } from "../utils/storage";
import { saveCompressedJobPhoto, photoExists, deletePhoto } from "../utils/photoStorage";
import { supabase } from "../utils/supabase";
import type { Job, JobPhoto } from "../types/models";

// Full FS mock: the global jest.setup mock lacks uploadAsync/FileSystemUploadType.
jest.mock("expo-file-system/legacy", () => ({
  documentDirectory: "file:///mock/",
  uploadAsync: jest.fn(),
  FileSystemUploadType: { BINARY_CONTENT: "binary" },
}));

jest.mock("../utils/storage", () => ({
  loadJobs: jest.fn(),
  saveJobs: jest.fn(),
  loadJobPhotos: jest.fn(),
  saveJobPhotos: jest.fn(),
}));
jest.mock("../utils/photoStorage", () => ({
  jobPhotoUri: (id: string) => `file:///mock/job-photos/${id}.jpg`,
  saveCompressedJobPhoto: jest.fn(),
  photoExists: jest.fn(),
  deletePhoto: jest.fn(),
}));
jest.mock("../utils/supabase", () => ({
  supabase: { auth: { getSession: jest.fn() } },
}));
jest.mock("../utils/analytics", () => ({ reportError: jest.fn() }));

const uploadAsync = FileSystem.uploadAsync as jest.Mock;
const getSession = supabase.auth.getSession as jest.Mock;

const REC: JobPhoto = {
  id: "p1723000000000_ab12",
  jobId: "j1",
  createdAt: "2026-08-06T00:00:00.000Z",
  width: 1600,
  height: 1200,
};

beforeEach(() => {
  jest.clearAllMocks();
  (loadJobPhotos as jest.Mock).mockResolvedValue([]);
  (saveJobPhotos as jest.Mock).mockResolvedValue(undefined);
  (loadJobs as jest.Mock).mockResolvedValue([]);
  (saveJobs as jest.Mock).mockResolvedValue(undefined);
  (saveCompressedJobPhoto as jest.Mock).mockResolvedValue({ width: 1600, height: 1200 });
  (photoExists as jest.Mock).mockResolvedValue(true);
  (deletePhoto as jest.Mock).mockResolvedValue(undefined);
  getSession.mockResolvedValue({ data: { session: null } }); // no token by default
  uploadAsync.mockResolvedValue({ status: 200 });
  (global as any).fetch = jest.fn(() => Promise.resolve({ ok: true, status: 204 }));
});

describe("newPhotoId", () => {
  test("matches the backend PHOTO_ID_RE shape", () => {
    for (let i = 0; i < 50; i++) {
      expect(newPhotoId()).toMatch(/^p[0-9]{1,20}_[a-z0-9]{1,32}$/);
    }
  });
});

describe("attachJobPhoto", () => {
  test("compresses, saves a record, and returns it", async () => {
    const rec = await attachJobPhoto("j9", "file:///tmp/pick.jpg");
    expect(rec).not.toBeNull();
    expect(rec!.jobId).toBe("j9");
    expect(rec!.width).toBe(1600);
    expect(saveJobPhotos).toHaveBeenCalledWith([rec]);
  });

  test("returns null and saves nothing when compression fails", async () => {
    (saveCompressedJobPhoto as jest.Mock).mockResolvedValue(null);
    const rec = await attachJobPhoto("j9", "file:///tmp/pick.jpg");
    expect(rec).toBeNull();
    expect(saveJobPhotos).not.toHaveBeenCalled();
  });
});

describe("uploadPendingPhotos", () => {
  test("PUTs a pending photo and stamps uploadedAt", async () => {
    const pending = { ...REC, uploadedAt: undefined };
    (loadJobPhotos as jest.Mock).mockResolvedValue([pending]);
    getSession.mockResolvedValue({ data: { session: { access_token: "tok" } } });

    await uploadPendingPhotos();

    expect(uploadAsync).toHaveBeenCalledWith(
      `https://tradeready-backend.tradeready.workers.dev/api/photos/${REC.id}`,
      `file:///mock/job-photos/${REC.id}.jpg`,
      expect.objectContaining({
        httpMethod: "PUT",
        uploadType: "binary",
        headers: expect.objectContaining({
          Authorization: "Bearer tok",
          "Content-Type": "image/jpeg",
        }),
      }),
    );
    const saved = (saveJobPhotos as jest.Mock).mock.calls[0][0];
    expect(saved[0].uploadedAt).toEqual(expect.any(String));
  });

  test("skips a record whose local file is missing (another device's)", async () => {
    (loadJobPhotos as jest.Mock).mockResolvedValue([{ ...REC, uploadedAt: undefined }]);
    getSession.mockResolvedValue({ data: { session: { access_token: "tok" } } });
    (photoExists as jest.Mock).mockResolvedValue(false);

    await uploadPendingPhotos();

    expect(uploadAsync).not.toHaveBeenCalled();
    expect(saveJobPhotos).not.toHaveBeenCalled();
  });

  test("no-op when every record is already uploaded", async () => {
    (loadJobPhotos as jest.Mock).mockResolvedValue([
      { ...REC, uploadedAt: "2026-08-06T00:00:05.000Z" },
    ]);
    getSession.mockResolvedValue({ data: { session: { access_token: "tok" } } });
    await uploadPendingPhotos();
    expect(uploadAsync).not.toHaveBeenCalled();
  });

  test("does not upload without a session token", async () => {
    (loadJobPhotos as jest.Mock).mockResolvedValue([{ ...REC, uploadedAt: undefined }]);
    await uploadPendingPhotos(); // getSession returns no session by default
    expect(uploadAsync).not.toHaveBeenCalled();
  });
});

describe("deleteJobPhoto", () => {
  test("removes the record, deletes the local file, and DELETEs from R2", async () => {
    (loadJobPhotos as jest.Mock).mockResolvedValue([REC, { ...REC, id: "p2_x" }]);
    getSession.mockResolvedValue({ data: { session: { access_token: "tok" } } });

    await deleteJobPhoto(REC.id);

    expect(saveJobPhotos).toHaveBeenCalledWith([{ ...REC, id: "p2_x" }]);
    expect(deletePhoto).toHaveBeenCalledWith(`file:///mock/job-photos/${REC.id}.jpg`);
    expect((global as any).fetch).toHaveBeenCalledWith(
      `https://tradeready-backend.tradeready.workers.dev/api/photos/${REC.id}`,
      expect.objectContaining({ method: "DELETE" }),
    );
  });
});

describe("migrateLegacyJobPhotos", () => {
  const jobWithPhotos: Job = {
    id: "j1",
    photos: ["file:///old/a.jpg", "file:///old/b.jpg"],
    createdAt: "2026-08-01",
  } as Job;

  test("idempotent fast path: no legacy photos → no writes", async () => {
    (loadJobs as jest.Mock).mockResolvedValue([{ id: "j1" } as Job]);
    await migrateLegacyJobPhotos();
    expect(saveJobs).not.toHaveBeenCalled();
    expect(saveJobPhotos).not.toHaveBeenCalled();
  });

  test("drains legacy URIs into records and clears Job.photos", async () => {
    (loadJobs as jest.Mock).mockResolvedValue([jobWithPhotos]);
    await migrateLegacyJobPhotos();

    const savedPhotos = (saveJobPhotos as jest.Mock).mock.calls[0][0];
    expect(savedPhotos).toHaveLength(2);
    expect(savedPhotos.every((p: JobPhoto) => p.jobId === "j1")).toBe(true);

    const savedJobs = (saveJobs as jest.Mock).mock.calls[0][0];
    expect(savedJobs[0].photos).toBeUndefined();
    expect(deletePhoto).toHaveBeenCalledTimes(2);
  });

  test("drops a dangling URI without creating a record", async () => {
    (photoExists as jest.Mock).mockResolvedValue(false);
    (loadJobs as jest.Mock).mockResolvedValue([
      { id: "j1", photos: ["file:///gone.jpg"], createdAt: "2026-08-01" } as Job,
    ]);
    await migrateLegacyJobPhotos();

    expect(saveJobPhotos).not.toHaveBeenCalled(); // no new records
    const savedJobs = (saveJobs as jest.Mock).mock.calls[0][0];
    expect(savedJobs[0].photos).toBeUndefined(); // dangling ref dropped
  });
});
