// screens/AddChangeOrderScreen.tsx
// Modal form for creating (or editing a still-PENDING) change order on a job.
// Fast on-site entry: title + description + amount. Negative amount = descope
// credit. Validation lives in utils/changeOrders.validateChangeOrderInput.

import React, { useEffect, useMemo, useState } from "react";
import { Alert, KeyboardAvoidingView, Platform, ScrollView, StyleSheet, Text, View } from "react-native";
import type { NativeStackScreenProps } from "@react-navigation/native-stack";
import Field from "../components/Field";
import { Button } from "../components/UI";
import { useTheme } from "../hooks/useTheme";
import { spacing } from "../utils/theme";
import type { ColorScheme, ShadowScheme } from "../utils/theme";
import { loadJobs, saveJobs } from "../utils/storage";
import {
  canAddChangeOrder,
  changeOrderStatus,
  newChangeOrderId,
  validateChangeOrderInput,
} from "../utils/changeOrders";
import { track } from "../utils/analytics";
import type { Job, ChangeOrder } from "../types/models";
import type { JobStackParamList } from "../types/navigation";

type Props = NativeStackScreenProps<JobStackParamList, "AddChangeOrder">;

export default function AddChangeOrderScreen({ route, navigation }: Props) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  const { jobId, changeOrderId } = route.params;

  const [job, setJob] = useState<Job | null>(null);
  const [title, setTitle] = useState("");
  const [description, setDescription] = useState("");
  const [amount, setAmount] = useState("");
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    (async () => {
      const jobs = await loadJobs();
      const j = jobs.find((x) => x.id === jobId);
      if (!j || (!changeOrderId && !canAddChangeOrder(j.status))) {
        Alert.alert("Error", "Change orders can be added once a job is approved and before it's invoiced.");
        navigation.goBack();
        return;
      }
      setJob(j);
      if (changeOrderId) {
        const co = (j.changeOrders ?? []).find((c) => c.id === changeOrderId);
        if (!co || changeOrderStatus(co) !== "pending") {
          Alert.alert("Error", "Only a change order that hasn't been sent or decided can be edited.");
          navigation.goBack();
          return;
        }
        navigation.setOptions({ title: "Edit Change Order" });
        setTitle(co.title);
        setDescription(co.description ?? "");
        setAmount(String(co.amount));
      }
    })();
  }, [jobId, changeOrderId, navigation]);

  async function handleSave() {
    if (!job) return;
    const result = validateChangeOrderInput(title, amount, job, changeOrderId);
    if (!result.ok) {
      Alert.alert("Check the form", result.message);
      return;
    }
    setSaving(true);
    try {
      const jobs = await loadJobs();
      const freshJob = jobs.find((x) => x.id === jobId);
      if (!freshJob) {
        Alert.alert("Error", "Could not save this change order. Please try again.");
        return;
      }
      const existing = freshJob.changeOrders ?? [];

      // Re-check against freshly-loaded data (not the stale `job` from mount)
      // in case a sync pulled in a decision while this screen was open.
      if (changeOrderId) {
        const freshCo = existing.find((c) => c.id === changeOrderId);
        if (!freshCo || changeOrderStatus(freshCo) !== "pending") {
          Alert.alert("Can't edit", "This change order was decided while you were editing. Your changes were not saved.");
          navigation.goBack();
          return;
        }
      } else if (!canAddChangeOrder(freshJob.status)) {
        Alert.alert("Error", "This job can no longer take change orders.");
        navigation.goBack();
        return;
      }

      const today = new Date().toISOString().split("T")[0];
      const updated = jobs.map((j): Job => {
        if (j.id !== jobId) return j;
        if (changeOrderId) {
          return {
            ...j,
            changeOrders: existing.map((c) =>
              c.id === changeOrderId
                ? { ...c, title: result.title, description: description.trim() || undefined, amount: result.amount }
                : c,
            ),
          };
        }
        const co: ChangeOrder = {
          id: newChangeOrderId(),
          title: result.title,
          ...(description.trim() ? { description: description.trim() } : {}),
          amount: result.amount,
          createdAt: today,
        };
        return { ...j, changeOrders: [...existing, co] };
      });
      await saveJobs(updated);
      if (!changeOrderId) track("change_order_created", { amount: result.amount });
      navigation.goBack();
    } catch (err) {
      console.error("AddChangeOrderScreen: save failed", err);
      Alert.alert("Error", "Could not save this change order. Please try again.");
    } finally {
      setSaving(false);
    }
  }

  return (
    <KeyboardAvoidingView style={styles.flex} behavior={Platform.OS === "ios" ? "padding" : undefined}>
      <ScrollView style={styles.container} keyboardShouldPersistTaps="handled">
        <Field label="What changed?" value={title} onChangeText={setTitle} placeholder="e.g. Replace rotted subfloor section" />
        <Field label="Details (optional)" value={description} onChangeText={setDescription} placeholder="What you found and what it takes to fix" multiline />
        <Field label="Amount ($)" value={amount} onChangeText={setAmount} placeholder="850 (negative for a credit)" keyboardType="numbers-and-punctuation" />
        <Text style={styles.hint}>
          Use a negative amount for a descope credit. The customer approves this change before the extra work starts.
        </Text>
        <View style={styles.buttonRow}>
          <Button
            label={saving ? "Saving…" : changeOrderId ? "Save changes" : "Add change order"}
            onPress={handleSave}
            loading={saving}
          />
        </View>
      </ScrollView>
    </KeyboardAvoidingView>
  );
}

function createStyles(colors: ColorScheme, shadow: ShadowScheme) {
  return StyleSheet.create({
    flex: { flex: 1 },
    container: { flex: 1, backgroundColor: colors.background, padding: spacing.lg },
    hint: { color: colors.textMuted, marginTop: spacing.sm, marginBottom: spacing.lg },
    buttonRow: { marginTop: spacing.md, marginBottom: spacing.xl },
  });
}
