// Mirrors utils/changeOrders.ts status + total math for change-view's context
// totals. backend/ is a separate CommonJS package, so this is a deliberate
// mirror — kept honest by __tests__/changeOrderParity.test.js. If you change
// one side, change both.

function roundToCents(n) {
  return Math.round(n * 100) / 100;
}

function changeOrderStatus(co) {
  if (co.cancelledAt) return 'cancelled';
  const decision = (co.approval && co.approval.decision) || (co.manualDecision && co.manualDecision.decision);
  if (decision === 'approved') return 'approved';
  if (decision === 'declined') return 'declined';
  if (co.approval) return 'awaiting';
  return 'pending';
}

function approvedChangeOrderTotal(changeOrders) {
  const list = Array.isArray(changeOrders) ? changeOrders : [];
  return roundToCents(list.reduce(
    (sum, co) => (changeOrderStatus(co) === 'approved' ? sum + (co.amount || 0) : sum),
    0,
  ));
}

// Context totals for the customer page: "Original" is the job's billable
// total EXCLUDING this CO (estimateTotal + other approved COs), computed
// LIVE so multi-CO jobs show truthful numbers. Returns null when the CO
// isn't on the job.
function billableContext(jobData, changeOrderId) {
  const list = Array.isArray(jobData.changeOrders) ? jobData.changeOrders : [];
  const co = list.find((c) => c && c.id === changeOrderId);
  if (!co) return null;
  const others = list.filter((c) => c && c.id !== changeOrderId);
  const originalTotal = roundToCents((jobData.estimateTotal || 0) + approvedChangeOrderTotal(others));
  return {
    originalTotal,
    changeAmount: co.amount || 0,
    newTotal: roundToCents(originalTotal + (co.amount || 0)),
  };
}

module.exports = { changeOrderStatus, approvedChangeOrderTotal, billableContext };
