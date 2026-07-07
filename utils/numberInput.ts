// utils/numberInput.ts
// Parsing for numeric form fields. The app is full of `parseFloat(x) || default`,
// which is subtly wrong: a legitimately-entered 0 is falsy, so it gets replaced
// by the default (e.g. you couldn't set 0% overhead/margin). parseNumberInput
// only falls back when the value is genuinely absent or unparseable — a real 0
// is kept.

export function parseNumberInput(
  value: string | number | null | undefined,
  fallback: number,
): number {
  const n = parseFloat(String(value ?? ""));
  return Number.isNaN(n) ? fallback : n;
}
