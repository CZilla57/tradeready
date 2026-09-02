import {
  createContext,
  useContext,
  useCallback,
  useEffect,
  useRef,
  useState,
  type ReactNode,
} from 'react';
import type {
  Job,
  Invoice,
  Customer,
  Expense,
  Settings,
  CustomerNotes,
  PricebookEntry,
  RecurringJob,
  RecurringInvoice,
} from '@shared/types/models';
import {
  fetchJobs,
  fetchInvoices,
  fetchCustomers,
  fetchExpenses,
  fetchSettings,
  fetchCustomerNotes,
  fetchPricebook,
  fetchRecurringJobs,
  fetchRecurringInvoices,
} from './repository';
import { useAuth } from './AuthContext';
import { publishDataChange, subscribeDataChange } from './dataSync';

// After a backgrounded tab comes forward, ignore focus/visibility events that
// arrive within this window of the last refresh — rapid app/tab switching would
// otherwise re-pull every collection several times a second.
const FOCUS_REFRESH_THROTTLE_MS = 3000;

// Each independently-loadable resource has a stable key. Loading, error, and
// "ever loaded" state are all tracked per key, so one collection failing (say
// pricebook) never blanks a screen that only needs another (Jobs, Money…).
export type ResourceKey =
  | 'jobs'
  | 'invoices'
  | 'customers'
  | 'expenses'
  | 'settings'
  | 'notes'
  | 'pricebook'
  | 'recurringJobs'
  | 'recurringInvoices';

export const RESOURCE_KEYS: ResourceKey[] = [
  'jobs',
  'invoices',
  'customers',
  'expenses',
  'settings',
  'notes',
  'pricebook',
  'recurringJobs',
  'recurringInvoices',
];

// The user-owned business data the portal renders. Every field is reset to its
// empty value when the authenticated user changes, so one account's rows can
// never be shown under another's session.
interface DataState {
  jobs: Job[];
  invoices: Invoice[];
  customers: Customer[];
  expenses: Expense[];
  settings: Settings | null;
  notes: CustomerNotes;
  pricebook: PricebookEntry[];
  recurringJobs: RecurringJob[];
  recurringInvoices: RecurringInvoice[];
}

const EMPTY_DATA: DataState = {
  jobs: [],
  invoices: [],
  customers: [],
  expenses: [],
  settings: null,
  notes: {},
  pricebook: [],
  recurringJobs: [],
  recurringInvoices: [],
};

// One fetcher per resource, each returning only the slice of DataState it owns.
// Keeping them uniform lets the loader treat every resource the same way.
const FETCHERS: Record<ResourceKey, () => Promise<Partial<DataState>>> = {
  jobs: async () => ({ jobs: await fetchJobs() }),
  invoices: async () => ({ invoices: await fetchInvoices() }),
  customers: async () => ({ customers: await fetchCustomers() }),
  expenses: async () => ({ expenses: await fetchExpenses() }),
  settings: async () => ({ settings: await fetchSettings() }),
  notes: async () => ({ notes: await fetchCustomerNotes() }),
  pricebook: async () => ({ pricebook: await fetchPricebook() }),
  recurringJobs: async () => ({ recurringJobs: await fetchRecurringJobs() }),
  recurringInvoices: async () => ({
    recurringInvoices: await fetchRecurringInvoices(),
  }),
};

type BoolByKey = Record<ResourceKey, boolean>;
type ErrorsByKey = Partial<Record<ResourceKey, string>>;

function fill(value: boolean): BoolByKey {
  return RESOURCE_KEYS.reduce((acc, k) => {
    acc[k] = value;
    return acc;
  }, {} as BoolByKey);
}

interface DataValue extends DataState {
  /** Currently in flight, per resource. */
  loading: BoolByKey;
  /** Has ever loaded successfully at least once, per resource. */
  loaded: BoolByKey;
  /** Latest error message, per resource (cleared when a reload starts). */
  errors: ErrorsByKey;
  /** Reload every resource (keeps already-loaded data visible meanwhile). */
  reload: () => void;
  /** Reload a specific subset of resources. */
  retry: (keys: ResourceKey[]) => void;
}

const DataCtx = createContext<DataValue | null>(null);

export function DataProvider({ children }: { children: ReactNode }) {
  const { session } = useAuth();
  const userId = session?.user?.id ?? null;

  const [data, setData] = useState<DataState>(EMPTY_DATA);
  // Start "loading" so the first render (before the effect fires) shows a
  // spinner rather than an empty-but-loaded flash. DataProvider only mounts
  // once a session exists, so a load is always imminent.
  const [loading, setLoading] = useState<BoolByKey>(() => fill(true));
  const [loaded, setLoaded] = useState<BoolByKey>(() => fill(false));
  const [errors, setErrors] = useState<ErrorsByKey>({});

  // Per-resource request generation. Every load bumps the key's generation;
  // a response is committed only if its generation is still current, so a
  // superseded request (a newer reload, or a user switch that reloads all)
  // can never overwrite fresher state or leak a previous user's rows.
  const genRef = useRef<Record<ResourceKey, number>>(
    RESOURCE_KEYS.reduce(
      (acc, k) => {
        acc[k] = 0;
        return acc;
      },
      {} as Record<ResourceKey, number>,
    ),
  );

  const load = useCallback((keys: ResourceKey[]) => {
    if (keys.length === 0) return;
    setLoading((prev) => {
      const next = { ...prev };
      for (const k of keys) next[k] = true;
      return next;
    });
    setErrors((prev) => {
      const next = { ...prev };
      for (const k of keys) delete next[k];
      return next;
    });
    for (const key of keys) {
      const gen = (genRef.current[key] += 1);
      FETCHERS[key]().then(
        (slice) => {
          if (genRef.current[key] !== gen) return; // superseded
          setData((prev) => ({ ...prev, ...slice }));
          setLoaded((prev) => ({ ...prev, [key]: true }));
          setLoading((prev) => ({ ...prev, [key]: false }));
        },
        (err: unknown) => {
          if (genRef.current[key] !== gen) return; // superseded
          setErrors((prev) => ({
            ...prev,
            [key]: err instanceof Error ? err.message : 'Failed to load',
          }));
          setLoading((prev) => ({ ...prev, [key]: false }));
        },
      );
    }
  }, []);

  const reload = useCallback(() => load(RESOURCE_KEYS), [load]);
  // A targeted reload is what a screen calls right after it writes, so it is also
  // the moment to tell sibling tabs which collections changed. Reloads that are
  // NOT app-driven writes — the focus refresh and an incoming cross-tab notice
  // (both call `load` directly) — deliberately do not re-broadcast, so tabs can't
  // ping-pong reloads at each other.
  const retry = useCallback(
    (keys: ResourceKey[]) => {
      load(keys);
      publishDataChange(keys);
    },
    [load],
  );

  // React to the authenticated user changing (including signing out, userId ->
  // null). Clearing here is what guarantees user A's rows are gone the instant
  // the session flips to user B; bumping every generation abandons any of A's
  // in-flight requests so a late response can't repaint B's screen.
  useEffect(() => {
    for (const k of RESOURCE_KEYS) genRef.current[k] += 1;
    setData(EMPTY_DATA);
    setLoaded(fill(false));
    setErrors({});
    if (userId) {
      setLoading(fill(true));
      load(RESOURCE_KEYS);
    } else {
      setLoading(fill(false));
    }
  }, [userId, load]);

  // Freshen a tab that was left open. A background tab misses every write made
  // elsewhere — another portal tab, the mobile app, a Stripe webhook — so when
  // it comes forward we silently re-pull from the server (loaded rows stay
  // visible; screens report `refreshing`, not a blocking `loading`). Throttled so
  // rapid app/tab switching doesn't stack redundant refreshes. Signed-out tabs
  // don't refresh — there is nothing to show.
  const lastFocusRefreshRef = useRef(0);
  useEffect(() => {
    if (!userId) return;
    function refreshIfStale() {
      if (document.visibilityState === 'hidden') return; // a blur, not a return
      const now = Date.now();
      if (now - lastFocusRefreshRef.current < FOCUS_REFRESH_THROTTLE_MS) return;
      lastFocusRefreshRef.current = now;
      load(RESOURCE_KEYS);
    }
    document.addEventListener('visibilitychange', refreshIfStale);
    window.addEventListener('focus', refreshIfStale);
    return () => {
      document.removeEventListener('visibilitychange', refreshIfStale);
      window.removeEventListener('focus', refreshIfStale);
    };
  }, [userId, load]);

  // React to a sibling tab announcing a write. Reload exactly the collections it
  // named (via `load`, not `retry`, so this tab doesn't re-broadcast). Guarded by
  // sign-in and by the current keys, so a stale message can't refetch under the
  // wrong session.
  useEffect(() => {
    if (!userId) return;
    return subscribeDataChange((keys) => {
      const known = keys.filter((k) => RESOURCE_KEYS.includes(k));
      if (known.length > 0) load(known);
    });
  }, [userId, load]);

  return (
    <DataCtx.Provider
      value={{
        ...data,
        loading,
        loaded,
        errors,
        reload,
        retry,
      }}
    >
      {children}
    </DataCtx.Provider>
  );
}

export function useData(): DataValue {
  const ctx = useContext(DataCtx);
  if (!ctx) throw new Error('useData must be used within DataProvider');
  return ctx;
}

/** What a screen needs to know about the specific resources it depends on. */
export interface ResourceStatus {
  /** No data yet and still loading — block the screen with a spinner. */
  loading: boolean;
  /** Failed with no data to fall back on — show a scoped error + retry. */
  error: string | null;
  /** Reloading while previously-loaded data is still on screen. */
  refreshing: boolean;
  /** Retry just the depended-on resources (only the failed ones, if any). */
  retry: () => void;
}

/**
 * Scope a screen to the resources it actually uses. A screen only blocks (or
 * errors) on those keys — an unrelated collection failing elsewhere never
 * blanks it. During a manual retry, already-loaded data stays visible and the
 * screen reports `refreshing` instead of `loading`.
 */
export function useResources(...keys: ResourceKey[]): ResourceStatus {
  const { loading, loaded, errors, retry } = useData();

  const failed = keys.filter((k) => errors[k] !== undefined && !loaded[k]);
  const error = failed.length > 0 ? (errors[failed[0]] ?? null) : null;
  const blockingLoad =
    error === null && keys.some((k) => loading[k] && !loaded[k]);
  const refreshing = keys.some((k) => loading[k] && loaded[k]);

  return {
    loading: blockingLoad,
    error,
    refreshing,
    retry: () => retry(failed.length > 0 ? failed : keys),
  };
}
