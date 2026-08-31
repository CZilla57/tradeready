import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter, Routes, Route } from 'react-router-dom';
import type { PricebookEntry } from '@shared/types/models';
import PricebookDetailScreen from './PricebookDetailScreen';

const writes = vi.hoisted(() => ({
  savePricebookEntry: vi.fn(),
  deletePricebookEntry: vi.fn(),
}));
vi.mock('../lib/writeRepository', () => writes);

const navigate = vi.hoisted(() => vi.fn());
vi.mock('react-router-dom', async (importOriginal) => ({
  ...(await importOriginal<typeof import('react-router-dom')>()),
  useNavigate: () => navigate,
}));

const retry = vi.hoisted(() => vi.fn());
const store = vi.hoisted(() => ({ pricebook: [] as PricebookEntry[] }));
vi.mock('../lib/DataContext', () => ({
  useData: () => ({ pricebook: store.pricebook, retry }),
  useResources: () => ({ loading: false, error: null, refreshing: false, retry }),
}));

function entry(over: Partial<PricebookEntry> = {}): PricebookEntry {
  return {
    id: 'pb1',
    name: 'Drain clear',
    category: 'Plumbing',
    description: '',
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

function renderScreen() {
  return render(
    <MemoryRouter initialEntries={['/pricebook/pb1']}>
      <Routes>
        <Route path="/pricebook/:id" element={<PricebookDetailScreen />} />
      </Routes>
    </MemoryRouter>,
  );
}

beforeEach(() => {
  writes.savePricebookEntry.mockReset().mockResolvedValue(entry());
  writes.deletePricebookEntry.mockReset().mockResolvedValue(undefined);
  retry.mockReset();
  navigate.mockReset();
  store.pricebook = [entry()];
});

describe('PricebookDetailScreen — edit', () => {
  it('saves metadata edits via savePricebookEntry and refreshes', async () => {
    renderScreen();
    await userEvent.click(screen.getByRole('button', { name: 'Edit service' }));
    const nameInput = screen.getByDisplayValue('Drain clear');
    await userEvent.clear(nameInput);
    await userEvent.type(nameInput, 'Drain clearing');
    await userEvent.click(screen.getByRole('button', { name: 'Save changes' }));

    await waitFor(() => expect(writes.savePricebookEntry).toHaveBeenCalledTimes(1));
    expect(writes.savePricebookEntry.mock.calls[0][0]).toMatchObject({
      id: 'pb1',
      name: 'Drain clearing',
    });
    expect(retry).toHaveBeenCalledWith(['pricebook']);
  });

  it('requires a name', async () => {
    renderScreen();
    await userEvent.click(screen.getByRole('button', { name: 'Edit service' }));
    await userEvent.clear(screen.getByDisplayValue('Drain clear'));
    await userEvent.click(screen.getByRole('button', { name: 'Save changes' }));

    expect(screen.getByRole('alert')).toHaveTextContent(/name is required/i);
    expect(writes.savePricebookEntry).not.toHaveBeenCalled();
  });

  it('deletes after confirmation and navigates to the list', async () => {
    renderScreen();
    await userEvent.click(screen.getByRole('button', { name: 'Edit service' }));
    await userEvent.click(screen.getByRole('button', { name: 'Delete service' }));
    await userEvent.click(screen.getByRole('button', { name: 'Delete' }));

    await waitFor(() =>
      expect(writes.deletePricebookEntry).toHaveBeenCalledWith('pb1'),
    );
    expect(navigate).toHaveBeenCalledWith('/pricebook');
  });
});
