import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import type { Expense, Invoice } from '@shared/types/models';
import MoneyScreen from './MoneyScreen';

const writes = vi.hoisted(() => ({
  saveExpense: vi.fn(),
  deleteExpense: vi.fn(),
}));
vi.mock('../lib/writeRepository', () => writes);

const retry = vi.hoisted(() => vi.fn());
const store = vi.hoisted(() => ({
  invoices: [] as Invoice[],
  expenses: [] as Expense[],
}));
vi.mock('../lib/DataContext', () => ({
  useData: () => ({ invoices: store.invoices, expenses: store.expenses, retry }),
  useResources: () => ({ loading: false, error: null, refreshing: false, retry }),
}));

function expense(over: Partial<Expense> = {}): Expense {
  return {
    id: 'e1',
    createdAt: '2026-08-01',
    description: 'Pipe fittings',
    amount: 42,
    category: 'materials',
    date: '2026-08-15',
    notes: '',
    receiptUri: null,
    ...over,
  };
}

beforeEach(() => {
  writes.saveExpense.mockReset().mockResolvedValue(expense());
  writes.deleteExpense.mockReset().mockResolvedValue(undefined);
  retry.mockReset();
  store.invoices = [];
  store.expenses = [expense()];
});

describe('MoneyScreen — expenses', () => {
  it('adds a validated expense via saveExpense and refreshes', async () => {
    render(<MoneyScreen />);
    await userEvent.click(screen.getByRole('button', { name: 'Add expense' }));

    // Description is the first textbox in the form (labels aren't htmlFor-linked).
    await userEvent.type(screen.getAllByRole('textbox')[0], 'New drill');
    await userEvent.type(screen.getByRole('spinbutton'), '120');
    await userEvent.click(screen.getByRole('button', { name: 'Add expense' }));

    await waitFor(() => expect(writes.saveExpense).toHaveBeenCalledTimes(1));
    const saved = writes.saveExpense.mock.calls[0][0];
    // stampExpense stamped an id + createdAt; our fields came through.
    expect(saved).toMatchObject({ description: 'New drill', amount: 120 });
    expect(saved.id).toBeTruthy();
    expect(saved.createdAt).toBeTruthy();
    expect(retry).toHaveBeenCalledWith(['expenses']);
  });

  it('blocks an amount of zero', async () => {
    render(<MoneyScreen />);
    await userEvent.click(screen.getByRole('button', { name: 'Add expense' }));
    await userEvent.type(screen.getAllByRole('textbox')[0], 'Bad');
    await userEvent.click(screen.getByRole('button', { name: 'Add expense' }));

    expect(screen.getByRole('alert')).toHaveTextContent(/greater than zero/i);
    expect(writes.saveExpense).not.toHaveBeenCalled();
  });

  it('edits an existing expense, preserving hidden fields', async () => {
    store.expenses = [expense({ receiptUri: 'r://1', jobId: 'job-9' })];
    render(<MoneyScreen />);
    await userEvent.click(screen.getByRole('button', { name: 'Edit' }));

    const amount = screen.getByRole('spinbutton');
    await userEvent.clear(amount);
    await userEvent.type(amount, '55');
    await userEvent.click(screen.getByRole('button', { name: 'Save changes' }));

    await waitFor(() => expect(writes.saveExpense).toHaveBeenCalledTimes(1));
    expect(writes.saveExpense.mock.calls[0][0]).toMatchObject({
      id: 'e1',
      amount: 55,
      receiptUri: 'r://1',
      jobId: 'job-9',
    });
  });

  it('deletes an expense after confirmation', async () => {
    render(<MoneyScreen />);
    await userEvent.click(screen.getByRole('button', { name: 'Delete' }));
    // Confirmation reveals the destructive Delete.
    await userEvent.click(screen.getByRole('button', { name: 'Delete' }));

    await waitFor(() => expect(writes.deleteExpense).toHaveBeenCalledWith('e1'));
    expect(retry).toHaveBeenCalledWith(['expenses']);
  });
});
