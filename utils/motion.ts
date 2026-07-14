// Central policy for honoring the OS "reduce motion" accessibility setting.
// Components read the flag via useReduceMotion() and feed it through
// animationDuration() so animations collapse to an instant jump for users
// who have vestibular-motion sensitivity.

import { useEffect, useState } from "react";
import { AccessibilityInfo } from "react-native";

export function animationDuration(reduceMotion: boolean, normalMs: number): number {
  return reduceMotion ? 0 : normalMs;
}

export function useReduceMotion(): boolean {
  const [reduceMotion, setReduceMotion] = useState(false);

  useEffect(() => {
    let mounted = true;
    // Optional-chained: older RN jest presets don't stub this method.
    AccessibilityInfo.isReduceMotionEnabled?.()
      .then((enabled) => { if (mounted) setReduceMotion(!!enabled); })
      .catch(() => {});
    const sub = AccessibilityInfo.addEventListener?.("reduceMotionChanged", (enabled) => {
      setReduceMotion(!!enabled);
    });
    return () => {
      mounted = false;
      sub?.remove?.();
    };
  }, []);

  return reduceMotion;
}
