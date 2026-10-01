// __tests__/nativeRunGuard.test.ts
// Pure decision logic of the Expo rollback safeguard (P12-012, playbook 5.3 E-1).
import {
  NATIVE_RUN_DIRECTORY_SENTINEL,
  applyHeldEntries,
  buildDetectionWrite,
  classifyMarker,
  decideNativeRun,
  diffSettingsLeaves,
  fnv1a32,
  markerFingerprint,
  mergeHeldEntries,
  nativeMarkerUri,
  parseRecord,
  type MarkerRead,
  type NativeRunRecord,
} from '../utils/nativeRunGuard';
import { SYNCED_COLLECTION_TABLES } from '../utils/storage/keys';

const usable = (run: number): MarkerRead => ({ kind: 'content', text: JSON.stringify({ run, schemaVersion: 1 }) });
const UNREADABLE: MarkerRead = { kind: 'unreadable' };
const MISSING: MarkerRead = { kind: 'missing' };

/** Runs one app start against a record; returns the record after it. */
function launch(read: MarkerRead, dirExists: boolean, record: NativeRunRecord | null) {
  const d = decideNativeRun(classifyMarker(read), dirExists, record);
  return { fired: d.fire, record: d.fire ? d.next : record };
}

describe('classifyMarker: the three states', () => {
  test('missing', () => {
    expect(classifyMarker(MISSING)).toEqual({ state: 'missing' });
  });

  test('usable: schemaVersion 1 and run a whole number >= 1', () => {
    expect(classifyMarker(usable(1))).toEqual({ state: 'usable', run: 1 });
    expect(classifyMarker(usable(2147483647))).toEqual({ state: 'usable', run: 2147483647 });
  });

  test.each([
    ['not JSON', 'nope{'],
    ['empty file', ''],
    ['JSON null', 'null'],
    ['wrong schemaVersion', '{"run":3,"schemaVersion":2}'],
    ['no schemaVersion', '{"run":3}'],
    ['run 0', '{"run":0,"schemaVersion":1}'],
    ['negative run', '{"run":-4,"schemaVersion":1}'],
    ['fractional run', '{"run":1.5,"schemaVersion":1}'],
    ['string run', '{"run":"7","schemaVersion":1}'],
    ['missing run', '{"schemaVersion":1}'],
  ])('unusable: %s', (_label, text) => {
    const m = classifyMarker({ kind: 'content', text });
    expect(m.state).toBe('unusable');
  });

  test('unusable: cannot open the file', () => {
    expect(classifyMarker(UNREADABLE)).toEqual({ state: 'unusable', fingerprint: markerFingerprint(UNREADABLE) });
  });

  test('fingerprint differs per content and never collides with the unreadable state', () => {
    const a = markerFingerprint({ kind: 'content', text: 'garbage-a' });
    const b = markerFingerprint({ kind: 'content', text: 'garbage-b' });
    expect(a).not.toBe(b);
    expect(markerFingerprint({ kind: 'content', text: 'unreadable' })).not.toBe(markerFingerprint(UNREADABLE));
    expect(fnv1a32('')).toBe('811c9dc5');
    expect(fnv1a32('a')).toBe('e40c292c');
  });
});

describe('decideNativeRun: usable marker (rule 1)', () => {
  test('no record yet fires and records the run as pending', () => {
    const r = launch(usable(7), true, null);
    expect(r.fired).toBe(true);
    expect(r.record).toEqual({ run: 7, state: 'pending', warn: true });
  });

  test('same run again does nothing; a new run fires once per change', () => {
    let s = launch(usable(7), true, null);
    s = launch(usable(7), true, s.record);
    expect(s.fired).toBe(false);
    s = launch(usable(8), true, s.record);
    expect(s.fired).toBe(true);
    expect(s.record?.run).toBe(8);
    s = launch(usable(8), true, s.record);
    expect(s.fired).toBe(false);
  });

  test('a new usable run clears any fingerprint', () => {
    let s = launch(UNREADABLE, true, { run: 5, state: 'seen' });
    expect(s.record?.fingerprint).toBeDefined();
    s = launch(usable(6), true, s.record);
    expect(s.fired).toBe(true);
    expect(s.record?.fingerprint).toBeUndefined();
  });

  test('a run that differs downward also fires (marker restarted at a random run)', () => {
    const s = launch(usable(3), true, { run: 900, state: 'seen' });
    expect(s.fired).toBe(true);
  });
});

describe('decideNativeRun: unusable marker (rule 2)', () => {
  test('fires once per change to the file, keeps the last usable run', () => {
    let s = launch(usable(5), true, null);
    const garbageA: MarkerRead = { kind: 'content', text: 'xxx' };
    const garbageB: MarkerRead = { kind: 'content', text: 'yyy' };

    s = launch(garbageA, true, s.record);
    expect(s.fired).toBe(true);
    expect(s.record?.run).toBe(5);
    expect(s.record?.state).toBe('pending');

    s = launch(garbageA, true, s.record); // same file at the next launch
    expect(s.fired).toBe(false);

    s = launch(garbageB, true, s.record); // the file changed
    expect(s.fired).toBe(true);
    expect(s.record?.run).toBe(5);
  });

  test('no record at all: fires, run is the "none" sentinel 0', () => {
    const s = launch(UNREADABLE, false, null);
    expect(s.fired).toBe(true);
    expect(s.record?.run).toBe(NATIVE_RUN_DIRECTORY_SENTINEL);
  });

  test('a record left by a new usable run has no fingerprint, so any unusable file fires', () => {
    const s = launch(UNREADABLE, true, { run: 5, state: 'seen' });
    expect(s.fired).toBe(true);
  });

  test('transient unreadable: fires once, then the marker reading back unchanged does NOT fire', () => {
    let s = launch(usable(5), true, null); // native run 5 detected
    s = launch(UNREADABLE, true, s.record); // transient failure: fail-safe detection
    expect(s.fired).toBe(true);
    expect(s.record?.run).toBe(5);
    s = launch(usable(5), true, s.record); // readable again, same run
    expect(s.fired).toBe(false);
    expect(s.record?.run).toBe(5);
    // a later transient failure reads the same way: still not a new detection,
    // because the usable launch left the fingerprint untouched
    s = launch(UNREADABLE, true, s.record);
    expect(s.fired).toBe(false);
  });
});

describe('decideNativeRun: missing marker (rules 3 and 4)', () => {
  test('directory fallback: no record + native directory fires once with sentinel 0', () => {
    let s = launch(MISSING, true, null);
    expect(s.fired).toBe(true);
    expect(s.record).toEqual({ run: 0, state: 'pending', warn: true });
    // the directory is permanent, so it must not fire at every launch
    s = launch(MISSING, true, s.record);
    expect(s.fired).toBe(false);
  });

  test('after the fallback, any later usable marker still counts as new', () => {
    let s = launch(MISSING, true, null);
    s = launch(usable(1), true, s.record);
    expect(s.fired).toBe(true);
    expect(s.record?.run).toBe(1);
  });

  test('missing marker and no native directory: nothing (L to R update never drops the queue)', () => {
    expect(launch(MISSING, false, null).fired).toBe(false);
  });

  test('missing marker with a record already present never fires, directory or not', () => {
    expect(launch(MISSING, true, { run: 4, state: 'seen' }).fired).toBe(false);
    expect(launch(MISSING, false, { run: 4, state: 'seen' }).fired).toBe(false);
    expect(launch(MISSING, true, { run: 4, state: 'pending' }).fired).toBe(false);
  });

  test('a relaunch of a pending run detects nothing and keeps it pending', () => {
    const rec: NativeRunRecord = { run: 9, state: 'pending', warn: true };
    const s = launch(usable(9), true, rec);
    expect(s.fired).toBe(false);
    expect(s.record).toBe(rec);
  });
});

describe('buildDetectionWrite: the one atomic reset', () => {
  const next: NativeRunRecord = { run: 3, state: 'pending', warn: true };
  const pairs = buildDetectionWrite(next);
  const map = new Map(pairs);

  test('empties the queue, resets the cursor, empties collections and notes and held paths', () => {
    expect(map.get('__syncQueue')).toBe('[]');
    expect(JSON.parse(map.get('__lastSyncedAt')!)).toEqual({ version: 2, tables: {} });
    for (const t of SYNCED_COLLECTION_TABLES) expect(map.get(t)).toBe('[]'); // written empty, not removed
    expect(map.get('customerNotes')).toBe('{}');
    expect(map.get('__nativeRunHeldSettings')).toBe('[]');
    expect(JSON.parse(map.get('__nativeRun')!)).toEqual(next);
  });

  test('keeps review_requests and never touches settings', () => {
    expect(map.has('review_requests')).toBe(false);
    expect(map.has('settings')).toBe(false);
  });

  test('every value stays under 1,024 characters (manifest-atomic write)', () => {
    for (const [, v] of pairs) expect(v.length).toBeLessThan(1024);
  });
});

describe('parseRecord', () => {
  test('round trips and rejects junk', () => {
    const rec: NativeRunRecord = { run: 2, state: 'seen', fingerprint: 'u:1234abcd' };
    expect(parseRecord(JSON.stringify(rec))).toEqual(rec);
    expect(parseRecord(null)).toBeNull();
    expect(parseRecord('{bad')).toBeNull();
    expect(parseRecord('{"run":1,"state":"weird"}')).toBeNull();
  });
});

describe('nativeMarkerUri', () => {
  test('builds Library/Application Support/TradeReadyNative from the Documents directory', () => {
    expect(nativeMarkerUri('file:///var/mobile/Containers/Data/Application/AB-12/Documents/')).toBe(
      'file:///var/mobile/Containers/Data/Application/AB-12/Library/Application%20Support/TradeReadyNative/native-run-marker.json',
    );
  });
  test('no signal when documentDirectory is not an iOS Documents path', () => {
    expect(nativeMarkerUri(null)).toBeNull();
    expect(nativeMarkerUri('file:///mock/')).toBeNull();
  });
});

describe('held settings paths', () => {
  test('diff records added, changed and removed leaves under full paths', () => {
    const stored = { businessName: 'Old', providerKeys: { square: 'tok', other: 'x' }, list: [1, 2] };
    const next = { businessName: 'Old', providerKeys: { other: 'x' }, list: [1, 2, 3], pushToken: { token: 't', platform: 'ios' } };
    const d = diffSettingsLeaves(stored, next);
    expect(d).toEqual(
      expect.arrayContaining([
        { path: ['list'], value: [1, 2, 3] },
        { path: ['pushToken', 'token'], value: 't' },
        { path: ['pushToken', 'platform'], value: 'ios' },
        { path: ['providerKeys', 'square'], removed: true },
      ]),
    );
    expect(d).toHaveLength(4); // unchanged leaves are not held
  });

  test('applying held leaves keeps the pulled sibling values', () => {
    const pulled = { businessName: 'Cloud', laborRate: 90, providerKeys: { square: 'tok', other: 'x' } };
    const held = [
      { path: ['laborRate'], value: 120 },
      { path: ['providerKeys', 'square'], removed: true as const },
      { path: ['pushToken', 'token'], value: 'abc' },
    ];
    expect(applyHeldEntries(pulled, held)).toEqual({
      businessName: 'Cloud',
      laborRate: 120,
      providerKeys: { other: 'x' },
      pushToken: { token: 'abc' },
    });
  });

  test('mergeHeldEntries replaces the same path with the newer value', () => {
    const merged = mergeHeldEntries([{ path: ['a'], value: 1 }], [{ path: ['a'], value: 2 }, { path: ['b'], value: 3 }]);
    expect(merged).toEqual([{ path: ['a'], value: 2 }, { path: ['b'], value: 3 }]);
  });
});
