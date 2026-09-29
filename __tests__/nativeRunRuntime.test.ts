// __tests__/nativeRunRuntime.test.ts
// The I/O half of the Expo rollback safeguard (P12-012, E-1..E-4): marker read
// through expo-file-system, the reset write, pull ordering, holds. Uses an
// in-memory AsyncStorage and the REAL utils/sync, storage and widgetActions.

import AsyncStorage from '@react-native-async-storage/async-storage';
import * as FileSystem from 'expo-file-system/legacy';
import * as Network from 'expo-network';

const mockDb: { calls: string[]; cloud: Record<string, any[]>; settingsRow: any; failTable: string | null } = {
  calls: [],
  cloud: {},
  settingsRow: null,
  failTable: null,
};

jest.mock('../utils/supabase', () => ({
  supabase: {
    auth: { getSession: jest.fn() },
    from: jest.fn((table: string) => {
      const chain: any = { table, _count: false };
      chain.select = jest.fn((_f: string, opts?: any) => { chain._count = !!opts?.count; return chain; });
      chain.eq = jest.fn(() => (chain._count ? Promise.resolve({ count: 1, error: null }) : chain));
      chain.gte = jest.fn(() => { mockDb.calls.push(`pull:${table}`); return chain; });
      chain.order = jest.fn(() => chain);
      chain.range = jest.fn(() =>
        Promise.resolve(
          mockDb.failTable === table
            ? { data: null, error: { message: 'boom' } }
            : { data: mockDb.cloud[table] ?? [], error: null },
        ),
      );
      chain.maybeSingle = jest.fn(() => Promise.resolve({ data: mockDb.settingsRow, error: null }));
      chain.upsert = jest.fn((row: any) => {
        mockDb.calls.push(`push:${table}:${row.id ?? row.customer_key ?? 'settings'}`);
        return Promise.resolve({ error: null });
      });
      chain.update = jest.fn(() => ({ eq: jest.fn(() => ({ eq: jest.fn().mockResolvedValue({ error: null }) })) }));
      return chain;
    }),
  },
}));

jest.mock('expo-file-system/legacy', () => ({
  documentDirectory: 'file:///var/mobile/Containers/Data/Application/ABC/Documents/',
  getInfoAsync: jest.fn(),
  readAsStringAsync: jest.fn(),
  writeAsStringAsync: jest.fn(),
  copyAsync: jest.fn(),
  deleteAsync: jest.fn(),
}));

jest.mock('../utils/notifications', () => ({ syncNotifications: jest.fn() }));

jest.mock('../utils/widgetBridge', () => ({
  getWidgetSharedItem: jest.fn(),
  removeWidgetSharedItem: jest.fn().mockResolvedValue(undefined),
  refreshWidgetSnapshot: jest.fn().mockResolvedValue(undefined),
  clearWidgetSnapshot: jest.fn().mockResolvedValue(undefined),
  WIDGET_ACTIONS_KEY: 'widgetActions',
  DONE_STATUSES: new Set(['complete', 'invoiced', 'paid', 'declined']),
}));

jest.mock('expo-task-manager', () => ({ defineTask: jest.fn(), isAvailableAsync: jest.fn() }));
jest.mock('expo-background-task', () => ({ registerTaskAsync: jest.fn(), BackgroundTaskResult: { Success: 1, Failed: 2 } }));

/* eslint-disable @typescript-eslint/no-require-imports */
const { supabase } = require('../utils/supabase');
const widgetBridge = require('../utils/widgetBridge');
const runtime = require('../utils/nativeRunRuntime');
const { initialSync, syncIfOnline, enqueue } = require('../utils/sync');
const { saveJobs, loadJobs, saveSettings, clearAllUserData } = require('../utils/storage');
const { replayWidgetActions } = require('../utils/widgetActions');
const { runBackgroundRefresh } = require('../utils/backgroundRefresh');
const { createAutoInvoiceForJob } = require('../utils/autoInvoice');
const { checkAndGenerateRecurringInvoices } = require('../utils/recurringInvoices');
/* eslint-enable @typescript-eslint/no-require-imports */

const SUPPORT_DIR = 'file:///var/mobile/Containers/Data/Application/ABC/Library/Application%20Support/TradeReadyNative/';
const MARKER_URI = `${SUPPORT_DIR}native-run-marker.json`;

let store: Map<string, string>;
let fsState: { marker: 'missing' | 'unreadable' | { text: string }; dir: boolean };

const marker = (run: number) => ({ text: JSON.stringify({ run, schemaVersion: 1 }) });
const get = (k: string) => (store.has(k) ? JSON.parse(store.get(k) as string) : undefined);
const record = () => get('__nativeRun');

/** Simulates killing and relaunching the JS runtime: same storage, fresh module state. */
function relaunch() {
  runtime.__resetNativeRunForTests();
}

beforeEach(() => {
  jest.clearAllMocks();
  store = new Map();
  mockDb.calls = [];
  mockDb.cloud = {};
  mockDb.settingsRow = null;
  mockDb.failTable = null;
  fsState = { marker: 'missing', dir: false };
  runtime.__resetNativeRunForTests();

  const A = AsyncStorage as any;
  A.getItem.mockImplementation((k: string) => Promise.resolve(store.has(k) ? (store.get(k) as string) : null));
  A.setItem.mockImplementation((k: string, v: string) => { store.set(k, v); return Promise.resolve(); });
  A.removeItem.mockImplementation((k: string) => { store.delete(k); return Promise.resolve(); });
  A.multiSet.mockImplementation((pairs: [string, string][]) => { pairs.forEach(([k, v]) => store.set(k, v)); return Promise.resolve(); });
  A.multiRemove.mockImplementation((keys: string[]) => { keys.forEach(k => store.delete(k)); return Promise.resolve(); });
  A.getAllKeys.mockImplementation(() => Promise.resolve([...store.keys()]));

  (FileSystem.getInfoAsync as jest.Mock).mockImplementation((uri: string) => {
    if (uri === MARKER_URI) return Promise.resolve({ exists: fsState.marker !== 'missing', isDirectory: false });
    if (uri === SUPPORT_DIR) return Promise.resolve({ exists: fsState.dir || fsState.marker !== 'missing', isDirectory: true });
    return Promise.resolve({ exists: false });
  });
  (FileSystem.readAsStringAsync as jest.Mock).mockImplementation((uri: string) => {
    if (uri !== MARKER_URI) return Promise.reject(new Error('unexpected read'));
    if (fsState.marker === 'unreadable' || fsState.marker === 'missing') return Promise.reject(new Error('EACCES'));
    return Promise.resolve(fsState.marker.text);
  });

  (Network.getNetworkStateAsync as jest.Mock).mockResolvedValue({ isConnected: true });
  (supabase.auth.getSession as jest.Mock).mockResolvedValue({ data: { session: { user: { id: 'u1' } } } });
  widgetBridge.getWidgetSharedItem.mockResolvedValue(null);
});

/** A device that ran Expo (stale queue and copies), then the native build. */
function seedStaleExpoState() {
  store.set('__syncQueue', JSON.stringify([{ table: 'jobs', op: 'upsert', recordId: 'stale1', payload: { id: 'stale1' }, ts: 't' }]));
  store.set('jobs', JSON.stringify([{ id: 'stale1', title: 'stale copy' }]));
  store.set('customerNotes', JSON.stringify({ k: 'note' }));
  store.set('review_requests', JSON.stringify([{ jobId: 'stale1' }]));
  store.set('__lastSyncedAt', JSON.stringify({ version: 2, tables: { jobs: '2026-01-01T00:00:00.000Z' } }));
  store.set('__initDone_u1', 'true');
  store.set('settings', JSON.stringify({ businessName: 'Pre-native Co', laborRate: 80 }));
}

describe('E-1 detection at app start', () => {
  test('usable marker: drops the queue, clears copies, keeps review_requests, records pending', async () => {
    seedStaleExpoState();
    fsState.marker = marker(4);
    await runtime.ensureNativeRunChecked();

    expect(get('__syncQueue')).toEqual([]);
    expect(get('jobs')).toEqual([]);
    expect(get('customerNotes')).toEqual({});
    expect(get('__lastSyncedAt')).toEqual({ version: 2, tables: {} });
    expect(get('review_requests')).toEqual([{ jobId: 'stale1' }]);
    expect(get('settings')).toEqual({ businessName: 'Pre-native Co', laborRate: 80 }); // the one pre-native copy kept
    expect(record()).toEqual({ run: 4, state: 'pending', warn: true });
    expect(await runtime.isNativeRunPending()).toBe(true);
  });

  test('the check never writes or deletes anything at the native path (E-3)', async () => {
    fsState.marker = marker(4);
    await runtime.ensureNativeRunChecked();
    expect(FileSystem.writeAsStringAsync).not.toHaveBeenCalled();
    expect(FileSystem.deleteAsync).not.toHaveBeenCalled();
    expect(FileSystem.copyAsync).not.toHaveBeenCalled();
  });

  test('is memoized: one detection per process however many callers await it', async () => {
    fsState.marker = marker(4);
    await Promise.all([runtime.ensureNativeRunChecked(), runtime.ensureNativeRunChecked()]);
    expect((AsyncStorage.multiSet as jest.Mock).mock.calls).toHaveLength(1);
  });

  test('relaunch with the same run detects nothing and drops nothing more', async () => {
    fsState.marker = marker(4);
    await runtime.ensureNativeRunChecked();
    // R creates a record while pending, then relaunches
    await enqueue('jobs', 'upsert', 'new1', { id: 'new1' });
    relaunch();
    await runtime.ensureNativeRunChecked();
    expect(get('__syncQueue')).toHaveLength(1);
    expect(record()?.state).toBe('pending');
    expect(await runtime.isNativeRunPending()).toBe(true);
  });

  test('a later native run detects again and drops the queue that predates it', async () => {
    fsState.marker = marker(4);
    await runtime.ensureNativeRunChecked();
    await runtime.completeNativeRunAfterPull(); // seen
    await enqueue('jobs', 'upsert', 'r-edit', { id: 'r-edit' });
    fsState.marker = marker(5); // N2 ran
    relaunch();
    await runtime.ensureNativeRunChecked();
    expect(get('__syncQueue')).toEqual([]);
    expect(record()).toEqual({ run: 5, state: 'pending', warn: true });
  });

  test('missing marker and no native directory: nothing detected, L edits stay queued', async () => {
    seedStaleExpoState();
    await runtime.ensureNativeRunChecked();
    expect(get('__syncQueue')).toHaveLength(1);
    expect(get('jobs')).toHaveLength(1);
    expect(record()).toBeUndefined();
    expect(await runtime.isNativeRunPending()).toBe(false);
    // and the queued L edit is pushed as usual
    await syncIfOnline('u1');
    expect(mockDb.calls).toContain('push:jobs:stale1');
  });

  test('directory fallback: sentinel run 0, fires once, not at every launch', async () => {
    seedStaleExpoState();
    fsState.dir = true;
    await runtime.ensureNativeRunChecked();
    expect(record()).toEqual({ run: 0, state: 'pending', warn: true });
    expect(get('__syncQueue')).toEqual([]);

    await enqueue('jobs', 'upsert', 'new1', { id: 'new1' });
    relaunch();
    await runtime.ensureNativeRunChecked();
    expect(get('__syncQueue')).toHaveLength(1); // not dropped again

    // a marker that appears later still counts as a new run
    fsState.marker = marker(1);
    relaunch();
    await runtime.ensureNativeRunChecked();
    expect(record()?.run).toBe(1);
    expect(get('__syncQueue')).toEqual([]);
  });

  test('unusable marker fires once per change; transient unreadable never re-fires', async () => {
    fsState.marker = marker(5);
    await runtime.ensureNativeRunChecked();
    await runtime.completeNativeRunAfterPull();

    await enqueue('jobs', 'upsert', 'a', { id: 'a' });
    fsState.marker = 'unreadable'; // transient failure
    relaunch();
    await runtime.ensureNativeRunChecked();
    expect(get('__syncQueue')).toEqual([]); // fail-safe: fired once
    expect(record()?.run).toBe(5); // last usable run unchanged
    expect(record()?.fingerprint).toBeDefined();

    await runtime.completeNativeRunAfterPull();
    await enqueue('jobs', 'upsert', 'b', { id: 'b' });
    fsState.marker = marker(5); // readable again, same run
    relaunch();
    await runtime.ensureNativeRunChecked();
    expect(get('__syncQueue')).toHaveLength(1); // not a new run

    fsState.marker = 'unreadable'; // reads the same way as before
    relaunch();
    await runtime.ensureNativeRunChecked();
    expect(get('__syncQueue')).toHaveLength(1); // still not

    fsState.marker = { text: 'corrupt-contents' }; // the file changed
    relaunch();
    await runtime.ensureNativeRunChecked();
    expect(get('__syncQueue')).toEqual([]);
  });

  test('a failed reset write blocks the push for this process (never pushes a stale queue)', async () => {
    seedStaleExpoState();
    fsState.marker = marker(4);
    (AsyncStorage.multiSet as jest.Mock).mockRejectedValue(new Error('disk full'));
    await runtime.ensureNativeRunChecked();
    expect(runtime.isNativeRunWriteFailed()).toBe(true);
    await syncIfOnline('u1');
    expect(mockDb.calls).toEqual([]);
    // next launch retries the reset
    (AsyncStorage.multiSet as jest.Mock).mockImplementation((pairs: [string, string][]) => { pairs.forEach(([k, v]) => store.set(k, v)); return Promise.resolve(); });
    relaunch();
    await runtime.ensureNativeRunChecked();
    expect(get('__syncQueue')).toEqual([]);
  });
});

describe('queue drop, stale clearing and pull ordering', () => {
  test('the stale queue is never pushed; the pull runs; the run completes after it', async () => {
    seedStaleExpoState();
    fsState.marker = marker(4);
    mockDb.cloud.jobs = [{ id: 'native1', data: { id: 'native1', title: 'native-era' }, deleted: false, updated_at: '2026-09-01T00:00:00.000Z' }];

    await runtime.ensureNativeRunChecked();
    await syncIfOnline('u1');

    expect(mockDb.calls.some(c => c.startsWith('push:jobs'))).toBe(false); // stale1 never pushed
    // only the pulled-settings re-queue (completion step 1) is ever pushed, and only after the pull
    expect(mockDb.calls.filter(c => c.startsWith('push:'))).toEqual(['push:settings:settings']);
    expect(mockDb.calls.indexOf('push:settings:settings')).toBeGreaterThan(mockDb.calls.indexOf('pull:jobs'));
    expect(mockDb.calls).toContain('pull:jobs');
    expect((get('jobs') as any[]).map(j => j.id)).toEqual(['native1']); // stale copy gone, native row in
    expect(record()?.state).toBe('seen');
  });

  test('a record created while pending is pushed, and survives the pull', async () => {
    fsState.marker = marker(4);
    await runtime.ensureNativeRunChecked();
    await saveJobs([{ id: 'made-while-pending', title: 'new' }]);
    mockDb.cloud.jobs = [{ id: 'native1', data: { id: 'native1' }, deleted: false, updated_at: '2026-09-01T00:00:00.000Z' }];
    await syncIfOnline('u1');
    expect(mockDb.calls.indexOf('push:jobs:made-while-pending')).toBeGreaterThanOrEqual(0);
    expect(mockDb.calls.indexOf('push:jobs:made-while-pending')).toBeLessThan(mockDb.calls.indexOf('pull:jobs'));
    expect((get('jobs') as any[]).map(j => j.id).sort()).toEqual(['made-while-pending', 'native1']);
  });

  test('a pull that fails on any table does not complete the run', async () => {
    fsState.marker = marker(4);
    await runtime.ensureNativeRunChecked();
    mockDb.failTable = 'invoices';
    await syncIfOnline('u1');
    expect(record()?.state).toBe('pending');
    mockDb.failTable = null;
    await syncIfOnline('u1');
    expect(record()?.state).toBe('seen');
  });

  test('offline start: cleared before any sync, nothing pushed, still pending', async () => {
    seedStaleExpoState();
    fsState.marker = marker(4);
    (Network.getNetworkStateAsync as jest.Mock).mockResolvedValue({ isConnected: false });

    await runtime.ensureNativeRunChecked();
    expect(get('__syncQueue')).toEqual([]);
    expect(get('jobs')).toEqual([]);

    // an offline save queues only the new record, never a pre-native copy
    await saveJobs([{ id: 'offline-new', title: 'x' }]);
    expect((get('__syncQueue') as any[]).map(q => q.recordId)).toEqual(['offline-new']);
    await syncIfOnline('u1');
    expect(mockDb.calls).toEqual([]);
    expect(record()?.state).toBe('pending');
  });

  test('signed-out start: detection runs with no session; first sign-in pull completes it', async () => {
    seedStaleExpoState();
    fsState.marker = marker(4);
    (supabase.auth.getSession as jest.Mock).mockResolvedValue({ data: { session: null } });

    await runBackgroundRefresh(); // headless wake, no session
    expect(get('__syncQueue')).toEqual([]);
    expect(mockDb.calls).toEqual([]);
    expect(record()?.state).toBe('pending');

    // sign in as a user with no __initDone: initialSync pulls without syncIfOnline
    store.delete('__initDone_u1');
    await initialSync('u1');
    expect(mockDb.calls).toContain('pull:jobs');
    expect(record()?.state).toBe('seen');
  });

  test('another account signing in clears the held settings paths', async () => {
    store.set('settings', JSON.stringify({ businessName: 'Pre-native Co', laborRate: 80 }));
    fsState.marker = marker(4);
    await runtime.ensureNativeRunChecked();
    await saveSettings({ businessName: 'Edited', laborRate: 80 });
    expect(get('__nativeRunHeldSettings')).toHaveLength(1);
    store.set('__dataOwner', JSON.stringify('someone-else'));
    store.delete('__initDone_u1');
    mockDb.failTable = 'jobs'; // keep the run pending so only the clear is observed
    await initialSync('u1');
    expect(store.has('__nativeRunHeldSettings')).toBe(false);
  });
});

describe('settings hold (I2)', () => {
  test('a settings save while pending is not queued; its changed leaf is held (compared before the write)', async () => {
    store.set('settings', JSON.stringify({ businessName: 'Pre-native Co', laborRate: 80 }));
    fsState.marker = marker(4);
    await runtime.ensureNativeRunChecked();

    await saveSettings({ businessName: 'Edited', laborRate: 80 });

    expect(get('__syncQueue')).toEqual([]); // settings not queued
    expect(get('settings').businessName).toBe('Edited'); // local edit is shown
    expect(get('__nativeRunHeldSettings')).toEqual([{ path: ['businessName'], value: 'Edited' }]);
  });

  test('after the pull: held leaves go over the pulled settings, are queued, the run is seen, held cleared', async () => {
    store.set('settings', JSON.stringify({ businessName: 'Pre-native Co', laborRate: 80 }));
    fsState.marker = marker(4);
    await runtime.ensureNativeRunChecked();
    await saveSettings({ businessName: 'Edited', laborRate: 80 });
    mockDb.settingsRow = { data: { businessName: 'Cloud Co', laborRate: 95 } };

    await syncIfOnline('u1');

    const merged = get('settings');
    expect(merged.businessName).toBe('Edited'); // R's edit kept
    expect(merged.laborRate).toBe(95); // pulled sibling not carried over stale
    expect(record()?.state).toBe('seen');
    expect(store.has('__nativeRunHeldSettings')).toBe(false);
    expect(mockDb.calls).toContain('push:settings:settings'); // queued and pushed
  });

  test('a settings save with the run seen queues as usual', async () => {
    await runtime.ensureNativeRunChecked(); // no marker, no dir: not pending
    await saveSettings({ businessName: 'Normal', laborRate: 1 });
    expect((get('__syncQueue') as any[]).map(q => q.table)).toContain('settings');
    expect(store.has('__nativeRunHeldSettings')).toBe(false);
  });

  test('the Expo sign-out clears held paths and the queue but keeps the run record (E-4)', async () => {
    store.set('settings', JSON.stringify({ businessName: 'Pre-native Co', laborRate: 80 }));
    fsState.marker = marker(4);
    await runtime.ensureNativeRunChecked();
    await saveSettings({ businessName: 'Edited', laborRate: 80 });
    await clearAllUserData();
    expect(store.has('__nativeRunHeldSettings')).toBe(false);
    expect(store.has('__syncQueue')).toBe(false);
    expect(record()).toEqual({ run: 4, state: 'pending', warn: true });
  });
});

describe('widget/Siri and invoice holds (R49)', () => {
  const timerAction = JSON.stringify([{ type: 'timer_start', jobId: 'j1', at: '2026-09-20T10:00:00.000Z', id: 'a1' }]);

  test('replay is held while pending: queue untouched, no snapshot refresh, in every entry point', async () => {
    fsState.marker = marker(4);
    widgetBridge.getWidgetSharedItem.mockResolvedValue(timerAction);
    await runtime.ensureNativeRunChecked();

    await replayWidgetActions(); // session start / foreground
    (supabase.auth.getSession as jest.Mock).mockResolvedValue({ data: { session: { user: { id: 'u1' } } } });
    mockDb.failTable = 'jobs'; // the pull fails, so the run stays pending
    await runBackgroundRefresh(); // background task

    expect(widgetBridge.getWidgetSharedItem).not.toHaveBeenCalled();
    expect(widgetBridge.removeWidgetSharedItem).not.toHaveBeenCalled();
    expect(widgetBridge.refreshWidgetSnapshot).not.toHaveBeenCalled();
  });

  test('after the pull: the run is seen first, then the queue is replayed once', async () => {
    fsState.marker = marker(4);
    widgetBridge.getWidgetSharedItem.mockResolvedValue(timerAction);
    let stateWhenConsumed: string | undefined;
    widgetBridge.removeWidgetSharedItem.mockImplementation(async () => { stateWhenConsumed = record()?.state; });
    mockDb.cloud.jobs = [{
      id: 'j1',
      data: { id: 'j1', title: 'job', status: 'scheduled', timeSessions: [] },
      deleted: false,
      updated_at: '2026-09-01T00:00:00.000Z',
    }];
    await runtime.ensureNativeRunChecked();
    await syncIfOnline('u1');

    expect(widgetBridge.removeWidgetSharedItem).toHaveBeenCalledTimes(1);
    expect(stateWhenConsumed).toBe('seen');
    const jobs = await loadJobs();
    expect(jobs.map((j: any) => j.id)).toEqual(['j1']);
  });

  test('invoice creation is blocked while pending (auto-invoice, recurring generator, helper) and open after the pull', async () => {
    fsState.marker = marker(4);
    await runtime.ensureNativeRunChecked();
    expect(await runtime.isInvoiceCreationBlocked()).toBe(true);
    expect(await createAutoInvoiceForJob('j1')).toBeNull();

    await saveJobs([]); // touch storage so the loaders have something
    store.set('recurringInvoices', JSON.stringify([{ id: 'r1', isActive: true, nextDueDate: '2000-01-01', cadence: 'monthly', occurrenceCount: 0, amount: 10, customerName: 'C', description: 'd', dueDays: 7 }]));
    await checkAndGenerateRecurringInvoices();
    expect(get('invoices')).toEqual([]); // nothing numbered against the cleared list
    expect(get('recurringInvoices')[0].occurrenceCount).toBe(0); // rule not advanced

    await syncIfOnline('u1');
    expect(await runtime.isInvoiceCreationBlocked()).toBe(false);
  });
});
