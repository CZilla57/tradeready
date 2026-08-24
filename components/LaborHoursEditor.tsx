// components/LaborHoursEditor.tsx
// Shared labor-hours input (Phase 3). Controlled: owns no state, reports
// { hours, breakdown } through onChange. In simple mode it's the single hours
// field the app has always had. In "break down" mode it edits four billable
// buckets (on-site / drive / supply run / setup+cleanup) whose sum becomes
// `hours` — the canonical billable total the engine reads — plus a
// non-billable note for drying/curing/waiting time that is never costed.

import React, { useEffect, useMemo, useState } from "react";
import { View, Text, TextInput, TouchableOpacity, StyleSheet } from "react-native";
import { sumLaborBreakdown } from "../utils/pricingEngine";
import { spacing, radius, fontSize, fonts, type ColorScheme, type ShadowScheme } from "../utils/theme";
import { useTheme } from "../hooks/useTheme";
import type { LaborTimeBreakdown } from "../types/models";

export interface LaborHoursValue {
  hours: string;
  breakdown?: LaborTimeBreakdown;
}

interface Props {
  value: LaborHoursValue;
  onChange: (next: LaborHoursValue) => void;
  doneBarId?: string;
}

const EMPTY: LaborTimeBreakdown = {
  onSiteHours: 0,
  driveHours: 0,
  supplyRunHours: 0,
  setupCleanupHours: 0,
};

type BucketKey = "onSiteHours" | "driveHours" | "supplyRunHours" | "setupCleanupHours";

function bucketText(b: LaborTimeBreakdown): Record<BucketKey, string> {
  return {
    onSiteHours: String(b.onSiteHours),
    driveHours: String(b.driveHours),
    supplyRunHours: String(b.supplyRunHours),
    setupCleanupHours: String(b.setupCleanupHours),
  };
}

export function LaborHoursEditor({ value, onChange, doneBarId }: Props) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  const detailed = !!value.breakdown;
  const b = value.breakdown ?? EMPTY;

  // Text buffers for the four bucket inputs. Controlled numeric inputs that
  // reformat from the parsed number strip a trailing "." before you can finish
  // a decimal (e.g. "0.5"); keeping the raw text here lets a partial decimal
  // survive while the model (breakdown) stays numeric.
  const [text, setText] = useState<Record<BucketKey, string>>(() => bucketText(b));
  // Resync a buffer ONLY when the model number no longer matches what's typed
  // (an external change — template/job load, or the toggle seeding). Never
  // clobber an in-progress "0." whose numeric value already equals the model.
  // Static member access (not b[k]) so exhaustive-deps can match each accessed
  // field to the dependency array — avoids depending on the whole `b` object,
  // which changes reference on every keystroke.
  const { onSiteHours, driveHours, supplyRunHours, setupCleanupHours } = b;
  useEffect(() => {
    setText((prev) => {
      let changed = false;
      const next = { ...prev };
      const sync = (k: BucketKey, model: number) => {
        if ((parseFloat(prev[k]) || 0) !== model) {
          next[k] = String(model);
          changed = true;
        }
      };
      sync("onSiteHours", onSiteHours);
      sync("driveHours", driveHours);
      sync("supplyRunHours", supplyRunHours);
      sync("setupCleanupHours", setupCleanupHours);
      return changed ? next : prev;
    });
  }, [onSiteHours, driveHours, supplyRunHours, setupCleanupHours]);

  function enableDetail() {
    // Seed the breakdown from the single total so nothing is lost on switch.
    const seeded: LaborTimeBreakdown = { ...EMPTY, onSiteHours: parseFloat(value.hours) || 0 };
    onChange({ hours: String(sumLaborBreakdown(seeded)), breakdown: seeded });
  }

  function disableDetail() {
    onChange({ hours: String(sumLaborBreakdown(b)), breakdown: undefined });
  }

  function updateBucket(field: BucketKey, raw: string) {
    setText((prev) => ({ ...prev, [field]: raw }));
    const next: LaborTimeBreakdown = { ...b, [field]: parseFloat(raw) || 0 };
    onChange({ hours: String(sumLaborBreakdown(next)), breakdown: next });
  }

  function updateNote(note: string) {
    onChange({ hours: value.hours, breakdown: { ...b, nonBillableNote: note } });
  }

  return (
    <View>
      <View style={styles.header}>
        <Text style={styles.label}>Labor hours</Text>
        <TouchableOpacity
          onPress={detailed ? disableDetail : enableDetail}
          accessibilityRole="button"
          accessibilityLabel={detailed ? "Use a single hours total" : "Break hours down by type"}
        >
          <Text style={styles.toggle}>{detailed ? "Use single total" : "Break down ▸"}</Text>
        </TouchableOpacity>
      </View>

      {!detailed ? (
        <TextInput
          style={styles.input}
          value={value.hours}
          onChangeText={(v) => onChange({ hours: v, breakdown: undefined })}
          keyboardType="decimal-pad"
          placeholder="2"
          placeholderTextColor={colors.textMuted}
          inputAccessoryViewID={doneBarId}
          accessibilityLabel="Labor hours"
        />
      ) : (
        <View>
          <View style={styles.grid}>
            <Bucket label="On-site" value={text.onSiteHours} onChange={(v) => updateBucket("onSiteHours", v)} doneBarId={doneBarId} styles={styles} colors={colors} />
            <Bucket label="Drive" value={text.driveHours} onChange={(v) => updateBucket("driveHours", v)} doneBarId={doneBarId} styles={styles} colors={colors} />
          </View>
          <View style={styles.grid}>
            <Bucket label="Supply run" value={text.supplyRunHours} onChange={(v) => updateBucket("supplyRunHours", v)} doneBarId={doneBarId} styles={styles} colors={colors} />
            <Bucket label="Setup / cleanup" value={text.setupCleanupHours} onChange={(v) => updateBucket("setupCleanupHours", v)} doneBarId={doneBarId} styles={styles} colors={colors} />
          </View>
          <Text style={styles.totalLine}>Total costed hours: {sumLaborBreakdown(b)} hrs</Text>
          <Text style={styles.noteLabel}>Non-billable time (drying, curing, waiting) — for your notes, not charged</Text>
          <TextInput
            style={styles.input}
            value={b.nonBillableNote ?? ""}
            onChangeText={updateNote}
            placeholder="e.g. 24h cure before second coat"
            placeholderTextColor={colors.textMuted}
            returnKeyType="done"
            accessibilityLabel="Non-billable time note"
          />
        </View>
      )}
    </View>
  );
}

function Bucket({ label, value, onChange, doneBarId, styles, colors }: { label: string; value: string; onChange: (v: string) => void; doneBarId?: string; styles: ReturnType<typeof createStyles>; colors: ColorScheme }) {
  return (
    <View style={{ flex: 1 }}>
      <Text style={styles.bucketLabel}>{label}</Text>
      <TextInput
        style={styles.input}
        value={value}
        onChangeText={onChange}
        keyboardType="decimal-pad"
        placeholder="0"
        placeholderTextColor={colors.textMuted}
        inputAccessoryViewID={doneBarId}
        accessibilityLabel={`${label} hours`}
      />
    </View>
  );
}

function createStyles(colors: ColorScheme, _shadow: ShadowScheme) {
  return StyleSheet.create({
    header: { flexDirection: "row", alignItems: "center", justifyContent: "space-between", marginBottom: 4 },
    label: { fontFamily: fonts.bodySemiBold, fontSize: fontSize.xs, color: colors.textSecondary },
    toggle: { fontFamily: fonts.bodySemiBold, fontSize: fontSize.xs, color: colors.accent },
    input: {
      fontFamily: fonts.bodyRegular, minHeight: 44, backgroundColor: colors.background,
      borderRadius: radius.sm, paddingHorizontal: spacing.sm, fontSize: fontSize.sm, color: colors.textPrimary,
      borderWidth: StyleSheet.hairlineWidth, borderColor: colors.border, marginBottom: spacing.xs,
    },
    grid: { flexDirection: "row", gap: spacing.sm },
    bucketLabel: { fontFamily: fonts.bodyMedium, fontSize: fontSize.xs, color: colors.textSecondary, marginBottom: 2 },
    totalLine: { fontFamily: fonts.mono, fontSize: 11, color: colors.textPrimary, marginTop: 2, marginBottom: spacing.xs },
    noteLabel: { fontFamily: fonts.bodyRegular, fontSize: fontSize.xs, color: colors.textMuted, marginBottom: 2 },
  });
}
