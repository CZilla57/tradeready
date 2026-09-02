import { describe, it, expect, vi, beforeEach } from 'vitest';
import type { Invoice, Payment } from '@shared/types/models';
import {
  updateInvoiceDetails,
  recordInvoicePayment,
  markInvoicePaid,
  voidInvoicePayment,
  deleteInvoice,
  deleteJob,
  saveSettings,
  saveSchedule,
  saveCustomer,
  updateJobDetails,
  setJobArchived,
  advanceJobStatus,
  updateJobPricing,
  savePricebookEntry,
  saveExpense,
  createCustomer,
  createJob,
  createInvoice,
  createPricebookEntry,
  scheduleJob,
  setRecurringJobActive,
  setRecurringInvoiceActive,
  updateRecurringInvoiceRule,
  updateRecurringJobRule,
  createRecurringInvoice,
  createRecurringJob,
  InvoiceNotFoundError,
  JobNotFoundError,
  JobEstimateApprovalLockedError,
  JobStatusTransitionError,
  PaymentValidationError,
  StaleWriteError,
  ValidationError,
} from './writeRepository';
import type {
  Customer,
  Expense,
  Job,
  PricebookEntry,
  RecurringInvoice,
  RecurringJob,
} from '@shared/types/models';

// A controllable supabase mock. `select(...).eq(...).maybeSingle()` resolves the
// current server row; `upsert(...)` captures what would be written and resolves
// an error-free result. Auth returns a fixed signed-in user.
const state = vi.hoisted(() => ({
  serverRow: null as { data: unknown; deleted: boolean } | null,
  settingsRow: null as { data: Record<string, unknown> } | null,
  lastUpsert: null as Record<string, unknown> | null,
  upsertError: null as { message: string } | null,
  lastTable: null as string | null,
  lastUpdate: null as Record<string, unknown> | null,
  updateFilters: {} as Record<string, unknown>,
  updateError: null as { message: string } | null,
  updateResult: null as { id: string } | null,
}));

vi.mock('./supabase', () => {
  const from = (table: string) => {
    // `settings` is fetched with `.select('data').maybeSingle()` (no .eq);
    // invoices with `.select(...).eq('id', …).maybeSingle()`. Support both.
    const maybeSingle = async () => ({
      data: table === 'settings' ? state.settingsRow : state.serverRow,
      error: null,
    });
    return {
      select: () => ({ maybeSingle, eq: () => ({ maybeSingle }) }),
      upsert: async (row: Record<string, unknown>) => {
        state.lastUpsert = row;
        state.lastTable = table;
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
          is(col: string, val: unknown) {
            state.updateFilters[col] = val;
            return builder;
          },
          select() {
            return {
              maybeSingle: async () => ({
                data: state.updateResult,
                error: state.updateError,
              }),
            };
          },
          then(resolve: (r: { error: unknown }) => unknown) {
            return Promise.resolve({ error: state.updateError }).then(resolve);
          },
        };
        return builder;
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
  state.settingsRow = null;
  state.lastUpsert = null;
  state.upsertError = null;
  state.lastTable = null;
  state.lastUpdate = null;
  state.updateFilters = {};
  state.updateError = null;
  state.updateResult = null;
});

/** The blob that would have been written in the last settings upsert. */
function writtenSettings(): Record<string, unknown> {
  return state.lastUpsert!.data as Record<string, unknown>;
}

describe('saveCustomer — whole-blob upsert', () => {
  function customer(over: Partial<Customer> = {}): Customer {
    return {
      id: 'c1',
      name: 'Acme',
      email: 'a@b.co',
      phone: '555',
      address: '1 St',
      notes: '',
      ...over,
    };
  }

  it('upserts the full customer blob to the customers table with stamps', async () => {
    // Include a field the portal never renders to prove it round-trips (P0.2).
    const c = customer({ portal: { token: 'tok', enabled: true } });
    await saveCustomer(c, customer());

    const row = state.lastUpsert!;
    expect(state.lastTable).toBe('customers');
    expect(row.id).toBe('c1');
    expect(row.user_id).toBe('user-1');
    expect(row.deleted).toBe(false);
    expect((row.data as Customer).portal).toEqual({ token: 'tok', enabled: true });
    // P0.3: the client no longer sends `updated_at` — the DB trigger owns it.
    expect(row).not.toHaveProperty('updated_at');
  });

  it('surfaces a write error rather than reporting success', async () => {
    state.upsertError = { message: 'rls denied' };
    await expect(saveCustomer(customer(), customer())).rejects.toMatchObject({
      message: 'rls denied',
    });
  });
});

describe('createCustomer — new record with a mobile-format id', () => {
  it('mints a c<ms>_<n> id, stamps createdAt, and upserts the full record', async () => {
    const before = Date.now();
    const created = await createCustomer({
      name: 'Jane’s Bakery',
      email: 'jane@example.com',
      phone: '555-1212',
      address: '5 Main',
      notes: 'gate code 4321',
    });

    expect(state.lastTable).toBe('customers');
    // Mobile id format: c<Date.now()>_<counter>.
    expect(created.id).toMatch(/^c\d+_\d+$/);
    expect(Date.parse(created.createdAt as string)).toBeGreaterThanOrEqual(before);
    const row = state.lastUpsert!;
    expect(row.id).toBe(created.id);
    expect(row.deleted).toBe(false);
    expect(row.data as Customer).toMatchObject({
      name: 'Jane’s Bakery',
      email: 'jane@example.com',
      phone: '555-1212',
      address: '5 Main',
      notes: 'gate code 4321',
    });
  });

  it('mints a unique id on each call within the same millisecond', async () => {
    const a = await createCustomer({ name: 'A', email: '', phone: '', address: '', notes: '' });
    const b = await createCustomer({ name: 'B', email: '', phone: '', address: '', notes: '' });
    expect(a.id).not.toBe(b.id);
  });
});

describe('createJob — new unpriced lead with a mobile-format id', () => {
  const fields = {
    customerId: 'c1',
    customerName: 'Acme',
    title: 'Deck rebuild',
    description: 'Replace rotten boards',
    address: '5 Main',
    scheduledDate: '2026-09-10' as const,
    scheduledStartTime: '09:00' as const,
    scheduledEndTime: '11:00' as const,
    notes: 'bring saw',
    laborRate: 120,
    materialMarkup: 25,
    overhead: 18,
    margin: 22,
  };

  it('mints a j<ms> id and writes the unpriced lead shape mobile creates', async () => {
    const created = await createJob(fields);

    expect(state.lastTable).toBe('jobs');
    expect(created.id).toMatch(/^j\d+$/); // mobile id format j<Date.now()>
    const row = state.lastUpsert!;
    expect(row.id).toBe(created.id);
    expect(row.deleted).toBe(false);
    const written = row.data as Job;
    // Unpriced lead invariants.
    expect(written.status).toBe('lead');
    expect(written.estimateTotal).toBe(0);
    expect(written.laborHours).toBe(0);
    expect(written.materials).toEqual([]);
    expect(written.invoiceId).toBeNull();
    expect(/^\d{4}-\d{2}-\d{2}$/.test(written.createdAt as string)).toBe(true);
    // Customer link, operational fields, and the seeded rates all carried.
    expect(written).toMatchObject({
      customerId: 'c1',
      customerName: 'Acme',
      title: 'Deck rebuild',
      address: '5 Main',
      scheduledDate: '2026-09-10',
      laborRate: 120,
      materialMarkup: 25,
      overhead: 18,
      margin: 22,
    });
    // P0.3: the client omits `updated_at`; the DB trigger stamps it.
    expect(row).not.toHaveProperty('updated_at');
  });

  it('mints a unique id on each call within the same millisecond', async () => {
    const a = await createJob(fields);
    const b = await createJob(fields);
    expect(a.id).not.toBe(b.id);
  });

  it('surfaces a write error rather than reporting success', async () => {
    state.upsertError = { message: 'rls denied' };
    await expect(createJob(fields)).rejects.toMatchObject({ message: 'rls denied' });
  });
});

describe('createInvoice — new manual invoice with a mobile-format id', () => {
  const fields = {
    customer: 'Acme',
    customerId: 'c1',
    number: 'INV-0007',
    amount: 450,
    due: '2026-09-30' as const,
    email: 'a@b.co',
    phone: '555',
    desc: 'Repair work',
  };

  it('mints a bare-numeric id and writes the fresh manual-invoice shape', async () => {
    const created = await createInvoice(fields);

    expect(state.lastTable).toBe('invoices');
    // Mobile manual id format: String(Date.now()) — digits only.
    expect(created.id).toMatch(/^\d+$/);
    const row = state.lastUpsert!;
    expect(row.id).toBe(created.id);
    expect(row.deleted).toBe(false);
    const written = row.data as Invoice;
    // Fresh manual invoice: unpaid, no ledger, no line items / jobId.
    expect(written.paid).toBe(false);
    expect(written.payments).toBeUndefined();
    expect(written.lineItems).toBeUndefined();
    expect(written.jobId).toBeUndefined();
    expect(written).toMatchObject({
      customer: 'Acme',
      customerId: 'c1',
      number: 'INV-0007',
      amount: 450,
      due: '2026-09-30',
      email: 'a@b.co',
      phone: '555',
      desc: 'Repair work',
    });
  });

  it('mints a unique id on each call within the same millisecond', async () => {
    const a = await createInvoice(fields);
    const b = await createInvoice(fields);
    expect(a.id).not.toBe(b.id);
  });

  it('surfaces a write error rather than reporting success', async () => {
    state.upsertError = { message: 'rls denied' };
    await expect(createInvoice(fields)).rejects.toMatchObject({ message: 'rls denied' });
  });
});

describe('updateJobDetails — edit onto a fresh server copy', () => {
  function job(over: Partial<Job> = {}): Job {
    return {
      id: 'job-1',
      customerId: 'c1',
      customerName: 'Acme',
      title: 'Old title',
      description: '',
      status: 'scheduled',
      scheduledDate: null,
      scheduledStartTime: null,
      scheduledEndTime: null,
      address: '',
      estimateTotal: 500,
      laborHours: 4,
      laborRate: 90,
      materials: [],
      materialMarkup: 0,
      overhead: 0,
      margin: 0,
      notes: '',
      invoiceId: null,
      createdAt: '2026-08-01',
      ...over,
    };
  }

  const edit = {
    title: 'New title',
    description: 'desc',
    address: '5 Main',
    scheduledDate: '2026-09-01',
    scheduledStartTime: '09:00',
    scheduledEndTime: '11:00',
    notes: 'bring ladder',
  };

  it('preserves server-authored fields (approval, changeOrders, status) the edit never touches', async () => {
    const approval = { decision: 'approved', token: 't', signerName: 'Jane' };
    const changeOrders = [{ id: 'co1', approval: { decision: 'approved' } }];
    state.serverRow = {
      data: job({
        approval,
        changeOrders,
        status: 'approved',
        invoiceId: 'inv-9',
      } as Partial<Job>),
      deleted: false,
    };

    await updateJobDetails('job-1', edit, job());

    const written = state.lastUpsert!.data as Job;
    expect(state.lastTable).toBe('jobs');
    // Edited operational fields applied…
    expect(written.title).toBe('New title');
    expect(written.scheduledDate).toBe('2026-09-01');
    // …while consent/workflow fields survive untouched from the server copy.
    expect((written as unknown as { approval: unknown }).approval).toEqual(approval);
    expect(written.changeOrders).toEqual(changeOrders);
    expect(written.status).toBe('approved');
    expect(written.invoiceId).toBe('inv-9');
  });

  it('throws JobNotFoundError when the row is missing', async () => {
    state.serverRow = null;
    await expect(updateJobDetails('job-1', edit, job())).rejects.toBeInstanceOf(
      JobNotFoundError,
    );
  });

  it('setJobArchived stamps archivedAt on the fresh server copy', async () => {
    state.serverRow = { data: job(), deleted: false };
    await setJobArchived('job-1', true);
    const written = state.lastUpsert!.data as Job;
    expect(written.archivedAt).toBeTruthy();
    expect(state.lastTable).toBe('jobs');
  });

  const schedule = {
    scheduledDate: '2026-09-10' as const,
    scheduledStartTime: '09:00' as const,
    scheduledEndTime: '11:00' as const,
  };

  it('scheduleJob assigns the date and advances an approved job to scheduled (P0.6)', async () => {
    const approval = { decision: 'approved', token: 't' };
    state.serverRow = {
      data: job({ status: 'approved', approval } as Partial<Job>),
      deleted: false,
    };
    await scheduleJob('job-1', schedule, job());

    const written = state.lastUpsert!.data as Job;
    expect(state.lastTable).toBe('jobs');
    expect(written.scheduledDate).toBe('2026-09-10');
    expect(written.scheduledStartTime).toBe('09:00');
    expect(written.status).toBe('scheduled'); // approved → scheduled
    // consent survives the fresh-row merge
    expect((written as unknown as { approval: unknown }).approval).toEqual(approval);
  });

  it('scheduleJob never regresses a later status', async () => {
    state.serverRow = { data: job({ status: 'in_progress' }), deleted: false };
    await scheduleJob('job-1', schedule, job());
    expect((state.lastUpsert!.data as Job).status).toBe('in_progress');
  });

  it('scheduleJob does not advance a pre-approval status', async () => {
    state.serverRow = { data: job({ status: 'estimate_sent' }), deleted: false };
    await scheduleJob('job-1', schedule, job());
    expect((state.lastUpsert!.data as Job).status).toBe('estimate_sent');
  });

  it('scheduleJob clearing the date leaves status untouched', async () => {
    state.serverRow = { data: job({ status: 'scheduled', scheduledDate: '2026-09-01' }), deleted: false };
    await scheduleJob('job-1', {
      scheduledDate: null,
      scheduledStartTime: null,
      scheduledEndTime: null,
    }, job({ status: 'scheduled', scheduledDate: '2026-09-01' }));
    const written = state.lastUpsert!.data as Job;
    expect(written.scheduledDate).toBeNull();
    expect(written.status).toBe('scheduled'); // no regress on unschedule
  });

  describe('advanceJobStatus — operational subset, fresh-row guarded', () => {
    it('advances scheduled → in_progress and preserves server-authored fields', async () => {
      const approval = { decision: 'approved', signerName: 'Jane' };
      state.serverRow = {
        data: job({ status: 'scheduled', approval, invoiceId: 'inv-9' } as Partial<Job>),
        deleted: false,
      };
      await advanceJobStatus('job-1');
      const written = state.lastUpsert!.data as Job;
      expect(state.lastTable).toBe('jobs');
      expect(written.status).toBe('in_progress');
      // Everything the advance doesn't touch rides through from the server copy.
      expect((written as unknown as { approval: unknown }).approval).toEqual(approval);
      expect(written.invoiceId).toBe('inv-9');
    });

    it('advances in_progress → complete', async () => {
      state.serverRow = { data: job({ status: 'in_progress' }), deleted: false };
      await advanceJobStatus('job-1');
      expect((state.lastUpsert!.data as Job).status).toBe('complete');
    });

    it('rejects a status with no sanctioned operational transition, writing nothing', async () => {
      // complete → invoiced is invoice-coupled; the portal must not drive it.
      state.serverRow = { data: job({ status: 'complete' }), deleted: false };
      await expect(advanceJobStatus('job-1')).rejects.toBeInstanceOf(
        JobStatusTransitionError,
      );
      expect(state.lastUpsert).toBeNull();
    });

    it('guards on the FRESH server status, not the caller — a raced-ahead job is rejected', async () => {
      // The screen still shows "scheduled", but the server row already moved to
      // invoiced (a phone/invoice flow). The re-check rejects rather than
      // clobbering the further-along state.
      state.serverRow = { data: job({ status: 'invoiced' }), deleted: false };
      await expect(advanceJobStatus('job-1')).rejects.toBeInstanceOf(
        JobStatusTransitionError,
      );
      expect(state.lastUpsert).toBeNull();
    });

    it('throws JobNotFoundError when the row is missing', async () => {
      state.serverRow = null;
      await expect(advanceJobStatus('job-1')).rejects.toBeInstanceOf(
        JobNotFoundError,
      );
    });
  });

  describe('updateJobPricing — author the estimate onto a fresh server copy', () => {
    const editedJobCost = {
      id: 'jc2',
      label: 'Dumpster',
      category: 'disposal' as const,
      quantity: 1,
      unitCost: 200,
      markupPercent: 0,
      markupPolicy: 'in_margin_base' as const,
      taxable: false,
      customerVisible: true,
    };
    const pricing = {
      laborHours: 3,
      laborRate: 100,
      materials: [{ id: 'm1', name: 'Pipe', quantity: 2, unitCost: 15 }],
      jobCosts: [editedJobCost],
      materialMarkup: 20,
      overhead: 10,
      margin: 20,
      estimateTotal: 456,
    };

    it('atomically overwrites only pricing while the server estimate remains undecided', async () => {
      const approval = { token: 't' };
      const changeOrders = [{ id: 'co1' }];
      const timeSessions = [{ start: '2026-09-01T09:00:00Z', end: null }];
      const laborBreakdown = {
        onSiteHours: 3,
        driveHours: 0.5,
        supplyRunHours: 0.25,
        setupCleanupHours: 0.25,
      };
      state.serverRow = {
        data: job({
          title: 'Deck rebuild',
          status: 'scheduled',
          invoiceId: 'inv-9',
          approval,
          changeOrders,
          timeSessions,
          laborBreakdown,
        } as Partial<Job>),
        deleted: false,
      };
      state.updateResult = { id: 'job-1' };

      await updateJobPricing('job-1', pricing, job());

      const written = state.lastUpdate!.data as Job;
      expect(state.lastTable).toBe('jobs');
      // Pricing fields written (materials AND direct-cost lines)…
      expect(written.laborRate).toBe(100);
      expect(written.materials).toEqual(pricing.materials);
      expect(written.jobCosts).toEqual([editedJobCost]);
      expect(written.estimateTotal).toBe(456);
      // …everything else preserved from the server row.
      expect(written.title).toBe('Deck rebuild');
      expect(written.status).toBe('scheduled');
      expect(written.invoiceId).toBe('inv-9');
      expect((written as unknown as { approval: unknown }).approval).toEqual(approval);
      expect(written.changeOrders).toEqual(changeOrders);
      expect(written.timeSessions).toEqual(timeSessions);
      // The edited 3-hour total cannot retain the old 4-hour component split.
      expect(written).not.toHaveProperty('laborBreakdown');
      expect(state.updateFilters).toEqual({
        id: 'job-1',
        user_id: 'user-1',
        deleted: false,
        'data->approval->>decision': null,
      });
    });

    it('preserves the component split when labor hours are unchanged', async () => {
      const laborBreakdown = {
        onSiteHours: 3,
        driveHours: 0.5,
        supplyRunHours: 0.25,
        setupCleanupHours: 0.25,
      };
      state.serverRow = {
        data: job({ laborHours: 4, laborBreakdown }),
        deleted: false,
      };
      state.updateResult = { id: 'job-1' };

      await updateJobPricing('job-1', { ...pricing, laborHours: 4 }, job({ laborHours: 4 }));

      const written = state.lastUpdate!.data as Job;
      expect(written.laborBreakdown).toEqual(laborBreakdown);
    });

    it('rejects pricing when the freshly loaded job already has a decision', async () => {
      state.serverRow = {
        data: job({ approval: { decision: 'approved', token: 't' } } as Partial<Job>),
        deleted: false,
      };

      await expect(updateJobPricing('job-1', pricing, job())).rejects.toEqual(
        expect.objectContaining({
          name: 'JobEstimateApprovalLockedError',
          decision: 'approved',
        }),
      );
      expect(state.lastUpdate).toBeNull();
      expect(state.lastUpsert).toBeNull();
    });

    it('rejects the write when approval lands between the reload and update', async () => {
      state.serverRow = {
        data: job({ approval: { token: 't' } } as Partial<Job>),
        deleted: false,
      };
      // A null UPDATE result means the database-side approval predicate no
      // longer matched by the time Postgres acquired the row for the write.
      state.updateResult = null;

      await expect(updateJobPricing('job-1', pricing, job())).rejects.toBeInstanceOf(
        JobEstimateApprovalLockedError,
      );
      expect(state.updateFilters['data->approval->>decision']).toBeNull();
    });

    it('throws JobNotFoundError when the row is missing', async () => {
      state.serverRow = null;
      await expect(updateJobPricing('job-1', pricing, job())).rejects.toBeInstanceOf(
        JobNotFoundError,
      );
    });
  });
});

describe('savePricebookEntry — metadata edit, pricing preserved', () => {
  function entry(over: Partial<PricebookEntry> = {}): PricebookEntry {
    return {
      id: 'pb1',
      name: 'Drain clear',
      laborHours: 2,
      laborRate: 90,
      materials: [],
      materialMarkup: 15,
      overhead: 10,
      margin: 20,
      estimateTotal: 350,
      createdAt: '2026-08-01',
      updatedAt: '2026-08-01',
      ...over,
    };
  }

  it('upserts the entry to pricebook, preserving derived pricing and bumping updatedAt', async () => {
    await savePricebookEntry(entry({ name: 'Drain clearing' }), entry());
    const row = state.lastUpsert!;
    const data = row.data as PricebookEntry;
    expect(state.lastTable).toBe('pricebook');
    expect(data.name).toBe('Drain clearing');
    // Derived pricing fields the portal doesn't edit round-trip untouched.
    expect(data.estimateTotal).toBe(350);
    expect(data.margin).toBe(20);
    // The blob's own updatedAt is refreshed.
    expect(data.updatedAt).not.toBe('2026-08-01');
  });
});

describe('createPricebookEntry — new service with a mobile-format id', () => {
  it('mints a pb-<ms> id, stamps created/updatedAt, and upserts the record', async () => {
    const before = Date.now();
    const created = await createPricebookEntry({
      name: 'Water heater flush',
      category: 'Plumbing',
      description: 'Annual maintenance',
      laborHours: 1.5,
      laborRate: 100,
      materials: [{ id: 'm1', name: 'Anode rod', quantity: 1, unitCost: 40 }],
      materialMarkup: 20,
      overhead: 15,
      margin: 20,
      estimateTotal: 215.63,
    });

    expect(state.lastTable).toBe('pricebook');
    expect(created.id).toMatch(/^pb-\d+$/);
    expect(Date.parse(created.createdAt)).toBeGreaterThanOrEqual(before);
    expect(created.updatedAt).toBe(created.createdAt);
    const data = state.lastUpsert!.data as PricebookEntry;
    expect(data).toMatchObject({
      name: 'Water heater flush',
      category: 'Plumbing',
      description: 'Annual maintenance',
      laborRate: 100,
      estimateTotal: 215.63,
      // Authored materials round-trip onto the created record.
      materials: [{ id: 'm1', name: 'Anode rod', quantity: 1, unitCost: 40 }],
    });
  });

  it('collapses blank category/description to undefined', async () => {
    const created = await createPricebookEntry({
      name: 'Basic call-out',
      category: '',
      description: '',
      laborHours: 1,
      laborRate: 90,
      materials: [],
      materialMarkup: 0,
      overhead: 0,
      margin: 0,
      estimateTotal: 90,
    });
    expect(created.category).toBeUndefined();
    expect(created.description).toBeUndefined();
  });

  it('mints a unique id on each call within the same millisecond', async () => {
    const a = await createPricebookEntry({
      name: 'A', category: '', description: '', laborHours: 1, laborRate: 1,
      materials: [], materialMarkup: 0, overhead: 0, margin: 0, estimateTotal: 1,
    });
    const b = await createPricebookEntry({
      name: 'B', category: '', description: '', laborHours: 1, laborRate: 1,
      materials: [], materialMarkup: 0, overhead: 0, margin: 0, estimateTotal: 1,
    });
    expect(a.id).not.toBe(b.id);
  });
});

describe('saveExpense — whole-blob upsert', () => {
  it('upserts the expense to the expenses table with stamps', async () => {
    const expense: Expense = {
      id: 'e1',
      createdAt: '2026-08-01',
      description: 'Pipe',
      amount: 42,
      category: 'materials',
      date: '2026-08-15',
      notes: '',
      receiptUri: null,
    };
    await saveExpense(expense);
    const row = state.lastUpsert!;
    expect(state.lastTable).toBe('expenses');
    expect(row.id).toBe('e1');
    expect((row.data as Expense).amount).toBe(42);
    // P0.3: the client omits `updated_at`; the DB trigger stamps it.
    expect(row).not.toHaveProperty('updated_at');
  });
});

describe('saveSettings — P0.5 strip secure fields, keep the rest', () => {
  it('strips credential fields carried on a legacy server blob', async () => {
    state.settingsRow = {
      data: {
        businessName: 'Old Co',
        laborRate: 90,
        // A legacy blob written before the SecureStore split carried these inline.
        providerKey: 'sk-provider',
        anthropicKey: 'sk-anthropic',
        groqKey: 'sk-groq',
      },
    };

    await saveSettings(
      { businessName: 'New Co' },
      { businessName: 'Old Co' } as Parameters<typeof saveSettings>[1],
    );

    const written = writtenSettings();
    expect(written.businessName).toBe('New Co'); // patch applied
    expect(written.laborRate).toBe(90); // unrendered field preserved (P0.2)
    expect(written).not.toHaveProperty('providerKey');
    expect(written).not.toHaveProperty('anthropicKey');
    expect(written).not.toHaveProperty('groqKey');
  });

  it('strips a credential field even if the caller mistakenly includes one', async () => {
    state.settingsRow = { data: { businessName: 'Co', laborRate: 80 } };
    await saveSettings(
      {
        businessName: 'Co2',
        groqKey: 'leak',
      } as Parameters<typeof saveSettings>[0],
      { businessName: 'Co' } as Parameters<typeof saveSettings>[1],
    );
    expect(writtenSettings()).not.toHaveProperty('groqKey');
  });

  it('upserts by user_id with no id/deleted/updated_at columns', async () => {
    state.settingsRow = { data: { businessName: 'Co' } };
    await saveSettings(
      { phone: '555' },
      { businessName: 'Co' } as Parameters<typeof saveSettings>[1],
    );

    const row = state.lastUpsert!;
    expect(state.lastTable).toBe('settings');
    expect(row.user_id).toBe('user-1');
    expect(row).not.toHaveProperty('id');
    expect(row).not.toHaveProperty('deleted');
    // P0.3: the client omits `updated_at`; the DB trigger stamps it.
    expect(row).not.toHaveProperty('updated_at');
  });

  it('creates a settings row when none exists yet', async () => {
    state.settingsRow = null;
    await saveSettings(
      { businessName: 'Fresh' },
      {} as Parameters<typeof saveSettings>[1],
    );
    expect(writtenSettings().businessName).toBe('Fresh');
  });

  it('surfaces a write error rather than reporting success', async () => {
    state.settingsRow = { data: { businessName: 'Co' } };
    state.upsertError = { message: 'rls denied' };
    await expect(
      saveSettings(
        { phone: '1' },
        { businessName: 'Co' } as Parameters<typeof saveSettings>[1],
      ),
    ).rejects.toMatchObject({
      message: 'rls denied',
    });
  });
});

describe('saveSchedule — nested deep-merge, booking fields preserved', () => {
  it('merges the patch onto the server schedule, keeping fields the portal never sets', async () => {
    state.settingsRow = {
      data: {
        businessName: 'Co',
        schedule: {
          // Booking fields the mobile Booking screen owns — the portal must not drop these.
          bookableSlotsEnabled: true,
          slotLeadHours: 12,
          slotWindowDays: 30,
          timeZone: 'America/Chicago',
          // A working-pattern field the portal DOES edit.
          workDayStart: '08:00',
          workDayEnd: '17:00',
        },
      },
    };

    await saveSchedule(
      { workDayStart: '07:00', workDayEnd: '16:00', workDays: [1, 2, 3] },
      {
        schedule: { workDayStart: '08:00', workDayEnd: '17:00' },
      } as Parameters<typeof saveSchedule>[1],
    );

    const schedule = (writtenSettings().schedule ?? {}) as Record<string, unknown>;
    // Edited fields applied…
    expect(schedule.workDayStart).toBe('07:00');
    expect(schedule.workDayEnd).toBe('16:00');
    expect(schedule.workDays).toEqual([1, 2, 3]);
    // …and the booking fields the portal never touched survived (P0.2, one level down).
    expect(schedule.bookableSlotsEnabled).toBe(true);
    expect(schedule.slotLeadHours).toBe(12);
    expect(schedule.slotWindowDays).toBe(30);
    expect(schedule.timeZone).toBe('America/Chicago');
  });

  it('keeps sibling top-level settings and still strips secrets', async () => {
    state.settingsRow = {
      data: { businessName: 'Co', laborRate: 90, groqKey: 'leak', schedule: {} },
    };
    await saveSchedule(
      { bufferMinutes: 15 },
      { schedule: {} } as Parameters<typeof saveSchedule>[1],
    );
    const written = writtenSettings();
    expect(written.businessName).toBe('Co');
    expect(written.laborRate).toBe(90);
    expect(written).not.toHaveProperty('groqKey');
    expect((written.schedule as Record<string, unknown>).bufferMinutes).toBe(15);
  });

  it('creates the schedule object when the settings blob has none', async () => {
    state.settingsRow = { data: { businessName: 'Co' } };
    await saveSchedule(
      { workDays: [1, 2, 3, 4, 5] },
      {} as Parameters<typeof saveSchedule>[1],
    );
    expect((writtenSettings().schedule as Record<string, unknown>).workDays).toEqual([
      1, 2, 3, 4, 5,
    ]);
  });
});

describe('recurring pause/resume — preserve generation state', () => {
  function recJob(over: Partial<RecurringJob> = {}): RecurringJob {
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

  function recPlan(over: Partial<RecurringInvoice> = {}): RecurringInvoice {
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

  it('flips only isActive on a recurring job, keeping advancing generation state', async () => {
    state.serverRow = { data: recJob(), deleted: false };
    await setRecurringJobActive('rj1', false);

    const written = state.lastUpsert!.data as RecurringJob;
    expect(state.lastTable).toBe('recurringJobs');
    expect(written.isActive).toBe(false);
    // Generation state carried forward from the server row (P0.2).
    expect(written.occurrenceCount).toBe(3);
    expect(written.lastGeneratedDate).toBe('2026-08-01');
    expect(written.nextDueDate).toBe('2026-09-01'); // jobs keep back-fill (no fast-forward)
  });

  it('job resume does NOT fast-forward nextDueDate (back-fill kept)', async () => {
    state.serverRow = { data: recJob({ isActive: false, nextDueDate: '2020-01-01' }), deleted: false };
    await setRecurringJobActive('rj1', true);
    const written = state.lastUpsert!.data as RecurringJob;
    expect(written.isActive).toBe(true);
    expect(written.nextDueDate).toBe('2020-01-01');
  });

  it('plan resume fast-forwards a stale nextDueDate past today (no back-billing)', async () => {
    state.serverRow = { data: recPlan({ isActive: false, nextDueDate: '2020-01-01' }), deleted: false };
    await setRecurringInvoiceActive('ri1', true);

    const written = state.lastUpsert!.data as RecurringInvoice;
    expect(state.lastTable).toBe('recurringInvoices');
    expect(written.isActive).toBe(true);
    const today = new Date().toISOString().split('T')[0];
    expect(written.nextDueDate > today).toBe(true); // advanced strictly past today
    expect(written.occurrenceCount).toBe(5); // skipped periods don't count
  });

  it('plan pause only flips the flag, leaving nextDueDate alone', async () => {
    state.serverRow = { data: recPlan({ nextDueDate: '2026-09-01' }), deleted: false };
    await setRecurringInvoiceActive('ri1', false);
    const written = state.lastUpsert!.data as RecurringInvoice;
    expect(written.isActive).toBe(false);
    expect(written.nextDueDate).toBe('2026-09-01');
  });

  it('plan resume on an ended plan leaves nextDueDate unchanged', async () => {
    // endCount already met → isEndConditionMet true → no fast-forward.
    state.serverRow = {
      data: recPlan({
        isActive: false,
        endCondition: 'count',
        endCount: 5,
        occurrenceCount: 5,
        nextDueDate: '2020-01-01',
      }),
      deleted: false,
    };
    await setRecurringInvoiceActive('ri1', true);
    const written = state.lastUpsert!.data as RecurringInvoice;
    expect(written.nextDueDate).toBe('2020-01-01');
  });

  it('updateRecurringInvoiceRule applies edits but preserves the plan history', async () => {
    state.serverRow = {
      data: recPlan({
        occurrenceCount: 7,
        lastGeneratedDate: '2026-08-01',
        isActive: true,
        createdAt: '2026-01-01',
        customerId: 'c1',
        customerName: 'Beta LLC',
      }),
      deleted: false,
    };

    await updateRecurringInvoiceRule('ri1', {
      description: 'Quarterly deep clean',
      amount: 275,
      dueDays: 15,
      cadence: 'quarterly',
      endCondition: 'never',
      originalNextDueDate: '2026-09-01',
      nextDueDate: '2026-10-01',
      autoSendEnabled: true,
    }, recPlan());

    const written = state.lastUpsert!.data as RecurringInvoice;
    expect(state.lastTable).toBe('recurringInvoices');
    // Edited fields applied…
    expect(written.description).toBe('Quarterly deep clean');
    expect(written.amount).toBe(275);
    expect(written.dueDays).toBe(15);
    expect(written.cadence).toBe('quarterly');
    expect(written.nextDueDate).toBe('2026-10-01');
    expect(written.autoSendEnabled).toBe(true);
    // …history preserved from the server row (never rolled back).
    expect(written.occurrenceCount).toBe(7);
    expect(written.lastGeneratedDate).toBe('2026-08-01');
    expect(written.isActive).toBe(true);
    expect(written.createdAt).toBe('2026-01-01');
    expect(written.customerId).toBe('c1');
    expect(written.customerName).toBe('Beta LLC');
  });

  it('updateRecurringJobRule applies edits, keeps history, and takes the caller total', async () => {
    state.serverRow = {
      data: recJob({
        occurrenceCount: 4,
        lastGeneratedDate: '2026-08-01',
        isActive: true,
        createdAt: '2026-01-01',
        customerId: 'c1',
        customerName: 'Acme',
        materials: [{ id: 'm1', name: 'Filter', quantity: 1, unitCost: 20 }],
      } as Partial<RecurringJob>),
      deleted: false,
    };

    await updateRecurringJobRule('rj1', {
      title: 'Deep gutter clean',
      description: 'twice-yearly',
      laborHours: 3,
      laborRate: 100,
      materials: [{ id: 'm2', name: 'Brush', quantity: 2, unitCost: 5 }],
      materialMarkup: 10,
      overhead: 15,
      margin: 20,
      estimateTotal: 999, // recomputed by the caller (port); the op trusts it
      cadence: 'quarterly',
      endCondition: 'count',
      endCount: 8,
      originalNextDueDate: '2026-09-01',
      nextDueDate: '2026-12-01',
    }, recJob({
      materials: [{ id: 'm1', name: 'Filter', quantity: 1, unitCost: 20 }],
    } as Partial<RecurringJob>));

    const written = state.lastUpsert!.data as RecurringJob;
    expect(state.lastTable).toBe('recurringJobs');
    expect(written.title).toBe('Deep gutter clean');
    expect(written.laborRate).toBe(100);
    expect(written.estimateTotal).toBe(999);
    expect(written.cadence).toBe('quarterly');
    expect(written.endCondition).toBe('count');
    expect(written.endCount).toBe(8);
    expect(written.endDate).toBeUndefined();
    // history preserved from the server row (never rolled back)…
    expect(written.occurrenceCount).toBe(4);
    expect(written.lastGeneratedDate).toBe('2026-08-01');
    expect(written.isActive).toBe(true);
    expect(written.customerId).toBe('c1');
    // …while the edited materials REPLACE the server list (Filter → Brush).
    expect(written.materials).toEqual([{ id: 'm2', name: 'Brush', quantity: 2, unitCost: 5 }]);
  });

  it('preserves a recurring job date advanced while its editor was open', async () => {
    state.serverRow = {
      data: recJob({
        occurrenceCount: 4,
        lastGeneratedDate: '2026-09-01',
        nextDueDate: '2026-10-01',
      }),
      deleted: false,
    };

    await updateRecurringJobRule('rj1', {
      title: 'Gutter clean',
      description: '',
      laborHours: 2,
      laborRate: 90,
      materials: [],
      materialMarkup: 0,
      overhead: 0,
      margin: 0,
      estimateTotal: 300,
      cadence: 'monthly',
      endCondition: 'never',
      originalNextDueDate: '2026-09-01',
      nextDueDate: '2026-09-01',
    }, recJob());

    const written = state.lastUpsert!.data as RecurringJob;
    expect(written.nextDueDate).toBe('2026-10-01');
    expect(written.occurrenceCount).toBe(4);
    expect(written.lastGeneratedDate).toBe('2026-09-01');
  });

  it('applies an explicitly edited recurring job date', async () => {
    state.serverRow = {
      data: recJob({ nextDueDate: '2026-10-01' }),
      deleted: false,
    };

    await updateRecurringJobRule('rj1', {
      title: 'Gutter clean',
      description: '',
      laborHours: 2,
      laborRate: 90,
      materials: [],
      materialMarkup: 0,
      overhead: 0,
      margin: 0,
      estimateTotal: 300,
      cadence: 'monthly',
      endCondition: 'never',
      originalNextDueDate: '2026-09-01',
      nextDueDate: '2026-11-15',
    }, recJob());

    expect((state.lastUpsert!.data as RecurringJob).nextDueDate).toBe('2026-11-15');
  });

  it('preserves a maintenance-plan date advanced while its editor was open', async () => {
    state.serverRow = {
      data: recPlan({
        occurrenceCount: 6,
        lastGeneratedDate: '2026-09-01',
        nextDueDate: '2026-10-01',
      }),
      deleted: false,
    };

    await updateRecurringInvoiceRule('ri1', {
      description: 'Monthly service',
      amount: 150,
      dueDays: 30,
      cadence: 'monthly',
      endCondition: 'never',
      originalNextDueDate: '2026-09-01',
      nextDueDate: '2026-09-01',
      autoSendEnabled: false,
    }, recPlan());

    const written = state.lastUpsert!.data as RecurringInvoice;
    expect(written.nextDueDate).toBe('2026-10-01');
    expect(written.occurrenceCount).toBe(6);
    expect(written.lastGeneratedDate).toBe('2026-09-01');
  });

  it('applies an explicitly edited maintenance-plan date', async () => {
    state.serverRow = {
      data: recPlan({ nextDueDate: '2026-10-01' }),
      deleted: false,
    };

    await updateRecurringInvoiceRule('ri1', {
      description: 'Monthly service',
      amount: 150,
      dueDays: 30,
      cadence: 'monthly',
      endCondition: 'never',
      originalNextDueDate: '2026-09-01',
      nextDueDate: '2026-11-15',
      autoSendEnabled: false,
    }, recPlan());

    expect((state.lastUpsert!.data as RecurringInvoice).nextDueDate).toBe('2026-11-15');
  });

  it('createRecurringInvoice inits a fresh series with a mobile-format id', async () => {
    const created = await createRecurringInvoice({
      customerId: 'c1',
      customerName: 'Beta LLC',
      description: 'Monthly service',
      amount: 150,
      dueDays: 30,
      cadence: 'monthly',
      endCondition: 'count',
      endCount: 12,
      nextDueDate: '2026-10-01',
      autoSendEnabled: true,
    });

    expect(state.lastTable).toBe('recurringInvoices');
    expect(created.id).toMatch(/^ri\d+$/);
    const data = state.lastUpsert!.data as RecurringInvoice;
    expect(data).toMatchObject({
      customerId: 'c1',
      customerName: 'Beta LLC',
      amount: 150,
      cadence: 'monthly',
      endCondition: 'count',
      endCount: 12,
      nextDueDate: '2026-10-01',
      autoSendEnabled: true,
      // fresh generation state
      occurrenceCount: 0,
      lastGeneratedDate: null,
      isActive: true,
    });
    expect(data.endDate).toBeUndefined();
    expect(data.createdAt).toMatch(/^\d{4}-\d{2}-\d{2}$/);
  });

  it('createRecurringInvoice normalises end bounds and mints unique ids', async () => {
    const a = await createRecurringInvoice({
      customerId: 'c1', customerName: 'A', description: '', amount: 10, dueDays: 30,
      cadence: 'monthly', endCondition: 'date', endDate: '2027-01-01',
      nextDueDate: '2026-10-01', autoSendEnabled: false,
    });
    const b = await createRecurringInvoice({
      customerId: 'c2', customerName: 'B', description: '', amount: 10, dueDays: 30,
      cadence: 'monthly', endCondition: 'never', nextDueDate: '2026-10-01', autoSendEnabled: false,
    });
    expect(a.endCount).toBeUndefined();
    expect(a.endDate).toBe('2027-01-01');
    expect(b.endDate).toBeUndefined();
    expect(a.id).not.toBe(b.id);
  });

  it('createRecurringJob inits a fresh series with a rj_<ms> id and no first occurrence', async () => {
    const created = await createRecurringJob({
      customerId: 'c1',
      customerName: 'Acme',
      title: 'Gutter clean',
      description: 'Quarterly',
      laborHours: 2,
      laborRate: 90,
      materials: [{ id: 'm1', name: 'Sealant', quantity: 1, unitCost: 12 }],
      materialMarkup: 20,
      overhead: 15,
      margin: 20,
      estimateTotal: 320,
      cadence: 'quarterly',
      endCondition: 'count',
      endCount: 8,
      nextDueDate: '2026-10-01',
    });

    expect(state.lastTable).toBe('recurringJobs');
    expect(created.id).toMatch(/^rj_\d+$/); // mobile id format rj_<Date.now()>
    const data = state.lastUpsert!.data as RecurringJob;
    expect(data).toMatchObject({
      customerId: 'c1',
      customerName: 'Acme',
      title: 'Gutter clean',
      estimateTotal: 320,
      cadence: 'quarterly',
      endCondition: 'count',
      endCount: 8,
      nextDueDate: '2026-10-01',
      // fresh generation state — the engine emits the first occurrence later
      occurrenceCount: 0,
      lastGeneratedDate: null,
      isActive: true,
    });
    // Authored materials round-trip; address/notes start blank.
    expect(data.materials).toEqual([{ id: 'm1', name: 'Sealant', quantity: 1, unitCost: 12 }]);
    expect(data.address).toBe('');
    expect(data.notes).toBe('');
    expect(data.endDate).toBeUndefined();
    expect(data.createdAt).toMatch(/^\d{4}-\d{2}-\d{2}$/);
  });

  it('createRecurringJob normalises end bounds and mints unique ids', async () => {
    const base = {
      customerId: 'c1', customerName: 'A', title: 'T', description: '',
      laborHours: 1, laborRate: 80, materials: [], materialMarkup: 0, overhead: 0, margin: 0,
      estimateTotal: 80, cadence: 'monthly' as const, nextDueDate: '2026-10-01' as const,
    };
    const a = await createRecurringJob({ ...base, endCondition: 'date', endDate: '2027-01-01' });
    const b = await createRecurringJob({ ...base, endCondition: 'never' });
    expect(a.endCount).toBeUndefined();
    expect(a.endDate).toBe('2027-01-01');
    expect(b.endDate).toBeUndefined();
    expect(a.id).not.toBe(b.id);
  });

  it('updateRecurringInvoiceRule normalises end bounds to the chosen condition', async () => {
    // Server carried an endCount; switching to endCondition:'date' must drop it.
    state.serverRow = {
      data: recPlan({ endCondition: 'count', endCount: 12 }),
      deleted: false,
    };
    await updateRecurringInvoiceRule('ri1', {
      description: 'x',
      amount: 100,
      dueDays: 30,
      cadence: 'monthly',
      endCondition: 'date',
      endDate: '2027-01-01',
      originalNextDueDate: '2026-09-01',
      nextDueDate: '2026-10-01',
      autoSendEnabled: false,
    }, recPlan({ endCondition: 'count', endCount: 12 }));
    const written = state.lastUpsert!.data as RecurringInvoice;
    expect(written.endCondition).toBe('date');
    expect(written.endDate).toBe('2027-01-01');
    expect(written.endCount).toBeUndefined();
  });
});

describe('persist stamping', () => {
  it('stamps user_id and deleted:false, and omits updated_at (DB-owned, P0.3)', async () => {
    state.serverRow = { data: invoice(), deleted: false };
    await markInvoicePaid('inv-1', '2026-08-02');

    const row = state.lastUpsert!;
    expect(row.id).toBe('inv-1');
    expect(row.user_id).toBe('user-1');
    expect(row.deleted).toBe(false);
    // P0.3: `updated_at` is no longer sent by the client — the server-side
    // set_updated_at trigger stamps the DB clock on every write, so a
    // client-sent value would only be overwritten. The device pull watermark
    // (gt updated_at) is fed by that authoritative stamp, not the browser clock.
    expect(row).not.toHaveProperty('updated_at');
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

describe('updateInvoiceDetails — patch owned fields onto the server invoice', () => {
  it('updates editor fields while preserving concurrent server-owned fields', async () => {
    state.serverRow = {
      data: invoice({
        desc: 'old',
        payments: [payment({ id: 'stripe_abc', amount: 600, method: 'stripe' })],
        depositRequest: { amount: 500, percent: 50, requestedAt: '2026-08-20' },
        paymentLinkUrl: 'https://buy.stripe.com/server-link',
        paymentLinkAmount: 400,
        autoEmailRequestedAt: '2026-08-20T12:00:00.000Z',
        lineItems: [{ description: 'Labor', amount: 1000, category: 'labor' }],
        jobId: 'job-server',
        recurringInvoiceId: 'ri-server',
        occurrenceNumber: 4,
        importBatchId: 'batch-server',
      }),
      deleted: false,
    };

    // Simulate an untyped/dynamic caller carrying stale hidden fields. The
    // repository must copy only its six approved fields, never spread these.
    const editWithStaleHiddenFields = {
      number: '001-A',
      amount: 1200,
      due: '2026-09-15',
      desc: 'new',
      email: 'billing@acme.test',
      phone: '555-0100',
      depositRequest: undefined,
      paymentLinkUrl: undefined,
      lineItems: [],
      autoEmailRequestedAt: undefined,
    };
    await updateInvoiceDetails('inv-1', editWithStaleHiddenFields, invoice({ desc: 'old' }));

    const written = writtenInvoice();
    expect(written).toMatchObject({
      number: '001-A',
      amount: 1200,
      due: '2026-09-15',
      desc: 'new',
      email: 'billing@acme.test',
      phone: '555-0100',
    });
    expect(written.payments!.map((p) => p.id)).toContain('stripe_abc');
    expect(written.depositRequest).toEqual({
      amount: 500,
      percent: 50,
      requestedAt: '2026-08-20',
    });
    expect(written.paymentLinkUrl).toBe('https://buy.stripe.com/server-link');
    expect(written.paymentLinkAmount).toBe(400);
    expect(written.autoEmailRequestedAt).toBe('2026-08-20T12:00:00.000Z');
    expect(written.lineItems).toEqual([
      { description: 'Labor', amount: 1000, category: 'labor' },
    ]);
    expect(written.jobId).toBe('job-server');
    expect(written.recurringInvoiceId).toBe('ri-server');
    expect(written.occurrenceNumber).toBe(4);
    expect(written.importBatchId).toBe('batch-server');
  });

  it('rejects an edit when the invoice no longer exists', async () => {
    state.serverRow = null;
    await expect(
      updateInvoiceDetails(
        'inv-missing',
        {
          number: '001',
          amount: 1000,
          due: '2026-08-01',
          desc: '',
          email: '',
          phone: '',
        },
        invoice(),
      ),
    ).rejects.toBeInstanceOf(InvoiceNotFoundError);
    expect(state.lastUpsert).toBeNull();
  });
});

describe('soft-delete — P0.4 tombstones, never row removal', () => {
  it('writes a deleted:true tombstone scoped to id+user, updated_at DB-owned', async () => {
    await deleteInvoice('inv-1');

    expect(state.lastTable).toBe('invoices');
    expect(state.lastUpdate!.deleted).toBe(true);
    // P0.3: the tombstone UPDATE omits `updated_at`; the set_updated_at trigger
    // stamps the DB clock, which is what carries the tombstone across each
    // device's `gt('updated_at', since)` pull filter.
    expect(state.lastUpdate).not.toHaveProperty('updated_at');
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

describe('P2.1 — field-scoped optimistic-concurrency guard', () => {
  // A minimal Job carrying the operational fields the detail/pricing ops guard,
  // plus a server-authored field (approval) they must always preserve.
  function gjob(over: Partial<Job> = {}): Job {
    return {
      id: 'job-1',
      customerId: 'c1',
      customerName: 'Acme',
      title: 'Original title',
      description: 'desc',
      status: 'scheduled',
      scheduledDate: '2026-09-01',
      scheduledStartTime: '09:00',
      scheduledEndTime: '11:00',
      address: '1 St',
      estimateTotal: 0,
      laborHours: 2,
      laborRate: 90,
      materials: [],
      materialMarkup: 10,
      overhead: 10,
      margin: 20,
      notes: '',
      invoiceId: null,
      createdAt: '2026-08-01',
      ...over,
    };
  }

  const detailsEdit = (over: Partial<Job> = {}) => ({
    title: 'Original title',
    description: 'desc',
    address: '1 St',
    scheduledDate: '2026-09-01' as const,
    scheduledStartTime: '09:00' as const,
    scheduledEndTime: '11:00' as const,
    notes: '',
    ...over,
  });

  describe('patch edit ops (updateJobDetails)', () => {
    it('rejects when a field the user edited was changed on the server', async () => {
      // Editor rendered title "Original title"; a phone changed it to "Phone
      // title"; the user is saving their own new title over that unseen change.
      const baseline = gjob({ title: 'Original title' });
      state.serverRow = { data: gjob({ title: 'Phone title' }), deleted: false };

      await expect(
        updateJobDetails('job-1', detailsEdit({ title: 'Web title' }), baseline),
      ).rejects.toBeInstanceOf(StaleWriteError);
      // Nothing was written — the stale save is refused, not silently applied.
      expect(state.lastUpsert).toBeNull();
    });

    it('names the conflicting field on the error', async () => {
      const baseline = gjob({ address: '1 St' });
      state.serverRow = { data: gjob({ address: '2 St' }), deleted: false };
      await expect(
        updateJobDetails('job-1', detailsEdit({ address: '3 St' }), baseline),
      ).rejects.toMatchObject({ name: 'StaleWriteError', field: 'address' });
    });

    it('applies when the user changed a field the server did not move', async () => {
      const baseline = gjob({ title: 'Original title' });
      state.serverRow = { data: gjob({ title: 'Original title' }), deleted: false };
      await updateJobDetails('job-1', detailsEdit({ title: 'Web title' }), baseline);
      expect((state.lastUpsert!.data as Job).title).toBe('Web title');
    });

    it('does not conflict when the user and server converged on the same value', async () => {
      // Both changed title to the same string — no lost update, so the write applies.
      const baseline = gjob({ title: 'Original title' });
      state.serverRow = { data: gjob({ title: 'Agreed title' }), deleted: false };
      await updateJobDetails('job-1', detailsEdit({ title: 'Agreed title' }), baseline);
      expect((state.lastUpsert!.data as Job).title).toBe('Agreed title');
    });

    it('ignores a concurrent change to a field the op never guards (approval preserved)', async () => {
      // The customer approved the estimate while the editor was open; the detail
      // op guards only operational fields, so it merges rather than rejecting.
      const approval = { decision: 'approved', signerName: 'Jane' };
      const baseline = gjob();
      state.serverRow = {
        data: gjob({ approval } as Partial<Job>),
        deleted: false,
      };
      const written = await updateJobDetails(
        'job-1',
        detailsEdit({ title: 'Web title' }),
        baseline,
      );
      expect(written.title).toBe('Web title');
      expect((written as unknown as { approval: unknown }).approval).toEqual(approval);
    });
  });

  describe('array/object fields (updateJobPricing materials)', () => {
    const pricingEdit = (over: Record<string, unknown> = {}) => ({
      laborHours: 2,
      laborRate: 90,
      materials: [{ id: 'm1', name: 'Pipe', quantity: 1, unitCost: 10 }],
      jobCosts: [],
      materialMarkup: 10,
      overhead: 10,
      margin: 20,
      estimateTotal: 500,
      ...over,
    });

    it('rejects when the server materials list moved and the user also edited it', async () => {
      const baseline = gjob({
        materials: [{ id: 'm1', name: 'Pipe', quantity: 1, unitCost: 10 }],
      });
      // Server list gained a second material since the editor opened…
      state.serverRow = {
        data: gjob({
          materials: [
            { id: 'm1', name: 'Pipe', quantity: 1, unitCost: 10 },
            { id: 'm2', name: 'Valve', quantity: 1, unitCost: 25 },
          ],
        }),
        deleted: false,
      };
      state.updateResult = { id: 'job-1' };
      await expect(
        updateJobPricing(
          'job-1',
          pricingEdit({
            materials: [{ id: 'm1', name: 'Pipe', quantity: 3, unitCost: 10 }],
          }),
          baseline,
        ),
      ).rejects.toBeInstanceOf(StaleWriteError);
      expect(state.lastUpdate).toBeNull();
    });

    it('applies when the materials list is byte-identical to the server (deep compare)', async () => {
      const materials = [{ id: 'm1', name: 'Pipe', quantity: 1, unitCost: 10 }];
      const baseline = gjob({ materials });
      // Same contents, a fresh array instance — deepEqual must treat it as unchanged.
      state.serverRow = {
        data: gjob({ materials: [{ id: 'm1', name: 'Pipe', quantity: 1, unitCost: 10 }] }),
        deleted: false,
      };
      state.updateResult = { id: 'job-1' };
      await updateJobPricing('job-1', pricingEdit({ laborRate: 120 }), baseline);
      expect((state.lastUpdate!.data as Job).laborRate).toBe(120);
    });
  });

  describe('whole-blob ops (saveCustomer) — guard AND merge', () => {
    function gcust(over: Partial<Customer> = {}): Customer {
      return {
        id: 'c1',
        name: 'Acme',
        email: 'a@b.co',
        phone: '555',
        address: '1 St',
        notes: '',
        ...over,
      };
    }

    it('rejects when a field the user edited was changed on the server', async () => {
      const baseline = gcust({ name: 'Acme' });
      state.serverRow = { data: gcust({ name: 'Acme Renamed' }), deleted: false };
      await expect(
        saveCustomer(gcust({ name: 'Acme Web Edit' }), baseline),
      ).rejects.toBeInstanceOf(StaleWriteError);
      expect(state.lastUpsert).toBeNull();
    });

    it('merges: a concurrent server-only field change survives the write', async () => {
      // User edits only the phone; the server changed the email meanwhile. The
      // three-way merge keeps the server email AND applies the user's phone.
      const baseline = gcust({ phone: '555', email: 'old@b.co' });
      state.serverRow = {
        data: gcust({ phone: '555', email: 'server-new@b.co' }),
        deleted: false,
      };
      const written = await saveCustomer(
        gcust({ phone: '999', email: 'old@b.co' }),
        baseline,
      );
      expect(written.phone).toBe('999'); // user's edit applied
      expect(written.email).toBe('server-new@b.co'); // server change preserved, not clobbered
    });

    it('writes straight through when the row does not exist yet (nothing to conflict with)', async () => {
      state.serverRow = null;
      const written = await saveCustomer(gcust({ name: 'New name' }), gcust());
      expect(written.name).toBe('New name');
      expect(state.lastTable).toBe('customers');
    });
  });

  describe('settings guard', () => {
    it('rejects when a patched setting was changed on the server', async () => {
      state.settingsRow = { data: { businessName: 'Server Co' } };
      await expect(
        saveSettings(
          { businessName: 'Web Co' },
          { businessName: 'Original Co' } as Parameters<typeof saveSettings>[1],
        ),
      ).rejects.toBeInstanceOf(StaleWriteError);
      expect(state.lastUpsert).toBeNull();
    });

    it('applies a patch to a field the server did not move', async () => {
      state.settingsRow = { data: { businessName: 'Co', laborRate: 90 } };
      await saveSettings(
        { laborRate: 120 },
        { businessName: 'Co', laborRate: 90 } as Parameters<typeof saveSettings>[1],
      );
      expect(writtenSettings().laborRate).toBe(120);
    });
  });
});

describe('P1.3 — write-layer payload validation', () => {
  // Validation runs FIRST in each op, before any fetch/guard, so these cases
  // reject without a server row and never reach a write. The baseline args are
  // therefore unreachable — a minimal cast is enough.
  const anyInvoice = {} as Invoice;
  const anyJob = {} as Job;
  const anyCustomer = {} as Customer;
  const anyPlan = {} as RecurringInvoice;
  const anyRecJob = {} as RecurringJob;

  const invoiceEdit = (over: Partial<Record<string, unknown>> = {}) => ({
    number: '001',
    amount: 1000,
    due: '2026-09-01' as const,
    desc: '',
    email: '',
    phone: '',
    ...over,
  });

  const pricingFields = {
    laborHours: 1,
    laborRate: 90,
    materials: [],
    materialMarkup: 10,
    overhead: 10,
    margin: 20,
  };

  async function rejectsValidation(p: Promise<unknown>) {
    await expect(p).rejects.toBeInstanceOf(ValidationError);
    // No op that fails validation ever writes.
    expect(state.lastUpsert).toBeNull();
    expect(state.lastUpdate).toBeNull();
  }

  it('rejects an invoice amount that is not greater than zero', async () => {
    await rejectsValidation(
      updateInvoiceDetails('inv-1', invoiceEdit({ amount: 0 }), anyInvoice),
    );
  });

  it('rejects a NaN amount (would corrupt derived math)', async () => {
    await rejectsValidation(
      updateInvoiceDetails('inv-1', invoiceEdit({ amount: Number.NaN }), anyInvoice),
    );
  });

  it('rejects a blank invoice number', async () => {
    await rejectsValidation(
      updateInvoiceDetails('inv-1', invoiceEdit({ number: '  ' }), anyInvoice),
    );
  });

  it('rejects a malformed due date', async () => {
    await rejectsValidation(
      updateInvoiceDetails('inv-1', invoiceEdit({ due: '2026/09/01' }), anyInvoice),
    );
  });

  it('rejects a manual invoice with no customer', async () => {
    await rejectsValidation(
      createInvoice({
        customer: '',
        customerId: 'c1',
        number: '002',
        amount: 100,
        due: '2026-09-01',
        email: '',
        phone: '',
        desc: '',
      }),
    );
  });

  it('rejects an expense with a blank description or non-positive amount', async () => {
    await rejectsValidation(
      saveExpense({
        id: 'e1',
        createdAt: '2026-08-01',
        description: '',
        amount: 10,
        category: 'materials',
        date: '2026-08-01',
        notes: '',
        receiptUri: null,
      }),
    );
  });

  it('rejects a negative pricing input on a job estimate', async () => {
    await rejectsValidation(
      updateJobPricing(
        'job-1',
        { ...pricingFields, margin: -5, jobCosts: [], estimateTotal: 100 },
        anyJob,
      ),
    );
  });

  it('rejects a material line with a negative unit cost', async () => {
    await rejectsValidation(
      updateJobPricing(
        'job-1',
        {
          ...pricingFields,
          materials: [{ id: 'm1', name: 'Pipe', quantity: 1, unitCost: -3 }],
          jobCosts: [],
          estimateTotal: 100,
        },
        anyJob,
      ),
    );
  });

  it('rejects a blank customer name on save and create', async () => {
    await rejectsValidation(saveCustomer({ ...anyCustomer, id: 'c1', name: '  ' } as Customer, anyCustomer));
    await rejectsValidation(
      createCustomer({ name: '', email: '', phone: '', address: '', notes: '' }),
    );
  });

  it('rejects a new job with no title or no customer', async () => {
    const base = {
      customerId: 'c1',
      customerName: 'Acme',
      title: 'Fix',
      description: '',
      address: '',
      scheduledDate: null,
      scheduledStartTime: null,
      scheduledEndTime: null,
      notes: '',
      laborRate: 90,
      materialMarkup: 10,
      overhead: 10,
      margin: 20,
    };
    await rejectsValidation(createJob({ ...base, title: '' }));
    await rejectsValidation(createJob({ ...base, customerId: '' }));
    await rejectsValidation(createJob({ ...base, margin: -1 }));
  });

  it('rejects a pricebook entry with a blank name or negative pricing', async () => {
    await rejectsValidation(
      createPricebookEntry({
        name: '',
        category: '',
        description: '',
        ...pricingFields,
        estimateTotal: 90,
      }),
    );
  });

  it('rejects a maintenance plan whose amount is not positive', async () => {
    await rejectsValidation(
      updateRecurringInvoiceRule(
        'ri1',
        {
          description: 'x',
          amount: 0,
          dueDays: 30,
          cadence: 'monthly',
          endCondition: 'never',
          originalNextDueDate: '2026-09-01',
          nextDueDate: '2026-09-01',
          autoSendEnabled: false,
        },
        anyPlan,
      ),
    );
  });

  it('rejects a count-ended rule with no end count', async () => {
    await rejectsValidation(
      updateRecurringInvoiceRule(
        'ri1',
        {
          description: 'x',
          amount: 100,
          dueDays: 30,
          cadence: 'monthly',
          endCondition: 'count',
          endCount: undefined,
          originalNextDueDate: '2026-09-01',
          nextDueDate: '2026-09-01',
          autoSendEnabled: false,
        },
        anyPlan,
      ),
    );
  });

  it('rejects a recurring job rule with a negative pricing input', async () => {
    await rejectsValidation(
      updateRecurringJobRule(
        'rj1',
        {
          title: 'Gutter clean',
          description: '',
          ...pricingFields,
          laborRate: -1,
          estimateTotal: 100,
          cadence: 'monthly',
          endCondition: 'never',
          originalNextDueDate: '2026-09-01',
          nextDueDate: '2026-09-01',
        },
        anyRecJob,
      ),
    );
  });

  it('rejects settings with a negative pricing field or a bad invoice start number', async () => {
    await rejectsValidation(
      saveSettings(
        { laborRate: -5 },
        { laborRate: -5 } as Parameters<typeof saveSettings>[1],
      ),
    );
    await rejectsValidation(
      saveSettings(
        { invoiceStartNumber: 0 },
        {} as Parameters<typeof saveSettings>[1],
      ),
    );
  });

  it('rejects a schedule with no work days or an inverted work window', async () => {
    await rejectsValidation(
      saveSchedule(
        { workDays: [] },
        {} as Parameters<typeof saveSchedule>[1],
      ),
    );
    await rejectsValidation(
      saveSchedule(
        { workDayStart: '17:00', workDayEnd: '08:00' },
        {} as Parameters<typeof saveSchedule>[1],
      ),
    );
  });

  it('rejects scheduling with an end time but no start', async () => {
    await rejectsValidation(
      scheduleJob(
        'job-1',
        { scheduledDate: '2026-09-01', scheduledStartTime: null, scheduledEndTime: '11:00' },
        anyJob,
      ),
    );
  });

  it('accepts unscheduling (a null date is valid)', async () => {
    state.serverRow = { data: { id: 'job-1', status: 'scheduled', scheduledDate: '2026-09-01' }, deleted: false };
    await scheduleJob(
      'job-1',
      { scheduledDate: null, scheduledStartTime: null, scheduledEndTime: null },
      { id: 'job-1', status: 'scheduled', scheduledDate: '2026-09-01' } as Job,
    );
    expect(state.lastUpsert!.data as Job).toMatchObject({ scheduledDate: null });
  });

  it('surfaces the payment validator as before (unchanged by P1.3)', async () => {
    state.serverRow = { data: invoice(), deleted: false };
    await expect(
      recordInvoicePayment('inv-1', { amount: 0, date: '2026-08-01', method: 'cash' }),
    ).rejects.toBeInstanceOf(PaymentValidationError);
  });
});
