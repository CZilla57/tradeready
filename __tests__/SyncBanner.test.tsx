// RNTL v14 ships an async render() — every test must await it.
import React from 'react';
import { render, fireEvent } from '@testing-library/react-native';
import { SyncBanner } from '../components/SyncBanner';

const mockSyncNow = jest.fn();
let mockStatus = { isOnline: true, pendingCount: 0, syncing: false, syncNow: mockSyncNow };

jest.mock('../context/SyncStatusContext', () => ({
  useSyncStatusContext: () => mockStatus,
}));
jest.mock('../context/ThemeContext', () => ({
  useThemeContext: () => ({
    colors: {
      danger: '#ff3b30',
      dangerBg: '#fff1f0',
      warning: '#ff9500',
      warningBg: '#fff8ed',
      textPrimary: '#1c1c1e',
      surface: '#ffffff',
    },
  }),
}));
jest.mock('react-native-safe-area-context', () => ({
  useSafeAreaInsets: () => ({ top: 44, bottom: 0, left: 0, right: 0 }),
}));
// @expo/vector-icons@15.1.1 resolves to an expo-font version incompatible
// with this project's Expo SDK 54 install (missing expo-asset in the Jest
// module-resolution path). Mock it here rather than touch dependencies.
jest.mock('@expo/vector-icons', () => ({
  Ionicons: 'Ionicons',
}));

beforeEach(() => {
  jest.clearAllMocks();
  mockStatus = { isOnline: true, pendingCount: 0, syncing: false, syncNow: mockSyncNow };
});

describe('SyncBanner', () => {
  it('renders nothing when online with zero pending changes', async () => {
    const { queryByText } = await render(<SyncBanner />);
    expect(queryByText("You're offline")).toBeNull();
    expect(queryByText(/changes pending/)).toBeNull();
  });

  it('shows "You\'re offline" text when isOnline is false', async () => {
    mockStatus = { ...mockStatus, isOnline: false };
    const { getByText } = await render(<SyncBanner />);
    expect(getByText("You're offline")).toBeTruthy();
  });

  it('shows pending changes with Sync Now button when pendingCount > 0 and online', async () => {
    mockStatus = { ...mockStatus, pendingCount: 3 };
    const { getByText } = await render(<SyncBanner />);
    expect(getByText('3 changes pending')).toBeTruthy();
    expect(getByText('Sync Now')).toBeTruthy();
  });

  it('Sync Now button calls syncNow', async () => {
    mockStatus = { ...mockStatus, pendingCount: 2 };
    const { getByText } = await render(<SyncBanner />);
    fireEvent.press(getByText('Sync Now'));
    expect(mockSyncNow).toHaveBeenCalledTimes(1);
  });

  it('shows ActivityIndicator while syncing is true', async () => {
    mockStatus = { ...mockStatus, pendingCount: 1, syncing: true };
    const { getByTestId, queryByText } = await render(<SyncBanner />);
    expect(getByTestId('sync-spinner')).toBeTruthy();
    expect(queryByText('Sync Now')).toBeNull();
  });

  it('does not show Sync Now button when offline', async () => {
    mockStatus = { ...mockStatus, isOnline: false, pendingCount: 5 };
    const { queryByText, getByText } = await render(<SyncBanner />);
    expect(getByText("You're offline")).toBeTruthy();
    expect(queryByText('Sync Now')).toBeNull();
  });
});
