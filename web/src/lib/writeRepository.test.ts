import { describe, it, expect, vi, beforeEach } from 'vitest';
import type { Invoice, Payment } from '@shared/types/models';
import {
  saveInvoice,
  recordInvoicePayment,
  markInvoicePaid,
  voidInvoicePayment,
  deleteInvoice,
  deleteJob,
  InvoiceNotFoundError,
  PaymentValidationError,
} from './writeRepository';

// A controllable supabase mock. `select(...).eq(...).maybeSingle()` resolves the
// current server row; `upsert(...)` captures what would be written and resolves
// an error-free result. Auth returns a fixed signed-in user.
const state = vi.hoisted(() => ({
  serverRow: null as { data: Invoice; deleted: boolean } | null,
  lastUpsert: null as Record<string, unknown> | null,
  upsertError: null as { message: string } | null,
  lastTable: null as string | null,
  lastUpdate: null as Record<string, unknown> | null,
  updateFilters: {} as Record<string, unknown>,
  updateError: null as { message: string } | null,
}));

vi.mock('./supabase', () => {
  const from = (table: string) => ({
    select: () => ({
      eq: () => ({
        maybeSingle: async () => ({ data: state.serverRow, error: null }),
      }),
    }),
    upsert: async (row: Record<string, unknown>) => {
      state.lastUpsert = row;
      return { error: state.upsertError };
    },
    // A thenable query builder: `.update(row).eq(a).eq(b)` records the payload
    // and every filter, and awaits to the (possibly error) result.
    update: (row: Record<string, unknown>) => {
      state.lastTable = table;
      state.lastUpdate = row;
      state.updateFilters = {};
      const builder = {
        eq(col: string, val: unknown) {
          state.updateFilters[col] = val;
          return builder;
        },
        then(resolve: (r: { error: unknown }) => unknown) {
          return Promise.resolve({ error: state.updateError }).then(resolve);
        },
      };
      return builder;
    },
  });
  return {
    supabase: {
      from,
      auth: {
        getUser: async () => ({ data: { user: { id: 'user-1' } }, error: null }),
      },
    },
  };
});

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

function payment(over: Partial<Payment> = {}): Payment {
  return { id: 'p1', amount: 100, date: '2026-07-01', method: 'cash', ...over };
}

/** The blob that would have been written to Supabase in the last upsert. */
function writtenInvoice(): Invoice {
  return state.lastUpsert!.data as Invoice;
}

beforeEach(() => {
  state.serverRow = null;
  state.lastUpsert = null;
  state.upsertError = null;
  state.lastTable = null;
  state.lastUpdate = null;
  state.updateFilters = {};
  state.updateError = null;
});

describe('persist stamping', () => {
  it('stamps user_id, a fresh updated_at, and deleted:false', async () => {
    state.serverRow = { data: invoice(), deleted: false };
    const before = Date.now();
    await markInvoicePaid('inv-1', '2026-08-02');

    const row = state.lastUpsert!;
    expect(row.id).toBe('inv-1');
    expect(row.user_id).toBe('user-1');
    expect(row.deleted).toBe(false);
    // updated_at must be a fresh, forward stamp so device pulls (gt updated_at)
    // actually see the edit — never omitted, never backdated.
    const stamped = Date.parse(row.updated_at as string);
    expect(stamped).toBeGreaterThanOrEqual(before);
  });

  it('surfaces a write error rather than reporting success', async () => {
    state.serverRow = { data: invoice(), deleted: false };
    state.upsertError = { message: 'rls denied' };
    await expect(markInvoicePaid('inv-1', '2026-08-02')).rejects.toMatchObject({
      message: 'rls denied',
    });
  });
});

describe('recordInvoicePayment — P0.1 ledger preservation', () => {
  it('preserves a server-side payment the caller never saw', async () => {
    // The Stripe webhook appended a $600 payment to the cloud row. The web
    // portal, which loaded the invoice before that, records a $400 cash payment.
    state.serverRow = {
      data: invoice({
        payments: [payment({ id: 'stripe_abc', amount: 600, method: 'stripe' })],
      }),
      deleted: false,
    };

    await recordInvoicePayment('inv-1', {
      amount: 400,
      date: '2026-07-20',
      method: 'cash',
    });

    const written = writtenInvoice();
    const ids = written.payments!.map((p) => p.id).sort();
    // Both payments survive — the server entry was NOT clobbered by the write.
    expect(ids).toEqual(['stripe_abc', expect.stringMatching(/^p\d+_\d+$/)].sort());
    const total = written.payments!.reduce((s, p) => s + p.amount, 0);
    expect(total).toBe(1000);
    // $600 + $400 settles the $1000 invoice.
    expect(written.paid).toBe(true);
  });

  it('rejects a non-positive amount before touching the server', async () => {
    await expect(
      recordInvoicePayment('inv-1', { amount: 0, date: '2026-07-01', method: 'cash' }),
    ).rejects.toBeInstanceOf(PaymentValidationError);
    expect(state.lastUpsert).toBeNull();
  });

  it('rejects a malformed date', async () => {
    await expect(
      recordInvoicePayment('inv-1', {
        amount: 50,
        date: '07/01/2026',
        method: 'cash',
      }),
    ).rejects.toBeInstanceOf(PaymentValidationError);
  });

  it('throws InvoiceNotFoundError when the row is missing', async () => {
    state.serverRow = null;
    await expect(
      recordInvoicePayment('inv-1', { amount: 50, date: '2026-07-01', method: 'cash' }),
    ).rejects.toBeInstanceOf(InvoiceNotFoundError);
  });

  it('treats a soft-deleted row as not found', async () => {
    state.serverRow = { data: invoice(), deleted: true };
    await expect(
      recordInvoicePayment('inv-1', { amount: 50, date: '2026-07-01', method: 'cash' }),
    ).rejects.toBeInstanceOf(InvoiceNotFoundError);
  });
});

describe('saveInvoice — edit scalars, keep the server ledger', () => {
  it('keeps edited scalar fields while unioning the server ledger', async () => {
    state.serverRow = {
      data: invoice({
        desc: 'old',
        payments: [payment({ id: 'stripe_abc', amount: 600, method: 'stripe' })],
      }),
      deleted: false,
    };

    // Editor changed the description; its in-memory copy predates the webhook so
    // its ledger is empty.
    await saveInvoice(invoice({ desc: 'new', payments: [] }));

    const written = writtenInvoice();
    expect(written.desc).toBe('new'); // edited scalar wins
    expect(written.payments!.map((p) => p.id)).toContain('stripe_abc'); // ledger kept
  });

  it('creates a new invoice when no server row exists', async () => {
    state.serverRow = null;
    await saveInvoice(invoice({ id: 'inv-new' }));
    expect(state.lastUpsert!.id).toBe('inv-new');
    expect(state.lastUpsert!.deleted).toBe(false);
  });
});

describe('soft-delete — P0.4 tombstones, never row removal', () => {
  it('writes a deleted:true tombstone with a fresh updated_at, scoped to id+user', async () => {
    const before = Date.now();
    await deleteInvoice('inv-1');

    expect(state.lastTable).toBe('invoices');
    expect(state.lastUpdate!.deleted).toBe(true);
    // The fresh stamp is what carries the tombstone across device pull filters.
    expect(Date.parse(state.lastUpdate!.updated_at as string)).toBeGreaterThanOrEqual(
      before,
    );
    expect(state.updateFilters).toEqual({ id: 'inv-1', user_id: 'user-1' });
    // A tombstone is an UPDATE, never a hard delete (no upsert either).
    expect(state.lastUpsert).toBeNull();
  });

  it('routes each typed deleter to its own collection', async () => {
    await deleteJob('job-9');
    expect(state.lastTable).toBe('jobs');
    expect(state.updateFilters.id).toBe('job-9');
  });

  it('surfaces a delete error rather than reporting success', async () => {
    state.updateError = { message: 'rls denied' };
    await expect(deleteInvoice('inv-1')).rejects.toMatchObject({
      message: 'rls denied',
    });
  });
});

describe('voidInvoicePayment', () => {
  it('stamps voidedAt and re-derives paid from the remaining ledger', async () => {
    state.serverRow = {
      data: invoice({
        paid: true,
        payments: [payment({ id: 'p1', amount: 1000, method: 'cash' })],
      }),
      deleted: false,
    };

    await voidInvoicePayment('inv-1', 'p1', '2026-08-10');

    const written = writtenInvoice();
    const voided = written.payments!.find((p) => p.id === 'p1');
    expect(voided!.voidedAt).toBe('2026-08-10');
    // The only payment is now void → nothing collected → invoice flips to unpaid.
    expect(written.paid).toBe(false);
  });
});
