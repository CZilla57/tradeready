import { useState, useCallback } from 'react';
import { useFocusEffect } from '@react-navigation/native';
import type { Invoice, Expense, Job, ExpenseDraft } from '../types/models';
import { loadInvoices, loadExpenses, saveExpenses, loadJobs } from '../utils/storage';
import { stampExpense } from '../utils/moneyUtils';
import { track, reportError } from '../utils/analytics';
import { useUndo } from '../context/UndoContext';

interface UseMoneyDataReturn {
  invoices: Invoice[];
  expenses: Expense[];
  jobs: Job[];
  loading: boolean;
  refresh: () => Promise<void>;
  handleAddExpense: (fields: ExpenseDraft) => void;
  handleDeleteExpense: (id: string) => void;
}

export function useMoneyData(): UseMoneyDataReturn {
  const { showUndo } = useUndo();
  const [invoices, setInvoices] = useState<Invoice[]>([]);
  const [expenses, setExpenses] = useState<Expense[]>([]);
  const [jobs, setJobs]         = useState<Job[]>([]);
  const [loading, setLoading]   = useState(true);

  useFocusEffect(
    useCallback(() => {
      let active = true;

      async function load() {
        try {
          const [invs, exps, jbs] = await Promise.all([
            loadInvoices(),
            loadExpenses(),
            loadJobs(),
          ]);
          if (!active) return;
          setInvoices(invs);
          setExpenses(exps);
          setJobs(jbs);
        } catch (err) {
          console.error('useMoneyData: failed to load data', err);
          reportError(err, { context: 'moneyDataLoad' });
        } finally {
          if (active) setLoading(false);
        }
      }

      load();
      return () => { active = false; };
    }, [])
  );

  const refresh = useCallback(async () => {
    try {
      const [invs, exps, jbs] = await Promise.all([
        loadInvoices(),
        loadExpenses(),
        loadJobs(),
      ]);
      setInvoices(invs);
      setExpenses(exps);
      setJobs(jbs);
    } catch (err) {
      console.error('useMoneyData: failed to load data', err);
      reportError(err, { context: 'moneyDataRefresh' });
    }
  }, []);

  const persistExpenses = useCallback(async (updated: Expense[]) => {
    try {
      await saveExpenses(updated);
    } catch (err) {
      console.error('useMoneyData: failed to save expenses', err);
      reportError(err, { context: 'expenseSave' });
    }
  }, []);

  const handleAddExpense = useCallback((fields: ExpenseDraft) => {
    const expense: Expense = stampExpense(fields);
    setExpenses(prev => {
      const updated = [expense, ...prev];
      persistExpenses(updated).then(() => {
        track('expense_logged', { category: fields.category, linkedToJob: Boolean(fields.jobId) });
      });
      return updated;
    });
  }, [persistExpenses]);

  const handleDeleteExpense = useCallback((id: string) => {
    const deleted = expenses.find(e => e.id === id);
    const updated = expenses.filter(e => e.id !== id);
    setExpenses(updated);
    persistExpenses(updated);
    if (deleted) {
      showUndo('Expense deleted', async () => {
        const current = await loadExpenses();
        if (!current.some(e => e.id === deleted.id)) {
          const restored = [deleted, ...current];
          setExpenses(restored);
          await persistExpenses(restored);
        }
      });
    }
  }, [expenses, persistExpenses, showUndo]);

  return {
    invoices,
    expenses,
    jobs,
    loading,
    refresh,
    handleAddExpense,
    handleDeleteExpense,
  };
}
