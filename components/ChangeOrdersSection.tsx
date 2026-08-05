// components/ChangeOrdersSection.tsx
// JobDetail's change-orders block: rows with derived-status badges, add/edit
// entry points, and the three decision actions (send link / mark decided /
// cancel). Owns its own storage writes; the parent just re-reads via
// onChanged. Decision notes use an in-component Modal (Alert.prompt is
// iOS-only, see confirmDecision below).

import React, { useMemo, useState } from "react";
import { Alert, Modal, StyleSheet, Text, TouchableOpacity, View } from "react-native";
import Field from "./Field";
import { Badge, Button, Card, SectionHeader } from "./UI";
import { useTheme } from "../hooks/useTheme";
import { spacing, radius, fontSize, fonts } from "../utils/theme";
import type { ColorScheme, ShadowScheme } from "../utils/theme";
import { formatQuote } from "../utils/format";
import {
  applyManualDecision,
  cancelChangeOrder,
  canAddChangeOrder,
  changeOrderStatus,
  type ChangeOrderStatus,
} from "../utils/changeOrders";
import { createChangeOrderLink } from "../utils/changeOrderLink";
import { composeEmail, composeSMS } from "../utils/messaging";
import { loadCustomers, loadJobs, loadSettings, saveJobs, resolveCustomer } from "../utils/storage";
import { track } from "../utils/analytics";
import type { ChangeOrder, Customer, Job } from "../types/models";

const STATUS_LABEL: Record<ChangeOrderStatus, string> = {
  pending: "Pending",
  awaiting: "Awaiting",
  approved: "Approved",
  declined: "Declined",
  cancelled: "Cancelled",
};
const STATUS_BADGE: Record<ChangeOrderStatus, "muted" | "accent" | "success" | "warning" | "danger"> = {
  pending: "muted",
  awaiting: "accent",
  approved: "success",
  declined: "danger",
  cancelled: "muted",
};

interface Props {
  job: Job;
  onChanged: () => void;
  onAdd: () => void;
  onEdit: (changeOrderId: string) => void;
}

export default function ChangeOrdersSection({ job, onChanged, onAdd, onEdit }: Props) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  const [busy, setBusy] = useState(false);
  // The decision modal's target: which CO + which decision is being recorded.
  const [decisionTarget, setDecisionTarget] = useState<{ id: string; decision: "approved" | "declined" } | null>(null);
  const [decisionNote, setDecisionNote] = useState("");

  const cos = job.changeOrders ?? [];
  const canAdd = canAddChangeOrder(job.status);
  if (cos.length === 0 && !canAdd) return null;

  async function mutateCo(id: string, fn: (co: ChangeOrder) => ChangeOrder): Promise<boolean> {
    const jobs = await loadJobs();
    let changed = false;
    const updated = jobs.map((j): Job => {
      if (j.id !== job.id) return j;
      return {
        ...j,
        changeOrders: (j.changeOrders ?? []).map((c) => {
          if (c.id !== id) return c;
          const next = fn(c);
          if (next !== c) changed = true;
          return next;
        }),
      };
    });
    // applyManualDecision/cancelChangeOrder return the SAME reference when
    // refused (already decided/cancelled) — skip the write in that case.
    if (changed) await saveJobs(updated);
    return changed;
  }

  async function handleSend(co: ChangeOrder) {
    setBusy(true);
    try {
      const [customers, settings, jobs] = await Promise.all([loadCustomers(), loadSettings(), loadJobs()]);
      const fresh = jobs.find((j) => j.id === job.id) ?? job;
      const resolved = resolveCustomer(customers, { customerId: job.customerId, customerName: job.customerName });
      // Display-only fallback for a dangling customer link — NEVER saved.
      // Customer records only ever come from resolveCustomer/getOrCreateCustomer.
      const customer: Customer = resolved ?? {
        id: "",
        name: job.customerName,
        email: "",
        phone: "",
        address: "",
        notes: "",
      };
      const result = await createChangeOrderLink(fresh, co, customer, settings);
      if (!result.ok) {
        Alert.alert("Couldn't create the link", result.message);
        return;
      }
      const body =
        `Hi ${customer.name || job.customerName}, while working on "${job.title}" we found something that changes the scope: ` +
        `${co.title} (${co.amount >= 0 ? "+" : ""}${formatQuote(co.amount)}). ` +
        `Please review and approve before we do this extra work: ${result.url}`;
      const phone = customer.phone?.trim();
      const email = customer.email?.trim();
      let sent = false;
      if (phone) {
        sent = await composeSMS({ recipients: [phone], body });
      } else if (email) {
        sent = await composeEmail({ recipients: [email], subject: `Change to your ${job.title} job`, body });
      } else {
        Alert.alert(
          "No contact info",
          `${customer.name || "This customer"} has no phone or email on file. Add one to send this change order.`,
        );
      }
      if (sent) track("change_order_sent", { amount: co.amount });
      onChanged();
    } finally {
      setBusy(false);
    }
  }

  // Clears BOTH the target and the note — the only correct way to leave the
  // decision modal. A note-less clear (e.g. the old onRequestClose) lets a
  // note typed for one CO survive to pre-fill the next one opened.
  function closeDecisionModal() {
    setDecisionTarget(null);
    setDecisionNote("");
  }

  async function confirmDecision() {
    // `busy` doubles as this modal's in-flight guard (shared with
    // handleSend) — a fast double-tap on Confirm must not fire two
    // overlapping mutateCo calls / duplicate analytics.
    if (!decisionTarget || busy) return;
    setBusy(true);
    try {
      const today = new Date().toISOString().split("T")[0];
      const changed = await mutateCo(decisionTarget.id, (c) =>
        applyManualDecision(c, decisionTarget.decision, decisionNote, today),
      );
      if (changed) track("change_order_decided", { decision: decisionTarget.decision, channel: "manual" });
      onChanged();
    } finally {
      setBusy(false);
      closeDecisionModal();
    }
  }

  function handleCancel(co: ChangeOrder) {
    Alert.alert("Cancel this change order?", "It stays in the list as cancelled and won't be billed.", [
      { text: "Keep it", style: "cancel" },
      {
        text: "Cancel change order",
        style: "destructive",
        onPress: async () => {
          const today = new Date().toISOString().split("T")[0];
          await mutateCo(co.id, (c) => cancelChangeOrder(c, today));
          onChanged();
        },
      },
    ]);
  }

  function handleDelete(co: ChangeOrder) {
    Alert.alert("Delete this change order?", "It was never sent, so no record is needed.", [
      { text: "Keep it", style: "cancel" },
      {
        text: "Delete",
        style: "destructive",
        onPress: async () => {
          const jobs = await loadJobs();
          const updated = jobs.map((j): Job =>
            j.id === job.id
              ? { ...j, changeOrders: (j.changeOrders ?? []).filter((c) => !(c.id === co.id && changeOrderStatus(c) === "pending")) }
              : j,
          );
          await saveJobs(updated);
          onChanged();
        },
      },
    ]);
  }

  function rowActions(co: ChangeOrder) {
    const status = changeOrderStatus(co);
    const actions: { text: string; onPress: () => void; style?: "destructive" | "cancel" }[] = [];
    if (status === "pending" || status === "awaiting") {
      actions.push({ text: status === "pending" ? "Send for approval" : "Re-send link", onPress: () => handleSend(co) });
      // Defense in depth: the note always starts blank for a newly-opened
      // target, even though closeDecisionModal already resets it on every
      // close path.
      actions.push({
        text: "Mark approved (on site)",
        onPress: () => {
          setDecisionTarget({ id: co.id, decision: "approved" });
          setDecisionNote("");
        },
      });
      actions.push({
        text: "Mark declined",
        onPress: () => {
          setDecisionTarget({ id: co.id, decision: "declined" });
          setDecisionNote("");
        },
      });
      actions.push({ text: "Cancel change order", style: "destructive", onPress: () => handleCancel(co) });
    }
    if (status === "pending") {
      actions.push({ text: "Edit", onPress: () => onEdit(co.id) });
      actions.push({ text: "Delete", style: "destructive", onPress: () => handleDelete(co) });
    }
    if (actions.length === 0) return; // approved/declined/cancelled: history row, no actions
    Alert.alert(co.title, formatQuote(co.amount), [...actions, { text: "Close", style: "cancel" }]);
  }

  return (
    <Card style={styles.card}>
      <SectionHeader title="Change orders" />
      {cos.map((co) => {
        const status = changeOrderStatus(co);
        return (
          <TouchableOpacity key={co.id} style={styles.row} onPress={() => rowActions(co)} disabled={busy}>
            <View style={styles.rowText}>
              <Text style={styles.rowTitle} numberOfLines={1}>{co.title}</Text>
              {co.manualDecision?.note ? (
                <Text style={styles.rowNote} numberOfLines={1}>{co.manualDecision.note}</Text>
              ) : null}
            </View>
            <Text style={styles.rowAmount}>{formatQuote(co.amount)}</Text>
            <Badge label={STATUS_LABEL[status]} color={STATUS_BADGE[status]} />
          </TouchableOpacity>
        );
      })}
      {canAdd && (
        <View style={styles.addRow}>
          <Button label="Add change order" onPress={onAdd} />
        </View>
      )}

      <Modal visible={decisionTarget !== null} transparent animationType="fade" onRequestClose={closeDecisionModal}>
        <View style={styles.modalBackdrop}>
          <View style={styles.modalCard}>
            <Text style={styles.modalTitle}>
              {decisionTarget?.decision === "approved" ? "Mark approved" : "Mark declined"}
            </Text>
            <Text style={styles.modalHint}>Record how the customer decided — e.g. &quot;verbal OK on site&quot;.</Text>
            <Field label="Note (optional)" value={decisionNote} onChangeText={setDecisionNote} placeholder="verbal OK on site" />
            <View style={styles.modalButtons}>
              <Button label="Cancel" variant="secondary" onPress={closeDecisionModal} />
              <Button label="Confirm" onPress={confirmDecision} loading={busy} />
            </View>
          </View>
        </View>
      </Modal>
    </Card>
  );
}

function createStyles(colors: ColorScheme, shadow: ShadowScheme) {
  return StyleSheet.create({
    card: { marginTop: spacing.lg },
    row: { flexDirection: "row", alignItems: "center", paddingVertical: spacing.sm, gap: spacing.sm },
    rowText: { flex: 1 },
    rowTitle: { fontFamily: fonts.bodyRegular, fontSize: fontSize.md, color: colors.textPrimary },
    rowNote: { fontFamily: fonts.bodyRegular, fontSize: fontSize.sm, color: colors.textMuted },
    rowAmount: { fontFamily: fonts.mono, fontSize: 12, color: colors.textPrimary, fontVariant: ["tabular-nums"] },
    addRow: { marginTop: spacing.sm },
    modalBackdrop: { flex: 1, backgroundColor: "rgba(0,0,0,0.5)", justifyContent: "center", padding: spacing.lg },
    modalCard: { backgroundColor: colors.surface, borderRadius: radius.lg, padding: spacing.lg, ...shadow.card },
    modalTitle: { fontFamily: fonts.display, fontSize: fontSize.lg, color: colors.textPrimary, marginBottom: spacing.xs },
    modalHint: { fontFamily: fonts.bodyRegular, fontSize: fontSize.sm, color: colors.textMuted, marginBottom: spacing.md },
    modalButtons: { flexDirection: "row", justifyContent: "flex-end", gap: spacing.sm, marginTop: spacing.md },
  });
}
