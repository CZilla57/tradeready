import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter, Routes, Route } from 'react-router-dom';
import type { PricebookEntry, Settings } from '@shared/types/models';
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
const store = vi.hoisted(() => ({
  pricebook: [] as PricebookEntry[],
  settings: { minimumJobFee: 0 } as Settings,
}));
vi.mock('../lib/DataContext', () => ({
  useData: () => ({ pricebook: store.pricebook, settings: store.settings, retry }),
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

  it('recomputes estimateTotal from edited pricing inputs', async () => {
    renderScreen();
    await userEvent.click(screen.getByRole('button', { name: 'Edit service' }));

    const rate = screen.getByDisplayValue('90');
    await userEvent.clear(rate);
    await userEvent.type(rate, '100');
    await userEvent.click(screen.getByRole('button', { name: 'Save changes' }));

    await waitFor(() => expect(writes.savePricebookEntry).toHaveBeenCalledTimes(1));
    // labor 2×100=200; overhead 10% → 220; margin 20% → 220/0.8 = 275.
    expect(writes.savePricebookEntry.mock.calls[0][0]).toMatchObject({
      laborRate: 100,
      estimateTotal: 275,
    });
  });

  it('rejects a blank pricing field', async () => {
    renderScreen();
    await userEvent.click(screen.getByRole('button', { name: 'Edit service' }));
    await userEvent.clear(screen.getByDisplayValue('90')); // labor rate
    await userEvent.click(screen.getByRole('button', { name: 'Save changes' }));

    expect(screen.getByRole('alert')).toHaveTextContent(/non-negative number/i);
    expect(writes.savePricebookEntry).not.toHaveBeenCalled();
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

describe('PricebookDetailScreen — materials editing', () => {
  it('seeds the editor from stored materials', async () => {
    store.pricebook = [
      entry({ materials: [{ id: 'm1', name: 'Filter', quantity: 1, unitCost: 20 }] }),
    ];
    renderScreen();
    await userEvent.click(screen.getByRole('button', { name: 'Edit service' }));
    expect(screen.getByDisplayValue('Filter')).toBeInTheDocument();
  });

  it('adds a material, recomputes the total, and writes it', async () => {
    renderScreen(); // entry() has no materials, laborRate 90, minimumJobFee 0
    await userEvent.click(screen.getByRole('button', { name: 'Edit service' }));

    await userEvent.click(screen.getByRole('button', { name: '+ Add material' }));
    await userEvent.type(screen.getByLabelText('Material name'), 'Copper pipe');
    const qty = screen.getByLabelText('Material quantity');
    await userEvent.clear(qty);
    await userEvent.type(qty, '2');
    const cost = screen.getByLabelText('Material unit cost');
    await userEvent.clear(cost);
    await userEvent.type(cost, '10');
    await userEvent.click(screen.getByRole('button', { name: 'Save changes' }));

    await waitFor(() => expect(writes.savePricebookEntry).toHaveBeenCalledTimes(1));
    const arg = writes.savePricebookEntry.mock.calls[0][0];
    expect(arg.materials).toHaveLength(1);
    expect(arg.materials[0]).toMatchObject({ name: 'Copper pipe', quantity: 2, unitCost: 10 });
    // labor 2×90=180; materials 2×10=20 ×1.15=23; subtotal 203; overhead 10% → 223.3;
    // margin 20% → 223.3/0.8 = 279.125 → 279.13.
    expect(arg.estimateTotal).toBeCloseTo(279.13, 2);
  });

  it('removes a material on Remove', async () => {
    store.pricebook = [
      entry({ materials: [{ id: 'm1', name: 'Filter', quantity: 1, unitCost: 20 }] }),
    ];
    renderScreen();
    await userEvent.click(screen.getByRole('button', { name: 'Edit service' }));
    await userEvent.click(screen.getByRole('button', { name: /Remove Filter/i }));
    await userEvent.click(screen.getByRole('button', { name: 'Save changes' }));

    await waitFor(() => expect(writes.savePricebookEntry).toHaveBeenCalledTimes(1));
    expect(writes.savePricebookEntry.mock.calls[0][0].materials).toEqual([]);
  });

  it('rejects a material row with no name', async () => {
    renderScreen();
    await userEvent.click(screen.getByRole('button', { name: 'Edit service' }));
    await userEvent.click(screen.getByRole('button', { name: '+ Add material' }));
    // Row added with default qty 1 / cost 0 but no name → not abandoned, invalid.
    await userEvent.click(screen.getByRole('button', { name: 'Save changes' }));

    expect(screen.getByRole('alert')).toHaveTextContent(/every material needs a name/i);
    expect(writes.savePricebookEntry).not.toHaveBeenCalled();
  });
});
