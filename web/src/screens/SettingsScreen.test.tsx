import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import type { Settings } from '@shared/types/models';
import SettingsScreen from './SettingsScreen';

const writes = vi.hoisted(() => ({
  saveSettings: vi.fn(),
  saveSchedule: vi.fn(),
}));
vi.mock('../lib/writeRepository', () => writes);

const retry = vi.hoisted(() => vi.fn());
const store = vi.hoisted(() => ({ settings: null as Settings | null }));
vi.mock('../lib/DataContext', () => ({
  useData: () => ({ settings: store.settings, retry }),
  useResources: () => ({ loading: false, error: null, refreshing: false, retry }),
}));

function settings(): Settings {
  return {
    businessName: 'Acme Plumbing',
    phone: '555',
    laborRate: 90,
    materialMarkup: 20,
    overheadPercent: 10,
    marginPercent: 15,
    minimumJobFee: 75,
    travelFeePerMile: 1.5,
    mileageRate: 0.7,
    invoicePrefix: 'INV',
    invoiceStartNumber: 100,
    autoInvoiceOnComplete: false,
    autoEmailInvoiceOnComplete: false,
  } as Settings;
}

/** Open the section whose "Edit" button sits inside the card with this label. */
async function openSection(label: string) {
  const heading = screen.getByText(label);
  const card = heading.closest('.card') as HTMLElement;
  await userEvent.click(within(card).getByRole('button', { name: 'Edit' }));
}

beforeEach(() => {
  writes.saveSettings.mockReset().mockResolvedValue(settings());
  writes.saveSchedule.mockReset().mockResolvedValue(settings());
  retry.mockReset();
  store.settings = settings();
});

describe('SettingsScreen — business profile edit', () => {
  it('saves profile fields via saveSettings and refreshes', async () => {
    render(<SettingsScreen />);
    await openSection('Business profile');

    const nameInput = screen.getByDisplayValue('Acme Plumbing');
    await userEvent.clear(nameInput);
    await userEvent.type(nameInput, 'Acme Plumbing Co');
    await userEvent.click(screen.getByRole('button', { name: 'Save changes' }));

    await waitFor(() => expect(writes.saveSettings).toHaveBeenCalledTimes(1));
    expect(writes.saveSettings.mock.calls[0][0]).toMatchObject({
      businessName: 'Acme Plumbing Co',
    });
    expect(retry).toHaveBeenCalledWith(['settings']);
  });

  it('surfaces a save error without closing the form', async () => {
    writes.saveSettings.mockRejectedValue(new Error('rls denied'));
    render(<SettingsScreen />);
    await openSection('Business profile');
    await userEvent.click(screen.getByRole('button', { name: 'Save changes' }));

    await waitFor(() =>
      expect(screen.getByRole('alert')).toHaveTextContent('rls denied'),
    );
    // Still in edit mode.
    expect(screen.getByRole('button', { name: 'Save changes' })).toBeInTheDocument();
    expect(retry).not.toHaveBeenCalled();
  });
});

describe('SettingsScreen — pricing defaults edit', () => {
  it('saves numeric pricing fields via saveSettings and refreshes', async () => {
    render(<SettingsScreen />);
    await openSection('Pricing defaults');

    const laborInput = screen.getByDisplayValue('90');
    await userEvent.clear(laborInput);
    await userEvent.type(laborInput, '120');
    await userEvent.click(screen.getByRole('button', { name: 'Save changes' }));

    await waitFor(() => expect(writes.saveSettings).toHaveBeenCalledTimes(1));
    expect(writes.saveSettings.mock.calls[0][0]).toMatchObject({
      laborRate: 120,
      materialMarkup: 20,
      marginPercent: 15,
      mileageRate: 0.7,
    });
    expect(retry).toHaveBeenCalledWith(['settings']);
  });

  it('rejects an invalid number without calling saveSettings', async () => {
    render(<SettingsScreen />);
    await openSection('Pricing defaults');

    const laborInput = screen.getByDisplayValue('90');
    await userEvent.clear(laborInput);
    // A `type="number"` input yields an empty value for non-numeric text, which
    // our parser treats as invalid.
    await userEvent.click(screen.getByRole('button', { name: 'Save changes' }));

    await waitFor(() =>
      expect(screen.getByRole('alert')).toHaveTextContent(/non-negative number/i),
    );
    expect(writes.saveSettings).not.toHaveBeenCalled();
    expect(retry).not.toHaveBeenCalled();
  });
});

describe('SettingsScreen — invoicing edit', () => {
  it('saves prefix, start number, and auto flags', async () => {
    render(<SettingsScreen />);
    await openSection('Invoicing');

    const prefixInput = screen.getByDisplayValue('INV');
    await userEvent.clear(prefixInput);
    await userEvent.type(prefixInput, 'ACM');
    await userEvent.click(
      screen.getByRole('checkbox', { name: /auto-create invoice/i }),
    );
    await userEvent.click(screen.getByRole('button', { name: 'Save changes' }));

    await waitFor(() => expect(writes.saveSettings).toHaveBeenCalledTimes(1));
    expect(writes.saveSettings.mock.calls[0][0]).toMatchObject({
      invoicePrefix: 'ACM',
      invoiceStartNumber: 100,
      autoInvoiceOnComplete: true,
    });
    expect(retry).toHaveBeenCalledWith(['settings']);
  });

  it('forces auto-email off when auto-create is off', async () => {
    store.settings = {
      ...settings(),
      autoInvoiceOnComplete: true,
      autoEmailInvoiceOnComplete: true,
    } as Settings;
    render(<SettingsScreen />);
    await openSection('Invoicing');

    // Turn auto-create off; auto-email must not be sent as true.
    await userEvent.click(
      screen.getByRole('checkbox', { name: /auto-create invoice/i }),
    );
    await userEvent.click(screen.getByRole('button', { name: 'Save changes' }));

    await waitFor(() => expect(writes.saveSettings).toHaveBeenCalledTimes(1));
    expect(writes.saveSettings.mock.calls[0][0]).toMatchObject({
      autoInvoiceOnComplete: false,
      autoEmailInvoiceOnComplete: false,
    });
  });

  it('clears the start number when left blank', async () => {
    render(<SettingsScreen />);
    await openSection('Invoicing');

    await userEvent.clear(screen.getByDisplayValue('100'));
    await userEvent.click(screen.getByRole('button', { name: 'Save changes' }));

    await waitFor(() => expect(writes.saveSettings).toHaveBeenCalledTimes(1));
    expect(writes.saveSettings.mock.calls[0][0]).toHaveProperty(
      'invoiceStartNumber',
      undefined,
    );
  });
});

describe('SettingsScreen — automation edit', () => {
  it('saves the five automation flags as explicit booleans', async () => {
    render(<SettingsScreen />);
    await openSection('Automation');

    await userEvent.click(
      screen.getByRole('checkbox', { name: /review requests/i }),
    );
    await userEvent.click(screen.getByRole('button', { name: 'Save changes' }));

    await waitFor(() => expect(writes.saveSettings).toHaveBeenCalledTimes(1));
    expect(writes.saveSettings.mock.calls[0][0]).toMatchObject({
      autoOutreachEnabled: false,
      autoSendEmailEnabled: false,
      appointmentRemindersEnabled: false,
      estimateFollowUpsEnabled: true,
      reviewRequestEnabled: true,
    });
    expect(retry).toHaveBeenCalledWith(['settings']);
  });

  it('treats an absent estimateFollowUpsEnabled as ON (reverse convention)', async () => {
    // A settings blob predating the field: the flag is absent entirely.
    store.settings = { businessName: 'Acme Plumbing' } as Settings;
    render(<SettingsScreen />);
    await openSection('Automation');

    const followUps = screen.getByRole('checkbox', {
      name: /estimate follow-up/i,
    });
    expect(followUps).toBeChecked();

    // Saving without touching it must persist the default-on state explicitly.
    await userEvent.click(screen.getByRole('button', { name: 'Save changes' }));
    await waitFor(() => expect(writes.saveSettings).toHaveBeenCalledTimes(1));
    expect(writes.saveSettings.mock.calls[0][0]).toMatchObject({
      estimateFollowUpsEnabled: true,
    });
  });

  it('persists estimate follow-ups OFF when unchecked', async () => {
    store.settings = {
      ...settings(),
      estimateFollowUpsEnabled: true,
    } as Settings;
    render(<SettingsScreen />);
    await openSection('Automation');

    await userEvent.click(
      screen.getByRole('checkbox', { name: /estimate follow-up/i }),
    );
    await userEvent.click(screen.getByRole('button', { name: 'Save changes' }));

    await waitFor(() => expect(writes.saveSettings).toHaveBeenCalledTimes(1));
    expect(writes.saveSettings.mock.calls[0][0]).toMatchObject({
      estimateFollowUpsEnabled: false,
    });
  });
});

describe('SettingsScreen — payments edit', () => {
  it('saves trimmed payment notes and keeps the processor read-only', async () => {
    store.settings = { ...settings(), provider: 'stripe' } as Settings;
    render(<SettingsScreen />);
    await openSection('Payments');

    // Provider stays visible but has no input — only notes are editable.
    expect(screen.getByText('stripe')).toBeInTheDocument();
    const notes = screen.getByLabelText('Payment notes');
    await userEvent.type(notes, '  Checks payable to Acme  ');
    await userEvent.click(screen.getByRole('button', { name: 'Save changes' }));

    await waitFor(() => expect(writes.saveSettings).toHaveBeenCalledTimes(1));
    expect(writes.saveSettings.mock.calls[0][0]).toEqual({
      paymentNotes: 'Checks payable to Acme',
    });
    expect(retry).toHaveBeenCalledWith(['settings']);
  });

  it('surfaces a save error without closing the form', async () => {
    writes.saveSettings.mockRejectedValue(new Error('rls denied'));
    render(<SettingsScreen />);
    await openSection('Payments');
    await userEvent.click(screen.getByRole('button', { name: 'Save changes' }));

    await waitFor(() =>
      expect(screen.getByRole('alert')).toHaveTextContent('rls denied'),
    );
    expect(screen.getByRole('button', { name: 'Save changes' })).toBeInTheDocument();
    expect(retry).not.toHaveBeenCalled();
  });
});

describe('SettingsScreen — schedule edit', () => {
  it('saves work pattern via saveSchedule and refreshes', async () => {
    render(<SettingsScreen />);
    await openSection('Schedule');

    // Absent schedule → resolved defaults: Mon–Sat selected, Sunday off.
    await userEvent.click(screen.getByRole('button', { name: 'Sunday' }));
    await userEvent.click(screen.getByRole('button', { name: 'Save changes' }));

    await waitFor(() => expect(writes.saveSchedule).toHaveBeenCalledTimes(1));
    const patch = writes.saveSchedule.mock.calls[0][0];
    expect(patch).toMatchObject({
      workDays: [1, 2, 3, 4, 5, 6, 7],
      workDayStart: '08:00',
      workDayEnd: '17:00',
      defaultDurationMinutes: 60,
      bufferMinutes: 0,
      blackouts: [],
    });
    expect(retry).toHaveBeenCalledWith(['settings']);
    // Schedule uses the dedicated nested-merge op, never the flat one.
    expect(writes.saveSettings).not.toHaveBeenCalled();
  });

  it('rejects a start that is not before the end', async () => {
    render(<SettingsScreen />);
    await openSection('Schedule');

    const start = screen.getByDisplayValue('08:00');
    await userEvent.clear(start);
    await userEvent.type(start, '18:00');
    await userEvent.click(screen.getByRole('button', { name: 'Save changes' }));

    await waitFor(() =>
      expect(screen.getByRole('alert')).toHaveTextContent(/start before it ends/i),
    );
    expect(writes.saveSchedule).not.toHaveBeenCalled();
    expect(retry).not.toHaveBeenCalled();
  });

  it('rejects deselecting every working day', async () => {
    render(<SettingsScreen />);
    await openSection('Schedule');

    for (const name of ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday']) {
      await userEvent.click(screen.getByRole('button', { name }));
    }
    await userEvent.click(screen.getByRole('button', { name: 'Save changes' }));

    await waitFor(() =>
      expect(screen.getByRole('alert')).toHaveTextContent(/at least one working day/i),
    );
    expect(writes.saveSchedule).not.toHaveBeenCalled();
  });

  it('adds and persists a time-off blackout', async () => {
    render(<SettingsScreen />);
    await openSection('Schedule');

    const [firstDay, lastDay] = screen.getAllByDisplayValue(/^\d{4}-\d{2}-\d{2}$/);
    await userEvent.clear(firstDay);
    await userEvent.type(firstDay, '2026-12-24');
    await userEvent.clear(lastDay);
    await userEvent.type(lastDay, '2026-12-26');
    await userEvent.type(screen.getByLabelText('Reason (optional)'), 'Holiday');
    await userEvent.click(screen.getByRole('button', { name: 'Add time off' }));

    // The added period shows in the list, then persists on save.
    expect(screen.getByText('Holiday')).toBeInTheDocument();
    await userEvent.click(screen.getByRole('button', { name: 'Save changes' }));

    await waitFor(() => expect(writes.saveSchedule).toHaveBeenCalledTimes(1));
    const patch = writes.saveSchedule.mock.calls[0][0];
    expect(patch.blackouts).toHaveLength(1);
    expect(patch.blackouts[0]).toMatchObject({
      start: '2026-12-24',
      end: '2026-12-26',
      reason: 'Holiday',
    });
  });
});
