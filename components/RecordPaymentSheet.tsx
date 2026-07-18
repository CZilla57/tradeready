// components/RecordPaymentSheet.tsx
// The record-payment form. Hands a PaymentDraft up rather than mutating the
// invoice itself — id stamping and applyPayment belong to the screen, which
// keeps id generation out of a component and this file testable without
// mocking storage.
//
// NOTE: 'stripe' is deliberately absent from the method chips. It is reserved
// for webhook-created entries so the two origins stay distinguishable; a
// manually recorded card payment is 'card'.

import React, { useEffect, useMemo, useState } from "react";
import { Modal, View, Text, TouchableOpacity, StyleSheet } from "react-native";
import Field from "./Field";
import { DateTimePickerSheet } from "./DateTimePickerSheet";
import { Button } from "./UI";
import { balanceDue } from "../utils/invoicePayments";
import { formatMoney } from "../utils/format";
import { spacing, radius, fontSize } from "../utils/theme";
import type { ColorScheme, ShadowScheme } from "../utils/theme";
import { useTheme } from "../hooks/useTheme";
import type { Invoice, PaymentDraft, PaymentMethod } from "../types/models";

const METHODS: { key: PaymentMethod; label: string }[] = [
  { key: "cash", label: "Cash" },
  { key: "check", label: "Cheque" },
  { key: "card", label: "Card" },
  { key: "other", label: "Other" },
];

function toDateString(d: Date): string {
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
}

export function RecordPaymentSheet({
  visible,
  invoice,
  onSave,
  onClose,
}: {
  visible: boolean;
  invoice: Invoice;
  onSave: (draft: PaymentDraft) => void;
  onClose: () => void;
}) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);

  const balance = balanceDue(invoice);
  const [amount, setAmount] = useState(String(balance));
  const [date, setDate] = useState(new Date());
  const [method, setMethod] = useState<PaymentMethod>("cash");
  const [note, setNote] = useState("");
  const [pickerOpen, setPickerOpen] = useState(false);
  const [saving, setSaving] = useState(false);

  // Re-seed whenever the sheet reopens or the balance changes underneath it.
  useEffect(() => {
    if (visible) {
      setAmount(String(balanceDue(invoice)));
      setDate(new Date());
      setMethod("cash");
      setNote("");
      setSaving(false);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [visible, invoice]);

  if (!visible) return null;

  const parsed = parseFloat(amount);
  const valid = Number.isFinite(parsed) && parsed > 0;
  const overBalance = valid && parsed > balance;

  function handleSave() {
    if (!valid) return;
    // The sheet is unmounted by the parent once its save completes (recordingFor
    // is cleared), so there's no matching setSaving(false) here — this flag only
    // needs to disable the button for the lifetime of this in-flight save.
    setSaving(true);
    const draft: PaymentDraft = {
      amount: parsed,
      date: toDateString(date),
      method,
    };
    if (note.trim()) draft.note = note.trim();
    onSave(draft);
  }

  return (
    <Modal visible transparent animationType="slide" onRequestClose={onClose}>
      <View style={styles.backdrop}>
        <View style={styles.sheet}>
          <Text style={styles.title}>Record a payment</Text>
          <Text style={styles.sub}>
            {invoice.number} · {formatMoney(balance)} due
          </Text>

          <Field
            label="Amount"
            value={amount}
            onChangeText={setAmount}
            keyboardType="decimal-pad"
          />
          {overBalance && (
            <Text style={styles.hint}>
              More than the {formatMoney(balance)} balance — that&apos;s fine, it will
              show as fully paid.
            </Text>
          )}

          <Text style={styles.label}>Date</Text>
          <TouchableOpacity
            style={styles.dateBtn}
            onPress={() => setPickerOpen(true)}
            accessibilityRole="button"
            accessibilityLabel="Payment date"
          >
            <Text style={styles.dateText}>{toDateString(date)}</Text>
          </TouchableOpacity>

          <Text style={styles.label}>Method</Text>
          <View style={styles.chipRow}>
            {METHODS.map((m) => (
              <TouchableOpacity
                key={m.key}
                style={[styles.chip, method === m.key && styles.chipActive]}
                onPress={() => setMethod(m.key)}
                accessibilityRole="radio"
                accessibilityState={{ selected: method === m.key }}
                accessibilityLabel={m.label}
              >
                <Text style={[styles.chipText, method === m.key && styles.chipTextActive]}>
                  {m.label}
                </Text>
              </TouchableOpacity>
            ))}
          </View>

          <Field label="Note (optional)" value={note} onChangeText={setNote} />

          <View style={styles.actions}>
            <Button label="Cancel" variant="secondary" onPress={onClose} style={{ flex: 1 }} />
            <Button label="Record payment" onPress={handleSave} loading={saving} style={{ flex: 1 }} />
          </View>
        </View>
      </View>

      <DateTimePickerSheet
        visible={pickerOpen}
        mode="date"
        value={date}
        title="Payment date"
        onChange={setDate}
        onClose={() => setPickerOpen(false)}
      />
    </Modal>
  );
}

function createStyles(colors: ColorScheme, shadow: ShadowScheme) {
  return StyleSheet.create({
    backdrop: { flex: 1, justifyContent: "flex-end", backgroundColor: "rgba(0,0,0,0.4)" },
    sheet: {
      backgroundColor: colors.surface,
      borderTopLeftRadius: radius.lg,
      borderTopRightRadius: radius.lg,
      padding: spacing.lg,
      ...shadow.card,
    },
    title: { fontSize: fontSize.lg, fontWeight: "700", color: colors.textPrimary },
    sub: { fontSize: fontSize.sm, color: colors.textMuted, marginBottom: spacing.md },
    label: { fontSize: fontSize.sm, color: colors.textMuted, marginTop: spacing.sm },
    hint: { fontSize: fontSize.sm, color: colors.warning, marginTop: spacing.xs },
    dateBtn: {
      borderWidth: 1, borderColor: colors.border, borderRadius: radius.md,
      padding: spacing.md, marginTop: spacing.xs, minHeight: 44, justifyContent: "center",
    },
    dateText: { fontSize: fontSize.md, color: colors.textPrimary },
    chipRow: { flexDirection: "row", flexWrap: "wrap", gap: spacing.xs, marginTop: spacing.xs },
    chip: {
      paddingVertical: spacing.sm, paddingHorizontal: spacing.md,
      borderRadius: radius.full, borderWidth: 1, borderColor: colors.border,
      minHeight: 44, justifyContent: "center",
    },
    chipActive: { backgroundColor: colors.accentBg, borderColor: colors.accent },
    chipText: { color: colors.textPrimary, fontSize: fontSize.sm },
    chipTextActive: { color: colors.accent, fontWeight: "600" },
    actions: { flexDirection: "row", gap: spacing.sm, marginTop: spacing.lg },
  });
}
