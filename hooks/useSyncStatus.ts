import { useState, useEffect, useCallback, useRef } from 'react';
import * as Network from 'expo-network';
import AsyncStorage from '@react-native-async-storage/async-storage';
import { trySyncAwait } from '../utils/sync';

const QUEUE_KEY = '__syncQueue';
const POLL_INTERVAL = 5000;

export interface SyncStatus {
  isOnline: boolean;
  pendingCount: number;
  syncing: boolean;
  syncNow: () => void;
}

async function poll(): Promise<{ isOnline: boolean; pendingCount: number }> {
  const [net, raw] = await Promise.all([
    Network.getNetworkStateAsync(),
    AsyncStorage.getItem(QUEUE_KEY),
  ]);
  const isOnline = net.isConnected ?? false;
  let pendingCount = 0;
  if (raw) {
    try { pendingCount = JSON.parse(raw).length; } catch { /* malformed queue, treat as empty */ }
  }
  return { isOnline, pendingCount };
}

export function useSyncStatus(): SyncStatus {
  const [isOnline, setIsOnline] = useState(true);
  const [pendingCount, setPendingCount] = useState(0);
  const [syncing, setSyncing] = useState(false);
  const mountedRef = useRef(true);

  const runPoll = useCallback(async () => {
    try {
      const result = await poll();
      if (mountedRef.current) {
        setIsOnline(result.isOnline);
        setPendingCount(result.pendingCount);
      }
    } catch { /* network or storage read failed; keep previous state */ }
  }, []);

  useEffect(() => {
    mountedRef.current = true;
    runPoll();
    const id = setInterval(runPoll, POLL_INTERVAL);
    return () => {
      mountedRef.current = false;
      clearInterval(id);
    };
  }, [runPoll]);

  const syncNow = useCallback(() => {
    if (syncing) return;
    setSyncing(true);
    (async () => {
      try {
        await trySyncAwait();
      } catch { /* sync failure surfaced via unchanged pendingCount */ }
      await runPoll();
    })().finally(() => {
      if (mountedRef.current) setSyncing(false);
    });
  }, [syncing, runPoll]);

  return { isOnline, pendingCount, syncing, syncNow };
}
