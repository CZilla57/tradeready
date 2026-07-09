import { useState, useCallback } from 'react';
import { trySyncAwait } from '../utils/sync';
import { track } from '../utils/analytics';

export function useRefresh(
  reload: () => Promise<void>,
  screen?: string,
): { refreshing: boolean; onRefresh: () => void } {
  const [refreshing, setRefreshing] = useState(false);

  const onRefresh = useCallback(() => {
    setRefreshing(true);

    (async () => {
      try { await trySyncAwait(); } catch {}
      try { await reload(); } catch (err) { console.error('useRefresh: reload failed', err); }
      if (screen) track('pull_to_refresh', { screen });
    })().finally(() => setRefreshing(false));
  }, [reload, screen]);

  return { refreshing, onRefresh };
}
