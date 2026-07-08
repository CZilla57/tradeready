import type { ExpenseCategoryId } from '../types/models';

export interface ExpenseCategory {
  id: ExpenseCategoryId;
  label: string;
  icon: string;
}

export interface DateFilter {
  id: 'this_month' | 'last_month' | 'this_year' | 'all_time';
  label: string;
}

export interface DateRange {
  start: Date;
  end: Date;
}

export interface MonthLabel {
  label: string;
  year: number;
  month: number;
}

export const EXPENSE_CATEGORIES: ExpenseCategory[] = [
  { id: 'materials', label: 'Materials',         icon: '🪵' },
  { id: 'tools',     label: 'Tools & Equipment', icon: '🔧' },
  { id: 'fuel',      label: 'Fuel & Transport',  icon: '⛽' },
  { id: 'labor',     label: 'Subcontractors',    icon: '👷' },
  { id: 'insurance', label: 'Insurance',         icon: '🛡️' },
  { id: 'software',  label: 'Software & Apps',   icon: '💻' },
  { id: 'marketing', label: 'Marketing',         icon: '📣' },
  { id: 'other',     label: 'Other',             icon: '📦' },
];

export const DATE_FILTERS: DateFilter[] = [
  { id: 'this_month', label: 'This Month' },
  { id: 'last_month', label: 'Last Month' },
  { id: 'this_year',  label: 'This Year'  },
  { id: 'all_time',   label: 'All Time'   },
];

export function getDateRange(filterId: string): DateRange {
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

export function getPreviousRange(filterId: string): DateRange | null {
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

/**
 * Parse a stored date string as LOCAL time.
 *
 * A bare "YYYY-MM-DD" is treated as LOCAL midnight. `new Date("YYYY-MM-DD")`
 * parses it as UTC midnight, which — in timezones west of UTC — lands on the
 * previous local day and shifts a record just outside its reporting period.
 * The date ranges it is compared against (getDateRange / getPreviousRange) are
 * built with the local-time `new Date(year, month, day)` constructor, so both
 * sides must be local for the comparison to be sound. Strings that carry a time
 * component fall through to the platform parser (already local when no `Z`).
 */
function parseLocalDate(dateString: string): Date {
  const dateOnly = /^(\d{4})-(\d{2})-(\d{2})$/.exec(dateString);
  if (dateOnly) {
    return new Date(Number(dateOnly[1]), Number(dateOnly[2]) - 1, Number(dateOnly[3]));
  }
  return new Date(dateString);
}

export function isInRange(dateString: string, start: Date, end: Date): boolean {
  const d = parseLocalDate(dateString);
  return d >= start && d <= end;
}

export function getLast6MonthLabels(): MonthLabel[] {
  const monthNames = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
  const now = new Date();
  const result: MonthLabel[] = [];
  for (let i = 5; i >= 0; i--) {
    const d = new Date(now.getFullYear(), now.getMonth() - i, 1);
    result.push({ label: monthNames[d.getMonth()], year: d.getFullYear(), month: d.getMonth() });
  }
  return result;
}

export function generateExpenseId(): string {
  return Date.now().toString() + Math.random().toString(36).substr(2, 5);
}
