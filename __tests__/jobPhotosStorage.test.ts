// __tests__/jobPhotosStorage.test.ts
// The jobPhotos collection: AsyncStorage under KEYS.jobPhotos, synced from
// birth (2026-08-06 job-photo R2 sync spec) — every save diffs into the sync
// queue like the other collections. Per-photo records so cross-device offline
// attaches never clobber (Job.photos, the whole-record LWW list, is legacy).

import AsyncStorage from '@react-native-async-storage/async-storage';
import { enqueueCollectionChanges, trySync } from '../utils/sync';
import { loadJobPhotos, saveJobPhotos, setJobPhotoVisibility } from '../utils/storage';
import type { JobPhoto } from '../types/models';

jest.mock('../utils/sync', () => ({
  enqueue: jest.fn(),
  enqueueCollectionChanges: jest.fn(),
  trySync: jest.fn(),
  pruneQueueRecords: jest.fn(),
}));
jest.mock('../utils/notifications', () => ({ syncNotifications: jest.fn() }));

const photo: JobPhoto = {
  id: 'p1723000000000_ab12xyz',
  jobId: 'j1700000000000_zzz',
  createdAt: '2026-08-06T15:00:00.000Z',
  uploadedAt: '2026-08-06T15:00:03.000Z',
  width: 1600,
  height: 1200,
};

beforeEach(() => {
  jest.clearAllMocks();
  (AsyncStorage.getItem as jest.Mock).mockResolvedValue(null);
  (AsyncStorage.setItem as jest.Mock).mockResolvedValue(undefined);
});

describe('jobPhotos storage', () => {
  test('loadJobPhotos returns [] when nothing is stored', async () => {
    expect(await loadJobPhotos()).toEqual([]);
  });

  test('saveJobPhotos writes JSON under the jobPhotos key', async () => {
    await saveJobPhotos([photo]);
    expect(AsyncStorage.setItem).toHaveBeenCalledWith(
      'jobPhotos',
      JSON.stringify([photo])
    );
  });

  test('saveJobPhotos diffs into the sync queue and kicks a background sync', async () => {
    await saveJobPhotos([photo]);
    expect(enqueueCollectionChanges).toHaveBeenCalledWith('jobPhotos', [], [photo]);
    expect(trySync).toHaveBeenCalled();
  });

  test('loadJobPhotos round-trips a saved record', async () => {
    (AsyncStorage.getItem as jest.Mock).mockResolvedValue(JSON.stringify([photo]));
    expect(await loadJobPhotos()).toEqual([photo]);
  });

  test('a record still pending upload (no uploadedAt) round-trips', async () => {
    const pending: JobPhoto = { id: 'p1_a', jobId: 'j1', createdAt: photo.createdAt };
    (AsyncStorage.getItem as jest.Mock).mockResolvedValue(JSON.stringify([pending]));
    const loaded = await loadJobPhotos();
    expect(loaded[0].uploadedAt).toBeUndefined();
  });

  test('corrupt JSON degrades to [] instead of throwing', async () => {
    (AsyncStorage.getItem as jest.Mock).mockResolvedValue('{not json');
    expect(await loadJobPhotos()).toEqual([]);
  });
});

describe('setJobPhotoVisibility (Phase 12B — absent means HIDDEN)', () => {
  test('toggling on persists customerVisible: true through the normal save path', async () => {
    (AsyncStorage.getItem as jest.Mock).mockResolvedValue(JSON.stringify([photo]));
    const updated = await setJobPhotoVisibility(photo.id, true);
    expect(updated).toEqual({ ...photo, customerVisible: true });
    expect(AsyncStorage.setItem).toHaveBeenCalledWith(
      'jobPhotos',
      JSON.stringify([{ ...photo, customerVisible: true }])
    );
    expect(enqueueCollectionChanges).toHaveBeenCalledWith('jobPhotos', [photo], [{ ...photo, customerVisible: true }]);
    expect(trySync).toHaveBeenCalled();
  });

  test('toggling off persists customerVisible: false (explicit, not deleted)', async () => {
    const visible: JobPhoto = { ...photo, customerVisible: true };
    (AsyncStorage.getItem as jest.Mock).mockResolvedValue(JSON.stringify([visible]));
    const updated = await setJobPhotoVisibility(photo.id, false);
    expect(updated?.customerVisible).toBe(false);
  });

  test('unknown id returns null and writes nothing', async () => {
    (AsyncStorage.getItem as jest.Mock).mockResolvedValue(JSON.stringify([photo]));
    expect(await setJobPhotoVisibility('p_nope', true)).toBeNull();
    expect(AsyncStorage.setItem).not.toHaveBeenCalled();
  });
});
