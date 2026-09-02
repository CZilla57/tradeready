import { describe, it, expect, vi, beforeEach } from 'vitest';
import type { Invoice, Job } from '@shared/types/models';
import {
  createInvoiceFromJob,
  finalizeInvoiceFromJob,
  InvoiceFromJobStateError,
  InvoiceNotFoundError,
  ValidationError,
  JobNotFoundError,
} from './writeRepository';

// A supabase mock that records EVERY upsert (each op writes twice: the invoice,
// then the advanced job), keyed by table, plus the current server rows the op
// reads back with `.select(...).eq('id', …).maybeSingle()` — per table, so
// finalize can read both the job and its existing deposit invoice.
const state = vi.hoisted(() => ({
  jobRow: null as { data: unknown; deleted: boolean } | null,
  invoiceRow: null as { data: unknown; deleted: boolean } | null,
  upserts: [] as { table: string; row: Record<string, unknown> }[],
  upsertError: null as { message: string } | null,
}));

vi.mock('./supabase', () => {
  const from = (table: string) => {
    const maybeSingle = async () => ({
      data: table === 'invoices' ? state.invoiceRow : state.jobRow,
      error: null,
    });
    return {
      select: () => ({ maybeSingle, eq: () => ({ maybeSingle }) }),
      upsert: async (row: Record<string, unknown>) => {
        state.upserts.push({ table, row });
        return { error: state.upsertError };
      },
    };
  };
  return {
    supabase: {
      from,
      auth: {
        getUser: async () => ({ data: { user: { id: 'user-1' } }, error: null }),
      },
    },
  };
});

function makeJob(over: Partial<Job> = {}): Job {
  return {
    id: 'j1',
    title: 'Water heater swap',
    customerName: 'Jane Smith',
    customerId: 'c1',
    status: 'complete',
    laborHours: 4,
    laborRate: 85,
    materials: [{ name: 'Heater', quantity: 1, unitCost: 300 }],
    materialMarkup: 20,
    estimateTotal: 966,
    // A field the op never touches, to prove it round-trips onto the job write.
    approval: { decision: 'approved', signedAt: '2026-08-01' },
    ...over,
  } as Job;
}

function setJob(job: Job | null) {
  state.jobRow = job ? { data: job, deleted: false } : null;
}
function setInvoice(inv: Invoice | null) {
  state.invoiceRow = inv ? { data: inv, deleted: false } : null;
}

function upsertTo(table: string) {
  return state.upserts.find((u) => u.table === table);
}
function writtenInvoice(): Invoice {
  return upsertTo('invoices')!.row.data as Invoice;
}
function writtenJob(): Job {
  return upsertTo('jobs')!.row.data as Job;
}

beforeEach(() => {
  state.jobRow = null;
  state.invoiceRow = null;
  state.upserts = [];
  state.upsertError = null;
});

describe('createInvoiceFromJob', () => {
  it('creates a final bill from a completed job and advances it to invoiced', async () => {
    setJob(makeJob());
    const created = await createInvoiceFromJob('j1', {
      number: 'INV-7',
      email: 'jane@example.com',
      phone: '555-1000',
    });

    // Invoice: derived amount + line items, job link, contact prefill.
    expect(created.amount).toBe(966);
    expect(created.jobId).toBe('j1');
    expect(created.number).toBe('INV-7');
    expect(created.email).toBe('jane@example.com');
    expect(created.customer).toBe('Jane Smith');
    expect(created.customerId).toBe('c1');
    expect(created.paid).toBe(false);
    expect(created.desc).toBe('Water heater swap');
    expect(created.lineItems?.map((l) => l.category)).toEqual(['labor', 'materials', 'overhead']);
    expect(created.lineItems!.reduce((s, l) => s + l.amount, 0)).toBeCloseTo(966, 2);

    // Both rows were written to the right tables, no client updated_at (P0.3).
    expect(upsertTo('invoices')!.row).not.toHaveProperty('updated_at');
    expect(writtenInvoice().id).toBe(created.id);

    // Job advanced complete → invoiced, linked, everything else preserved.
    const job = writtenJob();
    expect(job.status).toBe('invoiced');
    expect(job.invoiceId).toBe(created.id);
    expect(job.estimateTotal).toBe(966);
    expect(job.approval).toEqual({ decision: 'approved', signedAt: '2026-08-01' });
  });

  it('bills tracked timer hours on a finished job', async () => {
    const start = new Date('2026-08-01T08:00:00.000Z');
    const end = new Date(start.getTime() + 5.5 * 3600000);
    setJob(makeJob({ timeSessions: [{ start: start.toISOString(), end: end.toISOString() }] }));

    const created = await createInvoiceFromJob('j1', { number: 'INV-8' });
    expect(created.amount).toBe(1093.5); // 966 + 1.5h × $85
    expect(created.lineItems![0].description).toBe('Labor — 5.5 hrs @ $85/hr');
  });

  it('requestDeposit bills the estimate and holds the job status', async () => {
    setJob(makeJob({ status: 'scheduled' }));
    const created = await createInvoiceFromJob('j1', { number: 'INV-9' });

    expect(created.amount).toBe(966);
    const job = writtenJob();
    expect(job.status).toBe('scheduled'); // NOT advanced
    expect(job.invoiceId).toBe(created.id);
  });

  it('refuses a job that already has an invoice (finalize is out of scope)', async () => {
    setJob(makeJob({ invoiceId: 'inv-existing' }));
    await expect(createInvoiceFromJob('j1', { number: 'INV-1' })).rejects.toBeInstanceOf(
      InvoiceFromJobStateError,
    );
    expect(state.upserts).toHaveLength(0); // nothing written
  });

  it('refuses a job whose estimate is not yet approved', async () => {
    setJob(makeJob({ status: 'estimate_sent' }));
    await expect(createInvoiceFromJob('j1', { number: 'INV-1' })).rejects.toBeInstanceOf(
      InvoiceFromJobStateError,
    );
    expect(state.upserts).toHaveLength(0);
  });

  it('refuses a job with no billable amount', async () => {
    setJob(makeJob({ estimateTotal: 0, laborHours: 0, materials: [] }));
    await expect(createInvoiceFromJob('j1', { number: 'INV-1' })).rejects.toBeInstanceOf(
      ValidationError,
    );
    expect(state.upserts).toHaveLength(0);
  });

  it('rejects a blank invoice number before touching the server', async () => {
    setJob(makeJob());
    await expect(createInvoiceFromJob('j1', { number: '   ' })).rejects.toBeInstanceOf(
      ValidationError,
    );
    expect(state.upserts).toHaveLength(0);
  });

  it('throws when the job does not exist', async () => {
    setJob(null);
    await expect(createInvoiceFromJob('missing', { number: 'INV-1' })).rejects.toBeInstanceOf(
      JobNotFoundError,
    );
  });

  it('defaults the due date to 30 days out when none is given', async () => {
    setJob(makeJob());
    const created = await createInvoiceFromJob('j1', { number: 'INV-2' });
    expect(created.due).toMatch(/^\d{4}-\d{2}-\d{2}$/);
  });
});

describe('finalizeInvoiceFromJob', () => {
  // A completed job whose deposit invoice already exists and links back.
  function depositJob(over: Partial<Job> = {}): Job {
    return makeJob({ invoiceId: 'inv-dep', ...over });
  }
  function depositInvoice(over: Partial<Invoice> = {}): Invoice {
    return {
      id: 'inv-dep',
      customer: 'Jane Smith',
      customerId: 'c1',
      number: 'INV-DEP',
      amount: 483, // a 50% deposit of the $966 job
      due: '2026-07-01',
      email: 'jane@example.com',
      phone: '555-1000',
      desc: 'Deposit',
      paid: false,
      jobId: 'j1',
      depositRequest: { amount: 483, percent: 50 },
      ...over,
    } as Invoice;
  }

  it('rebills the full job total on the deposit invoice and carries its ledger', async () => {
    setJob(depositJob());
    setInvoice(
      depositInvoice({
        payments: [{ id: 'p1', amount: 483, date: '2026-07-02', method: 'card' }],
      }),
    );

    const updated = await finalizeInvoiceFromJob('j1');

    // The deposit invoice becomes the full bill, same id, ledger preserved.
    expect(updated.id).toBe('inv-dep');
    expect(updated.amount).toBe(966);
    expect(updated.payments).toHaveLength(1);
    expect(updated.paid).toBe(false); // 483 paid of 966 → balance remains
    // Identity fields kept from the deposit record.
    expect(updated.number).toBe('INV-DEP');
    expect(updated.email).toBe('jane@example.com');
    expect(updated.lineItems?.map((l) => l.category)).toEqual(['labor', 'materials', 'overhead']);

    // Job advanced complete → invoiced (balance remains), everything else kept.
    const job = writtenJob();
    expect(job.status).toBe('invoiced');
    expect(job.invoiceId).toBe('inv-dep');
    expect(job.approval).toEqual({ decision: 'approved', signedAt: '2026-08-01' });
  });

  it('advances the job to paid when the deposit already covers the full total', async () => {
    setJob(depositJob());
    setInvoice(
      depositInvoice({
        amount: 966,
        payments: [{ id: 'p1', amount: 966, date: '2026-07-02', method: 'card' }],
      }),
    );

    const updated = await finalizeInvoiceFromJob('j1');
    expect(updated.paid).toBe(true);
    expect(writtenJob().status).toBe('paid');
  });

  it('picks up approved change orders in the finalized total', async () => {
    setJob(
      depositJob({
        changeOrders: [
          { id: 'co1', title: 'Extra', amount: 100, createdAt: '2026-08-01', approval: { decision: 'approved' } } as never,
        ],
      }),
    );
    setInvoice(depositInvoice());

    const updated = await finalizeInvoiceFromJob('j1');
    expect(updated.amount).toBe(1066); // 966 + 100
  });

  it('refuses a completed job that has no deposit invoice (that is a create)', async () => {
    setJob(makeJob()); // complete, no invoiceId
    await expect(finalizeInvoiceFromJob('j1')).rejects.toBeInstanceOf(InvoiceFromJobStateError);
    expect(state.upserts).toHaveLength(0);
  });

  it('refuses a job that is not complete', async () => {
    setJob(makeJob({ status: 'scheduled', invoiceId: 'inv-dep' }));
    await expect(finalizeInvoiceFromJob('j1')).rejects.toBeInstanceOf(InvoiceFromJobStateError);
    expect(state.upserts).toHaveLength(0);
  });

  it('throws when the linked deposit invoice is missing', async () => {
    setJob(depositJob());
    setInvoice(null);
    await expect(finalizeInvoiceFromJob('j1')).rejects.toBeInstanceOf(InvoiceNotFoundError);
    // The invoice was never written (the read failed first).
    expect(state.upserts.find((u) => u.table === 'invoices')).toBeUndefined();
  });
});
