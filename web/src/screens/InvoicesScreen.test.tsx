import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter } from 'react-router-dom';
import type { Customer, Invoice, Settings } from '@shared/types/models';
import InvoicesScreen from './InvoicesScreen';

const invoices: Invoice[] = [
  { id: 'i1', customer: 'Acme', number: 'INV-0003', amount: 100, due: '2999-01-01', email: '', phone: '', desc: '', paid: false },
] as Invoice[];

const store = vi.hoisted(() => ({
  customers: [] as Customer[],
  settings: null as Settings | null,
}));
vi.mock('../lib/DataContext', () => ({
  useData: () => ({ invoices, customers: store.customers, settings: store.settings }),
  useResources: () => ({
    loading: false,
    error: null,
    refreshing: false,
    retry: vi.fn(),
  }),
}));

const writes = vi.hoisted(() => ({ createInvoice: vi.fn() }));
vi.mock('../lib/writeRepository', () => writes);

const navigate = vi.hoisted(() => vi.fn());
vi.mock('react-router-dom', async (importOriginal) => ({
  ...(await importOriginal<typeof import('react-router-dom')>()),
  useNavigate: () => navigate,
}));

beforeEach(() => {
  store.customers = [{ id: 'c1', name: 'Acme', email: 'a@b.co', phone: '555' } as Customer];
  store.settings = null;
  writes.createInvoice.mockReset().mockResolvedValue({ id: 'i-new' });
  navigate.mockReset();
});

function renderScreen() {
  return render(
    <MemoryRouter>
      <InvoicesScreen />
    </MemoryRouter>,
  );
}

describe('InvoicesScreen — new invoice', () => {
  it('defaults the number to the next in sequence and creates on save', async () => {
    renderScreen();
    await userEvent.click(screen.getByRole('button', { name: 'New invoice' }));

    // nextInvoiceNumber over INV-0003 → INV-0004 (shared helper, not mocked).
    expect(screen.getByLabelText('Number')).toHaveValue('INV-0004');

    await userEvent.selectOptions(screen.getByRole('combobox'), 'c1');
    await userEvent.type(screen.getByLabelText('Amount ($)'), '450');
    await userEvent.click(screen.getByRole('button', { name: 'Create invoice' }));

    expect(writes.createInvoice).toHaveBeenCalledTimes(1);
    expect(writes.createInvoice.mock.calls[0][0]).toMatchObject({
      customer: 'Acme',
      customerId: 'c1',
      number: 'INV-0004',
      amount: 450,
      // Contact snapshot adopted from the picked customer.
      email: 'a@b.co',
      phone: '555',
    });
    expect(navigate).toHaveBeenCalledWith('/invoices/i-new');
  });

  it('blocks submit until a customer and a positive amount are given', async () => {
    renderScreen();
    await userEvent.click(screen.getByRole('button', { name: 'New invoice' }));
    await userEvent.click(screen.getByRole('button', { name: 'Create invoice' }));
    expect(screen.getByRole('alert')).toHaveTextContent(/choose a customer/i);
    expect(writes.createInvoice).not.toHaveBeenCalled();

    await userEvent.selectOptions(screen.getByRole('combobox'), 'c1');
    await userEvent.click(screen.getByRole('button', { name: 'Create invoice' }));
    expect(screen.getByRole('alert')).toHaveTextContent(/amount greater than zero/i);
    expect(writes.createInvoice).not.toHaveBeenCalled();
  });

  it('prompts to add a customer first when none exist', async () => {
    store.customers = [];
    renderScreen();
    await userEvent.click(screen.getByRole('button', { name: 'New invoice' }));
    expect(screen.getByText(/add a customer first/i)).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Create invoice' })).toBeNull();
  });

  it('keeps the error visible when the write fails', async () => {
    writes.createInvoice.mockRejectedValueOnce(new Error('rls denied'));
    renderScreen();
    await userEvent.click(screen.getByRole('button', { name: 'New invoice' }));
    await userEvent.selectOptions(screen.getByRole('combobox'), 'c1');
    await userEvent.type(screen.getByLabelText('Amount ($)'), '450');
    await userEvent.click(screen.getByRole('button', { name: 'Create invoice' }));

    expect(await screen.findByRole('alert')).toHaveTextContent('rls denied');
    expect(navigate).not.toHaveBeenCalled();
  });
});
