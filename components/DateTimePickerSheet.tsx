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
//
// `minuteInterval` (optional, time mode) snaps selection to that many minutes
// on both platforms; the incoming value is pre-rounded via
// roundToMinuteInterval so stored odd times (9:37) don't confuse the spinner.

import React, { useMemo } from "react";
import {
  View,
  Text,
  Modal,
  ScrollView,
  TouchableOpacity,
  Platform,
  StyleSheet,
} from "react-native";
import DateTimePicker, {
  type DateTimePickerEvent,
} from "@react-native-community/datetimepicker";
import { spacing, radius, fontSize, fonts, layout } from "../utils/theme";
import type { ColorScheme, ShadowScheme } from "../utils/theme";
import { useTheme } from "../hooks/useTheme";

/** Mirrors the non-exported MinuteInterval union in
 * @react-native-community/datetimepicker's index.d.ts. */
type MinuteInterval = 1 | 2 | 3 | 4 | 5 | 6 | 10 | 12 | 15 | 20 | 30;

type DateTimePickerSheetProps = {
  visible: boolean;
  mode: "date" | "time";
  value: Date;
  title: string;
  onChange: (date: Date) => void;
  onClose: () => void;
  /** Snap time selection to this many minutes (time mode only). */
  minuteInterval?: MinuteInterval;
};

/**
 * Round a Date's time-of-day to the nearest interval multiple (hour carry,
 * clamped so 23:59 never rolls into the next day). Exported for tests and
 * used to pre-round incoming picker values.
 */
export function roundToMinuteInterval(value: Date, minuteInterval?: number): Date {
  if (!minuteInterval || minuteInterval <= 1) return value;
  let total =
    Math.round((value.getHours() * 60 + value.getMinutes()) / minuteInterval) *
    minuteInterval;
  if (total >= 24 * 60) total = 24 * 60 - minuteInterval;
  const rounded = new Date(value);
  rounded.setHours(Math.floor(total / 60), total % 60, 0, 0);
  return rounded;
}

export function DateTimePickerSheet({
  visible,
  mode,
  value,
  title,
  onChange,
  onClose,
  minuteInterval,
}: DateTimePickerSheetProps) {
  const { colors, shadow, isDark } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);

  if (!visible) return null;

  const isDate = mode === "date";
  const pickerValue = isDate ? value : roundToMinuteInterval(value, minuteInterval);

  if (Platform.OS === "ios") {
    const picker = (
      <DateTimePicker
        themeVariant={isDark ? "dark" : "light"}
        value={pickerValue}
        mode={mode}
        display={isDate ? "inline" : "spinner"}
        is24Hour={false}
        accentColor={isDate ? colors.accent : undefined}
        minuteInterval={minuteInterval}
        onChange={(_, d) => {
          if (d) onChange(d);
        }}
        style={isDate ? styles.iosDate : undefined}
      />
    );

    return (
      <Modal transparent animationType="slide" accessibilityLabel={title}>
        <View style={styles.overlay}>
          <View style={styles.sheet}>
            <View style={styles.header}>
              <Text style={styles.title}>{title}</Text>
              <TouchableOpacity
                onPress={() => {
                  onChange(pickerValue);
                  onClose();
                }}
                accessibilityRole="button"
                accessibilityLabel="Done"
              >
                <Text style={styles.done}>Done</Text>
              </TouchableOpacity>
            </View>
            {/* Only the inline calendar can outgrow a short viewport (it is
                ~350pt tall regardless of screen size); the spinner is a fixed
                ~216pt and fits everywhere, so it is left unwrapped to keep its
                wheel gestures untouched. When the sheet's maxHeight does not
                bind — every iPad orientation and every phone portrait — the
                ScrollView is unconstrained, sizes to its content and never
                scrolls, so this is a no-op there. */}
            {isDate ? (
              <ScrollView bounces={false} showsVerticalScrollIndicator={false}>
                {picker}
              </ScrollView>
            ) : (
              picker
            )}
          </View>
        </View>
      </Modal>
    );
  }

  return (
    <DateTimePicker
      themeVariant={isDark ? "dark" : "light"}
      value={pickerValue}
      mode={mode}
      display="default"
      is24Hour={false}
      minuteInterval={minuteInterval}
      onChange={(event: DateTimePickerEvent, d?: Date) => {
        onClose();
        if (event.type === "set" && d) onChange(roundToMinuteInterval(d, minuteInterval));
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
      // The overlay is `justifyContent: "flex-end"`, so a sheet taller than
      // the viewport is pushed off the TOP — taking the header, and with it
      // the only Done button, out of reach (the sheet has no cancel path).
      // Capping at 85% keeps the header on screen no matter how short the
      // window is. Same constant as TaxSettingsModal's sheet.
      maxHeight: "85%",
      // Keeps the sheet from spanning ~1180pt edge-to-edge on iPad; a no-op
      // below 700pt, so phone widths are untouched.
      ...layout.contentColumn,
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
    title: { fontFamily: fonts.bodySemiBold, fontSize: fontSize.md, color: colors.textPrimary },
    done: { fontFamily: fonts.bodySemiBold, fontSize: fontSize.md, color: colors.accent },
    iosDate: { alignSelf: "center" },
  });
}
