import React, { createContext, useContext } from 'react';
import { useSyncStatus, type SyncStatus } from '../hooks/useSyncStatus';

const defaultStatus: SyncStatus = {
  isOnline: true,
  pendingCount: 0,
  syncing: false,
  syncNow: () => {},
};

const SyncStatusContext = createContext<SyncStatus>(defaultStatus);

export function SyncStatusProvider({ children }: { children: React.ReactNode }) {
  const status = useSyncStatus();
  return (
    <SyncStatusContext.Provider value={status}>
      {children}
    </SyncStatusContext.Provider>
  );
}

export function useSyncStatusContext(): SyncStatus {
  return useContext(SyncStatusContext);
}
