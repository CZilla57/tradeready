import { useState } from 'react';
import type { ReactNode } from 'react';
import { useData, useResources } from '../lib/DataContext';
import { Card, PageHead, Empty, Badge, ErrorState } from '../ui/components';
import { formatMoney } from '@shared/utils/format';
import { formatDisplayDate, getTodayDateString } from '@shared/utils/dateHelpers';
import type {
  Customer,
  RecurrenceCadence,
  RecurrenceEndCondition,
  RecurringInvoice,
  RecurringJob,
} from '@shared/types/models';
import {
  setRecurringJobActive,
  setRecurringInvoiceActive,
  updateRecurringInvoiceRule,
  updateRecurringJobRule,
  createRecurringInvoice,
  createRecurringJob,
  deleteRecurringJob,
  deleteRecurringInvoice,
} from '../lib/writeRepository';
import { estimateTotalFromPricing } from '../ui/pricingMath';

const CADENCES: RecurrenceCadence[] = [
  'daily',
  'weekly',
  'monthly',
  'quarterly',
  'annually',
];
const CADENCE_LABEL: Record<RecurrenceCadence, string> = {
  daily: 'Daily',
  weekly: 'Weekly',
  monthly: 'Monthly',
  quarterly: 'Quarterly',
  annually: 'Annually',
};

const END_CONDITIONS: RecurrenceEndCondition[] = ['never', 'count', 'date'];
const END_LABEL: Record<RecurrenceEndCondition, string> = {
  never: 'Never',
  count: 'After N',
  date: 'By date',
};

function cadence(c: RecurrenceCadence): string {
  return CADENCE_LABEL[c] ?? c;
}

function errorMessage(err: unknown): string {
  return err instanceof Error ? err.message : 'Something went wrong';
}

/** Parse a required non-negative number field; null when blank or invalid. */
function parseNonNeg(s: string): number | null {
  const t = s.trim();
  if (t === '') return null;
  const n = Number(t);
  return Number.isFinite(n) && n >= 0 ? n : null;
}

/**
 * One recurring rule row with its pause/resume + delete controls (roadmap P3
 * stage 5). The write ops (`onToggle`, `onDelete`) re-fetch the server row and
 * preserve advancing generation state; this component only owns the per-row
 * in-flight/confirm/error UX (P2.2): a control disabled while in flight, a
 * failed write that surfaces the error and leaves the row unchanged, and a
 * server re-pull on success (handled by the op's caller via `retry`).
 */
function RecurringRow({
  title,
  meta,
  amount,
  isActive,
  deleteLabel,
  onToggle,
  onDelete,
  renderEditor,
}: {
  title: string;
  meta: string;
  amount: number;
  isActive: boolean;
  deleteLabel: string;
  onToggle: (active: boolean) => Promise<void>;
  onDelete: () => Promise<void>;
  /** When provided, the row shows an Edit button that swaps in this form. */
  renderEditor?: (close: () => void) => ReactNode;
}) {
  const [busy, setBusy] = useState(false);
  const [confirmDelete, setConfirmDelete] = useState(false);
  const [editing, setEditing] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function run(fn: () => Promise<void>) {
    if (busy) return;
    setBusy(true);
    setError(null);
    try {
      await fn();
    } catch (err) {
      setError(errorMessage(err));
    } finally {
      setBusy(false);
    }
  }

  if (editing && renderEditor) {
    return <div className="row" style={{ flexWrap: 'wrap' }}>{renderEditor(() => setEditing(false))}</div>;
  }

  return (
    <div className="row" style={{ flexWrap: 'wrap' }}>
      <div className="grow">
        <div className="title">{title}</div>
        <div className="meta">{meta}</div>
        {error && (
          <div className="inline-alert error" role="alert" style={{ marginTop: 6 }}>
            {error}
          </div>
        )}
      </div>
      <Badge color={isActive ? 'green' : 'slate'}>{isActive ? 'Active' : 'Paused'}</Badge>
      <span className="amt">{formatMoney(amount || 0)}</span>
      {confirmDelete ? (
        <div className="btn-row">
          <button type="button" className="btn danger sm" onClick={() => run(onDelete)} disabled={busy}>
            {busy ? 'Deleting…' : deleteLabel}
          </button>
          <button type="button" className="btn ghost sm" onClick={() => setConfirmDelete(false)} disabled={busy}>
            Cancel
          </button>
        </div>
      ) : (
        <div className="btn-row">
          <button
            type="button"
            className="btn sm"
            onClick={() => run(() => onToggle(!isActive))}
            disabled={busy}
          >
            {busy ? 'Saving…' : isActive ? 'Pause' : 'Resume'}
          </button>
          {renderEditor && (
            <button type="button" className="btn ghost sm" onClick={() => setEditing(true)} disabled={busy}>
              Edit
            </button>
          )}
          <button
            type="button"
            className="btn ghost sm"
            onClick={() => setConfirmDelete(true)}
            disabled={busy}
          >
            Delete
          </button>
        </div>
      )}
    </div>
  );
}

/**
 * Inline editor for a maintenance-plan rule (roadmap P3 stage 5b). Edits the
 * direct-value rule fields — description, amount, net terms, cadence, end
 * condition, next date, auto-send — through `updateRecurringInvoiceRule`, which
 * preserves the plan's generation history. Validation mirrors the mobile
 * AddRecurringInvoiceScreen (amount > 0, net ≥ 0, a positive end count, an end
 * date when required). Customer re-linking is deliberately not offered here.
 */
function PlanEditor({
  plan,
  onClose,
  onSaved,
}: {
  plan: RecurringInvoice;
  onClose: () => void;
  onSaved: () => void;
}) {
  const [description, setDescription] = useState(plan.description ?? '');
  const [amount, setAmount] = useState(String(plan.amount ?? ''));
  const [dueDays, setDueDays] = useState(String(plan.dueDays ?? 30));
  const [cad, setCad] = useState<RecurrenceCadence>(plan.cadence);
  const [endCondition, setEndCondition] = useState<RecurrenceEndCondition>(plan.endCondition);
  const [endCount, setEndCount] = useState(plan.endCount != null ? String(plan.endCount) : '');
  const [endDate, setEndDate] = useState(plan.endDate ?? '');
  const [nextDueDate, setNextDueDate] = useState(plan.nextDueDate || getTodayDateString());
  const [autoSend, setAutoSend] = useState(!!plan.autoSendEnabled);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function onSave(e: React.FormEvent) {
    e.preventDefault();
    if (busy) return;
    const amt = Number(amount.trim());
    if (!(amt > 0)) {
      setError('Enter an invoice amount greater than zero.');
      return;
    }
    const net = Number(dueDays.trim());
    if (!Number.isInteger(net) || net < 0) {
      setError('Net terms must be zero or a positive whole number of days.');
      return;
    }
    let endCountValue: number | undefined;
    if (endCondition === 'count') {
      endCountValue = Number(endCount.trim());
      if (!Number.isInteger(endCountValue) || endCountValue < 1) {
        setError('Enter a number of invoices greater than zero.');
        return;
      }
    }
    if (endCondition === 'date' && !endDate) {
      setError('Pick an end date for the plan.');
      return;
    }
    if (!nextDueDate) {
      setError('Pick the next invoice date.');
      return;
    }
    setBusy(true);
    setError(null);
    try {
      await updateRecurringInvoiceRule(plan.id, {
        description: description.trim(),
        amount: amt,
        dueDays: net,
        cadence: cad,
        endCondition,
        endCount: endCountValue,
        endDate: endCondition === 'date' ? endDate : undefined,
        nextDueDate,
        autoSendEnabled: autoSend,
      });
      onSaved();
    } catch (err) {
      setError(errorMessage(err));
      setBusy(false);
    }
  }

  return (
    <div className="grow" style={{ minWidth: 240 }}>
      <div className="title">{plan.customerName || 'Maintenance plan'}</div>
      {error && (
        <div className="inline-alert error" role="alert" style={{ marginTop: 6 }}>
          {error}
        </div>
      )}
      <form className="pay-form" style={{ marginTop: 8, borderTop: 0, paddingTop: 0 }} onSubmit={onSave}>
        <label className="field">
          <span>Description</span>
          <input className="field-input" type="text" value={description} onChange={(e) => setDescription(e.target.value)} />
        </label>
        <div className="btn-row">
          <label className="field" style={{ flex: 1 }}>
            <span>Amount ($)</span>
            <input className="field-input" type="number" step="0.01" min="0" inputMode="decimal" value={amount} onChange={(e) => setAmount(e.target.value)} />
          </label>
          <label className="field" style={{ flex: 1 }}>
            <span>Net (days)</span>
            <input className="field-input" type="number" step="1" min="0" inputMode="numeric" value={dueDays} onChange={(e) => setDueDays(e.target.value)} />
          </label>
        </div>
        <div className="field">
          <span>Repeats</span>
          <div className="chip-row" role="group" aria-label="Repeats">
            {CADENCES.map((c) => (
              <button
                key={c}
                type="button"
                className={`chip${cad === c ? ' selected' : ''}`}
                aria-pressed={cad === c}
                onClick={() => setCad(c)}
              >
                {CADENCE_LABEL[c]}
              </button>
            ))}
          </div>
        </div>
        <label className="field">
          <span>Next invoice date</span>
          <input className="field-input" type="date" value={nextDueDate} onChange={(e) => setNextDueDate(e.target.value)} />
        </label>
        <div className="field">
          <span>Ends</span>
          <div className="chip-row" role="group" aria-label="Ends">
            {END_CONDITIONS.map((ec) => (
              <button
                key={ec}
                type="button"
                className={`chip${endCondition === ec ? ' selected' : ''}`}
                aria-pressed={endCondition === ec}
                onClick={() => setEndCondition(ec)}
              >
                {END_LABEL[ec]}
              </button>
            ))}
          </div>
        </div>
        {endCondition === 'count' && (
          <label className="field">
            <span>Number of invoices</span>
            <input className="field-input" type="number" step="1" min="1" inputMode="numeric" value={endCount} onChange={(e) => setEndCount(e.target.value)} />
          </label>
        )}
        {endCondition === 'date' && (
          <label className="field">
            <span>End date</span>
            <input className="field-input" type="date" value={endDate} onChange={(e) => setEndDate(e.target.value)} />
          </label>
        )}
        <label className="field checkbox-field">
          <input type="checkbox" checked={autoSend} onChange={(e) => setAutoSend(e.target.checked)} />
          <span>Auto-send each invoice by email</span>
        </label>
        <div className="btn-row">
          <button type="submit" className="btn primary sm" disabled={busy}>
            {busy ? 'Saving…' : 'Save changes'}
          </button>
          <button type="button" className="btn ghost sm" onClick={onClose} disabled={busy}>
            Cancel
          </button>
        </div>
      </form>
    </div>
  );
}

/**
 * Inline editor for a recurring-JOB rule (roadmap P3 stage 5b). Like `PlanEditor`
 * but for a job series, with one extra concern: the DERIVED `estimateTotal`.
 * Editing the pricing inputs (labor hours/rate, material markup, overhead,
 * margin) recomputes the total on save via `estimateTotalFromPricing` (the
 * pricingMath port), over the rule's existing materials/jobCosts and the owner's
 * `minimumJobFee` — matching the mobile save path — so the series stays priced
 * exactly as it would on the phone. `updateRecurringJobRule` preserves the
 * series' generation history; customer re-linking and material line-item editing
 * are out of scope.
 */
function JobRuleEditor({
  rule,
  onClose,
  onSaved,
}: {
  rule: RecurringJob;
  onClose: () => void;
  onSaved: () => void;
}) {
  const { settings } = useData();
  const [title, setTitle] = useState(rule.title ?? '');
  const [description, setDescription] = useState(rule.description ?? '');
  const [laborHours, setLaborHours] = useState(String(rule.laborHours ?? 0));
  const [laborRate, setLaborRate] = useState(String(rule.laborRate ?? 0));
  const [materialMarkup, setMaterialMarkup] = useState(String(rule.materialMarkup ?? 0));
  const [overhead, setOverhead] = useState(String(rule.overhead ?? 0));
  const [margin, setMargin] = useState(String(rule.margin ?? 0));
  const [cad, setCad] = useState<RecurrenceCadence>(rule.cadence);
  const [endCondition, setEndCondition] = useState<RecurrenceEndCondition>(rule.endCondition);
  const [endCount, setEndCount] = useState(rule.endCount != null ? String(rule.endCount) : '');
  const [endDate, setEndDate] = useState(rule.endDate ?? '');
  const [nextDueDate, setNextDueDate] = useState(rule.nextDueDate || getTodayDateString());
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function onSave(e: React.FormEvent) {
    e.preventDefault();
    if (busy) return;
    if (!title.trim()) {
      setError('Job title is required.');
      return;
    }
    const pricing = {
      laborHours: parseNonNeg(laborHours),
      laborRate: parseNonNeg(laborRate),
      materialMarkup: parseNonNeg(materialMarkup),
      overhead: parseNonNeg(overhead),
      margin: parseNonNeg(margin),
    };
    if (Object.values(pricing).some((v) => v === null)) {
      setError('Enter a valid, non-negative number for every pricing field.');
      return;
    }
    let endCountValue: number | undefined;
    if (endCondition === 'count') {
      endCountValue = Number(endCount.trim());
      if (!Number.isInteger(endCountValue) || endCountValue < 1) {
        setError('Enter a number of jobs greater than zero.');
        return;
      }
    }
    if (endCondition === 'date' && !endDate) {
      setError('Pick an end date for the series.');
      return;
    }
    if (!nextDueDate) {
      setError('Pick the next job date.');
      return;
    }
    setBusy(true);
    setError(null);
    try {
      // Recompute the derived total the mobile way (travel/tax 0, non-emergency;
      // minimumJobFee from settings), over the rule's existing materials/jobCosts.
      const estimateTotal = estimateTotalFromPricing({
        laborHours: pricing.laborHours!,
        laborRate: pricing.laborRate!,
        materials: rule.materials ?? [],
        materialMarkup: pricing.materialMarkup!,
        jobCosts: rule.jobCosts,
        overheadPercent: pricing.overhead!,
        marginPercent: pricing.margin!,
        minimumJobFee: settings?.minimumJobFee ?? 75,
      });
      await updateRecurringJobRule(rule.id, {
        title: title.trim(),
        description: description.trim(),
        laborHours: pricing.laborHours!,
        laborRate: pricing.laborRate!,
        materialMarkup: pricing.materialMarkup!,
        overhead: pricing.overhead!,
        margin: pricing.margin!,
        estimateTotal,
        cadence: cad,
        endCondition,
        endCount: endCountValue,
        endDate: endCondition === 'date' ? endDate : undefined,
        nextDueDate,
      });
      onSaved();
    } catch (err) {
      setError(errorMessage(err));
      setBusy(false);
    }
  }

  return (
    <div className="grow" style={{ minWidth: 240 }}>
      <div className="title">{rule.title || rule.customerName || 'Recurring job'}</div>
      {error && (
        <div className="inline-alert error" role="alert" style={{ marginTop: 6 }}>
          {error}
        </div>
      )}
      <form className="pay-form" style={{ marginTop: 8, borderTop: 0, paddingTop: 0 }} onSubmit={onSave}>
        <label className="field">
          <span>Title</span>
          <input className="field-input" type="text" value={title} onChange={(e) => setTitle(e.target.value)} />
        </label>
        <label className="field">
          <span>Description</span>
          <input className="field-input" type="text" value={description} onChange={(e) => setDescription(e.target.value)} />
        </label>
        <div className="btn-row">
          <label className="field" style={{ flex: 1 }}>
            <span>Labor hours</span>
            <input className="field-input" type="number" step="0.25" min="0" inputMode="decimal" value={laborHours} onChange={(e) => setLaborHours(e.target.value)} />
          </label>
          <label className="field" style={{ flex: 1 }}>
            <span>Labor rate ($/hr)</span>
            <input className="field-input" type="number" step="0.01" min="0" inputMode="decimal" value={laborRate} onChange={(e) => setLaborRate(e.target.value)} />
          </label>
        </div>
        <div className="btn-row">
          <label className="field" style={{ flex: 1 }}>
            <span>Material markup (%)</span>
            <input className="field-input" type="number" step="0.1" min="0" inputMode="decimal" value={materialMarkup} onChange={(e) => setMaterialMarkup(e.target.value)} />
          </label>
          <label className="field" style={{ flex: 1 }}>
            <span>Overhead (%)</span>
            <input className="field-input" type="number" step="0.1" min="0" inputMode="decimal" value={overhead} onChange={(e) => setOverhead(e.target.value)} />
          </label>
          <label className="field" style={{ flex: 1 }}>
            <span>Margin (%)</span>
            <input className="field-input" type="number" step="0.1" min="0" inputMode="decimal" value={margin} onChange={(e) => setMargin(e.target.value)} />
          </label>
        </div>
        <div className="muted" style={{ fontSize: 12, fontWeight: 400 }}>
          The total is recalculated from these. Material line items are edited in
          the mobile app.
        </div>
        <div className="field">
          <span>Repeats</span>
          <div className="chip-row" role="group" aria-label="Repeats">
            {CADENCES.map((c) => (
              <button
                key={c}
                type="button"
                className={`chip${cad === c ? ' selected' : ''}`}
                aria-pressed={cad === c}
                onClick={() => setCad(c)}
              >
                {CADENCE_LABEL[c]}
              </button>
            ))}
          </div>
        </div>
        <label className="field">
          <span>Next job date</span>
          <input className="field-input" type="date" value={nextDueDate} onChange={(e) => setNextDueDate(e.target.value)} />
        </label>
        <div className="field">
          <span>Ends</span>
          <div className="chip-row" role="group" aria-label="Ends">
            {END_CONDITIONS.map((ec) => (
              <button
                key={ec}
                type="button"
                className={`chip${endCondition === ec ? ' selected' : ''}`}
                aria-pressed={endCondition === ec}
                onClick={() => setEndCondition(ec)}
              >
                {END_LABEL[ec]}
              </button>
            ))}
          </div>
        </div>
        {endCondition === 'count' && (
          <label className="field">
            <span>Number of jobs</span>
            <input className="field-input" type="number" step="1" min="1" inputMode="numeric" value={endCount} onChange={(e) => setEndCount(e.target.value)} />
          </label>
        )}
        {endCondition === 'date' && (
          <label className="field">
            <span>End date</span>
            <input className="field-input" type="date" value={endDate} onChange={(e) => setEndDate(e.target.value)} />
          </label>
        )}
        <div className="btn-row">
          <button type="submit" className="btn primary sm" disabled={busy}>
            {busy ? 'Saving…' : 'Save changes'}
          </button>
          <button type="button" className="btn ghost sm" onClick={onClose} disabled={busy}>
            Cancel
          </button>
        </div>
      </form>
    </div>
  );
}

/**
 * The "New recurring job" form (roadmap P3 stage 5c — creation flows). Creates a
 * recurring-JOB rule via `createRecurringJob` (a fresh series — the generation
 * engine emits the first occurrence on its next run, matching the plan create).
 * The customer is picked from existing records (id + denormalized name; inline
 * customer creation stays on the Customers screen). The derived `estimateTotal`
 * is recomputed the mobile way via `estimateTotalFromPricing` over the five
 * pricing inputs (materials are not authored here — line items stay deferred).
 * Pricing inputs seed from the business defaults. Follows the house UX.
 */
function NewJobRuleForm({
  customers,
  onClose,
  onCreated,
}: {
  customers: Customer[];
  onClose: () => void;
  onCreated: () => void;
}) {
  const { settings } = useData();
  const pickable = customers
    .filter((c) => !c.archivedAt)
    .sort((a, b) => (a.name || '').localeCompare(b.name || ''));
  const [customerId, setCustomerId] = useState('');
  const [title, setTitle] = useState('');
  const [description, setDescription] = useState('');
  const [laborHours, setLaborHours] = useState('0');
  const [laborRate, setLaborRate] = useState(String(settings?.laborRate ?? 85));
  const [materialMarkup, setMaterialMarkup] = useState(String(settings?.materialMarkup ?? 20));
  const [overhead, setOverhead] = useState(String(settings?.overheadPercent ?? 15));
  const [margin, setMargin] = useState(String(settings?.marginPercent ?? 20));
  const [cad, setCad] = useState<RecurrenceCadence>('monthly');
  const [endCondition, setEndCondition] = useState<RecurrenceEndCondition>('never');
  const [endCount, setEndCount] = useState('');
  const [endDate, setEndDate] = useState('');
  const [nextDueDate, setNextDueDate] = useState(getTodayDateString());
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function onSave(e: React.FormEvent) {
    e.preventDefault();
    if (busy) return;
    const customer = pickable.find((c) => c.id === customerId);
    if (!customer) {
      setError('Choose a customer.');
      return;
    }
    if (!title.trim()) {
      setError('Job title is required.');
      return;
    }
    const pricing = {
      laborHours: parseNonNeg(laborHours),
      laborRate: parseNonNeg(laborRate),
      materialMarkup: parseNonNeg(materialMarkup),
      overhead: parseNonNeg(overhead),
      margin: parseNonNeg(margin),
    };
    if (Object.values(pricing).some((v) => v === null)) {
      setError('Enter a valid, non-negative number for every pricing field.');
      return;
    }
    let endCountValue: number | undefined;
    if (endCondition === 'count') {
      endCountValue = Number(endCount.trim());
      if (!Number.isInteger(endCountValue) || endCountValue < 1) {
        setError('Enter a number of jobs greater than zero.');
        return;
      }
    }
    if (endCondition === 'date' && !endDate) {
      setError('Pick an end date for the series.');
      return;
    }
    if (!nextDueDate) {
      setError('Pick the first job date.');
      return;
    }
    setBusy(true);
    setError(null);
    try {
      // Recompute the derived total the mobile way (travel/tax 0, non-emergency;
      // minimumJobFee from settings) over an empty material set (deferred).
      const estimateTotal = estimateTotalFromPricing({
        laborHours: pricing.laborHours!,
        laborRate: pricing.laborRate!,
        materials: [],
        materialMarkup: pricing.materialMarkup!,
        overheadPercent: pricing.overhead!,
        marginPercent: pricing.margin!,
        minimumJobFee: settings?.minimumJobFee ?? 75,
      });
      await createRecurringJob({
        customerId: customer.id,
        customerName: customer.name,
        title: title.trim(),
        description: description.trim(),
        laborHours: pricing.laborHours!,
        laborRate: pricing.laborRate!,
        materialMarkup: pricing.materialMarkup!,
        overhead: pricing.overhead!,
        margin: pricing.margin!,
        estimateTotal,
        cadence: cad,
        endCondition,
        endCount: endCountValue,
        endDate: endCondition === 'date' ? endDate : undefined,
        nextDueDate,
      });
      onCreated();
    } catch (err) {
      setError(errorMessage(err));
      setBusy(false);
    }
  }

  return (
    <Card pad style={{ marginTop: 12 }}>
      <div className="section-label" style={{ padding: '0 0 10px' }}>
        New recurring job
      </div>
      {error && (
        <div className="inline-alert error" role="alert">
          {error}
        </div>
      )}
      {pickable.length === 0 ? (
        <div className="muted" style={{ fontSize: 13 }}>
          Add a customer first — a recurring job repeats for an existing customer.
          <div className="btn-row" style={{ marginTop: 10 }}>
            <button type="button" className="btn ghost sm" onClick={onClose}>
              Close
            </button>
          </div>
        </div>
      ) : (
        <form className="pay-form" style={{ marginTop: 0, borderTop: 0, paddingTop: 0 }} onSubmit={onSave}>
          <label className="field">
            <span>Customer</span>
            <select className="field-input" value={customerId} onChange={(e) => setCustomerId(e.target.value)}>
              <option value="">Select a customer…</option>
              {pickable.map((c) => (
                <option key={c.id} value={c.id}>
                  {c.name || 'Unnamed'}
                </option>
              ))}
            </select>
          </label>
          <label className="field">
            <span>Title</span>
            <input className="field-input" type="text" value={title} onChange={(e) => setTitle(e.target.value)} />
          </label>
          <label className="field">
            <span>Description</span>
            <input className="field-input" type="text" value={description} onChange={(e) => setDescription(e.target.value)} />
          </label>
          <div className="btn-row">
            <label className="field" style={{ flex: 1 }}>
              <span>Labor hours</span>
              <input className="field-input" type="number" step="0.25" min="0" inputMode="decimal" value={laborHours} onChange={(e) => setLaborHours(e.target.value)} />
            </label>
            <label className="field" style={{ flex: 1 }}>
              <span>Labor rate ($/hr)</span>
              <input className="field-input" type="number" step="0.01" min="0" inputMode="decimal" value={laborRate} onChange={(e) => setLaborRate(e.target.value)} />
            </label>
          </div>
          <div className="btn-row">
            <label className="field" style={{ flex: 1 }}>
              <span>Material markup (%)</span>
              <input className="field-input" type="number" step="0.1" min="0" inputMode="decimal" value={materialMarkup} onChange={(e) => setMaterialMarkup(e.target.value)} />
            </label>
            <label className="field" style={{ flex: 1 }}>
              <span>Overhead (%)</span>
              <input className="field-input" type="number" step="0.1" min="0" inputMode="decimal" value={overhead} onChange={(e) => setOverhead(e.target.value)} />
            </label>
            <label className="field" style={{ flex: 1 }}>
              <span>Margin (%)</span>
              <input className="field-input" type="number" step="0.1" min="0" inputMode="decimal" value={margin} onChange={(e) => setMargin(e.target.value)} />
            </label>
          </div>
          <div className="muted" style={{ fontSize: 12, fontWeight: 400 }}>
            The total is calculated from these. Material line items are added in
            the mobile app.
          </div>
          <div className="field">
            <span>Repeats</span>
            <div className="chip-row" role="group" aria-label="Repeats">
              {CADENCES.map((c) => (
                <button
                  key={c}
                  type="button"
                  className={`chip${cad === c ? ' selected' : ''}`}
                  aria-pressed={cad === c}
                  onClick={() => setCad(c)}
                >
                  {CADENCE_LABEL[c]}
                </button>
              ))}
            </div>
          </div>
          <label className="field">
            <span>First job date</span>
            <input className="field-input" type="date" value={nextDueDate} onChange={(e) => setNextDueDate(e.target.value)} />
          </label>
          <div className="field">
            <span>Ends</span>
            <div className="chip-row" role="group" aria-label="Ends">
              {END_CONDITIONS.map((ec) => (
                <button
                  key={ec}
                  type="button"
                  className={`chip${endCondition === ec ? ' selected' : ''}`}
                  aria-pressed={endCondition === ec}
                  onClick={() => setEndCondition(ec)}
                >
                  {END_LABEL[ec]}
                </button>
              ))}
            </div>
          </div>
          {endCondition === 'count' && (
            <label className="field">
              <span>Number of jobs</span>
              <input className="field-input" type="number" step="1" min="1" inputMode="numeric" value={endCount} onChange={(e) => setEndCount(e.target.value)} />
            </label>
          )}
          {endCondition === 'date' && (
            <label className="field">
              <span>End date</span>
              <input className="field-input" type="date" value={endDate} onChange={(e) => setEndDate(e.target.value)} />
            </label>
          )}
          <div className="btn-row">
            <button type="submit" className="btn primary" disabled={busy}>
              {busy ? 'Creating…' : 'Create recurring job'}
            </button>
            <button type="button" className="btn ghost" onClick={onClose} disabled={busy}>
              Cancel
            </button>
          </div>
        </form>
      )}
    </Card>
  );
}

/**
 * The "New maintenance plan" form (roadmap P3 stage 5 — creation flows). Creates
 * a standalone plan via `createRecurringInvoice`; the customer is picked from
 * existing records (a plan needs both id and denormalized name, and inline
 * customer creation belongs to the customer screen). Validation mirrors the
 * mobile AddRecurringInvoiceScreen (a customer, amount > 0, net ≥ 0, a positive
 * end count, an end date when required). Follows the house UX.
 */
function NewPlanForm({
  customers,
  onClose,
  onCreated,
}: {
  customers: Customer[];
  onClose: () => void;
  onCreated: () => void;
}) {
  const pickable = customers
    .filter((c) => !c.archivedAt)
    .sort((a, b) => (a.name || '').localeCompare(b.name || ''));
  const [customerId, setCustomerId] = useState('');
  const [description, setDescription] = useState('');
  const [amount, setAmount] = useState('');
  const [dueDays, setDueDays] = useState('30');
  const [cad, setCad] = useState<RecurrenceCadence>('monthly');
  const [endCondition, setEndCondition] = useState<RecurrenceEndCondition>('never');
  const [endCount, setEndCount] = useState('');
  const [endDate, setEndDate] = useState('');
  const [nextDueDate, setNextDueDate] = useState(getTodayDateString());
  const [autoSend, setAutoSend] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function onSave(e: React.FormEvent) {
    e.preventDefault();
    if (busy) return;
    const customer = pickable.find((c) => c.id === customerId);
    if (!customer) {
      setError('Choose a customer.');
      return;
    }
    const amt = Number(amount.trim());
    if (!(amt > 0)) {
      setError('Enter an invoice amount greater than zero.');
      return;
    }
    const net = Number(dueDays.trim());
    if (!Number.isInteger(net) || net < 0) {
      setError('Net terms must be zero or a positive whole number of days.');
      return;
    }
    let endCountValue: number | undefined;
    if (endCondition === 'count') {
      endCountValue = Number(endCount.trim());
      if (!Number.isInteger(endCountValue) || endCountValue < 1) {
        setError('Enter a number of invoices greater than zero.');
        return;
      }
    }
    if (endCondition === 'date' && !endDate) {
      setError('Pick an end date for the plan.');
      return;
    }
    if (!nextDueDate) {
      setError('Pick the first invoice date.');
      return;
    }
    setBusy(true);
    setError(null);
    try {
      await createRecurringInvoice({
        customerId: customer.id,
        customerName: customer.name,
        description: description.trim(),
        amount: amt,
        dueDays: net,
        cadence: cad,
        endCondition,
        endCount: endCountValue,
        endDate: endCondition === 'date' ? endDate : undefined,
        nextDueDate,
        autoSendEnabled: autoSend,
      });
      onCreated();
    } catch (err) {
      setError(errorMessage(err));
      setBusy(false);
    }
  }

  return (
    <Card pad style={{ marginTop: 12 }}>
      <div className="section-label" style={{ padding: '0 0 10px' }}>
        New maintenance plan
      </div>
      {error && (
        <div className="inline-alert error" role="alert">
          {error}
        </div>
      )}
      {pickable.length === 0 ? (
        <div className="muted" style={{ fontSize: 13 }}>
          Add a customer first — a plan bills an existing customer.
          <div className="btn-row" style={{ marginTop: 10 }}>
            <button type="button" className="btn ghost sm" onClick={onClose}>
              Close
            </button>
          </div>
        </div>
      ) : (
        <form className="pay-form" style={{ marginTop: 0, borderTop: 0, paddingTop: 0 }} onSubmit={onSave}>
          <label className="field">
            <span>Customer</span>
            <select className="field-input" value={customerId} onChange={(e) => setCustomerId(e.target.value)}>
              <option value="">Select a customer…</option>
              {pickable.map((c) => (
                <option key={c.id} value={c.id}>
                  {c.name || 'Unnamed'}
                </option>
              ))}
            </select>
          </label>
          <label className="field">
            <span>Description</span>
            <input className="field-input" type="text" value={description} onChange={(e) => setDescription(e.target.value)} />
          </label>
          <div className="btn-row">
            <label className="field" style={{ flex: 1 }}>
              <span>Amount ($)</span>
              <input className="field-input" type="number" step="0.01" min="0" inputMode="decimal" value={amount} onChange={(e) => setAmount(e.target.value)} />
            </label>
            <label className="field" style={{ flex: 1 }}>
              <span>Net (days)</span>
              <input className="field-input" type="number" step="1" min="0" inputMode="numeric" value={dueDays} onChange={(e) => setDueDays(e.target.value)} />
            </label>
          </div>
          <div className="field">
            <span>Repeats</span>
            <div className="chip-row" role="group" aria-label="Repeats">
              {CADENCES.map((c) => (
                <button
                  key={c}
                  type="button"
                  className={`chip${cad === c ? ' selected' : ''}`}
                  aria-pressed={cad === c}
                  onClick={() => setCad(c)}
                >
                  {CADENCE_LABEL[c]}
                </button>
              ))}
            </div>
          </div>
          <label className="field">
            <span>First invoice date</span>
            <input className="field-input" type="date" value={nextDueDate} onChange={(e) => setNextDueDate(e.target.value)} />
          </label>
          <div className="field">
            <span>Ends</span>
            <div className="chip-row" role="group" aria-label="Ends">
              {END_CONDITIONS.map((ec) => (
                <button
                  key={ec}
                  type="button"
                  className={`chip${endCondition === ec ? ' selected' : ''}`}
                  aria-pressed={endCondition === ec}
                  onClick={() => setEndCondition(ec)}
                >
                  {END_LABEL[ec]}
                </button>
              ))}
            </div>
          </div>
          {endCondition === 'count' && (
            <label className="field">
              <span>Number of invoices</span>
              <input className="field-input" type="number" step="1" min="1" inputMode="numeric" value={endCount} onChange={(e) => setEndCount(e.target.value)} />
            </label>
          )}
          {endCondition === 'date' && (
            <label className="field">
              <span>End date</span>
              <input className="field-input" type="date" value={endDate} onChange={(e) => setEndDate(e.target.value)} />
            </label>
          )}
          <label className="field checkbox-field">
            <input type="checkbox" checked={autoSend} onChange={(e) => setAutoSend(e.target.checked)} />
            <span>Auto-send each invoice by email</span>
          </label>
          <div className="btn-row">
            <button type="submit" className="btn primary" disabled={busy}>
              {busy ? 'Creating…' : 'Create plan'}
            </button>
            <button type="button" className="btn ghost" onClick={onClose} disabled={busy}>
              Cancel
            </button>
          </div>
        </form>
      )}
    </Card>
  );
}

export default function RecurringScreen() {
  const { recurringJobs, recurringInvoices, customers, retry } = useData();
  const state = useResources('recurringJobs', 'recurringInvoices');
  const [creatingPlan, setCreatingPlan] = useState(false);
  const [creatingJob, setCreatingJob] = useState(false);

  if (state.loading) return <Empty>Loading recurring work…</Empty>;
  if (state.error)
    return (
      <ErrorState
        message={`Couldn’t load recurring work: ${state.error}`}
        onRetry={state.retry}
      />
    );

  const jobs = [...recurringJobs].sort((a, b) =>
    (a.nextDueDate || '').localeCompare(b.nextDueDate || ''),
  );
  const plans = [...recurringInvoices].sort((a, b) =>
    (a.nextDueDate || '').localeCompare(b.nextDueDate || ''),
  );

  return (
    <>
      <PageHead
        title="Recurring"
        sub="Repeating jobs and maintenance plans"
      />

      <Card>
        <div className="btn-row" style={{ justifyContent: 'space-between', alignItems: 'center' }}>
          <div className="section-label" style={{ padding: 0 }}>
            Recurring jobs ({jobs.length})
          </div>
          {!creatingJob && (
            <button type="button" className="btn sm" onClick={() => setCreatingJob(true)}>
              New job
            </button>
          )}
        </div>
        {creatingJob && (
          <NewJobRuleForm
            customers={customers}
            onClose={() => setCreatingJob(false)}
            onCreated={() => {
              retry(['recurringJobs']);
              setCreatingJob(false);
            }}
          />
        )}
        {jobs.length === 0 ? (
          <Empty>No recurring jobs.</Empty>
        ) : (
          <div className="list">
            {jobs.map((r) => (
              <RecurringRow
                key={r.id}
                title={r.title || r.customerName || 'Recurring job'}
                meta={
                  cadence(r.cadence) +
                  (r.customerName ? ` · ${r.customerName}` : '') +
                  (r.nextDueDate ? ` · next ${formatDisplayDate(r.nextDueDate)}` : '')
                }
                amount={r.estimateTotal || 0}
                isActive={r.isActive}
                deleteLabel="Delete series"
                onToggle={async (active) => {
                  await setRecurringJobActive(r.id, active);
                  retry(['recurringJobs']);
                }}
                onDelete={async () => {
                  await deleteRecurringJob(r.id);
                  retry(['recurringJobs']);
                }}
                renderEditor={(close) => (
                  <JobRuleEditor
                    rule={r}
                    onClose={close}
                    onSaved={() => {
                      retry(['recurringJobs']);
                      close();
                    }}
                  />
                )}
              />
            ))}
          </div>
        )}
      </Card>

      {creatingPlan && (
        <NewPlanForm
          customers={customers}
          onClose={() => setCreatingPlan(false)}
          onCreated={() => {
            retry(['recurringInvoices']);
            setCreatingPlan(false);
          }}
        />
      )}

      <Card style={{ marginTop: 16 }}>
        <div className="btn-row" style={{ justifyContent: 'space-between', alignItems: 'center' }}>
          <div className="section-label" style={{ padding: 0 }}>
            Maintenance plans ({plans.length})
          </div>
          {!creatingPlan && (
            <button type="button" className="btn sm" onClick={() => setCreatingPlan(true)}>
              New plan
            </button>
          )}
        </div>
        {plans.length === 0 ? (
          <Empty>No maintenance plans.</Empty>
        ) : (
          <div className="list">
            {plans.map((r) => (
              <RecurringRow
                key={r.id}
                title={r.customerName || 'Maintenance plan'}
                meta={
                  `${cadence(r.cadence)} · net ${r.dueDays}d` +
                  (r.nextDueDate ? ` · next ${formatDisplayDate(r.nextDueDate)}` : '') +
                  (r.autoSendEnabled ? ' · auto-send' : '')
                }
                amount={r.amount || 0}
                isActive={r.isActive}
                deleteLabel="Delete plan"
                onToggle={async (active) => {
                  await setRecurringInvoiceActive(r.id, active);
                  retry(['recurringInvoices']);
                }}
                onDelete={async () => {
                  await deleteRecurringInvoice(r.id);
                  retry(['recurringInvoices']);
                }}
                renderEditor={(close) => (
                  <PlanEditor
                    plan={r}
                    onClose={close}
                    onSaved={() => {
                      retry(['recurringInvoices']);
                      close();
                    }}
                  />
                )}
              />
            ))}
          </div>
        )}
      </Card>
    </>
  );
}
