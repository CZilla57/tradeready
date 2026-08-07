// screens/CalendarScreen.tsx
// Phase 11 A4 — the owner calendar (2026-08-07 spec §7): day + week views
// over the pure selectors in utils/calendar.ts, the unscheduled-approved
// queue, and the tap-to-reschedule sheet (DateTimePickerSheet + smart
// defaults + buffer-aware conflict warning + largest-gap suggestion).
// Today remains the daily action surface; this screen is the planning
// surface. Reschedule is tap-based by design — drag would need a gesture
// dependency (Rule 3) and would fight the ScrollView.
//
// Conflict warnings are warning-only (findScheduleConflicts contract):
// Save is never blocked. Saving walks the AddJobScreen edit-path semantics:
// advanceStatusForSchedule advances approved → scheduled, nothing else.

import React, { useCallback, useEffect, useMemo, useState } from "react";
import {
  ActivityIndicator,
  Alert,
  ScrollView,
  StyleSheet,
  Text,
  TouchableOpacity,
  View,
} from "react-native";
import { Ionicons } from "@expo/vector-icons";
import type { TodayStackScreenProps } from "../types/navigation";
import type { Job, Settings } from "../types/models";
import { loadJobs, loadSettings, saveJobs } from "../utils/storage";
import {
  buildCalendarDay,
  buildCalendarWeek,
  dayAxis,
  minutesToLabel,
  selectUnscheduledApproved,
  type CalendarBlock,
  type CalendarDay,
} from "../utils/calendar";
import {
  resolveSchedule,
  isBlackoutDate,
  SCHEDULE_DEFAULTS,
  type ResolvedSchedule,
} from "../utils/scheduleConfig";
import {
  defaultEndTime,
  defaultStartTime,
  findScheduleConflicts,
  formatLaborHint,
  largestFreeGap,
  toMinutes,
} from "../utils/scheduleSmarts";
import { advanceStatusForSchedule } from "../utils/jobStatus";
import { getJobStatusDisplay } from "../utils/jobStatusDisplay";
import {
  formatDisplayDate,
  formatTimeRange,
  getTodayDateString,
  shiftDate,
  toDateString,
} from "../utils/dateHelpers";
import { parseLocalDate } from "../utils/moneyUtils";
import { DateTimePickerSheet } from "../components/DateTimePickerSheet";
import { SectionHeader } from "../components/UI";
import { useTheme } from "../hooks/useTheme";
import { spacing, radius, fontSize, fonts } from "../utils/theme";
import type { ColorScheme, ShadowScheme } from "../utils/theme";

const PX_PER_MIN = 1; // 60px per hour — comfortable tap targets on a 9h day
const DAY_LETTERS = ["M", "T", "W", "T", "F", "S", "S"];

type Mode = "day" | "week";
type PickerKind = "date" | "start" | "end";

interface ReschedState {
  job: Job;
  date: string;
  start: string;
  end: string;
}

/** "HH:MM" → a Date today at that time (parent-owned picker conversion). */
function timeToDate(time: string): Date {
  const d = new Date();
  const [h, m] = time.split(":").map(Number);
  d.setHours(h || 0, m || 0, 0, 0);
  return d;
}

function toTimeStr(d: Date): string {
  return `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
}

export default function CalendarScreen({ navigation }: TodayStackScreenProps<"Calendar">) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);

  const [jobs, setJobs] = useState<Job[]>([]);
  const [settings, setSettings] = useState<Settings | null>(null);
  const [loading, setLoading] = useState(true);
  const [mode, setMode] = useState<Mode>("day");
  const [selectedDate, setSelectedDate] = useState(getTodayDateString());
  const [resched, setResched] = useState<ReschedState | null>(null);
  const [picker, setPicker] = useState<PickerKind | null>(null);
  const [saving, setSaving] = useState(false);

  const load = useCallback(async () => {
    const [j, s] = await Promise.all([loadJobs(), loadSettings()]);
    setJobs(j);
    setSettings(s);
    setLoading(false);
  }, []);

  useEffect(() => {
    load();
    return navigation.addListener("focus", load);
  }, [navigation, load]);

  const schedule: ResolvedSchedule = useMemo(
    () => (settings ? resolveSchedule(settings) : SCHEDULE_DEFAULTS),
    [settings]
  );
  const today = getTodayDateString();
  const day = useMemo(
    () => buildCalendarDay(jobs, selectedDate, schedule),
    [jobs, selectedDate, schedule]
  );
  const axis = useMemo(() => dayAxis(day, schedule), [day, schedule]);
  const week = useMemo(
    () => (mode === "week" ? buildCalendarWeek(jobs, selectedDate, schedule) : []),
    [mode, jobs, selectedDate, schedule]
  );
  const queue = useMemo(() => selectUnscheduledApproved(jobs), [jobs]);

  const openResched = useCallback((job: Job) => {
    const date = job.scheduledDate || getTodayDateString();
    const start = job.scheduledStartTime || defaultStartTime(date, new Date());
    const end = job.scheduledEndTime || defaultEndTime(start, job.laborHours ?? 0);
    setResched({ job, date, start, end });
  }, []);

  const conflicts = useMemo(() => {
    if (!resched) return [];
    return findScheduleConflicts(jobs, {
      excludeJobId: resched.job.id,
      date: resched.date,
      start: resched.start,
      end: resched.end,
      laborHours: resched.job.laborHours ?? 0,
      bufferMinutes: schedule.bufferMinutes,
    });
  }, [resched, jobs, schedule.bufferMinutes]);

  // Exclude the job being moved — its current slot is about to be vacated.
  const gap = useMemo(() => {
    if (!resched) return null;
    return largestFreeGap(
      jobs.filter((j) => j.id !== resched.job.id),
      resched.date,
      schedule.workDayStart,
      schedule.workDayEnd
    );
  }, [resched, jobs, schedule.workDayStart, schedule.workDayEnd]);

  const goDetail = useCallback(
    (jobId: string) => {
      navigation.getParent()?.navigate("Jobs", {
        screen: "JobDetail",
        params: { jobId },
      });
    },
    [navigation]
  );

  const onBlockPress = useCallback(
    (block: CalendarBlock) => {
      Alert.alert(
        block.job.title,
        formatTimeRange(block.job.scheduledStartTime, block.job.scheduledEndTime),
        [
          { text: "View details", onPress: () => goDetail(block.job.id) },
          { text: "Reschedule", onPress: () => openResched(block.job) },
          { text: "Cancel", style: "cancel" },
        ]
      );
    },
    [goDetail, openResched]
  );

  const saveResched = useCallback(async () => {
    if (!resched || saving) return;
    setSaving(true);
    try {
      const all = await loadJobs();
      const updated = all.map((j) =>
        j.id === resched.job.id
          ? {
              ...j,
              scheduledDate: resched.date,
              scheduledStartTime: resched.start,
              scheduledEndTime: resched.end,
              status: advanceStatusForSchedule(j.status, true),
            }
          : j
      );
      await saveJobs(updated);
      setJobs(updated);
      setSelectedDate(resched.date);
      setResched(null);
    } finally {
      setSaving(false);
    }
  }, [resched, saving]);

  const shiftSelected = (days: number) => setSelectedDate((d) => shiftDate(d, days));

  if (loading) {
    return (
      <View style={styles.loadingWrap}>
        <ActivityIndicator color={colors.accent} />
      </View>
    );
  }

  return (
    <View style={styles.screen}>
      <ScrollView contentContainerStyle={styles.scrollContent}>
        {/* Controls: mode toggle + date paging */}
        <View style={styles.controlsRow}>
          <View style={styles.modeToggle}>
            {(["day", "week"] as Mode[]).map((m) => (
              <TouchableOpacity
                key={m}
                onPress={() => setMode(m)}
                style={[styles.modeBtn, mode === m && styles.modeBtnActive]}
                accessibilityRole="button"
                accessibilityState={{ selected: mode === m }}
              >
                <Text style={[styles.modeBtnText, mode === m && styles.modeBtnTextActive]}>
                  {m === "day" ? "Day" : "Week"}
                </Text>
              </TouchableOpacity>
            ))}
          </View>
          {selectedDate !== today && (
            <TouchableOpacity
              onPress={() => setSelectedDate(today)}
              style={styles.todayChip}
              accessibilityRole="button"
              accessibilityLabel="Jump to today"
            >
              <Text style={styles.todayChipText}>Today</Text>
            </TouchableOpacity>
          )}
        </View>

        <View style={styles.dateNavRow}>
          <TouchableOpacity
            onPress={() => shiftSelected(mode === "day" ? -1 : -7)}
            style={styles.navBtn}
            hitSlop={{ top: 10, bottom: 10, left: 10, right: 10 }}
            accessibilityRole="button"
            accessibilityLabel={mode === "day" ? "Previous day" : "Previous week"}
          >
            <Text style={styles.navBtnText}>‹</Text>
          </TouchableOpacity>
          <Text style={styles.dateLabel} maxFontSizeMultiplier={1.3}>
            {formatDisplayDate(selectedDate)}
          </Text>
          <TouchableOpacity
            onPress={() => shiftSelected(mode === "day" ? 1 : 7)}
            style={styles.navBtn}
            hitSlop={{ top: 10, bottom: 10, left: 10, right: 10 }}
            accessibilityRole="button"
            accessibilityLabel={mode === "day" ? "Next day" : "Next week"}
          >
            <Text style={styles.navBtnText}>›</Text>
          </TouchableOpacity>
        </View>

        {isBlackoutDate(schedule, selectedDate) && mode === "day" && (
          <View style={styles.blackoutBanner}>
            <Ionicons name="moon-outline" size={14} color={colors.warning} />
            <Text style={styles.blackoutText}>Time off</Text>
          </View>
        )}

        {mode === "day" ? (
          <DayGrid
            day={day}
            axisStart={axis.startMinutes}
            axisEnd={axis.endMinutes}
            schedule={schedule}
            styles={styles}
            colors={colors}
            onBlockPress={onBlockPress}
            onSetTime={openResched}
          />
        ) : (
          <WeekGrid
            week={week}
            schedule={schedule}
            styles={styles}
            colors={colors}
            onOpenDay={(date) => {
              setSelectedDate(date);
              setMode("day");
            }}
          />
        )}

        {/* Unscheduled approved-work queue */}
        {queue.length > 0 && (
          <View style={styles.queueSection}>
            <SectionHeader title="Needs scheduling" />
            {queue.map((j) => (
              <View key={j.id} style={[styles.queueRow, shadow.card]}>
                <TouchableOpacity
                  style={styles.queueInfo}
                  onPress={() => goDetail(j.id)}
                  accessibilityRole="button"
                  accessibilityLabel={`Open ${j.title}`}
                >
                  <Text style={styles.queueTitle} numberOfLines={1}>{j.title}</Text>
                  <Text style={styles.queueMeta} numberOfLines={1}>
                    {j.customerName}
                    {j.laborHours > 0 ? ` · ${formatLaborHint(j.laborHours)}` : ""}
                  </Text>
                </TouchableOpacity>
                <TouchableOpacity
                  style={styles.queueBtn}
                  onPress={() => openResched(j)}
                  accessibilityRole="button"
                  accessibilityLabel={`Schedule ${j.title}`}
                >
                  <Text style={styles.queueBtnText}>Schedule</Text>
                </TouchableOpacity>
              </View>
            ))}
          </View>
        )}
      </ScrollView>

      {/* Reschedule sheet (inline overlay — pickers stack above it) */}
      {resched && (
        <View style={StyleSheet.absoluteFill}>
          <TouchableOpacity
            style={styles.sheetBackdrop}
            activeOpacity={1}
            onPress={() => setResched(null)}
            accessibilityLabel="Dismiss"
          />
          <View style={[styles.sheet, shadow.card]}>
            <Text style={styles.sheetTitle}>Reschedule</Text>
            <Text style={styles.sheetSubtitle} numberOfLines={1}>{resched.job.title}</Text>

            <TouchableOpacity style={styles.sheetField} onPress={() => setPicker("date")} accessibilityRole="button">
              <Text style={styles.sheetFieldLabel}>Date</Text>
              <Text style={styles.sheetFieldValue}>{formatDisplayDate(resched.date)}</Text>
            </TouchableOpacity>
            <View style={styles.sheetTimeRow}>
              <TouchableOpacity style={[styles.sheetField, styles.sheetFieldHalf]} onPress={() => setPicker("start")} accessibilityRole="button">
                <Text style={styles.sheetFieldLabel}>Start</Text>
                <Text style={styles.sheetFieldValue}>{formatTimeRange(resched.start, null)}</Text>
              </TouchableOpacity>
              <TouchableOpacity style={[styles.sheetField, styles.sheetFieldHalf]} onPress={() => setPicker("end")} accessibilityRole="button">
                <Text style={styles.sheetFieldLabel}>End</Text>
                <Text style={styles.sheetFieldValue}>{formatTimeRange(resched.end, null)}</Text>
              </TouchableOpacity>
            </View>

            {gap && gap.minutes >= 30 && (
              <TouchableOpacity
                style={styles.suggestChip}
                onPress={() =>
                  setResched((r) =>
                    r && {
                      ...r,
                      start: gap.start,
                      end: defaultEndTime(gap.start, r.job.laborHours ?? 0),
                    }
                  )
                }
                accessibilityRole="button"
                accessibilityLabel={`Use suggested start ${gap.start}`}
              >
                <Ionicons name="flash-outline" size={13} color={colors.accent} />
                <Text style={styles.suggestChipText}>
                  Suggested: {formatTimeRange(gap.start, null)} ({formatLaborHint(gap.minutes / 60)} free)
                </Text>
              </TouchableOpacity>
            )}

            {conflicts.length > 0 && (
              <View style={styles.conflictRow} accessibilityRole="alert">
                <Ionicons name="warning-outline" size={14} color={colors.warning} />
                <Text style={styles.conflictText} numberOfLines={2}>
                  {`Overlaps: ${conflicts[0].title} (${formatTimeRange(
                    conflicts[0].scheduledStartTime,
                    conflicts[0].scheduledEndTime
                  )})`}
                  {conflicts.length > 1 ? `  +${conflicts.length - 1} more` : ""}
                </Text>
              </View>
            )}

            <View style={styles.sheetActions}>
              <TouchableOpacity
                style={[styles.sheetBtn, styles.sheetBtnGhost]}
                onPress={() => setResched(null)}
                accessibilityRole="button"
              >
                <Text style={styles.sheetBtnGhostText}>Cancel</Text>
              </TouchableOpacity>
              <TouchableOpacity
                style={[styles.sheetBtn, styles.sheetBtnPrimary]}
                onPress={saveResched}
                disabled={saving}
                accessibilityRole="button"
              >
                <Text style={styles.sheetBtnPrimaryText}>{saving ? "Saving…" : "Save"}</Text>
              </TouchableOpacity>
            </View>
          </View>

          <DateTimePickerSheet
            visible={picker === "date"}
            mode="date"
            title="Choose date"
            value={parseLocalDate(resched.date)}
            onChange={(d) => setResched((r) => r && { ...r, date: toDateString(d) })}
            onClose={() => setPicker(null)}
          />
          <DateTimePickerSheet
            visible={picker === "start"}
            mode="time"
            title="Start time"
            minuteInterval={5}
            value={timeToDate(resched.start)}
            onChange={(d) => setResched((r) => r && { ...r, start: toTimeStr(d) })}
            onClose={() => setPicker(null)}
          />
          <DateTimePickerSheet
            visible={picker === "end"}
            mode="time"
            title="End time"
            minuteInterval={5}
            value={timeToDate(resched.end)}
            onChange={(d) => setResched((r) => r && { ...r, end: toTimeStr(d) })}
            onClose={() => setPicker(null)}
          />
        </View>
      )}
    </View>
  );
}

// ─── Day grid ────────────────────────────────────────────────────────────────

interface DayGridProps {
  day: CalendarDay;
  axisStart: number;
  axisEnd: number;
  schedule: ResolvedSchedule;
  styles: ReturnType<typeof createStyles>;
  colors: ColorScheme;
  onBlockPress: (block: CalendarBlock) => void;
  onSetTime: (job: Job) => void;
}

function DayGrid({ day, axisStart, axisEnd, schedule, styles, colors, onBlockPress, onSetTime }: DayGridProps) {
  const height = (axisEnd - axisStart) * PX_PER_MIN;
  const hours: number[] = [];
  for (let m = axisStart; m <= axisEnd; m += 60) hours.push(m);
  const workTop = (toMinutes(schedule.workDayStart) - axisStart) * PX_PER_MIN;
  const workBottom = (toMinutes(schedule.workDayEnd) - axisStart) * PX_PER_MIN;

  return (
    <View>
      {day.untimed.length > 0 && (
        <View style={styles.untimedSection}>
          <Text style={styles.untimedHeader}>No time set</Text>
          {day.untimed.map((j) => (
            <View key={j.id} style={styles.untimedRow}>
              <View style={[styles.untimedDot, { backgroundColor: getJobStatusDisplay(j.status).color }]} />
              <Text style={styles.untimedTitle} numberOfLines={1}>{j.title}</Text>
              <TouchableOpacity
                onPress={() => onSetTime(j)}
                style={styles.untimedBtn}
                accessibilityRole="button"
                accessibilityLabel={`Set time for ${j.title}`}
              >
                <Text style={styles.untimedBtnText}>Set time</Text>
              </TouchableOpacity>
            </View>
          ))}
        </View>
      )}

      {day.timed.length === 0 && day.untimed.length === 0 && (
        <Text style={styles.emptyDayText}>Nothing scheduled</Text>
      )}

      <View style={styles.gridRow}>
        <View style={styles.gutter}>
          {hours.map((m) => (
            <Text
              key={m}
              style={[styles.hourLabel, { top: (m - axisStart) * PX_PER_MIN - 7 }]}
              maxFontSizeMultiplier={1.2}
            >
              {minutesToLabel(m)}
            </Text>
          ))}
        </View>
        <View style={[styles.canvas, { height }]}>
          {/* Out-of-hours shading */}
          {workTop > 0 && <View style={[styles.offHours, { top: 0, height: workTop }]} />}
          {workBottom < height && (
            <View style={[styles.offHours, { top: workBottom, height: height - workBottom }]} />
          )}
          {hours.map((m) => (
            <View key={m} style={[styles.hourLine, { top: (m - axisStart) * PX_PER_MIN }]} />
          ))}
          {day.timed.map((b) => {
            const status = getJobStatusDisplay(b.job.status);
            const laneWidthPct = 100 / b.laneCount;
            return (
              <TouchableOpacity
                key={b.job.id}
                onPress={() => onBlockPress(b)}
                accessibilityRole="button"
                accessibilityLabel={`${b.job.title}, ${formatTimeRange(b.job.scheduledStartTime, b.job.scheduledEndTime)}${b.inConflict ? ", conflicts with another job" : ""}`}
                style={[
                  styles.block,
                  {
                    top: (b.startMinutes - axisStart) * PX_PER_MIN,
                    height: Math.max((b.endMinutes - b.startMinutes) * PX_PER_MIN - 2, 22),
                    left: `${b.lane * laneWidthPct}%`,
                    width: `${laneWidthPct}%`,
                    borderLeftColor: status.color,
                  },
                  b.inConflict && styles.blockConflict,
                  b.isTerminal && styles.blockTerminal,
                ]}
              >
                <Text style={styles.blockTitle} numberOfLines={1} maxFontSizeMultiplier={1.2}>
                  {b.job.title}
                </Text>
                <Text style={styles.blockMeta} numberOfLines={1} maxFontSizeMultiplier={1.2}>
                  {formatTimeRange(b.job.scheduledStartTime, b.job.scheduledEndTime)}
                </Text>
                {b.inConflict && (
                  <Ionicons
                    name="warning"
                    size={12}
                    color={colors.warning}
                    style={styles.blockWarnIcon}
                  />
                )}
              </TouchableOpacity>
            );
          })}
        </View>
      </View>
    </View>
  );
}

// ─── Week grid ───────────────────────────────────────────────────────────────

interface WeekGridProps {
  week: CalendarDay[];
  schedule: ResolvedSchedule;
  styles: ReturnType<typeof createStyles>;
  colors: ColorScheme;
  onOpenDay: (date: string) => void;
}

const WEEK_PX_PER_MIN = 0.35;

function WeekGrid({ week, schedule, styles, colors, onOpenDay }: WeekGridProps) {
  // Shared axis: union of every day's hour-aligned range.
  let start = Number.MAX_SAFE_INTEGER;
  let end = 0;
  for (const d of week) {
    const a = dayAxis(d, schedule);
    start = Math.min(start, a.startMinutes);
    end = Math.max(end, a.endMinutes);
  }
  const height = (end - start) * WEEK_PX_PER_MIN;

  return (
    <View style={styles.weekRow}>
      {week.map((d, i) => {
        const dayNum = parseInt(d.date.split("-")[2], 10);
        const hasConflict = d.timed.some((b) => b.inConflict);
        return (
          <TouchableOpacity
            key={d.date}
            testID="week-col"
            style={styles.weekCol}
            onPress={() => onOpenDay(d.date)}
            accessibilityRole="button"
            accessibilityLabel={`Open ${d.date}${hasConflict ? ", has conflicts" : ""}`}
          >
            <Text style={styles.weekColLetter} maxFontSizeMultiplier={1.2}>{DAY_LETTERS[i]}</Text>
            <View style={styles.weekColNumWrap}>
              <Text style={styles.weekColNum} maxFontSizeMultiplier={1.2}>{dayNum}</Text>
              {hasConflict && <View style={[styles.weekConflictDot, { backgroundColor: colors.warning }]} />}
            </View>
            <View style={[styles.weekCanvas, { height }]}>
              {isBlackoutDate(schedule, d.date) && <View style={styles.weekBlackout} />}
              {d.timed.map((b) => (
                <View
                  key={b.job.id}
                  style={[
                    styles.weekBar,
                    {
                      top: (b.startMinutes - start) * WEEK_PX_PER_MIN,
                      height: Math.max((b.endMinutes - b.startMinutes) * WEEK_PX_PER_MIN, 3),
                      backgroundColor: getJobStatusDisplay(b.job.status).color,
                    },
                    b.isTerminal && styles.blockTerminal,
                  ]}
                />
              ))}
            </View>
            {d.untimed.length > 0 && (
              <Text style={styles.weekUntimedBadge} maxFontSizeMultiplier={1.2}>+{d.untimed.length}</Text>
            )}
          </TouchableOpacity>
        );
      })}
    </View>
  );
}

// ─── Styles ──────────────────────────────────────────────────────────────────

function createStyles(colors: ColorScheme, shadow: ShadowScheme) {
  return StyleSheet.create({
    screen: { flex: 1, backgroundColor: colors.background },
    loadingWrap: { flex: 1, alignItems: "center", justifyContent: "center", backgroundColor: colors.background },
    scrollContent: { padding: spacing.md, paddingBottom: spacing.xl * 2 },

    controlsRow: { flexDirection: "row", alignItems: "center", justifyContent: "space-between", marginBottom: spacing.sm },
    modeToggle: { flexDirection: "row", backgroundColor: colors.surface, borderRadius: radius.md, padding: 3, borderWidth: 1, borderColor: colors.border },
    modeBtn: { paddingVertical: 6, paddingHorizontal: spacing.md, borderRadius: radius.sm },
    modeBtnActive: { backgroundColor: colors.accent },
    modeBtnText: { fontFamily: fonts.bodyMedium, fontSize: fontSize.sm, color: colors.textSecondary },
    modeBtnTextActive: { color: colors.textOnAccent },
    todayChip: { paddingVertical: 5, paddingHorizontal: spacing.sm, borderRadius: radius.sm, borderWidth: 1, borderColor: colors.accent },
    todayChipText: { fontFamily: fonts.bodyMedium, fontSize: fontSize.xs, color: colors.accent },

    dateNavRow: { flexDirection: "row", alignItems: "center", justifyContent: "space-between", marginBottom: spacing.sm },
    navBtn: { paddingHorizontal: spacing.sm },
    navBtnText: { fontSize: 24, color: colors.accent, fontFamily: fonts.bodyMedium },
    dateLabel: { fontFamily: fonts.bodySemiBold, fontSize: fontSize.md, color: colors.textPrimary },

    blackoutBanner: { flexDirection: "row", alignItems: "center", gap: 6, backgroundColor: colors.surface, borderRadius: radius.sm, paddingVertical: 6, paddingHorizontal: spacing.sm, marginBottom: spacing.sm, borderWidth: 1, borderColor: colors.border },
    blackoutText: { fontFamily: fonts.bodyMedium, fontSize: fontSize.xs, color: colors.warning },

    untimedSection: { marginBottom: spacing.sm },
    untimedHeader: { fontFamily: fonts.bodySemiBold, fontSize: fontSize.xs, color: colors.textSecondary, textTransform: "uppercase", letterSpacing: 0.5, marginBottom: 4 },
    untimedRow: { flexDirection: "row", alignItems: "center", gap: spacing.sm, paddingVertical: 6 },
    untimedDot: { width: 8, height: 8, borderRadius: 4 },
    untimedTitle: { flex: 1, fontFamily: fonts.bodyMedium, fontSize: fontSize.sm, color: colors.textPrimary },
    untimedBtn: { paddingVertical: 4, paddingHorizontal: spacing.sm, borderRadius: radius.sm, backgroundColor: colors.accent },
    untimedBtnText: { fontFamily: fonts.bodyMedium, fontSize: fontSize.xs, color: colors.textOnAccent },

    emptyDayText: { fontFamily: fonts.bodyRegular, fontSize: fontSize.sm, color: colors.textSecondary, marginBottom: spacing.sm },

    gridRow: { flexDirection: "row" },
    gutter: { width: 48, position: "relative" },
    hourLabel: { position: "absolute", right: 6, fontFamily: fonts.mono, fontSize: 10, color: colors.textSecondary },
    canvas: { flex: 1, position: "relative", borderRadius: radius.sm, backgroundColor: colors.surface, overflow: "hidden", borderWidth: 1, borderColor: colors.border },
    offHours: { position: "absolute", left: 0, right: 0, backgroundColor: colors.background, opacity: 0.55 },
    hourLine: { position: "absolute", left: 0, right: 0, height: StyleSheet.hairlineWidth, backgroundColor: colors.border },
    block: { position: "absolute", borderLeftWidth: 3, borderRadius: radius.sm, backgroundColor: colors.surface, paddingHorizontal: 6, paddingVertical: 3, borderWidth: StyleSheet.hairlineWidth, borderColor: colors.border },
    blockConflict: { borderColor: colors.warning, borderWidth: 1 },
    blockTerminal: { opacity: 0.45 },
    blockTitle: { fontFamily: fonts.bodyMedium, fontSize: fontSize.xs, color: colors.textPrimary },
    blockMeta: { fontFamily: fonts.bodyRegular, fontSize: 10, color: colors.textSecondary },
    blockWarnIcon: { position: "absolute", top: 3, right: 4 },

    weekRow: { flexDirection: "row", gap: 4 },
    weekCol: { flex: 1, alignItems: "center" },
    weekColLetter: { fontFamily: fonts.bodyMedium, fontSize: fontSize.xs, color: colors.textSecondary },
    weekColNumWrap: { alignItems: "center", marginBottom: 4 },
    weekColNum: { fontFamily: fonts.bodySemiBold, fontSize: fontSize.sm, color: colors.textPrimary },
    weekConflictDot: { width: 5, height: 5, borderRadius: 2.5, marginTop: 2 },
    weekCanvas: { alignSelf: "stretch", position: "relative", backgroundColor: colors.surface, borderRadius: radius.sm, borderWidth: 1, borderColor: colors.border, overflow: "hidden" },
    weekBlackout: { ...StyleSheet.absoluteFillObject, backgroundColor: colors.background, opacity: 0.55 },
    weekBar: { position: "absolute", left: 2, right: 2, borderRadius: 2 },
    weekUntimedBadge: { marginTop: 2, fontFamily: fonts.bodyMedium, fontSize: 10, color: colors.textSecondary },

    queueSection: { marginTop: spacing.lg },
    queueRow: { flexDirection: "row", alignItems: "center", backgroundColor: colors.surface, borderRadius: radius.md, padding: spacing.sm, marginBottom: spacing.sm, borderWidth: 1, borderColor: colors.border },
    queueInfo: { flex: 1, marginRight: spacing.sm },
    queueTitle: { fontFamily: fonts.bodyMedium, fontSize: fontSize.sm, color: colors.textPrimary },
    queueMeta: { fontFamily: fonts.bodyRegular, fontSize: fontSize.xs, color: colors.textSecondary, marginTop: 1 },
    queueBtn: { paddingVertical: 6, paddingHorizontal: spacing.md, borderRadius: radius.sm, backgroundColor: colors.accent },
    queueBtnText: { fontFamily: fonts.bodyMedium, fontSize: fontSize.xs, color: colors.textOnAccent },

    sheetBackdrop: { ...StyleSheet.absoluteFillObject, backgroundColor: "rgba(0,0,0,0.4)" },
    sheet: { position: "absolute", left: 0, right: 0, bottom: 0, backgroundColor: colors.surface, borderTopLeftRadius: radius.lg, borderTopRightRadius: radius.lg, padding: spacing.md, paddingBottom: spacing.xl },
    sheetTitle: { fontFamily: fonts.bodySemiBold, fontSize: fontSize.md, color: colors.textPrimary },
    sheetSubtitle: { fontFamily: fonts.bodyRegular, fontSize: fontSize.sm, color: colors.textSecondary, marginBottom: spacing.sm },
    sheetField: { backgroundColor: colors.surface, borderRadius: radius.sm, borderWidth: 1, borderColor: colors.border, paddingVertical: 8, paddingHorizontal: spacing.sm, marginBottom: spacing.sm },
    sheetFieldHalf: { flex: 1 },
    sheetTimeRow: { flexDirection: "row", gap: spacing.sm },
    sheetFieldLabel: { fontFamily: fonts.bodyMedium, fontSize: 10, color: colors.textSecondary, textTransform: "uppercase", letterSpacing: 0.5 },
    sheetFieldValue: { fontFamily: fonts.bodyMedium, fontSize: fontSize.sm, color: colors.textPrimary, marginTop: 1 },
    suggestChip: { flexDirection: "row", alignItems: "center", gap: 5, alignSelf: "flex-start", borderWidth: 1, borderColor: colors.accent, borderRadius: radius.sm, paddingVertical: 5, paddingHorizontal: spacing.sm, marginBottom: spacing.sm },
    suggestChipText: { fontFamily: fonts.bodyMedium, fontSize: fontSize.xs, color: colors.accent },
    conflictRow: { flexDirection: "row", alignItems: "center", gap: 6, marginBottom: spacing.sm },
    conflictText: { flex: 1, fontFamily: fonts.bodyMedium, fontSize: fontSize.xs, color: colors.warning },
    sheetActions: { flexDirection: "row", gap: spacing.sm, marginTop: spacing.xs },
    sheetBtn: { flex: 1, alignItems: "center", paddingVertical: 11, borderRadius: radius.md },
    sheetBtnGhost: { borderWidth: 1, borderColor: colors.border },
    sheetBtnGhostText: { fontFamily: fonts.bodyMedium, fontSize: fontSize.sm, color: colors.textPrimary },
    sheetBtnPrimary: { backgroundColor: colors.accent },
    sheetBtnPrimaryText: { fontFamily: fonts.bodyMedium, fontSize: fontSize.sm, color: colors.textOnAccent },
  });
}
