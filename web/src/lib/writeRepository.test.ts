import { describe, it, expect, vi, beforeEach } from 'vitest';
import type { Invoice, Payment } from '@shared/types/models';
import {
  saveInvoice,
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
  savePricebookEntry,
  saveExpense,
  scheduleJob,
  setRecurringJobActive,
  setRecurringInvoiceActive,
  updateRecurringInvoiceRule,
  updateRecurringJobRule,
  InvoiceNotFoundError,
  JobNotFoundError,
  PaymentValidationError,
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
    const before = Date.now();
    // Include a field the portal never renders to prove it round-trips (P0.2).
    const c = customer({ portal: { token: 'tok', enabled: true } });
    await saveCustomer(c);

    const row = state.lastUpsert!;
    expect(state.lastTable).toBe('customers');
    expect(row.id).toBe('c1');
    expect(row.user_id).toBe('user-1');
    expect(row.deleted).toBe(false);
    expect((row.data as Customer).portal).toEqual({ token: 'tok', enabled: true });
    expect(Date.parse(row.updated_at as string)).toBeGreaterThanOrEqual(before);
  });

  it('surfaces a write error rather than reporting success', async () => {
    state.upsertError = { message: 'rls denied' };
    await expect(saveCustomer(customer())).rejects.toMatchObject({
      message: 'rls denied',
    });
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

    await updateJobDetails('job-1', edit);

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
    await expect(updateJobDetails('job-1', edit)).rejects.toBeInstanceOf(
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
    await scheduleJob('job-1', schedule);

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
    await scheduleJob('job-1', schedule);
    expect((state.lastUpsert!.data as Job).status).toBe('in_progress');
  });

  it('scheduleJob does not advance a pre-approval status', async () => {
    state.serverRow = { data: job({ status: 'estimate_sent' }), deleted: false };
    await scheduleJob('job-1', schedule);
    expect((state.lastUpsert!.data as Job).status).toBe('estimate_sent');
  });

  it('scheduleJob clearing the date leaves status untouched', async () => {
    state.serverRow = { data: job({ status: 'scheduled', scheduledDate: '2026-09-01' }), deleted: false };
    await scheduleJob('job-1', {
      scheduledDate: null,
      scheduledStartTime: null,
      scheduledEndTime: null,
    });
    const written = state.lastUpsert!.data as Job;
    expect(written.scheduledDate).toBeNull();
    expect(written.status).toBe('scheduled'); // no regress on unschedule
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
    await savePricebookEntry(entry({ name: 'Drain clearing' }));
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

describe('saveExpense — whole-blob upsert', () => {
  it('upserts the expense to the expenses table with stamps', async () => {
    const before = Date.now();
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
    expect(Date.parse(row.updated_at as string)).toBeGreaterThanOrEqual(before);
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

    await saveSettings({ businessName: 'New Co' });

    const written = writtenSettings();
    expect(written.businessName).toBe('New Co'); // patch applied
    expect(written.laborRate).toBe(90); // unrendered field preserved (P0.2)
    expect(written).not.toHaveProperty('providerKey');
    expect(written).not.toHaveProperty('anthropicKey');
    expect(written).not.toHaveProperty('groqKey');
  });

  it('strips a credential field even if the caller mistakenly includes one', async () => {
    state.settingsRow = { data: { businessName: 'Co', laborRate: 80 } };
    await saveSettings({
      businessName: 'Co2',
      groqKey: 'leak',
    } as Parameters<typeof saveSettings>[0]);
    expect(writtenSettings()).not.toHaveProperty('groqKey');
  });

  it('upserts by user_id with a fresh updated_at and no id/deleted column', async () => {
    state.settingsRow = { data: { businessName: 'Co' } };
    const before = Date.now();
    await saveSettings({ phone: '555' });

    const row = state.lastUpsert!;
    expect(state.lastTable).toBe('settings');
    expect(row.user_id).toBe('user-1');
    expect(row).not.toHaveProperty('id');
    expect(row).not.toHaveProperty('deleted');
    expect(Date.parse(row.updated_at as string)).toBeGreaterThanOrEqual(before);
  });

  it('creates a settings row when none exists yet', async () => {
    state.settingsRow = null;
    await saveSettings({ businessName: 'Fresh' });
    expect(writtenSettings().businessName).toBe('Fresh');
  });

  it('surfaces a write error rather than reporting success', async () => {
    state.settingsRow = { data: { businessName: 'Co' } };
    state.upsertError = { message: 'rls denied' };
    await expect(saveSettings({ phone: '1' })).rejects.toMatchObject({
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

    await saveSchedule({ workDayStart: '07:00', workDayEnd: '16:00', workDays: [1, 2, 3] });

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
    await saveSchedule({ bufferMinutes: 15 });
    const written = writtenSettings();
    expect(written.businessName).toBe('Co');
    expect(written.laborRate).toBe(90);
    expect(written).not.toHaveProperty('groqKey');
    expect((written.schedule as Record<string, unknown>).bufferMinutes).toBe(15);
  });

  it('creates the schedule object when the settings blob has none', async () => {
    state.settingsRow = { data: { businessName: 'Co' } };
    await saveSchedule({ workDays: [1, 2, 3, 4, 5] });
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
      nextDueDate: '2026-10-01',
      autoSendEnabled: true,
    });

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
      materialMarkup: 10,
      overhead: 15,
      margin: 20,
      estimateTotal: 999, // recomputed by the caller (port); the op trusts it
      cadence: 'quarterly',
      endCondition: 'count',
      endCount: 8,
      nextDueDate: '2026-12-01',
    });

    const written = state.lastUpsert!.data as RecurringJob;
    expect(state.lastTable).toBe('recurringJobs');
    expect(written.title).toBe('Deep gutter clean');
    expect(written.laborRate).toBe(100);
    expect(written.estimateTotal).toBe(999);
    expect(written.cadence).toBe('quarterly');
    expect(written.endCondition).toBe('count');
    expect(written.endCount).toBe(8);
    expect(written.endDate).toBeUndefined();
    // history + materials preserved from the server row
    expect(written.occurrenceCount).toBe(4);
    expect(written.lastGeneratedDate).toBe('2026-08-01');
    expect(written.isActive).toBe(true);
    expect(written.customerId).toBe('c1');
    expect(written.materials).toEqual([{ id: 'm1', name: 'Filter', quantity: 1, unitCost: 20 }]);
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
      nextDueDate: '2026-10-01',
      autoSendEnabled: false,
    });
    const written = state.lastUpsert!.data as RecurringInvoice;
    expect(written.endCondition).toBe('date');
    expect(written.endDate).toBe('2027-01-01');
    expect(written.endCount).toBeUndefined();
  });
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
