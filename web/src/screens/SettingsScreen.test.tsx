import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import type { Settings } from '@shared/types/models';
import SettingsScreen from './SettingsScreen';

const writes = vi.hoisted(() => ({ saveSettings: vi.fn() }));
vi.mock('../lib/writeRepository', () => writes);

const retry = vi.hoisted(() => vi.fn());
const store = vi.hoisted(() => ({ settings: null as Settings | null }));
vi.mock('../lib/DataContext', () => ({
  useData: () => ({ settings: store.settings, retry }),
  useResources: () => ({ loading: false, error: null, refreshing: false, retry }),
}));

function settings(): Settings {
  return { businessName: 'Acme Plumbing', phone: '555' } as Settings;
}

beforeEach(() => {
  writes.saveSettings.mockReset().mockResolvedValue(settings());
  retry.mockReset();
  store.settings = settings();
});

describe('SettingsScreen — business profile edit', () => {
  it('saves profile fields via saveSettings and refreshes', async () => {
    render(<SettingsScreen />);
    await userEvent.click(screen.getByRole('button', { name: 'Edit' }));

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
    await userEvent.click(screen.getByRole('button', { name: 'Edit' }));
    await userEvent.click(screen.getByRole('button', { name: 'Save changes' }));

    await waitFor(() =>
      expect(screen.getByRole('alert')).toHaveTextContent('rls denied'),
    );
    // Still in edit mode.
    expect(screen.getByRole('button', { name: 'Save changes' })).toBeInTheDocument();
    expect(retry).not.toHaveBeenCalled();
  });
});
