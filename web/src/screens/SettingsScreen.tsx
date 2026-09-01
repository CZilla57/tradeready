import { useMemo, useState } from 'react';
import { useData, useResources } from '../lib/DataContext';
import { Card, PageHead, Empty, KV, Badge, ErrorState } from '../ui/components';
import { formatMoney } from '@shared/utils/format';
import { resolveSchedule } from '@shared/utils/scheduleConfig';
import type { Settings } from '@shared/types/models';
import { saveSettings } from '../lib/writeRepository';

const DOW = ['', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const EMPTY_SETTINGS = {} as Settings;

function yesNo(v: unknown): string {
  return v ? 'On' : 'Off';
}

function errorMessage(err: unknown): string {
  return err instanceof Error ? err.message : 'Something went wrong';
}

/** Render a stored number for a text field (undefined → the display default). */
function numStr(v: number | undefined | null, fallback = 0): string {
  return String(v ?? fallback);
}

/** Parse a required non-negative number field; null when blank or invalid.
 *  (`Number('')` is 0, so blank is rejected explicitly rather than saved as 0.) */
function parseNonNeg(s: string): number | null {
  const t = s.trim();
  if (t === '') return null;
  const n = Number(t);
  return Number.isFinite(n) && n >= 0 ? n : null;
}

/**
 * The editable Business profile card (roadmap P3 stage 4). Saves through
 * `saveSettings`, which merges the patch onto the full server settings blob
 * (preserving every field the portal doesn't render) and strips credential
 * fields. Only direct-value profile fields are edited here — no derived or
 * coupled settings.
 */
function ProfileEditor({ settings }: { settings: Settings }) {
  const { retry } = useData();
  const [open, setOpen] = useState(false);
  const [businessName, setBusinessName] = useState(settings.businessName ?? '');
  const [contactName, setContactName] = useState(settings.contactName ?? '');
  const [phone, setPhone] = useState(settings.phone ?? '');
  const [email, setEmail] = useState(settings.email ?? '');
  const [address, setAddress] = useState(settings.address ?? '');
  const [region, setRegion] = useState(settings.region ?? '');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  function openEditor() {
    setBusinessName(settings.businessName ?? '');
    setContactName(settings.contactName ?? '');
    setPhone(settings.phone ?? '');
    setEmail(settings.email ?? '');
    setAddress(settings.address ?? '');
    setRegion(settings.region ?? '');
    setError(null);
    setOpen(true);
  }

  async function onSave(e: React.FormEvent) {
    e.preventDefault();
    if (busy) return;
    setBusy(true);
    setError(null);
    try {
      await saveSettings({
        businessName: businessName.trim(),
        contactName: contactName.trim(),
        phone: phone.trim(),
        email: email.trim(),
        address: address.trim(),
        region: region.trim(),
      });
      retry(['settings']);
      setOpen(false);
    } catch (err) {
      setError(errorMessage(err));
    } finally {
      setBusy(false);
    }
  }

  if (!open) {
    return (
      <Card pad>
        <div className="btn-row" style={{ justifyContent: 'space-between' }}>
          <div className="section-label" style={{ padding: 0 }}>
            Business profile
          </div>
          <button type="button" className="btn sm" onClick={openEditor}>
            Edit
          </button>
        </div>
        <div style={{ marginTop: 8 }}>
          <KV k="Business" v={settings.businessName || '—'} />
          <KV k="Contact" v={settings.contactName || '—'} />
          <KV k="Trade" v={settings.trade || '—'} />
          <KV k="Phone" v={settings.phone || '—'} />
          <KV k="Email" v={settings.email || '—'} />
          <KV k="Address" v={settings.address || '—'} />
          {settings.region && <KV k="Region" v={settings.region} />}
        </div>
      </Card>
    );
  }

  return (
    <Card pad>
      <div className="section-label" style={{ padding: '0 0 10px' }}>
        Business profile
      </div>
      {error && (
        <div className="inline-alert error" role="alert">
          {error}
        </div>
      )}
      <form className="pay-form" style={{ marginTop: 0, borderTop: 0, paddingTop: 0 }} onSubmit={onSave}>
        <label className="field">
          <span>Business name</span>
          <input className="field-input" type="text" value={businessName} onChange={(e) => setBusinessName(e.target.value)} />
        </label>
        <label className="field">
          <span>Contact name</span>
          <input className="field-input" type="text" value={contactName} onChange={(e) => setContactName(e.target.value)} />
        </label>
        <label className="field">
          <span>Phone</span>
          <input className="field-input" type="tel" value={phone} onChange={(e) => setPhone(e.target.value)} />
        </label>
        <label className="field">
          <span>Email</span>
          <input className="field-input" type="email" value={email} onChange={(e) => setEmail(e.target.value)} />
        </label>
        <label className="field">
          <span>Address</span>
          <input className="field-input" type="text" value={address} onChange={(e) => setAddress(e.target.value)} />
        </label>
        <label className="field">
          <span>Region</span>
          <input className="field-input" type="text" value={region} onChange={(e) => setRegion(e.target.value)} />
        </label>
        <div className="btn-row">
          <button type="submit" className="btn primary" disabled={busy}>
            {busy ? 'Saving…' : 'Save changes'}
          </button>
          <button type="button" className="btn ghost" onClick={() => setOpen(false)} disabled={busy}>
            Cancel
          </button>
        </div>
      </form>
    </Card>
  );
}

/**
 * The editable Pricing defaults card (roadmap P3 stage 4). Every field here is a
 * direct-value setting applied to future estimates — none is derived or
 * cross-entity-coupled — so it saves through the same `saveSettings` patch path
 * as the profile. The estimate math that CONSUMES these values is not run here;
 * this only stores the inputs, exactly as the mobile Settings screen does.
 */
function PricingEditor({ settings }: { settings: Settings }) {
  const { retry } = useData();
  const [open, setOpen] = useState(false);
  const [laborRate, setLaborRate] = useState('');
  const [materialMarkup, setMaterialMarkup] = useState('');
  const [overheadPercent, setOverheadPercent] = useState('');
  const [marginPercent, setMarginPercent] = useState('');
  const [minimumJobFee, setMinimumJobFee] = useState('');
  const [travelFeePerMile, setTravelFeePerMile] = useState('');
  const [mileageRate, setMileageRate] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  function openEditor() {
    setLaborRate(numStr(settings.laborRate));
    setMaterialMarkup(numStr(settings.materialMarkup));
    setOverheadPercent(numStr(settings.overheadPercent));
    setMarginPercent(numStr(settings.marginPercent));
    setMinimumJobFee(numStr(settings.minimumJobFee));
    setTravelFeePerMile(numStr(settings.travelFeePerMile));
    setMileageRate(numStr(settings.mileageRate));
    setError(null);
    setOpen(true);
  }

  async function onSave(e: React.FormEvent) {
    e.preventDefault();
    if (busy) return;
    const values = {
      laborRate: parseNonNeg(laborRate),
      materialMarkup: parseNonNeg(materialMarkup),
      overheadPercent: parseNonNeg(overheadPercent),
      marginPercent: parseNonNeg(marginPercent),
      minimumJobFee: parseNonNeg(minimumJobFee),
      travelFeePerMile: parseNonNeg(travelFeePerMile),
      mileageRate: parseNonNeg(mileageRate),
    };
    if (Object.values(values).some((v) => v === null)) {
      setError('Enter a valid, non-negative number for every field.');
      return;
    }
    setBusy(true);
    setError(null);
    try {
      await saveSettings(values as Partial<Settings>);
      retry(['settings']);
      setOpen(false);
    } catch (err) {
      setError(errorMessage(err));
    } finally {
      setBusy(false);
    }
  }

  if (!open) {
    return (
      <Card pad>
        <div className="btn-row" style={{ justifyContent: 'space-between' }}>
          <div className="section-label" style={{ padding: 0 }}>
            Pricing defaults
          </div>
          <button type="button" className="btn sm" onClick={openEditor}>
            Edit
          </button>
        </div>
        <div style={{ marginTop: 8 }}>
          <KV k="Labor rate" v={`${formatMoney(settings.laborRate || 0)}/hr`} />
          <KV k="Material markup" v={`${settings.materialMarkup ?? 0}%`} />
          <KV k="Overhead" v={`${settings.overheadPercent ?? 0}%`} />
          <KV k="Margin" v={`${settings.marginPercent ?? 0}%`} />
          <KV k="Minimum job fee" v={formatMoney(settings.minimumJobFee || 0)} />
          <KV k="Travel fee" v={`${formatMoney(settings.travelFeePerMile || 0)}/mi`} />
          <KV k="Mileage rate" v={`${formatMoney(settings.mileageRate || 0)}/mi`} />
        </div>
      </Card>
    );
  }

  return (
    <Card pad>
      <div className="section-label" style={{ padding: '0 0 10px' }}>
        Pricing defaults
      </div>
      {error && (
        <div className="inline-alert error" role="alert">
          {error}
        </div>
      )}
      <form className="pay-form" style={{ marginTop: 0, borderTop: 0, paddingTop: 0 }} onSubmit={onSave}>
        <label className="field">
          <span>Labor rate ($/hr)</span>
          <input className="field-input" type="number" step="0.01" min="0" inputMode="decimal" value={laborRate} onChange={(e) => setLaborRate(e.target.value)} />
        </label>
        <label className="field">
          <span>Material markup (%)</span>
          <input className="field-input" type="number" step="0.1" min="0" inputMode="decimal" value={materialMarkup} onChange={(e) => setMaterialMarkup(e.target.value)} />
        </label>
        <label className="field">
          <span>Overhead (%)</span>
          <input className="field-input" type="number" step="0.1" min="0" inputMode="decimal" value={overheadPercent} onChange={(e) => setOverheadPercent(e.target.value)} />
        </label>
        <label className="field">
          <span>Margin (%)</span>
          <input className="field-input" type="number" step="0.1" min="0" inputMode="decimal" value={marginPercent} onChange={(e) => setMarginPercent(e.target.value)} />
        </label>
        <label className="field">
          <span>Minimum job fee ($)</span>
          <input className="field-input" type="number" step="0.01" min="0" inputMode="decimal" value={minimumJobFee} onChange={(e) => setMinimumJobFee(e.target.value)} />
        </label>
        <label className="field">
          <span>Travel fee ($/mi)</span>
          <input className="field-input" type="number" step="0.01" min="0" inputMode="decimal" value={travelFeePerMile} onChange={(e) => setTravelFeePerMile(e.target.value)} />
        </label>
        <label className="field">
          <span>Mileage rate ($/mi)</span>
          <input className="field-input" type="number" step="0.01" min="0" inputMode="decimal" value={mileageRate} onChange={(e) => setMileageRate(e.target.value)} />
        </label>
        <div className="btn-row">
          <button type="submit" className="btn primary" disabled={busy}>
            {busy ? 'Saving…' : 'Save changes'}
          </button>
          <button type="button" className="btn ghost" onClick={() => setOpen(false)} disabled={busy}>
            Cancel
          </button>
        </div>
      </form>
    </Card>
  );
}

/**
 * The editable Invoicing card (roadmap P3 stage 4). The prefix and start-number
 * feed `utils/invoiceNumber` (blank prefix → "INV", absent start → 1), and the
 * two auto-on-complete flags are plain booleans — all direct-value settings, so
 * they save through the same `saveSettings` patch path. The auto-invoice
 * workflow that READS these flags runs on-device; this only stores them.
 */
function InvoicingEditor({ settings }: { settings: Settings }) {
  const { retry } = useData();
  const [open, setOpen] = useState(false);
  const [prefix, setPrefix] = useState('');
  const [startNumber, setStartNumber] = useState('');
  const [autoInvoice, setAutoInvoice] = useState(false);
  const [autoEmail, setAutoEmail] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  function openEditor() {
    setPrefix(settings.invoicePrefix ?? '');
    setStartNumber(settings.invoiceStartNumber != null ? String(settings.invoiceStartNumber) : '');
    setAutoInvoice(!!settings.autoInvoiceOnComplete);
    setAutoEmail(!!settings.autoEmailInvoiceOnComplete);
    setError(null);
    setOpen(true);
  }

  async function onSave(e: React.FormEvent) {
    e.preventDefault();
    if (busy) return;
    // Start number is optional (blank → cleared, the util then defaults to 1);
    // when present it must be a non-negative whole number.
    const trimmedStart = startNumber.trim();
    let startValue: number | undefined;
    if (trimmedStart !== '') {
      const n = Number(trimmedStart);
      if (!Number.isInteger(n) || n < 0) {
        setError('Start number must be a whole number (or left blank).');
        return;
      }
      startValue = n;
    }
    setBusy(true);
    setError(null);
    try {
      await saveSettings({
        invoicePrefix: prefix.trim(),
        invoiceStartNumber: startValue,
        autoInvoiceOnComplete: autoInvoice,
        // Auto-email only makes sense alongside auto-create; keep them consistent.
        autoEmailInvoiceOnComplete: autoInvoice && autoEmail,
      });
      retry(['settings']);
      setOpen(false);
    } catch (err) {
      setError(errorMessage(err));
    } finally {
      setBusy(false);
    }
  }

  if (!open) {
    return (
      <Card pad>
        <div className="btn-row" style={{ justifyContent: 'space-between' }}>
          <div className="section-label" style={{ padding: 0 }}>
            Invoicing
          </div>
          <button type="button" className="btn sm" onClick={openEditor}>
            Edit
          </button>
        </div>
        <div style={{ marginTop: 8 }}>
          <KV k="Number prefix" v={settings.invoicePrefix || '—'} />
          <KV k="Start number" v={String(settings.invoiceStartNumber ?? '—')} />
          <KV k="Auto-create on complete" v={yesNo(settings.autoInvoiceOnComplete)} />
          <KV k="Auto-email on complete" v={yesNo(settings.autoEmailInvoiceOnComplete)} />
        </div>
      </Card>
    );
  }

  return (
    <Card pad>
      <div className="section-label" style={{ padding: '0 0 10px' }}>
        Invoicing
      </div>
      {error && (
        <div className="inline-alert error" role="alert">
          {error}
        </div>
      )}
      <form className="pay-form" style={{ marginTop: 0, borderTop: 0, paddingTop: 0 }} onSubmit={onSave}>
        <label className="field">
          <span>Number prefix</span>
          <input className="field-input" type="text" value={prefix} placeholder="INV" onChange={(e) => setPrefix(e.target.value)} />
        </label>
        <label className="field">
          <span>Start number (optional)</span>
          <input className="field-input" type="number" step="1" min="0" inputMode="numeric" value={startNumber} placeholder="1" onChange={(e) => setStartNumber(e.target.value)} />
        </label>
        <label className="field checkbox-field">
          <input type="checkbox" checked={autoInvoice} onChange={(e) => setAutoInvoice(e.target.checked)} />
          <span>Auto-create invoice when a job is completed</span>
        </label>
        <label className="field checkbox-field">
          <input type="checkbox" checked={autoEmail} disabled={!autoInvoice} onChange={(e) => setAutoEmail(e.target.checked)} />
          <span>Auto-email the invoice on completion</span>
        </label>
        <div className="btn-row">
          <button type="submit" className="btn primary" disabled={busy}>
            {busy ? 'Saving…' : 'Save changes'}
          </button>
          <button type="button" className="btn ghost" onClick={() => setOpen(false)} disabled={busy}>
            Cancel
          </button>
        </div>
      </form>
    </Card>
  );
}

/**
 * The editable Automation card (roadmap P3 stage 4). Five opt-in/out boolean
 * flags, saved through the same `saveSettings` patch path — no coupling to any
 * other entity; the backend sweeps and on-device notifications that ACT on these
 * flags read them, the portal only stores them.
 *
 * ⚠️ `estimateFollowUpsEnabled` uses the REVERSE convention of the others:
 * ABSENT means ON (read as `!== false`), an explicit owner decision — see the
 * field comment in types/models.ts. So it is read with `!== false` here (the
 * plain-`yesNo` read-only card was wrong for a settings blob that predates the
 * field), and always written as an explicit boolean so the meaning is preserved.
 */
function AutomationEditor({ settings }: { settings: Settings }) {
  const { retry } = useData();
  const [open, setOpen] = useState(false);
  const [autoOutreach, setAutoOutreach] = useState(false);
  const [autoSendEmail, setAutoSendEmail] = useState(false);
  const [appointmentReminders, setAppointmentReminders] = useState(false);
  const [estimateFollowUps, setEstimateFollowUps] = useState(true);
  const [reviewRequest, setReviewRequest] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  function openEditor() {
    setAutoOutreach(!!settings.autoOutreachEnabled);
    setAutoSendEmail(!!settings.autoSendEmailEnabled);
    setAppointmentReminders(!!settings.appointmentRemindersEnabled);
    // Reverse convention: absent → ON.
    setEstimateFollowUps(settings.estimateFollowUpsEnabled !== false);
    setReviewRequest(!!settings.reviewRequestEnabled);
    setError(null);
    setOpen(true);
  }

  async function onSave(e: React.FormEvent) {
    e.preventDefault();
    if (busy) return;
    setBusy(true);
    setError(null);
    try {
      await saveSettings({
        autoOutreachEnabled: autoOutreach,
        autoSendEmailEnabled: autoSendEmail,
        appointmentRemindersEnabled: appointmentReminders,
        estimateFollowUpsEnabled: estimateFollowUps,
        reviewRequestEnabled: reviewRequest,
      });
      retry(['settings']);
      setOpen(false);
    } catch (err) {
      setError(errorMessage(err));
    } finally {
      setBusy(false);
    }
  }

  if (!open) {
    return (
      <Card pad>
        <div className="btn-row" style={{ justifyContent: 'space-between' }}>
          <div className="section-label" style={{ padding: 0 }}>
            Automation
          </div>
          <button type="button" className="btn sm" onClick={openEditor}>
            Edit
          </button>
        </div>
        <div style={{ marginTop: 8 }}>
          <KV k="Overdue auto-outreach" v={yesNo(settings.autoOutreachEnabled)} />
          <KV k="Reminder auto-email" v={yesNo(settings.autoSendEmailEnabled)} />
          <KV k="Appointment reminders" v={yesNo(settings.appointmentRemindersEnabled)} />
          <KV k="Estimate follow-ups" v={yesNo(settings.estimateFollowUpsEnabled !== false)} />
          <KV k="Review requests" v={yesNo(settings.reviewRequestEnabled)} />
        </div>
      </Card>
    );
  }

  return (
    <Card pad>
      <div className="section-label" style={{ padding: '0 0 10px' }}>
        Automation
      </div>
      {error && (
        <div className="inline-alert error" role="alert">
          {error}
        </div>
      )}
      <form className="pay-form" style={{ marginTop: 0, borderTop: 0, paddingTop: 0 }} onSubmit={onSave}>
        <label className="field checkbox-field">
          <input type="checkbox" checked={autoOutreach} onChange={(e) => setAutoOutreach(e.target.checked)} />
          <span>Overdue-invoice auto-outreach</span>
        </label>
        <label className="field checkbox-field">
          <input type="checkbox" checked={autoSendEmail} onChange={(e) => setAutoSendEmail(e.target.checked)} />
          <span>Auto-email overdue payment reminders</span>
        </label>
        <label className="field checkbox-field">
          <input type="checkbox" checked={appointmentReminders} onChange={(e) => setAppointmentReminders(e.target.checked)} />
          <span>Appointment (day-before) reminders</span>
        </label>
        <label className="field checkbox-field">
          <input type="checkbox" checked={estimateFollowUps} onChange={(e) => setEstimateFollowUps(e.target.checked)} />
          <span>Estimate follow-up nudges</span>
        </label>
        <label className="field checkbox-field">
          <input type="checkbox" checked={reviewRequest} onChange={(e) => setReviewRequest(e.target.checked)} />
          <span>Review requests after job completion</span>
        </label>
        <div className="btn-row">
          <button type="submit" className="btn primary" disabled={busy}>
            {busy ? 'Saving…' : 'Save changes'}
          </button>
          <button type="button" className="btn ghost" onClick={() => setOpen(false)} disabled={busy}>
            Cancel
          </button>
        </div>
      </form>
    </Card>
  );
}

export default function SettingsScreen() {
  const { settings } = useData();
  const state = useResources('settings');
  const schedule = useMemo(
    () => resolveSchedule(settings ?? EMPTY_SETTINGS),
    [settings],
  );

  if (state.loading) return <Empty>Loading settings…</Empty>;
  if (state.error)
    return (
      <ErrorState
        message={`Couldn’t load settings: ${state.error}`}
        onRetry={state.retry}
      />
    );
  if (!settings) return <Empty>No settings on file yet.</Empty>;

  const s = settings;

  return (
    <>
      <PageHead
        title="Settings"
        sub="Your business configuration"
      />

      <div className="detail-grid">
        <div className="stack">
          <ProfileEditor settings={s} />
          <PricingEditor settings={s} />
          <InvoicingEditor settings={s} />
        </div>

        <div className="stack">
          <Card pad>
            <div className="section-label" style={{ padding: '0 0 8px' }}>
              Schedule
            </div>
            <KV
              k="Work days"
              v={schedule.workDays.map((d) => DOW[d]).join(', ')}
            />
            <KV
              k="Hours"
              v={`${schedule.workDayStart} – ${schedule.workDayEnd}`}
            />
            <KV
              k="Appointment length"
              v={`${schedule.defaultDurationMinutes} min`}
            />
            <KV k="Buffer" v={`${schedule.bufferMinutes} min`} />
            {schedule.timeZone && <KV k="Time zone" v={schedule.timeZone} />}
            <KV
              k="Online booking"
              v={yesNo(schedule.bookableSlotsEnabled)}
            />
            {schedule.blackouts.length > 0 && (
              <KV k="Time off periods" v={String(schedule.blackouts.length)} />
            )}
          </Card>

          <Card pad>
            <div className="section-label" style={{ padding: '0 0 8px' }}>
              Payments
            </div>
            <KV
              k="Processor"
              v={
                s.provider ? (
                  <Badge color="blue">{s.provider}</Badge>
                ) : (
                  'Not set'
                )
              }
            />
            {s.paymentNotes && <KV k="Payment notes" v={s.paymentNotes} />}
          </Card>

          <AutomationEditor settings={s} />
        </div>
      </div>

      <div className="muted" style={{ marginTop: 16, fontSize: 13 }}>
        You can update your business profile, pricing defaults, invoicing, and
        automation settings here. Schedule and payment-processor settings are
        edited in the TradeReady mobile app.
      </div>
    </>
  );
}
