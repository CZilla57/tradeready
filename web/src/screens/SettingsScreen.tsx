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

          <Card pad>
            <div className="section-label" style={{ padding: '0 0 8px' }}>
              Pricing defaults
            </div>
            <KV k="Labor rate" v={`${formatMoney(s.laborRate || 0)}/hr`} />
            <KV k="Material markup" v={`${s.materialMarkup ?? 0}%`} />
            <KV k="Overhead" v={`${s.overheadPercent ?? 0}%`} />
            <KV k="Margin" v={`${s.marginPercent ?? 0}%`} />
            <KV k="Minimum job fee" v={formatMoney(s.minimumJobFee || 0)} />
            <KV k="Travel fee" v={`${formatMoney(s.travelFeePerMile || 0)}/mi`} />
            <KV k="Mileage rate" v={`${formatMoney(s.mileageRate || 0)}/mi`} />
          </Card>

          <Card pad>
            <div className="section-label" style={{ padding: '0 0 8px' }}>
              Invoicing
            </div>
            <KV k="Number prefix" v={s.invoicePrefix || '—'} />
            <KV k="Start number" v={String(s.invoiceStartNumber ?? '—')} />
            <KV
              k="Auto-create on complete"
              v={yesNo(s.autoInvoiceOnComplete)}
            />
            <KV
              k="Auto-email on complete"
              v={yesNo(s.autoEmailInvoiceOnComplete)}
            />
          </Card>
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

          <Card pad>
            <div className="section-label" style={{ padding: '0 0 8px' }}>
              Automation
            </div>
            <KV k="Overdue auto-outreach" v={yesNo(s.autoOutreachEnabled)} />
            <KV k="Reminder auto-email" v={yesNo(s.autoSendEmailEnabled)} />
            <KV
              k="Appointment reminders"
              v={yesNo(s.appointmentRemindersEnabled)}
            />
            <KV
              k="Estimate follow-ups"
              v={yesNo(s.estimateFollowUpsEnabled)}
            />
            <KV k="Review requests" v={yesNo(s.reviewRequestEnabled)} />
          </Card>
        </div>
      </div>

      <div className="muted" style={{ marginTop: 16, fontSize: 13 }}>
        You can update your business profile here. Pricing, invoicing, schedule,
        payments, and automation settings are edited in the TradeReady mobile
        app.
      </div>
    </>
  );
}
