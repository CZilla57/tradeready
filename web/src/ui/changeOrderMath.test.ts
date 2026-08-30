import { describe, it, expect } from 'vitest';
import type {
  ChangeOrder,
  ChangeOrderDecision,
  EstimateApproval,
  Job,
} from '@shared/types/models';
import {
  changeOrderStatus,
  approvedChangeOrderTotal,
  jobBillableTotal,
} from './changeOrderMath';

function co(partial: Partial<ChangeOrder> = {}): ChangeOrder {
  return {
    id: 'co1',
    title: 'Extra work',
    amount: 0,
    createdAt: '2026-08-01',
    ...partial,
  };
}

// Only the `.decision` field is read by the math under test — the rest of these
// server/device-owned records is irrelevant here, so keep the fixtures minimal.
function approval(decision?: 'approved' | 'declined'): EstimateApproval {
  return { decision } as unknown as EstimateApproval;
}
function manual(decision: 'approved' | 'declined'): ChangeOrderDecision {
  return { decision } as unknown as ChangeOrderDecision;
}

describe('changeOrderStatus', () => {
  it('is cancelled when cancelledAt is set (regardless of decision)', () => {
    expect(
      changeOrderStatus(
        co({ cancelledAt: '2026-08-02', manualDecision: manual('approved') }),
      ),
    ).toBe('cancelled');
  });
  it('reads an approved manual decision', () => {
    expect(changeOrderStatus(co({ manualDecision: manual('approved') }))).toBe(
      'approved',
    );
  });
  it('reads a declined server approval', () => {
    expect(
      changeOrderStatus(co({ approval: approval('declined') })),
    ).toBe('declined');
  });
  it('is awaiting when a link approval exists with no decision yet', () => {
    expect(changeOrderStatus(co({ approval: approval() }))).toBe('awaiting');
  });
  it('is pending with no approval and no decision', () => {
    expect(changeOrderStatus(co())).toBe('pending');
  });
});

describe('approvedChangeOrderTotal', () => {
  it('sums only approved change orders and rounds to cents', () => {
    const job: Pick<Job, 'changeOrders'> = {
      changeOrders: [
        co({ id: 'a', amount: 33.333, manualDecision: manual('approved') }),
        co({ id: 'b', amount: 50, approval: approval('declined') }),
        co({ id: 'c', amount: 25 }), // pending
        co({ id: 'd', amount: 200, cancelledAt: '2026-08-03', manualDecision: manual('approved') }),
      ],
    };
    // Only 'a' counts; rounded to cents.
    expect(approvedChangeOrderTotal(job)).toBe(33.33);
  });
  it('is zero with no change orders', () => {
    expect(approvedChangeOrderTotal({ changeOrders: undefined })).toBe(0);
  });
});

describe('jobBillableTotal', () => {
  it('adds the estimate total to approved change orders', () => {
    const job: Pick<Job, 'estimateTotal' | 'changeOrders'> = {
      estimateTotal: 1000,
      changeOrders: [
        co({ id: 'a', amount: 250, approval: approval('approved') }),
        co({ id: 'b', amount: -100, manualDecision: manual('approved') }),
      ],
    };
    // 1000 + 250 - 100 = 1150
    expect(jobBillableTotal(job)).toBe(1150);
  });
  it('is just the estimate when there are no approved change orders', () => {
    expect(jobBillableTotal({ estimateTotal: 500, changeOrders: [] })).toBe(500);
  });
});
