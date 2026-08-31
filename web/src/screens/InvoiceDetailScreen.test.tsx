import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter, Routes, Route } from 'react-router-dom';
import type { Invoice } from '@shared/types/models';
import { getTodayDateString } from '@shared/utils/dateHelpers';
import InvoiceDetailScreen from './InvoiceDetailScreen';

// The write module is mocked — this test verifies the screen calls the typed
// ops with validated inputs and refreshes on success, not the ledger math
// (that lives in writeRepository.test.ts).
const writes = vi.hoisted(() => ({
  recordInvoicePayment: vi.fn(),
  markInvoicePaid: vi.fn(),
  voidInvoicePayment: vi.fn(),
}));
vi.mock('../lib/writeRepository', () => writes);

const retry = vi.hoisted(() => vi.fn());
const store = vi.hoisted(() => ({ invoices: [] as Invoice[] }));
vi.mock('../lib/DataContext', () => ({
  useData: () => ({ invoices: store.invoices, customers: [], retry }),
  useResources: () => ({ loading: false, error: null, refreshing: false, retry }),
}));

function invoice(over: Partial<Invoice> = {}): Invoice {
  return {
    id: 'inv-1',
    customer: 'Acme',
    number: '001',
    amount: 1000,
    due: '2026-08-01',
    email: '',
    phone: '',
    desc: '',
    paid: false,
    ...over,
  };
}

function renderScreen() {
  return render(
    <MemoryRouter initialEntries={['/invoices/inv-1']}>
      <Routes>
        <Route path="/invoices/:id" element={<InvoiceDetailScreen />} />
      </Routes>
    </MemoryRouter>,
  );
}

beforeEach(() => {
  writes.recordInvoicePayment.mockReset().mockResolvedValue(invoice());
  writes.markInvoicePaid.mockReset().mockResolvedValue(invoice());
  writes.voidInvoicePayment.mockReset().mockResolvedValue(invoice());
  retry.mockReset();
  store.invoices = [invoice()];
});

describe('InvoiceDetailScreen — record payment', () => {
  it('records a validated payment and refreshes invoices', async () => {
    renderScreen();
    await userEvent.click(screen.getByRole('button', { name: 'Record a payment' }));
    await userEvent.type(screen.getByRole('spinbutton'), '250');
    await userEvent.click(screen.getByRole('button', { name: 'Save payment' }));

    await waitFor(() =>
      expect(writes.recordInvoicePayment).toHaveBeenCalledWith('inv-1', {
        amount: 250,
        date: getTodayDateString(),
        method: 'cash',
      }),
    );
    expect(retry).toHaveBeenCalledWith(['invoices']);
  });

  it('blocks a non-positive amount without calling the write', async () => {
    renderScreen();
    await userEvent.click(screen.getByRole('button', { name: 'Record a payment' }));
    await userEvent.click(screen.getByRole('button', { name: 'Save payment' }));

    expect(screen.getByRole('alert')).toHaveTextContent(/greater than zero/i);
    expect(writes.recordInvoicePayment).not.toHaveBeenCalled();
  });

  it('surfaces a write failure and does not report success', async () => {
    writes.recordInvoicePayment.mockRejectedValue(new Error('rls denied'));
    renderScreen();
    await userEvent.click(screen.getByRole('button', { name: 'Record a payment' }));
    await userEvent.type(screen.getByRole('spinbutton'), '250');
    await userEvent.click(screen.getByRole('button', { name: 'Save payment' }));

    await waitFor(() =>
      expect(screen.getByRole('alert')).toHaveTextContent('rls denied'),
    );
    // Form stays open (still shows the amount field), so the write never looks saved.
    expect(screen.getByRole('spinbutton')).toBeInTheDocument();
    expect(retry).not.toHaveBeenCalled();
  });
});

describe('InvoiceDetailScreen — mark paid', () => {
  it('settles the balance and refreshes', async () => {
    renderScreen();
    await userEvent.click(
      screen.getByRole('button', { name: /Mark paid/ }),
    );
    await waitFor(() =>
      expect(writes.markInvoicePaid).toHaveBeenCalledWith(
        'inv-1',
        getTodayDateString(),
      ),
    );
    expect(retry).toHaveBeenCalledWith(['invoices']);
  });

  it('hides the actions on an already-paid invoice', () => {
    store.invoices = [
      invoice({
        paid: true,
        payments: [{ id: 'p1', amount: 1000, date: '2026-07-01', method: 'cash' }],
      }),
    ];
    renderScreen();
    expect(screen.getByText('This invoice is fully paid.')).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /Mark paid/ })).toBeNull();
  });
});

describe('InvoiceDetailScreen — void payment', () => {
  it('voids a payment after confirmation', async () => {
    store.invoices = [
      invoice({
        payments: [{ id: 'p1', amount: 400, date: '2026-07-01', method: 'cash' }],
      }),
    ];
    renderScreen();

    await userEvent.click(screen.getByRole('button', { name: 'Void' }));
    // Confirmation revealed a Cancel affordance next to the confirm Void.
    expect(screen.getByRole('button', { name: 'Cancel' })).toBeInTheDocument();
    await userEvent.click(screen.getByRole('button', { name: 'Void' }));

    await waitFor(() =>
      expect(writes.voidInvoicePayment).toHaveBeenCalledWith(
        'inv-1',
        'p1',
        getTodayDateString(),
      ),
    );
    expect(retry).toHaveBeenCalledWith(['invoices']);
  });
});
