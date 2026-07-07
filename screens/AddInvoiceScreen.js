// screens/AddInvoiceScreen.js
// Used for both adding a new invoice and editing an existing one.
// navigation.navigate("AddInvoice", { invoiceId: "123" }) to edit,
// navigation.navigate("AddInvoice", {}) to add new.

import React, { useState, useEffect, useMemo } from "react";
import {
  View,
  ScrollView,
  StyleSheet,
  Alert,
  KeyboardAvoidingView,
  Platform,
} from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";
import { loadInvoices, saveInvoices, getOrCreateCustomer } from "../utils/storage";
import { syncNotifications } from "../utils/notifications";
import { Button } from "../components/UI";
import Field from "../components/Field";
import { spacing } from "../utils/theme";
import { useTheme } from '../hooks/useTheme';

export default function AddInvoiceScreen({ route, navigation }) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  const { invoiceId, prefill } = route.params || {};
  const isEditing = !!invoiceId;

  const [customer, setCustomer] = useState("");
  const [number, setNumber] = useState("");
  const [amount, setAmount] = useState("");
  const [due, setDue] = useState(defaultDueDate());
  const [email, setEmail] = useState("");
  const [phone, setPhone] = useState("");
  const [desc, setDesc] = useState("");
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    navigation.setOptions({ title: isEditing ? "Edit Invoice" : "New Invoice" });
    if (isEditing) {
      loadInvoices().then((invoices) => {
        const inv = invoices.find((i) => i.id === invoiceId);
        if (inv) {
          setCustomer(inv.customer);
          setNumber(inv.number);
          setAmount(String(inv.amount));
          setDue(inv.due);
          setEmail(inv.email);
          setPhone(inv.phone);
          setDesc(inv.desc);
        }
      });
    } else if (prefill) {
      if (prefill.customer) setCustomer(prefill.customer);
      if (prefill.email)    setEmail(prefill.email);
      if (prefill.phone)    setPhone(prefill.phone);
    }
  }, [invoiceId, isEditing, navigation, prefill]);

  async function handleSave() {
    if (!customer.trim() || !amount.trim()) {
      Alert.alert("Missing info", "Customer name and amount are required.");
      return;
    }
    setSaving(true);
    const invoices = await loadInvoices();
    // Link to a real customer record (creating one if needed); `customer` stays
    // as the denormalized display name (roadmap #5).
    const record = await getOrCreateCustomer({
      name: customer.trim(),
      email: email.trim(),
      phone: phone.trim(),
    });
    const invoiceFields = {
      customer: customer.trim(),
      customerId: record?.id ?? "",
      number: number.trim() || autoInvoiceNumber(invoices),
      amount: parseFloat(amount) || 0,
      due,
      email: email.trim(),
      phone: phone.trim(),
      desc: desc.trim(),
    };

    let updated;
    if (isEditing) {
      // Spread only editable fields so paid status is never silently reset
      updated = invoices.map((i) => (i.id === invoiceId ? { ...i, ...invoiceFields } : i));
    } else {
      updated = [...invoices, { ...invoiceFields, paid: false, id: String(Date.now()) }];
    }

    await saveInvoices(updated);
    syncNotifications(); // fire-and-forget — reschedules all reminders
    setSaving(false);
    navigation.goBack();
  }

  return (
    <SafeAreaView style={styles.container} edges={["bottom"]}>
      <KeyboardAvoidingView
        behavior={Platform.OS === "ios" ? "padding" : undefined}
        style={{ flex: 1 }}
      >
        <ScrollView contentContainerStyle={styles.scroll} keyboardShouldPersistTaps="handled">
          <Field label="Customer name *" value={customer} onChangeText={setCustomer} placeholder="Jane's Bakery" />
          <Field label="Invoice #" value={number} onChangeText={setNumber} placeholder="INV-0042 (auto if blank)" />
          <Row>
            <Field label="Amount ($) *" value={amount} onChangeText={setAmount} placeholder="1500" keyboardType="decimal-pad" flex />
            <View style={{ width: spacing.md }} />
            <Field label="Due date" value={due} onChangeText={setDue} placeholder="YYYY-MM-DD" flex />
          </Row>
          <Field label="Customer email" value={email} onChangeText={setEmail} placeholder="jane@example.com" keyboardType="email-address" autoCapitalize="none" />
          <Field label="Customer phone" value={phone} onChangeText={setPhone} placeholder="(555) 123-4567" keyboardType="phone-pad" />
          <Field label="Description of work" value={desc} onChangeText={setDesc} placeholder="Website redesign — Phase 2" />

          <View style={styles.actions}>
            <Button label="Cancel" variant="ghost" onPress={() => navigation.goBack()} style={{ flex: 1 }} />
            <View style={{ width: spacing.sm }} />
            <Button label={isEditing ? "Save changes" : "Add invoice"} onPress={handleSave} loading={saving} style={{ flex: 2 }} />
          </View>
        </ScrollView>
      </KeyboardAvoidingView>
    </SafeAreaView>
  );
}

// ── Small helpers ──────────────────────────────────────────────────────────

function Row({ children }) {
  return <View style={{ flexDirection: "row" }}>{children}</View>;
}

function defaultDueDate() {
  const d = new Date();
  d.setDate(d.getDate() + 30);
  return d.toISOString().split("T")[0];
}

function autoInvoiceNumber(invoices) {
  const nums = invoices
    .map((i) => parseInt(i.number.replace(/\D/g, "")))
    .filter(Boolean);
  const next = nums.length ? Math.max(...nums) + 1 : 1;
  return `INV-${String(next).padStart(4, "0")}`;
}

function createStyles(colors, shadow) {
  return StyleSheet.create({
  container: { flex: 1, backgroundColor: colors.background },
  scroll: { padding: spacing.md, paddingTop: spacing.lg, paddingBottom: 160 },
  actions: { flexDirection: "row", marginTop: spacing.lg },
  });
}
