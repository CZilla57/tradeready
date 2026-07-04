// hooks/useMoneyData.js
// Data loading and expense mutation logic for the Money tab.
// Extracted from MoneyScreen so the screen only owns UI state.

import { useState, useCallback } from 'react';
import { useFocusEffect } from '@react-navigation/native';
import { loadInvoices, loadExpenses, saveExpenses, loadJobs } from '../utils/storage';
import { generateExpenseId } from '../utils/moneyUtils';

export function useMoneyData() {
  const [invoices, setInvoices] = useState([]);
  const [expenses, setExpenses] = useState([]);
  const [jobs, setJobs]         = useState([]);
  const [loading, setLoading]   = useState(true);

  // Reload every time this tab comes into focus so P&L reflects the latest data
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

  const persistExpenses = useCallback(async (updated) => {
    try {
      await saveExpenses(updated);
    } catch (err) {
      console.error('useMoneyData: failed to save expenses', err);
    }
  }, []);

  // Accepts the form fields from AddExpenseModal; stamps id + createdAt here
  const handleAddExpense = useCallback((fields) => {
    const expense = {
      id:        generateExpenseId(),
      createdAt: new Date().toISOString(),
      ...fields,
    };
    setExpenses(prev => {
      const updated = [expense, ...prev];
      persistExpenses(updated);
      return updated;
    });
  }, [persistExpenses]);

  const handleDeleteExpense = useCallback((id) => {
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
