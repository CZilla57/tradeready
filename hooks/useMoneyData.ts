import { useState, useCallback } from 'react';
import { useFocusEffect } from '@react-navigation/native';
import type { Invoice, Expense, Job, ExpenseDraft } from '../types/models';
import { loadInvoices, loadExpenses, saveExpenses, loadJobs } from '../utils/storage';
import { generateExpenseId } from '../utils/moneyUtils';
import { track } from '../utils/analytics';

interface UseMoneyDataReturn {
  invoices: Invoice[];
  expenses: Expense[];
  jobs: Job[];
  loading: boolean;
  handleAddExpense: (fields: ExpenseDraft) => void;
  handleDeleteExpense: (id: string) => void;
}

export function useMoneyData(): UseMoneyDataReturn {
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
        } finally {
          if (active) setLoading(false);
        }
      }

      load();
      return () => { active = false; };
    }, [])
  );

  const persistExpenses = useCallback(async (updated: Expense[]) => {
    try {
      await saveExpenses(updated);
    } catch (err) {
      console.error('useMoneyData: failed to save expenses', err);
    }
  }, []);

  const handleAddExpense = useCallback((fields: ExpenseDraft) => {
    const expense: Expense = {
      id:        generateExpenseId(),
      createdAt: new Date().toISOString(),
      ...fields,
    };
    setExpenses(prev => {
      const updated = [expense, ...prev];
      persistExpenses(updated).then(() => {
        track('expense_logged', { category: fields.category });
      });
      return updated;
    });
  }, [persistExpenses]);

  const handleDeleteExpense = useCallback((id: string) => {
    setExpenses(prev => {
      const updated = prev.filter(e => e.id !== id);
      persistExpenses(updated);
      return updated;
    });
  }, [persistExpenses]);

  return {
    invoices,
    expenses,
    jobs,
    loading,
    handleAddExpense,
    handleDeleteExpense,
  };
}
