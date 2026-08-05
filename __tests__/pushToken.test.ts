// __tests__/pushToken.test.ts
// Push registration must be harmless everywhere it can't work (Expo Go, no
// entitlement, no permission, offline): silent no-op, never a throw, never a
// prompt (the local-reminders flow owns the permission ask). Saves only on
// change — every settings save re-enqueues the whole blob.

import { registerPushToken } from '../utils/pushToken';
import * as Notifications from 'expo-notifications';
import { loadSettings, saveSettings } from '../utils/storage';

jest.mock('expo-notifications', () => ({
  getPermissionsAsync: jest.fn(),
  getExpoPushTokenAsync: jest.fn(),
}));
jest.mock('expo-constants', () => ({
  expoConfig: { extra: { backendUrl: 'https://backend.unit.test', eas: { projectId: 'proj-123' } } },
}));
jest.mock('../utils/storage', () => ({
  loadSettings: jest.fn(),
  saveSettings: jest.fn(),
}));

const perms = Notifications.getPermissionsAsync as jest.Mock;
const getToken = Notifications.getExpoPushTokenAsync as jest.Mock;
const load = loadSettings as jest.Mock;
const save = saveSettings as jest.Mock;

beforeEach(() => {
  jest.clearAllMocks();
  perms.mockResolvedValue({ granted: true });
  getToken.mockResolvedValue({ data: 'ExponentPushToken[abc]' });
  load.mockResolvedValue({ businessName: 'X' });
  save.mockResolvedValue(undefined);
});

describe('registerPushToken', () => {
  it('saves a new token into settings.pushToken', async () => {
    await registerPushToken();
    expect(getToken).toHaveBeenCalledWith({ projectId: 'proj-123' });
    const saved = save.mock.calls[0][0];
    expect(saved.pushToken.token).toBe('ExponentPushToken[abc]');
    expect(['ios', 'android']).toContain(saved.pushToken.platform);
    expect(typeof saved.pushToken.updatedAt).toBe('string');
  });

  it('does nothing without permission — and never prompts', async () => {
    perms.mockResolvedValue({ granted: false });
    await registerPushToken();
    expect(getToken).not.toHaveBeenCalled();
    expect(save).not.toHaveBeenCalled();
  });

  it('does not save when the stored token is already current', async () => {
    load.mockResolvedValue({ pushToken: { token: 'ExponentPushToken[abc]', platform: 'ios', updatedAt: 't' } });
    await registerPushToken();
    expect(save).not.toHaveBeenCalled();
  });

  it('silently no-ops when getExpoPushTokenAsync throws (Expo Go / no entitlement)', async () => {
    getToken.mockRejectedValue(new Error('no push capability'));
    await expect(registerPushToken()).resolves.toBeUndefined();
    expect(save).not.toHaveBeenCalled();
  });
});
