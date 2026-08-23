// components/JobCostsEditor.tsx
// Shared editor for a job's direct-cost lines (Phase 2). Controlled: owns no
// state, edits `value` through `onChange`. Used by the Pricing Calculator and
// the Pricebook entry screen so the direct-costs UI lives in exactly one place.

import React, { useMemo } from "react";
import { View, Text, TextInput, TouchableOpacity, ScrollView, Switch, StyleSheet } from "react-native";
import { Ionicons } from "@expo/vector-icons";
import { formatQuote } from "../utils/format";
import { JOB_COST_CATEGORIES, defaultMarkupPolicyForCategory } from "../utils/pricingEngine";
import { spacing, radius, fontSize, fonts, type ColorScheme, type ShadowScheme } from "../utils/theme";
import { useTheme } from "../hooks/useTheme";
import type { JobCost, JobCostCategory } from "../types/models";

interface Props {
  value: JobCost[];
  onChange: (next: JobCost[]) => void;
  /** inputAccessoryViewID for the shared "Done" keyboard bar, if the host has one. */
  doneBarId?: string;
}

export function JobCostsEditor({ value, onChange, doneBarId }: Props) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);

  function add() {
    const category: JobCostCategory = "other";
    onChange([
      ...value,
      {
        id: `jc${Date.now()}`,
        label: "",
        category,
        quantity: 1,
        unitCost: 0,
        markupPercent: 0,
        markupPolicy: defaultMarkupPolicyForCategory(category),
        taxable: false,
        customerVisible: true,
      },
    ]);
  }

  function update(id: string, patch: Partial<JobCost>) {
    onChange(value.map((c) => (c.id === id ? { ...c, ...patch } : c)));
  }

  // Changing the category resets the markup policy to that category's default
  // (permits pass through at cost; everything else joins the margin base) — the
  // toggle still lets the owner override it per line.
  function changeCategory(id: string, category: JobCostCategory) {
    update(id, { category, markupPolicy: defaultMarkupPolicyForCategory(category) });
  }

  function remove(id: string) {
    onChange(value.filter((c) => c.id !== id));
  }

  return (
    <View>
      {value.length === 0 && (
        <Text style={styles.empty}>
          Permits, disposal, rental, subcontractors, delivery — costs that aren&apos;t labor or materials.
        </Text>
      )}
      {value.map((c) => {
        const base = (Number(c.quantity) || 0) * (Number(c.unitCost) || 0);
        const isPassthrough = c.markupPolicy === "passthrough";
        const amount = isPassthrough ? base : base * (1 + (Number(c.markupPercent) || 0) / 100);
        return (
          <View key={c.id} style={styles.costCard}>
            <View style={styles.row}>
              <TextInput
                style={[styles.input, { flex: 2 }]}
                placeholder="Label (e.g. City permit)"
                placeholderTextColor={colors.textMuted}
                value={c.label}
                onChangeText={(v) => update(c.id, { label: v })}
                returnKeyType="done"
                accessibilityLabel="Direct cost label"
              />
              <Text style={styles.amount}>{formatQuote(amount)}</Text>
              <TouchableOpacity
                onPress={() => remove(c.id)}
                style={styles.removeBtn}
                accessibilityRole="button"
                accessibilityLabel={`Remove cost ${c.label || "item"}`}
              >
                <Ionicons name="close" size={16} color={colors.danger} />
              </TouchableOpacity>
            </View>

            <ScrollView horizontal showsHorizontalScrollIndicator={false} style={styles.chipRow} keyboardShouldPersistTaps="handled">
              {JOB_COST_CATEGORIES.map((cat) => {
                const active = c.category === cat.id;
                return (
                  <TouchableOpacity
                    key={cat.id}
                    style={[styles.chip, active && styles.chipActive]}
                    onPress={() => changeCategory(c.id, cat.id)}
                    accessibilityRole="button"
                    accessibilityLabel={cat.label}
                    accessibilityState={{ selected: active }}
                  >
                    <Text style={[styles.chipText, active && styles.chipTextActive]}>{cat.label}</Text>
                  </TouchableOpacity>
                );
              })}
            </ScrollView>

            <View style={styles.numRow}>
              <NumField label="Qty" value={String(c.quantity)} onChange={(v) => update(c.id, { quantity: parseFloat(v) || 0 })} doneBarId={doneBarId} colors={colors} styles={styles} />
              <NumField label="$ each" value={String(c.unitCost)} onChange={(v) => update(c.id, { unitCost: parseFloat(v) || 0 })} doneBarId={doneBarId} colors={colors} styles={styles} />
              {!isPassthrough && (
                <NumField label="Markup %" value={String(c.markupPercent)} onChange={(v) => update(c.id, { markupPercent: parseFloat(v) || 0 })} doneBarId={doneBarId} colors={colors} styles={styles} />
              )}
            </View>

            <ToggleRow label="Bill at cost (no markup or margin)" value={isPassthrough} onValueChange={(on) => update(c.id, { markupPolicy: on ? "passthrough" : "in_margin_base" })} styles={styles} accessibilityLabel="Bill at cost, outside the margin" />
            <ToggleRow label="Show to customer" value={c.customerVisible} onValueChange={(on) => update(c.id, { customerVisible: on })} styles={styles} accessibilityLabel="Show this cost to the customer" />
            <ToggleRow label="Taxable" value={c.taxable} onValueChange={(on) => update(c.id, { taxable: on })} styles={styles} accessibilityLabel="Apply tax to this cost" />
          </View>
        );
      })}
      <TouchableOpacity style={styles.addBtn} onPress={add} accessibilityRole="button" accessibilityLabel="Add direct cost">
        <Text style={styles.addText}>+ Add direct cost</Text>
      </TouchableOpacity>
    </View>
  );
}

function NumField({ label, value, onChange, doneBarId, colors, styles }: { label: string; value: string; onChange: (v: string) => void; doneBarId?: string; colors: ColorScheme; styles: ReturnType<typeof createStyles> }) {
  return (
    <View style={{ flex: 1 }}>
      <Text style={styles.numLabel}>{label}</Text>
      <TextInput
        style={styles.input}
        value={value}
        onChangeText={onChange}
        keyboardType="decimal-pad"
        placeholderTextColor={colors.textMuted}
        inputAccessoryViewID={doneBarId}
        accessibilityLabel={label}
      />
    </View>
  );
}

function ToggleRow({ label, value, onValueChange, styles, accessibilityLabel }: { label: string; value: boolean; onValueChange: (on: boolean) => void; styles: ReturnType<typeof createStyles>; accessibilityLabel: string }) {
  return (
    <View style={styles.toggleRow}>
      <Text style={styles.toggleLabel}>{label}</Text>
      <Switch value={value} onValueChange={onValueChange} accessibilityLabel={accessibilityLabel} />
    </View>
  );
}

function createStyles(colors: ColorScheme, shadow: ShadowScheme) {
  return StyleSheet.create({
    empty: { fontFamily: fonts.bodyRegular, fontSize: fontSize.sm, color: colors.textMuted, marginBottom: spacing.sm },
    costCard: {
      backgroundColor: colors.background, borderRadius: radius.md, padding: spacing.sm,
      marginBottom: spacing.sm, borderWidth: StyleSheet.hairlineWidth, borderColor: colors.border,
    },
    row: { flexDirection: "row", gap: 6, alignItems: "center" },
    input: {
      fontFamily: fonts.bodyRegular, flex: 1, minHeight: 44, backgroundColor: colors.surface,
      borderRadius: radius.sm, paddingHorizontal: spacing.sm, fontSize: fontSize.sm, color: colors.textPrimary,
      borderWidth: StyleSheet.hairlineWidth, borderColor: colors.border,
    },
    amount: { fontFamily: fonts.mono, fontSize: 12, color: colors.textPrimary, alignSelf: "center", minWidth: 60, textAlign: "right" },
    removeBtn: { padding: 6, minHeight: 44, minWidth: 44, justifyContent: "center", alignItems: "center" },
    chipRow: { flexDirection: "row", marginTop: 8 },
    chip: {
      paddingVertical: 5, paddingHorizontal: 10, borderRadius: radius.sm, marginRight: 6,
      backgroundColor: colors.surface, borderWidth: StyleSheet.hairlineWidth, borderColor: colors.border,
    },
    chipActive: { backgroundColor: colors.accent, borderColor: colors.accent },
    chipText: { fontFamily: fonts.bodyMedium, fontSize: fontSize.xs, color: colors.textSecondary },
    chipTextActive: { fontFamily: fonts.bodySemiBold, color: colors.textOnAccent },
    numRow: { flexDirection: "row", gap: spacing.sm, marginTop: spacing.sm },
    numLabel: { fontFamily: fonts.bodySemiBold, fontSize: fontSize.xs, color: colors.textSecondary, marginBottom: 4 },
    toggleRow: { flexDirection: "row", alignItems: "center", justifyContent: "space-between", marginTop: spacing.xs },
    toggleLabel: { fontFamily: fonts.bodyRegular, fontSize: fontSize.sm, color: colors.textPrimary, flex: 1, paddingRight: spacing.sm },
    addBtn: {
      paddingVertical: spacing.sm, alignItems: "center", borderRadius: radius.md,
      borderWidth: 1, borderColor: colors.border, borderStyle: "dashed", marginTop: 4,
    },
    addText: { fontFamily: fonts.bodyMedium, fontSize: fontSize.sm, color: colors.accent },
  });
}
