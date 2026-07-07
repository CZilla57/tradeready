// utils/moneyUtils.js
// Pure helpers and constants for the Money tab — no UI, no side effects, fully testable.

export const EXPENSE_CATEGORIES = [
  { id: 'materials', label: 'Materials',        icon: '🪵' },
  { id: 'tools',     label: 'Tools & Equipment', icon: '🔧' },
  { id: 'fuel',      label: 'Fuel & Transport',  icon: '⛽' },
  { id: 'labor',     label: 'Subcontractors',    icon: '👷' },
  { id: 'insurance', label: 'Insurance',         icon: '🛡️' },
  { id: 'software',  label: 'Software & Apps',   icon: '💻' },
  { id: 'marketing', label: 'Marketing',         icon: '📣' },
  { id: 'other',     label: 'Other',             icon: '📦' },
];

export const DATE_FILTERS = [
  { id: 'this_month', label: 'This Month' },
  { id: 'last_month', label: 'Last Month' },
  { id: 'this_year',  label: 'This Year'  },
  { id: 'all_time',   label: 'All Time'   },
];

// Get start/end Date objects for a filter period
export function getDateRange(filterId) {
  const now = new Date();
  const year = now.getFullYear();
  const month = now.getMonth();

  switch (filterId) {
    case 'this_month':
      return {
        start: new Date(year, month, 1),
        end:   new Date(year, month + 1, 0, 23, 59, 59),
      };
    case 'last_month':
      return {
        start: new Date(year, month - 1, 1),
        end:   new Date(year, month, 0, 23, 59, 59),
      };
    case 'this_year':
      return {
        start: new Date(year, 0, 1),
        end:   new Date(year, 11, 31, 23, 59, 59),
      };
    case 'all_time':
    default:
      return { start: new Date(0), end: new Date(9999, 11, 31) };
  }
}

// Get the comparison period immediately before the active filter (for MoM/YoY badges).
// Returns null for 'all_time' (no meaningful previous period).
export function getPreviousRange(filterId) {
  const now = new Date();
  const year = now.getFullYear();
  const month = now.getMonth();
  switch (filterId) {
    case 'this_month':
      return { start: new Date(year, month - 1, 1), end: new Date(year, month, 0, 23, 59, 59) };
    case 'last_month':
      return { start: new Date(year, month - 2, 1), end: new Date(year, month - 1, 0, 23, 59, 59) };
    case 'this_year':
      return { start: new Date(year - 1, 0, 1), end: new Date(year - 1, 11, 31, 23, 59, 59) };
    default:
      return null;
  }
}

// Check whether a date string falls within [start, end]
export function isInRange(dateString, start, end) {
  const d = new Date(dateString);
  return d >= start && d <= end;
}

// Returns the last 6 calendar months as { label, year, month } objects, oldest first
export function getLast6MonthLabels() {
  const monthNames = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
  const now = new Date();
  const result = [];
  for (let i = 5; i >= 0; i--) {
    const d = new Date(now.getFullYear(), now.getMonth() - i, 1);
    result.push({ label: monthNames[d.getMonth()], year: d.getFullYear(), month: d.getMonth() });
  }
  return result;
}

// Generate a unique ID for a new expense record
export function generateExpenseId() {
  return Date.now().toString() + Math.random().toString(36).substr(2, 5);
}
