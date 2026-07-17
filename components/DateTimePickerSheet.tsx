// components/DateTimePickerSheet.tsx
// Single home for the platform-branched date/time picker (roadmap #4 —
// replaces 4 near-identical copies: AddJob's date + start-time + end-time, and
// AddExpenseModal's date).
//
// iOS renders a bottom-sheet modal with a "Done" button; the picker updates
// the value live, and "Done" commits the currently displayed value before
// dismissing — so opening with nothing selected and tapping Done selects the
// parent's fallback (today/now) instead of requiring the user to scroll away
// and back (owner requirement, 2026-07-16). Re-committing an existing
// selection is a no-op, and the sheet has no cancel path, so this is safe.
// Android shows the native default dialog, whose OK already returns the
// displayed date even when untouched.
//
// `mode` drives every styling difference — this matches the four originals
// exactly: date → inline calendar, accent-tinted, centered; time → spinner,
// 12-hour, system-tinted. The parent owns the string↔Date conversion: it
// passes a Date in `value` and gets a Date back in `onChange`.

import React, { useMemo } from "react";
import {
  View,
  Text,
  Modal,
  TouchableOpacity,
  Platform,
  StyleSheet,
} from "react-native";
import DateTimePicker, {
  type DateTimePickerEvent,
} from "@react-native-community/datetimepicker";
import { spacing, radius, fontSize } from "../utils/theme";
import type { ColorScheme, ShadowScheme } from "../utils/theme";
import { useTheme } from "../hooks/useTheme";

type DateTimePickerSheetProps = {
  visible: boolean;
  mode: "date" | "time";
  value: Date;
  title: string;
  onChange: (date: Date) => void;
  onClose: () => void;
};

export function DateTimePickerSheet({
  visible,
  mode,
  value,
  title,
  onChange,
  onClose,
}: DateTimePickerSheetProps) {
  const { colors, shadow, isDark } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);

  if (!visible) return null;

  const isDate = mode === "date";

  if (Platform.OS === "ios") {
    return (
      <Modal transparent animationType="slide" accessibilityLabel={title}>
        <View style={styles.overlay}>
          <View style={styles.sheet}>
            <View style={styles.header}>
              <Text style={styles.title}>{title}</Text>
              <TouchableOpacity
                onPress={() => {
                  onChange(value);
                  onClose();
                }}
                accessibilityRole="button"
                accessibilityLabel="Done"
              >
                <Text style={styles.done}>Done</Text>
              </TouchableOpacity>
            </View>
            <DateTimePicker
              themeVariant={isDark ? "dark" : "light"}
              value={value}
              mode={mode}
              display={isDate ? "inline" : "spinner"}
              is24Hour={false}
              accentColor={isDate ? colors.accent : undefined}
              onChange={(_, d) => {
                if (d) onChange(d);
              }}
              style={isDate ? styles.iosDate : undefined}
            />
          </View>
        </View>
      </Modal>
    );
  }

  return (
    <DateTimePicker
      themeVariant={isDark ? "dark" : "light"}
      value={value}
      mode={mode}
      display="default"
      is24Hour={false}
      onChange={(event: DateTimePickerEvent, d?: Date) => {
        onClose();
        if (event.type === "set" && d) onChange(d);
      }}
    />
  );
}

function createStyles(colors: ColorScheme, shadow: ShadowScheme) {
  return StyleSheet.create({
    overlay: {
      flex: 1,
      justifyContent: "flex-end",
      backgroundColor: "rgba(0,0,0,0.35)",
    },
    sheet: {
      backgroundColor: colors.surface,
      borderTopLeftRadius: radius.lg,
      borderTopRightRadius: radius.lg,
      paddingHorizontal: spacing.md,
      paddingBottom: 40,
    },
    header: {
      flexDirection: "row",
      justifyContent: "space-between",
      alignItems: "center",
      paddingVertical: spacing.md,
      borderBottomWidth: StyleSheet.hairlineWidth,
      borderBottomColor: colors.border,
      marginBottom: spacing.sm,
    },
    title: { fontSize: fontSize.md, fontWeight: "600", color: colors.textPrimary },
    done: { fontSize: fontSize.md, fontWeight: "600", color: colors.accent },
    iosDate: { alignSelf: "center" },
  });
}
