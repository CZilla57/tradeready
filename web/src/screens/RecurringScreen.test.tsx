import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import type {
  Customer,
  RecurringInvoice,
  RecurringJob,
  Settings,
} from '@shared/types/models';
import RecurringScreen from './RecurringScreen';

const writes = vi.hoisted(() => ({
  setRecurringJobActive: vi.fn(),
  setRecurringInvoiceActive: vi.fn(),
  updateRecurringInvoiceRule: vi.fn(),
  updateRecurringJobRule: vi.fn(),
  createRecurringInvoice: vi.fn(),
  createRecurringJob: vi.fn(),
  deleteRecurringJob: vi.fn(),
  deleteRecurringInvoice: vi.fn(),
}));
vi.mock('../lib/writeRepository', () => writes);

const retry = vi.hoisted(() => vi.fn());
const store = vi.hoisted(() => ({
  recurringJobs: [] as RecurringJob[],
  recurringInvoices: [] as RecurringInvoice[],
  customers: [] as Customer[],
  settings: { minimumJobFee: 0 } as Settings,
}));
vi.mock('../lib/DataContext', () => ({
  useData: () => ({
    recurringJobs: store.recurringJobs,
    recurringInvoices: store.recurringInvoices,
    customers: store.customers,
    settings: store.settings,
    retry,
  }),
  useResources: () => ({ loading: false, error: null, refreshing: false, retry }),
}));

function job(over: Partial<RecurringJob> = {}): RecurringJob {
  return {
    id: 'rj1',
    customerId: 'c1',
    customerName: 'Acme',
    title: 'Gutter clean',
    description: '',
    address: '',
    notes: '',
    estimateTotal: 300,
    laborHours: 2,
    laborRate: 90,
    materials: [],
    materialMarkup: 0,
    overhead: 0,
    margin: 0,
    cadence: 'monthly',
    endCondition: 'never',
    occurrenceCount: 3,
    lastGeneratedDate: '2026-08-01',
    nextDueDate: '2026-09-01',
    isActive: true,
    createdAt: '2026-01-01',
    ...over,
  };
}

function plan(over: Partial<RecurringInvoice> = {}): RecurringInvoice {
  return {
    id: 'ri1',
    customerId: 'c1',
    customerName: 'Beta LLC',
    description: 'Monthly service',
    amount: 150,
    dueDays: 30,
    cadence: 'monthly',
    endCondition: 'never',
    occurrenceCount: 5,
    lastGeneratedDate: '2026-08-01',
    nextDueDate: '2026-09-01',
    isActive: true,
    createdAt: '2026-01-01',
    ...over,
  };
}

/** The row (`.row`) whose title text matches. */
function rowFor(title: string): HTMLElement {
  return screen.getByText(title).closest('.row') as HTMLElement;
}

beforeEach(() => {
  writes.setRecurringJobActive.mockReset().mockResolvedValue(job());
  writes.setRecurringInvoiceActive.mockReset().mockResolvedValue(plan());
  writes.updateRecurringInvoiceRule.mockReset().mockResolvedValue(plan());
  writes.updateRecurringJobRule.mockReset().mockResolvedValue(job());
  writes.createRecurringInvoice.mockReset().mockResolvedValue(plan());
  writes.createRecurringJob.mockReset().mockResolvedValue(job());
  writes.deleteRecurringJob.mockReset().mockResolvedValue(undefined);
  writes.deleteRecurringInvoice.mockReset().mockResolvedValue(undefined);
  retry.mockReset();
  store.recurringJobs = [job()];
  store.recurringInvoices = [plan()];
  store.customers = [
    { id: 'c1', name: 'Beta LLC', email: '', phone: '', address: '', notes: '' },
  ];
});

describe('RecurringScreen — pause/resume', () => {
  it('pauses an active recurring job and refreshes', async () => {
    render(<RecurringScreen />);
    const row = rowFor('Gutter clean');
    await userEvent.click(within(row).getByRole('button', { name: 'Pause' }));

    await waitFor(() =>
      expect(writes.setRecurringJobActive).toHaveBeenCalledWith('rj1', false),
    );
    expect(retry).toHaveBeenCalledWith(['recurringJobs']);
  });

  it('resumes a paused maintenance plan', async () => {
    store.recurringInvoices = [plan({ isActive: false })];
    render(<RecurringScreen />);
    const row = rowFor('Beta LLC');
    await userEvent.click(within(row).getByRole('button', { name: 'Resume' }));

    await waitFor(() =>
      expect(writes.setRecurringInvoiceActive).toHaveBeenCalledWith('ri1', true),
    );
    expect(retry).toHaveBeenCalledWith(['recurringInvoices']);
  });

  it('surfaces a toggle error and leaves the row unchanged', async () => {
    writes.setRecurringJobActive.mockRejectedValue(new Error('rls denied'));
    render(<RecurringScreen />);
    const row = rowFor('Gutter clean');
    await userEvent.click(within(row).getByRole('button', { name: 'Pause' }));

    await waitFor(() =>
      expect(within(row).getByRole('alert')).toHaveTextContent('rls denied'),
    );
    expect(retry).not.toHaveBeenCalled();
  });
});

describe('RecurringScreen — delete', () => {
  it('deletes a plan behind an inline confirm', async () => {
    render(<RecurringScreen />);
    const row = rowFor('Beta LLC');

    await userEvent.click(within(row).getByRole('button', { name: 'Delete' }));
    // The toggle is now hidden behind the confirm; nothing written yet.
    expect(writes.deleteRecurringInvoice).not.toHaveBeenCalled();

    await userEvent.click(within(row).getByRole('button', { name: 'Delete plan' }));
    await waitFor(() =>
      expect(writes.deleteRecurringInvoice).toHaveBeenCalledWith('ri1'),
    );
    expect(retry).toHaveBeenCalledWith(['recurringInvoices']);
  });

  it('cancels a pending delete without writing', async () => {
    render(<RecurringScreen />);
    const row = rowFor('Gutter clean');

    await userEvent.click(within(row).getByRole('button', { name: 'Delete' }));
    await userEvent.click(within(row).getByRole('button', { name: 'Cancel' }));

    expect(within(row).getByRole('button', { name: 'Pause' })).toBeInTheDocument();
    expect(writes.deleteRecurringJob).not.toHaveBeenCalled();
  });
});

describe('RecurringScreen — maintenance plan rule editing', () => {
  it('edits plan fields via updateRecurringInvoiceRule and refreshes', async () => {
    render(<RecurringScreen />);
    const row = rowFor('Beta LLC');
    await userEvent.click(within(row).getByRole('button', { name: 'Edit' }));

    const amount = within(row).getByDisplayValue('150');
    await userEvent.clear(amount);
    await userEvent.type(amount, '200');
    await userEvent.click(within(row).getByRole('button', { name: 'Quarterly' }));
    await userEvent.click(within(row).getByRole('button', { name: 'Save changes' }));

    await waitFor(() =>
      expect(writes.updateRecurringInvoiceRule).toHaveBeenCalledTimes(1),
    );
    expect(writes.updateRecurringInvoiceRule).toHaveBeenCalledWith('ri1', {
      description: 'Monthly service',
      amount: 200,
      dueDays: 30,
      cadence: 'quarterly',
      endCondition: 'never',
      endCount: undefined,
      endDate: undefined,
      originalNextDueDate: '2026-09-01',
      nextDueDate: '2026-09-01',
      autoSendEnabled: false,
    });
    expect(retry).toHaveBeenCalledWith(['recurringInvoices']);
  });

  it('requires an end count when the plan ends after N invoices', async () => {
    render(<RecurringScreen />);
    const row = rowFor('Beta LLC');
    await userEvent.click(within(row).getByRole('button', { name: 'Edit' }));

    await userEvent.click(within(row).getByRole('button', { name: 'After N' }));
    // Leave the (now-visible) count blank and save.
    await userEvent.click(within(row).getByRole('button', { name: 'Save changes' }));

    await waitFor(() =>
      expect(within(row).getByRole('alert')).toHaveTextContent(/greater than zero/i),
    );
    expect(writes.updateRecurringInvoiceRule).not.toHaveBeenCalled();
    expect(retry).not.toHaveBeenCalled();
  });

  it('rejects a non-positive amount', async () => {
    render(<RecurringScreen />);
    const row = rowFor('Beta LLC');
    await userEvent.click(within(row).getByRole('button', { name: 'Edit' }));

    const amount = within(row).getByDisplayValue('150');
    await userEvent.clear(amount);
    await userEvent.type(amount, '0');
    await userEvent.click(within(row).getByRole('button', { name: 'Save changes' }));

    await waitFor(() =>
      expect(within(row).getByRole('alert')).toHaveTextContent(/greater than zero/i),
    );
    expect(writes.updateRecurringInvoiceRule).not.toHaveBeenCalled();
  });

});

describe('RecurringScreen — recurring job rule editing', () => {
  it('edits job rule + recomputes estimateTotal via the pricing port', async () => {
    render(<RecurringScreen />);
    const row = rowFor('Gutter clean');
    await userEvent.click(within(row).getByRole('button', { name: 'Edit' }));

    // job() pricing: laborHours 2, overhead 0, margin 0. Set rate 100 → total 200.
    const rate = within(row).getByDisplayValue('90');
    await userEvent.clear(rate);
    await userEvent.type(rate, '100');
    await userEvent.click(within(row).getByRole('button', { name: 'Save changes' }));

    await waitFor(() =>
      expect(writes.updateRecurringJobRule).toHaveBeenCalledTimes(1),
    );
    expect(writes.updateRecurringJobRule.mock.calls[0][0]).toBe('rj1');
    expect(writes.updateRecurringJobRule.mock.calls[0][1]).toMatchObject({
      title: 'Gutter clean',
      laborRate: 100,
      estimateTotal: 200,
      cadence: 'monthly',
      endCondition: 'never',
      originalNextDueDate: '2026-09-01',
      nextDueDate: '2026-09-01',
    });
    expect(retry).toHaveBeenCalledWith(['recurringJobs']);
  });

  it('requires a title', async () => {
    render(<RecurringScreen />);
    const row = rowFor('Gutter clean');
    await userEvent.click(within(row).getByRole('button', { name: 'Edit' }));

    await userEvent.clear(within(row).getByDisplayValue('Gutter clean'));
    await userEvent.click(within(row).getByRole('button', { name: 'Save changes' }));

    await waitFor(() =>
      expect(within(row).getByRole('alert')).toHaveTextContent(/title is required/i),
    );
    expect(writes.updateRecurringJobRule).not.toHaveBeenCalled();
  });

  it('rejects a blank pricing field', async () => {
    render(<RecurringScreen />);
    const row = rowFor('Gutter clean');
    await userEvent.click(within(row).getByRole('button', { name: 'Edit' }));

    await userEvent.clear(within(row).getByDisplayValue('90')); // labor rate
    await userEvent.click(within(row).getByRole('button', { name: 'Save changes' }));

    await waitFor(() =>
      expect(within(row).getByRole('alert')).toHaveTextContent(/non-negative number/i),
    );
    expect(writes.updateRecurringJobRule).not.toHaveBeenCalled();
  });

  it('seeds the materials editor from the rule and writes edited materials', async () => {
    store.recurringJobs = [
      job({ materials: [{ id: 'm1', name: 'Filter', quantity: 1, unitCost: 20 }] }),
    ];
    render(<RecurringScreen />);
    const row = rowFor('Gutter clean');
    await userEvent.click(within(row).getByRole('button', { name: 'Edit' }));

    // Existing material seeded into the editor.
    expect(within(row).getByDisplayValue('Filter')).toBeInTheDocument();
    // Add a second material.
    await userEvent.click(within(row).getByRole('button', { name: '+ Add material' }));
    const names = within(row).getAllByLabelText('Material name');
    await userEvent.type(names[names.length - 1], 'Bracket');
    await userEvent.click(within(row).getByRole('button', { name: 'Save changes' }));

    await waitFor(() =>
      expect(writes.updateRecurringJobRule).toHaveBeenCalledTimes(1),
    );
    const edit = writes.updateRecurringJobRule.mock.calls[0][1];
    expect(edit.materials).toHaveLength(2);
    expect(edit.materials.map((m: { name: string }) => m.name)).toEqual(['Filter', 'Bracket']);
  });
});

describe('RecurringScreen — create maintenance plan', () => {
  it('creates a plan for a picked customer and refreshes', async () => {
    render(<RecurringScreen />);
    await userEvent.click(screen.getByRole('button', { name: 'New plan' }));

    await userEvent.selectOptions(screen.getByLabelText('Customer'), 'c1');
    await userEvent.type(screen.getByLabelText('Amount ($)'), '150');
    await userEvent.type(screen.getByLabelText('Description'), 'Monthly service');
    await userEvent.click(screen.getByRole('button', { name: 'Create plan' }));

    await waitFor(() => expect(writes.createRecurringInvoice).toHaveBeenCalledTimes(1));
    expect(writes.createRecurringInvoice.mock.calls[0][0]).toMatchObject({
      customerId: 'c1',
      customerName: 'Beta LLC',
      description: 'Monthly service',
      amount: 150,
      dueDays: 30,
      cadence: 'monthly',
      endCondition: 'never',
      autoSendEnabled: false,
    });
    expect(retry).toHaveBeenCalledWith(['recurringInvoices']);
  });

  it('requires a customer to be chosen', async () => {
    render(<RecurringScreen />);
    await userEvent.click(screen.getByRole('button', { name: 'New plan' }));

    await userEvent.type(screen.getByLabelText('Amount ($)'), '150');
    await userEvent.click(screen.getByRole('button', { name: 'Create plan' }));

    await waitFor(() =>
      expect(screen.getByRole('alert')).toHaveTextContent(/choose a customer/i),
    );
    expect(writes.createRecurringInvoice).not.toHaveBeenCalled();
  });

  it('rejects a non-positive amount', async () => {
    render(<RecurringScreen />);
    await userEvent.click(screen.getByRole('button', { name: 'New plan' }));

    await userEvent.selectOptions(screen.getByLabelText('Customer'), 'c1');
    await userEvent.click(screen.getByRole('button', { name: 'Create plan' }));

    await waitFor(() =>
      expect(screen.getByRole('alert')).toHaveTextContent(/greater than zero/i),
    );
    expect(writes.createRecurringInvoice).not.toHaveBeenCalled();
  });

  it('prompts to add a customer first when none exist', async () => {
    store.customers = [];
    render(<RecurringScreen />);
    await userEvent.click(screen.getByRole('button', { name: 'New plan' }));

    expect(screen.getByText(/add a customer first/i)).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Create plan' })).not.toBeInTheDocument();
  });
});

describe('RecurringScreen — create recurring job', () => {
  it('creates a fresh series for a picked customer with a recomputed total', async () => {
    render(<RecurringScreen />);
    await userEvent.click(screen.getByRole('button', { name: 'New job' }));

    await userEvent.selectOptions(screen.getByLabelText('Customer'), 'c1');
    await userEvent.type(screen.getByLabelText('Title'), 'Quarterly gutter clean');
    const hours = screen.getByLabelText('Labor hours');
    await userEvent.clear(hours);
    await userEvent.type(hours, '2');
    await userEvent.click(screen.getByRole('button', { name: 'Create recurring job' }));

    await waitFor(() => expect(writes.createRecurringJob).toHaveBeenCalledTimes(1));
    const arg = writes.createRecurringJob.mock.calls[0][0];
    expect(arg).toMatchObject({
      customerId: 'c1',
      customerName: 'Beta LLC',
      title: 'Quarterly gutter clean',
      laborHours: 2,
      cadence: 'monthly',
      endCondition: 'never',
    });
    // estimateTotal is recomputed (derived), not left unset.
    expect(typeof arg.estimateTotal).toBe('number');
    expect(arg.estimateTotal).toBeGreaterThan(0);
    expect(retry).toHaveBeenCalledWith(['recurringJobs']);
  });

  it('authors a material on create and includes it in the payload', async () => {
    render(<RecurringScreen />);
    await userEvent.click(screen.getByRole('button', { name: 'New job' }));

    await userEvent.selectOptions(screen.getByLabelText('Customer'), 'c1');
    await userEvent.type(screen.getByLabelText('Title'), 'Gutter clean');
    await userEvent.click(screen.getByRole('button', { name: '+ Add material' }));
    await userEvent.type(screen.getByLabelText('Material name'), 'Sealant');
    const cost = screen.getByLabelText('Material unit cost');
    await userEvent.clear(cost);
    await userEvent.type(cost, '12'); // qty defaults to 1
    await userEvent.click(screen.getByRole('button', { name: 'Create recurring job' }));

    await waitFor(() => expect(writes.createRecurringJob).toHaveBeenCalledTimes(1));
    const arg = writes.createRecurringJob.mock.calls[0][0];
    expect(arg.materials).toHaveLength(1);
    expect(arg.materials[0]).toMatchObject({ name: 'Sealant', quantity: 1, unitCost: 12 });
  });

  it('requires a customer and a title', async () => {
    render(<RecurringScreen />);
    await userEvent.click(screen.getByRole('button', { name: 'New job' }));

    await userEvent.click(screen.getByRole('button', { name: 'Create recurring job' }));
    await waitFor(() =>
      expect(screen.getByRole('alert')).toHaveTextContent(/choose a customer/i),
    );
    expect(writes.createRecurringJob).not.toHaveBeenCalled();

    await userEvent.selectOptions(screen.getByLabelText('Customer'), 'c1');
    await userEvent.click(screen.getByRole('button', { name: 'Create recurring job' }));
    await waitFor(() =>
      expect(screen.getByRole('alert')).toHaveTextContent(/title is required/i),
    );
    expect(writes.createRecurringJob).not.toHaveBeenCalled();
  });

  it('prompts to add a customer first when none exist', async () => {
    store.customers = [];
    render(<RecurringScreen />);
    await userEvent.click(screen.getByRole('button', { name: 'New job' }));

    expect(screen.getByText(/add a customer first/i)).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Create recurring job' })).not.toBeInTheDocument();
  });
});
