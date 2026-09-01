import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter } from 'react-router-dom';
import type { PricebookEntry, Settings } from '@shared/types/models';
import PricebookScreen from './PricebookScreen';

const writes = vi.hoisted(() => ({ createPricebookEntry: vi.fn() }));
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

function renderScreen() {
  return render(
    <MemoryRouter>
      <PricebookScreen />
    </MemoryRouter>,
  );
}

beforeEach(() => {
  writes.createPricebookEntry
    .mockReset()
    .mockResolvedValue({ id: 'pb-new' } as PricebookEntry);
  navigate.mockReset();
  retry.mockReset();
  store.pricebook = [];
  store.settings = { minimumJobFee: 0 } as Settings;
});

describe('PricebookScreen — create', () => {
  it('creates a service, recomputes the total via the port, and navigates', async () => {
    renderScreen();
    await userEvent.click(screen.getByRole('button', { name: 'New service' }));

    await userEvent.type(screen.getByLabelText('Name'), 'Heater flush');
    // Defaults: laborHours 1, laborRate 85, markup 20, overhead 15, margin 20.
    // Set rate 100 → labor 100; overhead 15% → 115; margin 20% → 115/0.8 = 143.75.
    const rate = screen.getByLabelText('Labor rate ($/hr)');
    await userEvent.clear(rate);
    await userEvent.type(rate, '100');
    await userEvent.click(screen.getByRole('button', { name: 'Create service' }));

    await waitFor(() => expect(writes.createPricebookEntry).toHaveBeenCalledTimes(1));
    expect(writes.createPricebookEntry.mock.calls[0][0]).toMatchObject({
      name: 'Heater flush',
      laborRate: 100,
      estimateTotal: 143.75,
    });
    expect(navigate).toHaveBeenCalledWith('/pricebook/pb-new');
  });

  it('authors a material on create and includes it in the recompute', async () => {
    renderScreen();
    await userEvent.click(screen.getByRole('button', { name: 'New service' }));
    await userEvent.type(screen.getByLabelText('Name'), 'Heater flush');

    await userEvent.click(screen.getByRole('button', { name: '+ Add material' }));
    await userEvent.type(screen.getByLabelText('Material name'), 'Anode rod');
    const cost = screen.getByLabelText('Material unit cost');
    await userEvent.clear(cost);
    await userEvent.type(cost, '40'); // qty defaults to 1
    await userEvent.click(screen.getByRole('button', { name: 'Create service' }));

    await waitFor(() => expect(writes.createPricebookEntry).toHaveBeenCalledTimes(1));
    const arg = writes.createPricebookEntry.mock.calls[0][0];
    expect(arg.materials).toHaveLength(1);
    expect(arg.materials[0]).toMatchObject({ name: 'Anode rod', quantity: 1, unitCost: 40 });
    // Materials contribute to the derived total (defaults: labor 1×85=85,
    // materials 40×1.20=48 → subtotal 133, so the total exceeds the no-material one).
    expect(arg.estimateTotal).toBeGreaterThan(143.75);
  });

  it('requires a name', async () => {
    renderScreen();
    await userEvent.click(screen.getByRole('button', { name: 'New service' }));
    await userEvent.click(screen.getByRole('button', { name: 'Create service' }));

    expect(screen.getByRole('alert')).toHaveTextContent(/name/i);
    expect(writes.createPricebookEntry).not.toHaveBeenCalled();
  });

  it('rejects a blank pricing field', async () => {
    renderScreen();
    await userEvent.click(screen.getByRole('button', { name: 'New service' }));
    await userEvent.type(screen.getByLabelText('Name'), 'X');
    await userEvent.clear(screen.getByLabelText('Labor hours'));
    await userEvent.click(screen.getByRole('button', { name: 'Create service' }));

    expect(screen.getByRole('alert')).toHaveTextContent(/non-negative number/i);
    expect(writes.createPricebookEntry).not.toHaveBeenCalled();
  });

  it('surfaces a write error and keeps the form open', async () => {
    writes.createPricebookEntry.mockRejectedValue(new Error('rls denied'));
    renderScreen();
    await userEvent.click(screen.getByRole('button', { name: 'New service' }));
    await userEvent.type(screen.getByLabelText('Name'), 'X');
    await userEvent.click(screen.getByRole('button', { name: 'Create service' }));

    await waitFor(() =>
      expect(screen.getByRole('alert')).toHaveTextContent('rls denied'),
    );
    expect(screen.getByRole('button', { name: 'Create service' })).toBeInTheDocument();
    expect(navigate).not.toHaveBeenCalled();
  });
});
