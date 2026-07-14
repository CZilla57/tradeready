import AsyncStorage from '@react-native-async-storage/async-storage';
import * as Network from 'expo-network';
import { supabase } from './supabase';
import { reportError } from './analytics';
import type { Settings, CustomerNotes } from '../types/models';

const QUEUE_KEY       = '__syncQueue';
const LAST_SYNCED_KEY = '__lastSyncedAt';
const INIT_DONE_KEY   = '__initDone_';
const DATA_OWNER_KEY  = '__dataOwner';

const COLLECTION_TABLES = ['jobs', 'invoices', 'customers', 'expenses', 'pricebook'] as const;

type SyncOp = 'upsert' | 'delete';

interface QueueItem {
  table: string;
  op: SyncOp;
  recordId: string;
  payload: unknown;
  ts: string;
}

export async function enqueue(table: string, op: SyncOp, recordId: string, payload: unknown): Promise<void> {
  const queue = await getQueue();
  const filtered = queue.filter(
    item => !(item.table === table && item.recordId === recordId)
  );
  filtered.push({ table, op, recordId, payload, ts: new Date().toISOString() });
  await AsyncStorage.setItem(QUEUE_KEY, JSON.stringify(filtered));
}

export async function enqueueCollectionChanges(
  table: string,
  oldRecords: { id?: string }[],
  newRecords: { id?: string }[]
): Promise<void> {
  const oldIds = new Set(oldRecords.map(r => r.id).filter(Boolean));
  const newIds = new Set(newRecords.map(r => r.id).filter(Boolean));

  for (const id of oldIds) {
    if (!newIds.has(id)) {
      await enqueue(table, 'delete', id as string, null);
    }
  }
  for (const record of newRecords) {
    if (record.id) await enqueue(table, 'upsert', record.id, record);
  }
}

async function getQueue(): Promise<QueueItem[]> {
  try {
    const raw = await AsyncStorage.getItem(QUEUE_KEY);
    return raw ? JSON.parse(raw) : [];
  } catch {
    return [];
  }
}

// Drops queue items whose recordId is in the given set. Used by the
// sample-id migration: legacy-id upserts can never succeed (they collide
// with another account's rows and RLS rejects them forever), and the same
// records are re-enqueued under their new ids by the migration's saves.
export async function pruneQueueRecords(recordIds: Set<string>): Promise<number> {
  const queue = await getQueue();
  const kept = queue.filter(item => !recordIds.has(item.recordId));
  const removed = queue.length - kept.length;
  if (removed > 0) {
    await AsyncStorage.setItem(QUEUE_KEY, JSON.stringify(kept));
  }
  return removed;
}

async function pushQueue(userId: string): Promise<void> {
  const queue = await getQueue();
  if (!queue.length) return;

  const failed: QueueItem[] = [];
  let firstError: unknown = null;
  for (const item of queue) {
    try {
      if (item.op === 'upsert') {
        if (item.table === 'settings') {
          const { error } = await supabase.from('settings').upsert({
            user_id: userId,
            data: item.payload,
            updated_at: item.ts,
          });
          if (error) throw error;
        } else if (item.table === 'customer_notes') {
          const { error } = await supabase.from('customer_notes').upsert({
            user_id: userId,
            customer_key: item.recordId,
            note: item.payload,
            updated_at: item.ts,
          });
          if (error) throw error;
        } else {
          const { error } = await supabase.from(item.table).upsert({
            id: item.recordId,
            user_id: userId,
            data: item.payload,
            updated_at: item.ts,
            deleted: false,
          });
          if (error) throw error;
        }
      } else if (item.op === 'delete') {
        const { error } = await supabase
          .from(item.table)
          .update({ deleted: true, updated_at: item.ts })
          .eq('id', item.recordId)
          .eq('user_id', userId);
        if (error) throw error;
      }
    } catch (e: unknown) {
      if (firstError === null) firstError = e;
      failed.push(item);
    }
  }
  // Failed items are retained for retry (unchanged behavior) — but silence
  // here let a missing cloud table wedge the queue invisibly for weeks
  // ("changes pending" forever; beta finding 2026-07-14). Surface one report
  // per push attempt with what failed, not one per item.
  if (failed.length) {
    const tables = [...new Set(failed.map(i => i.table))].join(',');
    console.warn(`Sync push: ${failed.length} item(s) failed (${tables}):`, (firstError as Error)?.message);
    reportError(firstError, { context: 'pushQueue', failedCount: failed.length, tables });
  }
  await AsyncStorage.setItem(QUEUE_KEY, JSON.stringify(failed));
}

async function pullRemote(userId: string): Promise<void> {
  try {
    const lastRaw = await AsyncStorage.getItem(LAST_SYNCED_KEY);
    const lastSynced: Record<string, string> = lastRaw ? JSON.parse(lastRaw) : {};
    const now = new Date().toISOString();

    for (const table of COLLECTION_TABLES) {
      const since = lastSynced[table] || '1970-01-01T00:00:00.000Z';
      const { data, error } = await supabase
        .from(table)
        .select('id, data, deleted')
        .eq('user_id', userId)
        .gt('updated_at', since);

      if (error || !data?.length) continue;

      const localRaw = await AsyncStorage.getItem(table);
      let local: { id: string }[] = localRaw ? JSON.parse(localRaw) : [];

      for (const remote of data) {
        if (remote.deleted) {
          local = local.filter(r => r.id !== remote.id);
        } else {
          const idx = local.findIndex(r => r.id === remote.id);
          if (idx >= 0) {
            local[idx] = remote.data;
          } else {
            local.push(remote.data);
          }
        }
      }
      await AsyncStorage.setItem(table, JSON.stringify(local));
      lastSynced[table] = now;
    }

    const { data: settingsRow } = await supabase
      .from('settings')
      .select('data')
      .eq('user_id', userId)
      .maybeSingle();

    if (settingsRow?.data) {
      await AsyncStorage.setItem('settings', JSON.stringify(settingsRow.data));
    }

    const { data: notesData } = await supabase
      .from('customer_notes')
      .select('customer_key, note')
      .eq('user_id', userId);

    if (notesData) {
      const map: Record<string, string> = {};
      notesData.forEach((n: { customer_key: string; note: string }) => { map[n.customer_key] = n.note; });
      await AsyncStorage.setItem('customerNotes', JSON.stringify(map));
    }

    await AsyncStorage.setItem(LAST_SYNCED_KEY, JSON.stringify(lastSynced));
  } catch (e: unknown) {
    console.warn('Sync pull failed:', (e as Error).message);
    reportError(e, { context: 'pullRemote' });
  }
}

export async function syncIfOnline(userId: string): Promise<void> {
  try {
    const net = await Network.getNetworkStateAsync();
    if (!net.isConnected) return;
    await pushQueue(userId);
    await pullRemote(userId);
  } catch (e: unknown) {
    console.warn('Sync failed:', (e as Error).message);
    reportError(e, { context: 'trySyncNow' });
  }
}

export async function trySync(): Promise<void> {
  try {
    const { data: { session } } = await supabase.auth.getSession();
    if (session?.user?.id) syncIfOnline(session.user.id);
  } catch { /* not logged in or offline */ }
}

export async function trySyncAwait(): Promise<void> {
  try {
    const { data: { session } } = await supabase.auth.getSession();
    if (session?.user?.id) await syncIfOnline(session.user.id);
  } catch { /* not logged in or offline */ }
}

export async function initialSync(userId: string): Promise<void> {
  try {
    const done = await AsyncStorage.getItem(INIT_DONE_KEY + userId);
    if (done) {
      syncIfOnline(userId);
      return;
    }

    const net = await Network.getNetworkStateAsync();
    if (!net.isConnected) return;

    const storedOwnerRaw = await AsyncStorage.getItem(DATA_OWNER_KEY);
    const dataOwner: string | null = storedOwnerRaw ? JSON.parse(storedOwnerRaw) : null;
    const localDataBelongsToOtherUser = dataOwner !== null && dataOwner !== userId;

    const { count } = await supabase
      .from('settings')
      .select('user_id', { count: 'exact', head: true })
      .eq('user_id', userId);

    if (count === 0 && !localDataBelongsToOtherUser) {
      await pushAllLocalToCloud(userId);
    } else {
      if (localDataBelongsToOtherUser) {
        await AsyncStorage.multiRemove([...COLLECTION_TABLES, 'customerNotes', 'recurringJobs', 'trips']);
        await AsyncStorage.removeItem(QUEUE_KEY);
      }
      await AsyncStorage.setItem(LAST_SYNCED_KEY, JSON.stringify({}));
      await pullRemote(userId);
    }

    await AsyncStorage.setItem(DATA_OWNER_KEY, JSON.stringify(userId));
    await AsyncStorage.setItem(INIT_DONE_KEY + userId, 'true');
  } catch (e: unknown) {
    console.warn('Initial sync failed:', (e as Error).message);
    reportError(e, { context: 'initialSync' });
  }
}

async function pushAllLocalToCloud(userId: string): Promise<void> {
  for (const table of COLLECTION_TABLES) {
    const raw = await AsyncStorage.getItem(table);
    const records: { id: string }[] = raw ? JSON.parse(raw) : [];
    if (!records.length) continue;
    const { error } = await supabase.from(table).upsert(
      records.map(r => ({
        id: r.id,
        user_id: userId,
        data: r,
        updated_at: new Date().toISOString(),
        deleted: false,
      }))
    );
    // Ignoring these errors hid the sample-id RLS collisions for weeks —
    // keep the first-device push best-effort, but never silent.
    if (error) {
      console.warn(`Initial push failed for ${table}:`, error.message);
      reportError(error, { context: 'pushAllLocalToCloud', table });
    }
  }

  const raw = await AsyncStorage.getItem('settings');
  if (raw) {
    const settings: Partial<Settings> = JSON.parse(raw);
    const safe = { ...settings };
    delete (safe as any).providerKey;
    delete (safe as any).anthropicKey;
    await supabase.from('settings').upsert({
      user_id: userId,
      data: safe,
      updated_at: new Date().toISOString(),
    });
  }

  const notesRaw = await AsyncStorage.getItem('customerNotes');
  if (notesRaw) {
    const notes: CustomerNotes = JSON.parse(notesRaw);
    const rows = Object.entries(notes).map(([key, note]) => ({
      user_id: userId,
      customer_key: key,
      note,
      updated_at: new Date().toISOString(),
    }));
    if (rows.length) await supabase.from('customer_notes').upsert(rows);
  }
}
