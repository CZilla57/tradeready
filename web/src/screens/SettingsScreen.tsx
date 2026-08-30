import { useMemo } from 'react';
import { useData, useResources } from '../lib/DataContext';
import { Card, PageHead, Empty, KV, Badge, ErrorState } from '../ui/components';
import { formatMoney } from '@shared/utils/format';
import { resolveSchedule } from '@shared/utils/scheduleConfig';
import type { Settings } from '@shared/types/models';

const DOW = ['', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const EMPTY_SETTINGS = {} as Settings;

function yesNo(v: unknown): string {
  return v ? 'On' : 'Off';
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
        sub="Read-only view of your business configuration"
      />

      <div className="detail-grid">
        <div className="stack">
          <Card pad>
            <div className="section-label" style={{ padding: '0 0 8px' }}>
              Business profile
            </div>
            <KV k="Business" v={s.businessName || '—'} />
            <KV k="Contact" v={s.contactName || '—'} />
            <KV k="Trade" v={s.trade || '—'} />
            <KV k="Phone" v={s.phone || '—'} />
            <KV k="Email" v={s.email || '—'} />
            <KV k="Address" v={s.address || '—'} />
            {s.region && <KV k="Region" v={s.region} />}
          </Card>

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
        Settings are edited in the TradeReady mobile app. This is a read-only
        view.
      </div>
    </>
  );
}
