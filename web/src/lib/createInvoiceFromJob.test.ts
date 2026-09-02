import { describe, it, expect, vi, beforeEach } from 'vitest';
import type { Invoice, Job } from '@shared/types/models';
import {
  createInvoiceFromJob,
  InvoiceFromJobStateError,
  ValidationError,
  JobNotFoundError,
} from './writeRepository';

// A supabase mock that records EVERY upsert (the op writes twice: the invoice,
// then the advanced job), keyed by table, plus the current job server row the
// op reads back with `.select(...).eq('id', …).maybeSingle()`.
const state = vi.hoisted(() => ({
  jobRow: null as { data: unknown; deleted: boolean } | null,
  upserts: [] as { table: string; row: Record<string, unknown> }[],
  upsertError: null as { message: string } | null,
}));

vi.mock('./supabase', () => {
  const from = (table: string) => {
    const maybeSingle = async () => ({ data: state.jobRow, error: null });
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
    setJob(makeJob({ status: 'quoted' }));
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
