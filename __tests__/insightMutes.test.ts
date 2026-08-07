// __tests__/insightMutes.test.ts
// Pins the Phase 15 insight dismiss/snooze store (utils/insightMutes.ts):
// local-frame snooze expiry, mute filtering ahead of the card's top-3 slice,
// prune-on-write growth bound, and the AsyncStorage round-trip under the
// wipe-covered key. Fixed clock: Tue Aug 4 2026, 10:00 local.

import AsyncStorage from '@react-native-async-storage/async-storage';
import {
  INSIGHT_MUTES_STORAGE_KEY,
  makeMute,
  isMuteActive,
  filterMutedInsights,
  pruneMutes,
  loadInsightMutes,
  muteInsight,
  type InsightMute,
} from '../utils/insightMutes';

const NOW = new Date(2026, 7, 4, 10, 0);
const TODAY = '2026-08-04';

describe('makeMute', () => {
  test('without days: permanent dismiss (no until)', () => {
    const mute = makeMute('low_margin:j1:1200', NOW);
    expect(mute.id).toBe('low_margin:j1:1200');
    expect(mute.until).toBeUndefined();
  });

  test('with days: snooze until today + days, local-frame', () => {
    expect(makeMute('maintenance_due:c1', NOW, 30).until).toBe('2026-09-03');
    expect(makeMute('maintenance_due:c1', NOW, 1).until).toBe('2026-08-05');
  });
});

describe('isMuteActive', () => {
  test('permanent dismiss is always active', () => {
    expect(isMuteActive({ id: 'x', mutedAt: NOW.toISOString() }, TODAY)).toBe(true);
  });

  test('snooze is active strictly before its until day, expired from that day on', () => {
    const mute: InsightMute = { id: 'x', mutedAt: NOW.toISOString(), until: '2026-08-05' };
    expect(isMuteActive(mute, '2026-08-04')).toBe(true);
    expect(isMuteActive(mute, '2026-08-05')).toBe(false);
    expect(isMuteActive(mute, '2026-08-06')).toBe(false);
  });
});

describe('filterMutedInsights', () => {
  const insights = [
    { id: 'a', title: 'A' },
    { id: 'b', title: 'B' },
    { id: 'c', title: 'C' },
    { id: 'd', title: 'D' },
  ];

  test('drops actively-muted insights, preserving order (top-3 backfill)', () => {
    const mutes: InsightMute[] = [{ id: 'b', mutedAt: NOW.toISOString() }];
    expect(filterMutedInsights(insights, mutes, NOW).map(i => i.id)).toEqual(['a', 'c', 'd']);
  });

  test('an expired snooze no longer hides its insight', () => {
    const mutes: InsightMute[] = [{ id: 'b', mutedAt: NOW.toISOString(), until: '2026-08-04' }];
    expect(filterMutedInsights(insights, mutes, NOW).map(i => i.id)).toEqual(['a', 'b', 'c', 'd']);
  });

  test('no mutes is a pass-through', () => {
    expect(filterMutedInsights(insights, [], NOW)).toBe(insights);
  });
});

describe('pruneMutes', () => {
  const dismiss: InsightMute = { id: 'keep', mutedAt: NOW.toISOString() };
  const expired: InsightMute = { id: 'old', mutedAt: NOW.toISOString(), until: '2026-08-01' };
  const stale: InsightMute = { id: 'gone', mutedAt: NOW.toISOString() };

  test('drops expired snoozes', () => {
    expect(pruneMutes([dismiss, expired], TODAY)).toEqual([dismiss]);
  });

  test('with liveIds: also drops mutes for insights the engine no longer emits', () => {
    expect(pruneMutes([dismiss, stale], TODAY, ['keep'])).toEqual([dismiss]);
  });

  test('without liveIds: keeps every non-expired mute', () => {
    expect(pruneMutes([dismiss, stale], TODAY)).toEqual([dismiss, stale]);
  });
});

describe('persistence round-trip', () => {
  test('loadInsightMutes tolerates empty, malformed, and wrong-shape storage', async () => {
    (AsyncStorage.getItem as jest.Mock).mockResolvedValueOnce(null);
    expect(await loadInsightMutes()).toEqual([]);
    (AsyncStorage.getItem as jest.Mock).mockResolvedValueOnce('not json');
    expect(await loadInsightMutes()).toEqual([]);
    (AsyncStorage.getItem as jest.Mock).mockResolvedValueOnce('{"a":1}');
    expect(await loadInsightMutes()).toEqual([]);
    (AsyncStorage.getItem as jest.Mock).mockResolvedValueOnce(JSON.stringify([{ id: 'a' }, { bad: true }]));
    expect(await loadInsightMutes()).toEqual([{ id: 'a' }]);
  });

  test('muteInsight writes the new mute under the wipe-covered key and prunes in the same write', async () => {
    const existing: InsightMute[] = [
      { id: 'keep', mutedAt: '2026-08-01T00:00:00.000Z' },
      { id: 'expired', mutedAt: '2026-08-01T00:00:00.000Z', until: '2026-08-02' },
      { id: 'no-longer-live', mutedAt: '2026-08-01T00:00:00.000Z' },
    ];
    (AsyncStorage.getItem as jest.Mock).mockResolvedValueOnce(JSON.stringify(existing));

    const mute = await muteInsight('maintenance_due:c9', NOW, {
      days: 30,
      liveIds: ['keep', 'maintenance_due:c9'],
    });

    expect(mute.until).toBe('2026-09-03');
    const [key, raw] = (AsyncStorage.setItem as jest.Mock).mock.calls.slice(-1)[0];
    expect(key).toBe(INSIGHT_MUTES_STORAGE_KEY);
    const stored = JSON.parse(raw);
    expect(stored.map((m: InsightMute) => m.id)).toEqual(['keep', 'maintenance_due:c9']);
  });

  test('re-muting the same id replaces its entry instead of stacking', async () => {
    (AsyncStorage.getItem as jest.Mock).mockResolvedValueOnce(
      JSON.stringify([{ id: 'x', mutedAt: '2026-08-01T00:00:00.000Z', until: '2026-08-10' }])
    );
    await muteInsight('x', NOW);
    const [, raw] = (AsyncStorage.setItem as jest.Mock).mock.calls.slice(-1)[0];
    const stored = JSON.parse(raw);
    expect(stored).toHaveLength(1);
    expect(stored[0].id).toBe('x');
    expect(stored[0].until).toBeUndefined();
  });
});
