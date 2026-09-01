import AsyncStorage from '@react-native-async-storage/async-storage';
import * as Network from 'expo-network';
import { supabase } from './supabase';
import { reportError } from './analytics';
import { mergeRemoteRecord } from './syncMerge';
import type { SyncRecord } from './syncMerge';
import { REVIEW_REQUESTS_STORAGE_KEY } from './reviewRequest';
import { SECURE_FIELDS } from './storage/keys';
import type { Settings, CustomerNotes } from '../types/models';

const QUEUE_KEY       = '__syncQueue';
const LAST_SYNCED_KEY = '__lastSyncedAt';
const INIT_DONE_KEY   = '__initDone_';
const DATA_OWNER_KEY  = '__dataOwner';

// Pull cursor v2 stores DATABASE timestamps returned by Supabase, never the
// device clock. Versioning is load-bearing: v1 stored `new Date()` from the
// phone, so an ahead-of-time device may already have a poisoned future cursor.
// Treat every pre-v2 value as empty and perform one safe full pull after upgrade.
const SYNC_CURSOR_VERSION = 2 as const;
const PULL_PAGE_SIZE = 500;
const PULL_OVERLAP_MS = 5 * 60 * 1000;
const EPOCH = '1970-01-01T00:00:00.000Z';

type ServerWatermarks = Record<string, string>;

interface PersistedSyncCursor {
  version: typeof SYNC_CURSOR_VERSION;
  tables: ServerWatermarks;
}

interface RemoteSyncRow {
  id: string;
  data: SyncRecord;
  deleted: boolean;
  updated_at: string;
}

function emptySyncCursor(): PersistedSyncCursor {
  return { version: SYNC_CURSOR_VERSION, tables: {} };
}

function parseSyncCursor(raw: string | null): PersistedSyncCursor {
  if (!raw) return emptySyncCursor();
  try {
    const parsed = JSON.parse(raw) as Partial<PersistedSyncCursor>;
    if (
      parsed.version === SYNC_CURSOR_VERSION &&
      parsed.tables &&
      typeof parsed.tables === 'object' &&
      !Array.isArray(parsed.tables)
    ) {
      return { version: SYNC_CURSOR_VERSION, tables: parsed.tables };
    }
  } catch {
    // Corrupt or legacy cursor: recover with a full, idempotent pull.
  }
  return emptySyncCursor();
}

function pullStart(watermark: string | undefined): string {
  if (!watermark) return EPOCH;
  const ms = Date.parse(watermark);
  if (!Number.isFinite(ms)) return EPOCH;
  return new Date(Math.max(0, ms - PULL_OVERLAP_MS)).toISOString();
}

function laterTimestamp(current: string | undefined, candidate: string): string {
  if (!current) return candidate;
  const currentMs = Date.parse(current);
  const candidateMs = Date.parse(candidate);
  if (!Number.isFinite(candidateMs)) return current;
  if (!Number.isFinite(currentMs) || candidateMs > currentMs) return candidate;
  return current;
}

const COLLECTION_TABLES = ['jobs', 'invoices', 'customers', 'expenses', 'pricebook', 'recurringJobs', 'recurringInvoices', 'trips', 'bookingRequests', 'jobPhotos'] as const;

// Tables added to COLLECTION_TABLES after their collections already existed
// on devices (2026-08-03 durability work). Existing installs hold local
// records that predate sync for these — nothing re-enqueues a collection
// until its next save, so a one-time backfill enqueues every local record on
// the first sign-in after this code ships. Per-user flag: the queue itself is
// persistent and failed pushes are retained for retry, so stamping right
// after enqueue is safe even offline.
const BACKFILLED_TABLES = ['recurringJobs', 'recurringInvoices', 'trips'] as const;
const BACKFILL_KEY = '__collBackfill_v1_';

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
    // Stamp with the moment this item is actually being pushed, not
    // item.ts (when the user saved / enqueued it). A queued item can be
    // pushed long after it was saved (failed push retried, offline device
    // reconnecting) — if updated_at were backdated to save time, it would
    // be invisible to another device's `gt('updated_at', since)` pull
    // filter whenever that device's watermark had already advanced past
    // the backdated stamp, so the row would never propagate.
    const pushedAt = new Date().toISOString();
    try {
      if (item.op === 'upsert') {
        if (item.table === 'settings') {
          const { error } = await supabase.from('settings').upsert({
            user_id: userId,
            data: item.payload,
            updated_at: pushedAt,
          });
          if (error) throw error;
        } else if (item.table === 'customer_notes') {
          const { error } = await supabase.from('customer_notes').upsert({
            user_id: userId,
            customer_key: item.recordId,
            note: item.payload,
            updated_at: pushedAt,
          });
          if (error) throw error;
        } else {
          const { error } = await supabase.from(item.table).upsert({
            id: item.recordId,
            user_id: userId,
            data: item.payload,
            updated_at: pushedAt,
            deleted: false,
          });
          if (error) throw error;
        }
      } else if (item.op === 'delete') {
        const { error } = await supabase
          .from(item.table)
          .update({ deleted: true, updated_at: pushedAt })
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
    const cursor = parseSyncCursor(lastRaw);

    for (const table of COLLECTION_TABLES) {
      const since = pullStart(cursor.tables[table]);
      let offset = 0;
      let local: SyncRecord[] | null = null;
      let tableWatermark = cursor.tables[table];
      let failed = false;

      // Supabase projects cap select responses (commonly 1,000 rows). Pull in a
      // deterministic order and drain every page before committing the local
      // collection or advancing its cursor. The overlap makes a late-committing
      // transaction visible on the next pass even if its transaction timestamp
      // sorts just behind the previous high-water mark.
      while (true) {
        const { data, error } = await supabase
          .from(table)
          .select('id, data, deleted, updated_at')
          .eq('user_id', userId)
          .gte('updated_at', since)
          .order('updated_at', { ascending: true })
          .order('id', { ascending: true })
          .range(offset, offset + PULL_PAGE_SIZE - 1);

        if (error) {
          failed = true;
          break;
        }

        const page = (data ?? []) as RemoteSyncRow[];
        if (!page.length) break;

        if (local === null) {
          const localRaw = await AsyncStorage.getItem(table);
          local = localRaw ? JSON.parse(localRaw) : [];
        }
        let pageLocal: SyncRecord[] = local ?? [];

        for (const remote of page) {
          tableWatermark = laterTimestamp(tableWatermark, remote.updated_at);
          if (remote.deleted) {
            pageLocal = pageLocal.filter(r => r.id !== remote.id);
          } else {
            const idx = pageLocal.findIndex(r => r.id === remote.id);
            if (idx >= 0) {
              // invoices union their payment ledgers instead of replacing —
              // see utils/syncMerge.ts. Every other table replaces as before.
              pageLocal[idx] = mergeRemoteRecord(table, pageLocal[idx], remote.data);
            } else {
              // Route new records through the dispatcher too — otherwise an
              // invoice arriving on a device that has never seen it keeps
              // whatever `paid` its blob cached.
              pageLocal.push(mergeRemoteRecord(table, undefined, remote.data));
            }
          }
        }
        local = pageLocal;

        offset += page.length;
        if (page.length < PULL_PAGE_SIZE) break;
      }

      // A later-page error must not leave a partial local apply paired with an
      // advanced cursor. Discard the in-memory pages and retry the table in full.
      if (failed || local === null) continue;
      await AsyncStorage.setItem(table, JSON.stringify(local));
      if (tableWatermark) cursor.tables[table] = tableWatermark;
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

    await AsyncStorage.setItem(LAST_SYNCED_KEY, JSON.stringify(cursor));
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

// One-time enqueue of every local record in the BACKFILLED_TABLES. Runs
// before the sign-in sync so the very next push carries the records. Safe to
// call repeatedly (flag-gated); safe offline (enqueue is local-only).
async function backfillLocalOnlyCollections(userId: string): Promise<void> {
  try {
    const done = await AsyncStorage.getItem(BACKFILL_KEY + userId);
    if (done) return;
    for (const table of BACKFILLED_TABLES) {
      const raw = await AsyncStorage.getItem(table);
      const records: { id?: string }[] = raw ? JSON.parse(raw) : [];
      for (const record of records) {
        if (record.id) await enqueue(table, 'upsert', record.id, record);
      }
    }
    await AsyncStorage.setItem(BACKFILL_KEY + userId, 'true');
  } catch (e: unknown) {
    console.warn('Collection backfill failed:', (e as Error).message);
    reportError(e, { context: 'backfillLocalOnlyCollections' });
  }
}

export async function initialSync(userId: string): Promise<void> {
  try {
    const done = await AsyncStorage.getItem(INIT_DONE_KEY + userId);
    if (done) {
      await backfillLocalOnlyCollections(userId);
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
      // pushAllLocalToCloud iterates COLLECTION_TABLES, which now includes
      // the backfilled tables — their records just went up directly, so the
      // one-time backfill would only re-enqueue what was pushed. Skip it.
      await AsyncStorage.setItem(BACKFILL_KEY + userId, 'true');
    } else {
      if (localDataBelongsToOtherUser) {
        // recurringJobs / recurringInvoices / trips joined COLLECTION_TABLES
        // 2026-08-03, so the spread now covers them.
        await AsyncStorage.multiRemove([...COLLECTION_TABLES, 'customerNotes', REVIEW_REQUESTS_STORAGE_KEY]);
        await AsyncStorage.removeItem(QUEUE_KEY);
      }
      await AsyncStorage.setItem(LAST_SYNCED_KEY, JSON.stringify(emptySyncCursor()));
      await pullRemote(userId);
      // Same-user reinstall / pre-sync device: local-only records in the
      // backfilled tables aren't in the cloud yet — enqueue them once. (After
      // a cross-user wipe the collections are empty, so this is a no-op that
      // just stamps the flag.)
      await backfillLocalOnlyCollections(userId);
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
    // A blob written before the SecureStore split can carry the credential
    // fields inline. Iterate the shared list — hand-naming fields here is how
    // groqKey went unstripped (2026-08-02 security audit, item 10a).
    for (const field of SECURE_FIELDS) {
      delete (safe as Record<string, unknown>)[field];
    }
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
