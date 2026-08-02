// context/UndoContext.tsx
// Global undo snackbar for deletes: showUndo("Job deleted", restoreFn) surfaces
// a bottom snackbar with an UNDO button for a few seconds. Delete sites still
// confirm first (the dialog guards intent; the snackbar guards regret), and the
// restore fn re-saves the deleted record through the normal save path, so the
// restoration syncs like any other edit. Mounted once in App.tsx next to the
// other overlay chrome (SyncBanner) — the snackbar overlays every screen.

import React, { createContext, useCallback, useContext, useEffect, useRef, useState } from "react";
import { Animated, StyleSheet, Text, TouchableOpacity } from "react-native";
import { useSafeAreaInsets } from "react-native-safe-area-context";
import { useThemeContext } from "./ThemeContext";
import { animationDuration, useReduceMotion } from "../utils/motion";
import { fonts } from "../utils/theme";

export const UNDO_WINDOW_MS = 6000;

interface UndoRequest {
  id: number;
  message: string;
  onUndo: () => void | Promise<void>;
}

interface UndoContextValue {
  showUndo: (message: string, onUndo: () => void | Promise<void>) => void;
}

const UndoContext = createContext<UndoContextValue>({ showUndo: () => {} });

export function useUndo(): UndoContextValue {
  return useContext(UndoContext);
}

export function UndoProvider({ children }: { children: React.ReactNode }) {
  const [request, setRequest] = useState<UndoRequest | null>(null);
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const nextId = useRef(0);

  const dismiss = useCallback(() => {
    if (timerRef.current) { clearTimeout(timerRef.current); timerRef.current = null; }
    setRequest(null);
  }, []);

  const showUndo = useCallback((message: string, onUndo: () => void | Promise<void>) => {
    if (timerRef.current) clearTimeout(timerRef.current);
    nextId.current += 1;
    setRequest({ id: nextId.current, message, onUndo });
    timerRef.current = setTimeout(() => {
      timerRef.current = null;
      setRequest(null);
    }, UNDO_WINDOW_MS);
  }, []);

  useEffect(() => () => { if (timerRef.current) clearTimeout(timerRef.current); }, []);

  const handleUndo = useCallback(() => {
    if (!request) return;
    dismiss();
    // Fire-and-forget like every other local-first write; the restore re-saves
    // through the collection save path, which never rejects in normal use.
    Promise.resolve(request.onUndo()).catch(() => {});
  }, [request, dismiss]);

  return (
    <UndoContext.Provider value={{ showUndo }}>
      {children}
      <UndoSnackbar request={request} onUndo={handleUndo} />
    </UndoContext.Provider>
  );
}

function UndoSnackbar({ request, onUndo }: { request: UndoRequest | null; onUndo: () => void }) {
  const { colors, shadow } = useThemeContext();
  const insets = useSafeAreaInsets();
  const reduceMotion = useReduceMotion();

  const visible = request !== null;
  const translateY = useRef(new Animated.Value(visible ? 0 : 120)).current;
  // Same mount dance as SyncBanner: stay mounted while the hide animation
  // plays, unmount fully once off-screen. Keep the last request so the text
  // doesn't blank out mid-animation.
  const [mounted, setMounted] = useState(visible);
  const lastRequest = useRef(request);
  if (request) lastRequest.current = request;

  useEffect(() => {
    if (visible) setMounted(true);
    const duration = animationDuration(reduceMotion, 250);
    if (duration === 0) {
      // Reduce-motion: jump instantly — no timing pass, no async completion.
      translateY.setValue(visible ? 0 : 120);
      if (!visible) setMounted(false);
      return;
    }
    Animated.timing(translateY, {
      toValue: visible ? 0 : 120,
      duration,
      useNativeDriver: true,
    }).start(({ finished }) => {
      if (finished && !visible) setMounted(false);
    });
  }, [visible, translateY, reduceMotion]);

  if (!mounted || !lastRequest.current) return null;

  return (
    <Animated.View
      style={[
        styles.container,
        {
          transform: [{ translateY }],
          bottom: insets.bottom + 64,
          backgroundColor: colors.textPrimary,
          ...shadow.card,
        },
      ]}
      pointerEvents={visible ? "auto" : "none"}
      accessibilityLiveRegion="polite"
    >
      <Text style={[styles.message, { color: colors.background }]} numberOfLines={1} maxFontSizeMultiplier={1.3}>
        {lastRequest.current.message}
      </Text>
      <TouchableOpacity
        onPress={onUndo}
        style={styles.undoBtn}
        accessibilityRole="button"
        accessibilityLabel="Undo"
        hitSlop={{ top: 8, bottom: 8, left: 8, right: 8 }}
      >
        <Text style={[styles.undoText, { color: colors.accent }]} maxFontSizeMultiplier={1.3}>UNDO</Text>
      </TouchableOpacity>
    </Animated.View>
  );
}

const styles = StyleSheet.create({
  container: {
    position: "absolute",
    left: 16,
    right: 16,
    borderRadius: 12,
    flexDirection: "row",
    alignItems: "center",
    paddingLeft: 16,
    paddingRight: 8,
    minHeight: 48,
    zIndex: 998,
  },
  message: {
    flex: 1,
    fontFamily: fonts.bodyMedium,
    fontSize: 14,
  },
  undoBtn: {
    minHeight: 44,
    justifyContent: "center",
    paddingHorizontal: 12,
  },
  undoText: {
    fontFamily: fonts.bodyBold,
    fontSize: 13,
    letterSpacing: 0.6,
  },
});
