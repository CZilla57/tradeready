import AsyncStorage from '@react-native-async-storage/async-storage';
import * as Network from 'expo-network';
import { supabase } from './supabase';

const QUEUE_KEY      = '__syncQueue';
const LAST_SYNCED_KEY = '__lastSyncedAt';
const INIT_DONE_KEY  = '__initDone_';
const DATA_OWNER_KEY = '__dataOwner';

const COLLECTION_TABLES = ['jobs', 'invoices', 'customers', 'expenses'];

// ── Queue ─────────────────────────────────────────────────────────────────────

export async function enqueue(table, op, recordId, payload) {
  const queue = await getQueue();
  // Replace any existing pending op for the same (table, recordId) to deduplicate
  const filtered = queue.filter(
    item => !(item.table === table && item.recordId === recordId)
  );
  filtered.push({ table, op, recordId, payload, ts: new Date().toISOString() });
  await AsyncStorage.setItem(QUEUE_KEY, JSON.stringify(filtered));
}

export async function enqueueCollectionChanges(table, oldRecords, newRecords) {
  const oldIds = new Set(oldRecords.map(r => r.id).filter(Boolean));
  const newIds = new Set(newRecords.map(r => r.id).filter(Boolean));

  for (const id of oldIds) {
    if (!newIds.has(id)) {
      await enqueue(table, 'delete', id, null);
    }
  }
  for (const record of newRecords) {
    if (record.id) await enqueue(table, 'upsert', record.id, record);
  }
}

async function getQueue() {
  try {
    const raw = await AsyncStorage.getItem(QUEUE_KEY);
    return raw ? JSON.parse(raw) : [];
  } catch {
    return [];
  }
}

// ── Push (local → cloud) ──────────────────────────────────────────────────────

async function pushQueue(userId) {
  const queue = await getQueue();
  if (!queue.length) return;

  const failed = [];
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
    } catch {
      failed.push(item);
    }
  }
  await AsyncStorage.setItem(QUEUE_KEY, JSON.stringify(failed));
}

// ── Pull (cloud → local) ──────────────────────────────────────────────────────

async function pullRemote(userId) {
  try {
    const lastRaw = await AsyncStorage.getItem(LAST_SYNCED_KEY);
    const lastSynced = lastRaw ? JSON.parse(lastRaw) : {};
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
      let local = localRaw ? JSON.parse(localRaw) : [];

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

    // Pull settings. SECURE_FIELDS (providerKey, anthropicKey, groqKey) are
    // never written to AsyncStorage by saveSettings — they live in SecureStore
    // only. loadSettings reads SecureStore after every pull and overwrites those
    // fields, so no special merge is needed here.
    const { data: settingsRow } = await supabase
      .from('settings')
      .select('data')
      .eq('user_id', userId)
      .maybeSingle();

    if (settingsRow?.data) {
      await AsyncStorage.setItem('settings', JSON.stringify(settingsRow.data));
    }

    // Pull customer notes
    const { data: notesData } = await supabase
      .from('customer_notes')
      .select('customer_key, note')
      .eq('user_id', userId);

    if (notesData) {
      const map = {};
      notesData.forEach(n => { map[n.customer_key] = n.note; });
      await AsyncStorage.setItem('customerNotes', JSON.stringify(map));
    }

    await AsyncStorage.setItem(LAST_SYNCED_KEY, JSON.stringify(lastSynced));
  } catch (e) {
    console.warn('Sync pull failed:', e.message);
  }
}

// ── Online check + sync ───────────────────────────────────────────────────────

export async function syncIfOnline(userId) {
  try {
    const net = await Network.getNetworkStateAsync();
    if (!net.isConnected) return;
    await pushQueue(userId);
    await pullRemote(userId);
  } catch (e) {
    console.warn('Sync failed:', e.message);
  }
}

// Fire-and-forget: reads current session and syncs if logged in
export async function trySync() {
  try {
    const { data: { session } } = await supabase.auth.getSession();
    if (session?.user?.id) syncIfOnline(session.user.id);
  } catch { /* not logged in or offline */ }
}

// ── Initial sync (first login / new device) ───────────────────────────────────

export async function initialSync(userId) {
  try {
    const done = await AsyncStorage.getItem(INIT_DONE_KEY + userId);
    if (done) {
      syncIfOnline(userId);
      return;
    }

    const net = await Network.getNetworkStateAsync();
    if (!net.isConnected) return;

    // Guard: if local data was created by a different user, never push it up.
    // This is defense-in-depth for cases where clearAllUserData() had a partial failure.
    const storedOwnerRaw = await AsyncStorage.getItem(DATA_OWNER_KEY);
    const dataOwner = storedOwnerRaw ? JSON.parse(storedOwnerRaw) : null;
    const localDataBelongsToOtherUser = dataOwner !== null && dataOwner !== userId;

    // Check whether this user has ever synced before by looking for a settings
    // row. Using 'settings' rather than 'jobs' avoids misclassifying a user
    // who has zero jobs (but existing invoices/customers) as a new user.
    // pushAllLocalToCloud always writes a settings row, so its presence is a
    // reliable "has synced before" signal.
    const { count } = await supabase
      .from('settings')
      .select('user_id', { count: 'exact', head: true })
      .eq('user_id', userId);

    if (count === 0 && !localDataBelongsToOtherUser) {
      // First device — push whatever is stored locally up to the cloud
      await pushAllLocalToCloud(userId);
    } else {
      if (localDataBelongsToOtherUser) {
        // Stale data from a prior user is present; wipe it before merging cloud data
        // so the wrong user's records don't persist alongside this user's records.
        await AsyncStorage.multiRemove([...COLLECTION_TABLES, 'customerNotes']);
      }
      // Second device / reinstall / different-user stale data — pull from cloud
      await AsyncStorage.setItem(LAST_SYNCED_KEY, JSON.stringify({}));
      await pullRemote(userId);
    }

    // Mark local data as owned by this user from this point forward
    await AsyncStorage.setItem(DATA_OWNER_KEY, JSON.stringify(userId));
    await AsyncStorage.setItem(INIT_DONE_KEY + userId, 'true');
  } catch (e) {
    console.warn('Initial sync failed:', e.message);
  }
}

async function pushAllLocalToCloud(userId) {
  for (const table of COLLECTION_TABLES) {
    const raw = await AsyncStorage.getItem(table);
    const records = raw ? JSON.parse(raw) : [];
    if (!records.length) continue;
    await supabase.from(table).upsert(
      records.map(r => ({
        id: r.id,
        user_id: userId,
        data: r,
        updated_at: new Date().toISOString(),
        deleted: false,
      }))
    );
  }

  // Push settings (without the secure fields that live in SecureStore only)
  const raw = await AsyncStorage.getItem('settings');
  if (raw) {
    const settings = JSON.parse(raw);
    const safe = { ...settings };
    delete safe.providerKey;
    delete safe.anthropicKey;
    await supabase.from('settings').upsert({
      user_id: userId,
      data: safe,
      updated_at: new Date().toISOString(),
    });
  }

  // Push customer notes
  const notesRaw = await AsyncStorage.getItem('customerNotes');
  if (notesRaw) {
    const notes = JSON.parse(notesRaw);
    const rows = Object.entries(notes).map(([key, note]) => ({
      user_id: userId,
      customer_key: key,
      note,
      updated_at: new Date().toISOString(),
    }));
    if (rows.length) await supabase.from('customer_notes').upsert(rows);
  }
}
