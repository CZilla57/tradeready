// Detecting a live text-size (fontScale) change. RN repaints text at the new
// scale but does not re-measure existing layout — headers chop, siblings stay
// unscaled (device-verified 2026-07-14; a restart renders correctly). The
// FontScaleWatcher in App.tsx uses this to offer that restart.

const EPSILON = 0.001;

export function fontScaleChanged(
  initial: number | undefined,
  current: number | undefined
): boolean {
  if (typeof initial !== "number" || typeof current !== "number") return false;
  return Math.abs(current - initial) > EPSILON;
}
