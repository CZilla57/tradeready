import {
  createContext,
  useContext,
  useCallback,
  useEffect,
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
} from '@shared/types/models';
import {
  fetchJobs,
  fetchInvoices,
  fetchCustomers,
  fetchExpenses,
  fetchSettings,
  fetchCustomerNotes,
} from './repository';
import { useAuth } from './AuthContext';

interface DataValue {
  jobs: Job[];
  invoices: Invoice[];
  customers: Customer[];
  expenses: Expense[];
  settings: Settings | null;
  notes: CustomerNotes;
  loading: boolean;
  error: string | null;
  reload: () => void;
}

const DataCtx = createContext<DataValue | null>(null);

export function DataProvider({ children }: { children: ReactNode }) {
  const { session } = useAuth();
  const userId = session?.user?.id ?? null;

  const [jobs, setJobs] = useState<Job[]>([]);
  const [invoices, setInvoices] = useState<Invoice[]>([]);
  const [customers, setCustomers] = useState<Customer[]>([]);
  const [expenses, setExpenses] = useState<Expense[]>([]);
  const [settings, setSettings] = useState<Settings | null>(null);
  const [notes, setNotes] = useState<CustomerNotes>({});
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [nonce, setNonce] = useState(0);

  const reload = useCallback(() => setNonce((n) => n + 1), []);

  useEffect(() => {
    if (!userId) return;
    let active = true;
    setLoading(true);
    setError(null);
    Promise.all([
      fetchJobs(),
      fetchInvoices(),
      fetchCustomers(),
      fetchExpenses(),
      fetchSettings(),
      fetchCustomerNotes(),
    ])
      .then(([j, i, c, e, s, n]) => {
        if (!active) return;
        setJobs(j);
        setInvoices(i);
        setCustomers(c);
        setExpenses(e);
        setSettings(s);
        setNotes(n);
      })
      .catch((err: unknown) => {
        if (active)
          setError(err instanceof Error ? err.message : 'Failed to load data');
      })
      .finally(() => {
        if (active) setLoading(false);
      });
    return () => {
      active = false;
    };
  }, [userId, nonce]);

  return (
    <DataCtx.Provider
      value={{
        jobs,
        invoices,
        customers,
        expenses,
        settings,
        notes,
        loading,
        error,
        reload,
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
