// screens/SettingsScheduleScreen.tsx
// Settings → Schedule (Phase 11 A5, 2026-08-07 spec §7): working hours, work
// days, appointment defaults, and time-off blackouts — the schedule config
// behind the calendar, conflict buffers, and open-slot insights. Form page on
// the useSettingsDraft contract. Values persist EXPLICITLY into
// Settings.schedule; display always goes through resolveSchedule so an
// absent/partial blob shows its effective defaults. The time-off add form is
// commit-only (Add button) and deliberately NOT flushed: its date fields
// always hold values (they default to today), so auto-folding on save would
// fabricate a blackout the user never added.
import React, { useMemo, useState } from "react";
import {
  Alert,
  KeyboardAvoidingView,
  Platform,
  ScrollView,
  StyleSheet,
  Text,
  TouchableOpacity,
  View,
} from "react-native";
import { Ionicons } from "@expo/vector-icons";
import { useSettingsDraft } from "../hooks/useSettingsDraft";
import { SettingsField as Field } from "../components/SettingsField";
import { DateTimePickerSheet } from "../components/DateTimePickerSheet";
import { resolveSchedule } from "../utils/scheduleConfig";
import { formatDisplayDate, formatTimeRange, getTodayDateString, toDateString } from "../utils/dateHelpers";
import { parseLocalDate } from "../utils/moneyUtils";
import { useTheme } from "../hooks/useTheme";
import { spacing, radius, fontSize, fonts, layout, type ColorScheme, type ShadowScheme } from "../utils/theme";
import type { TodayStackScreenProps } from "../types/navigation";
import type { ScheduleBlackout, ScheduleConfig, Settings } from "../types/models";

const DAY_CHIPS: { iso: number; letter: string; name: string }[] = [
  { iso: 1, letter: "M", name: "Monday" },
  { iso: 2, letter: "T", name: "Tuesday" },
  { iso: 3, letter: "W", name: "Wednesday" },
  { iso: 4, letter: "T", name: "Thursday" },
  { iso: 5, letter: "F", name: "Friday" },
  { iso: 6, letter: "S", name: "Saturday" },
  { iso: 7, letter: "S", name: "Sunday" },
];

type PickerKind = "start" | "end" | "boStart" | "boEnd";

function timeToDate(time: string): Date {
  const d = new Date();
  const [h, m] = time.split(":").map(Number);
  d.setHours(h || 0, m || 0, 0, 0);
  return d;
}

function toTimeStr(d: Date): string {
  return `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
}

function validateSchedule(flushed: Settings): string[] {
  const sch = flushed.schedule;
  if (!sch?.workDayStart || !sch?.workDayEnd) return [];
  return sch.workDayStart >= sch.workDayEnd
    ? ["Work day must start before it ends."]
    : [];
}

export default function SettingsScheduleScreen({ navigation }: TodayStackScreenProps<"SettingsSchedule">) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  const [picker, setPicker] = useState<PickerKind | null>(null);
  const [boDraft, setBoDraft] = useState(() => ({
    start: getTodayDateString(),
    end: getTodayDateString(),
    reason: "",
  }));

  const { s, update } = useSettingsDraft(navigation, { validate: validateSchedule });
  if (!s) return null;

  const sched: ScheduleConfig = s.schedule ?? {};
  const resolved = resolveSchedule(s);
  const setSched = (patch: Partial<ScheduleConfig>) => update("schedule", { ...sched, ...patch });

  const activeDays = sched.workDays ?? resolved.workDays;
  const toggleDay = (iso: number) => {
    const next = activeDays.includes(iso)
      ? activeDays.filter((d) => d !== iso)
      : [...activeDays, iso].sort((a, b) => a - b);
    if (next.length === 0) {
      Alert.alert("Keep at least one working day");
      return;
    }
    setSched({ workDays: next });
  };

  const parseMinutes = (v: string): number | undefined => {
    const n = parseInt(v, 10);
    return Number.isFinite(n) ? n : undefined;
  };

  const addBlackout = () => {
    const start = boDraft.start;
    const end = boDraft.end < start ? start : boDraft.end;
    const entry: ScheduleBlackout = {
      id: `bo${Date.now()}`,
      start,
      end,
      reason: boDraft.reason.trim() || undefined,
    };
    setSched({ blackouts: [...(sched.blackouts ?? []), entry] });
    setBoDraft({ start: getTodayDateString(), end: getTodayDateString(), reason: "" });
  };

  const removeBlackout = (id: string) =>
    setSched({ blackouts: (sched.blackouts ?? []).filter((b) => b.id !== id) });

  const blackouts = resolved.blackouts;

  return (
    <View style={styles.container}>
      <KeyboardAvoidingView behavior={Platform.OS === "ios" ? "padding" : undefined} style={{ flex: 1 }}>
        <ScrollView
          contentContainerStyle={styles.scroll}
          showsVerticalScrollIndicator={false}
          keyboardShouldPersistTaps="handled"
          keyboardDismissMode="on-drag"
        >
          <Text style={styles.subtitle}>
            Your working pattern powers the calendar, conflict warnings, and open-slot suggestions.
          </Text>

          <Text style={styles.sectionLabel}>Working hours</Text>
          <View style={styles.card}>
            <View style={styles.timeRow}>
              <TouchableOpacity
                style={styles.timeField}
                onPress={() => setPicker("start")}
                accessibilityRole="button"
                accessibilityLabel="Work day start"
              >
                <Text style={styles.timeFieldLabel}>Start</Text>
                <Text style={styles.timeFieldValue}>{formatTimeRange(resolved.workDayStart, null)}</Text>
              </TouchableOpacity>
              <TouchableOpacity
                style={styles.timeField}
                onPress={() => setPicker("end")}
                accessibilityRole="button"
                accessibilityLabel="Work day end"
              >
                <Text style={styles.timeFieldLabel}>End</Text>
                <Text style={styles.timeFieldValue}>{formatTimeRange(resolved.workDayEnd, null)}</Text>
              </TouchableOpacity>
            </View>
            <View style={styles.dayRow}>
              {DAY_CHIPS.map((d) => {
                const selected = activeDays.includes(d.iso);
                return (
                  <TouchableOpacity
                    key={d.iso}
                    style={[styles.dayChip, selected && styles.dayChipSelected]}
                    onPress={() => toggleDay(d.iso)}
                    accessibilityRole="button"
                    accessibilityLabel={d.name}
                    accessibilityState={{ selected }}
                  >
                    <Text style={[styles.dayChipText, selected && styles.dayChipTextSelected]}>
                      {d.letter}
                    </Text>
                  </TouchableOpacity>
                );
              })}
            </View>
          </View>

          <Text style={styles.sectionLabel}>Appointments</Text>
          <View style={styles.card}>
            <Field
              label="Default appointment length (minutes)"
              value={String(sched.defaultDurationMinutes ?? resolved.defaultDurationMinutes)}
              onChangeText={(v) => setSched({ defaultDurationMinutes: parseMinutes(v) })}
              keyboardType="number-pad"
              colors={colors}
            />
            <Field
              label="Buffer between jobs (minutes)"
              value={String(sched.bufferMinutes ?? resolved.bufferMinutes)}
              onChangeText={(v) => setSched({ bufferMinutes: parseMinutes(v) })}
              keyboardType="number-pad"
              colors={colors}
            />
            <Text style={styles.note}>
              The buffer is extra travel or cleanup time kept free between jobs — conflict
              warnings respect it. TradeReady never guesses travel time on its own.
            </Text>
          </View>

          <Text style={styles.sectionLabel}>Time off</Text>
          <View style={styles.card}>
            {blackouts.length === 0 && (
              <Text style={styles.note}>No time off planned.</Text>
            )}
            {blackouts.map((b) => (
              <View key={b.id} style={styles.blackoutRow}>
                <View style={styles.blackoutInfo}>
                  <Text style={styles.blackoutDates}>
                    {b.start === b.end
                      ? formatDisplayDate(b.start)
                      : `${formatDisplayDate(b.start)} – ${formatDisplayDate(b.end)}`}
                  </Text>
                  {!!b.reason && <Text style={styles.blackoutReason}>{b.reason}</Text>}
                </View>
                <TouchableOpacity
                  onPress={() => removeBlackout(b.id)}
                  hitSlop={{ top: 8, bottom: 8, left: 8, right: 8 }}
                  accessibilityRole="button"
                  accessibilityLabel={`Remove time off ${b.reason || b.start}`}
                >
                  <Ionicons name="close-circle-outline" size={20} color={colors.textSecondary} />
                </TouchableOpacity>
              </View>
            ))}

            <View style={styles.timeRow}>
              <TouchableOpacity
                style={styles.timeField}
                onPress={() => setPicker("boStart")}
                accessibilityRole="button"
                accessibilityLabel="Time off first day"
              >
                <Text style={styles.timeFieldLabel}>First day</Text>
                <Text style={styles.timeFieldValue}>{formatDisplayDate(boDraft.start)}</Text>
              </TouchableOpacity>
              <TouchableOpacity
                style={styles.timeField}
                onPress={() => setPicker("boEnd")}
                accessibilityRole="button"
                accessibilityLabel="Time off last day"
              >
                <Text style={styles.timeFieldLabel}>Last day</Text>
                <Text style={styles.timeFieldValue}>{formatDisplayDate(boDraft.end)}</Text>
              </TouchableOpacity>
            </View>
            <Field
              label="Reason (optional)"
              value={boDraft.reason}
              onChangeText={(v) => setBoDraft((d) => ({ ...d, reason: v }))}
              colors={colors}
            />
            <TouchableOpacity
              style={styles.addBtn}
              onPress={addBlackout}
              accessibilityRole="button"
            >
              <Text style={styles.addBtnText}>Add time off</Text>
            </TouchableOpacity>
          </View>
        </ScrollView>
      </KeyboardAvoidingView>

      <DateTimePickerSheet
        visible={picker === "start"}
        mode="time"
        title="Work day starts"
        minuteInterval={15}
        value={timeToDate(resolved.workDayStart)}
        onChange={(d) => setSched({ workDayStart: toTimeStr(d) })}
        onClose={() => setPicker(null)}
      />
      <DateTimePickerSheet
        visible={picker === "end"}
        mode="time"
        title="Work day ends"
        minuteInterval={15}
        value={timeToDate(resolved.workDayEnd)}
        onChange={(d) => setSched({ workDayEnd: toTimeStr(d) })}
        onClose={() => setPicker(null)}
      />
      <DateTimePickerSheet
        visible={picker === "boStart"}
        mode="date"
        title="Time off starts"
        value={parseLocalDate(boDraft.start)}
        onChange={(d) => {
          const start = toDateString(d);
          setBoDraft((prev) => ({ ...prev, start, end: prev.end < start ? start : prev.end }));
        }}
        onClose={() => setPicker(null)}
      />
      <DateTimePickerSheet
        visible={picker === "boEnd"}
        mode="date"
        title="Time off ends"
        value={parseLocalDate(boDraft.end)}
        onChange={(d) => {
          const end = toDateString(d);
          setBoDraft((prev) => ({ ...prev, end: end < prev.start ? prev.start : end }));
        }}
        onClose={() => setPicker(null)}
      />
    </View>
  );
}

function createStyles(colors: ColorScheme, shadow: ShadowScheme) {
  return StyleSheet.create({
    container: { flex: 1, backgroundColor: colors.background },
    scroll: { padding: spacing.md, paddingBottom: 60, ...layout.contentColumn },
    subtitle: { fontFamily: fonts.bodyRegular, fontSize: fontSize.sm, color: colors.textSecondary, marginBottom: spacing.sm },
    sectionLabel: { fontFamily: fonts.bodySemiBold, fontSize: fontSize.xs, color: colors.textSecondary, textTransform: "uppercase", letterSpacing: 0.5, marginBottom: 6, marginTop: spacing.sm },
    card: { backgroundColor: colors.surface, borderRadius: radius.lg, padding: spacing.md, marginBottom: spacing.sm, ...shadow.card },
    timeRow: { flexDirection: "row", gap: spacing.sm, marginBottom: spacing.sm },
    timeField: { flex: 1, backgroundColor: colors.background, borderRadius: radius.md, borderWidth: StyleSheet.hairlineWidth, borderColor: colors.border, paddingVertical: 8, paddingHorizontal: spacing.sm },
    timeFieldLabel: { fontFamily: fonts.bodyMedium, fontSize: 10, color: colors.textSecondary, textTransform: "uppercase", letterSpacing: 0.5 },
    timeFieldValue: { fontFamily: fonts.bodyMedium, fontSize: fontSize.md, color: colors.textPrimary, marginTop: 1 },
    dayRow: { flexDirection: "row", gap: 6 },
    dayChip: { flex: 1, alignItems: "center", paddingVertical: 8, borderRadius: radius.sm, borderWidth: 1, borderColor: colors.border, backgroundColor: colors.background },
    dayChipSelected: { backgroundColor: colors.accent, borderColor: colors.accent },
    dayChipText: { fontFamily: fonts.bodyMedium, fontSize: fontSize.sm, color: colors.textSecondary },
    dayChipTextSelected: { color: colors.textOnAccent },
    note: { fontFamily: fonts.bodyRegular, fontSize: fontSize.xs, color: colors.textMuted, marginBottom: spacing.sm },
    blackoutRow: { flexDirection: "row", alignItems: "center", justifyContent: "space-between", paddingVertical: 6, borderBottomWidth: StyleSheet.hairlineWidth, borderBottomColor: colors.border, marginBottom: 6 },
    blackoutInfo: { flex: 1, marginRight: spacing.sm },
    blackoutDates: { fontFamily: fonts.bodyMedium, fontSize: fontSize.sm, color: colors.textPrimary },
    blackoutReason: { fontFamily: fonts.bodyRegular, fontSize: fontSize.xs, color: colors.textSecondary, marginTop: 1 },
    addBtn: { alignSelf: "flex-start", paddingVertical: 8, paddingHorizontal: spacing.md, borderRadius: radius.sm, backgroundColor: colors.accent, marginTop: 2 },
    addBtnText: { fontFamily: fonts.bodyMedium, fontSize: fontSize.sm, color: colors.textOnAccent },
  });
}
