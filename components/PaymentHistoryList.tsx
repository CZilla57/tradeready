// components/PaymentHistoryList.tsx
// The payment history for one invoice.
//
// Voided entries STAY in the list, struck through with their void date. That
// is the point of voiding rather than deleting: deletion has to be recorded as
// data, because the sync union cannot distinguish "a payment I don't know
// about" from "one I deleted".
//
// The synthesized `legacy_<id>` entry — which every invoice marked paid before
// itemised history carries — is shown plainly labelled rather than hidden, so
// an old invoice's total visibly adds up and a wrongly-marked-paid invoice
// still has a correction path.
//
// The void CONFIRM lives in the screen, not here. This component just reports
// the intent.

import React, { useMemo } from "react";
import { View, Text, TouchableOpacity, StyleSheet } from "react-native";
import { effectivePayments } from "../utils/invoicePayments";
import { formatMoney } from "../utils/format";
import { spacing, radius, fontSize } from "../utils/theme";
import type { ColorScheme } from "../utils/theme";
import { useTheme } from "../hooks/useTheme";
import type { Invoice, Payment } from "../types/models";

const METHOD_LABELS: Record<string, string> = {
  cash: "Cash",
  check: "Cheque",
  card: "Card",
  stripe: "Stripe",
  other: "Other",
};

function isLegacyEntry(p: Payment): boolean {
  return p.id.startsWith("legacy_");
}

export function PaymentHistoryList({
  invoice,
  onVoid,
}: {
  invoice: Invoice;
  onVoid: (paymentId: string) => void;
}) {
  const { colors } = useTheme();
  const styles = useMemo(() => createStyles(colors), [colors]);
  const payments = effectivePayments(invoice);

  if (payments.length === 0) {
    return <Text style={styles.empty}>No payments recorded yet.</Text>;
  }

  return (
    <View>
      {payments.map((p) => {
        const voided = Boolean(p.voidedAt);
        return (
          <TouchableOpacity
            key={p.id}
            style={styles.row}
            onLongPress={voided ? undefined : () => onVoid(p.id)}
            delayLongPress={500}
            accessibilityRole="button"
            accessibilityLabel={`Payment of ${formatMoney(p.amount)} on ${p.date}${voided ? ", voided" : ""}`}
            accessibilityHint={voided ? undefined : "Long press to void this payment"}
          >
            <View style={styles.rowMain}>
              <Text style={[styles.amount, voided && styles.struck]}>
                {formatMoney(p.amount)}
              </Text>
              <Text style={styles.meta}>
                {p.date} · {METHOD_LABELS[p.method] ?? p.method}
              </Text>
            </View>
            {isLegacyEntry(p) && (
              <Text style={styles.note}>recorded before itemised history</Text>
            )}
            {p.note && !isLegacyEntry(p) && <Text style={styles.note}>{p.note}</Text>}
            {voided && <Text style={styles.voided}>voided {p.voidedAt}</Text>}
          </TouchableOpacity>
        );
      })}
    </View>
  );
}

function createStyles(colors: ColorScheme) {
  return StyleSheet.create({
    empty: { color: colors.textMuted, fontSize: fontSize.sm, paddingVertical: spacing.sm },
    row: {
      backgroundColor: colors.surface,
      paddingVertical: spacing.sm,
      paddingHorizontal: spacing.sm,
      borderRadius: radius.sm,
      borderBottomWidth: StyleSheet.hairlineWidth,
      borderBottomColor: colors.border,
      minHeight: 44,
      justifyContent: "center",
    },
    rowMain: { flexDirection: "row", justifyContent: "space-between", alignItems: "center" },
    amount: { fontSize: fontSize.md, fontWeight: "600", color: colors.textPrimary },
    struck: { textDecorationLine: "line-through", color: colors.textMuted },
    meta: { fontSize: fontSize.sm, color: colors.textMuted },
    note: { fontSize: fontSize.sm, color: colors.textMuted, fontStyle: "italic" },
    voided: { fontSize: fontSize.sm, color: colors.warning },
  });
}
