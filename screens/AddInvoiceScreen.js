// screens/AddInvoiceScreen.js
// Used for both adding a new invoice and editing an existing one.
// navigation.navigate("AddInvoice", { invoiceId: "123" }) to edit,
// navigation.navigate("AddInvoice", {}) to add new.

import React, { useState, useEffect } from "react";
import {
  View,
  Text,
  TextInput,
  ScrollView,
  StyleSheet,
  Alert,
  KeyboardAvoidingView,
  Platform,
  TouchableOpacity,
} from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";
import { loadInvoices, saveInvoices } from "../utils/storage";
import { syncNotifications } from "../utils/notifications";
import { Button } from "../components/UI";
import { colors, spacing, radius, fontSize } from "../utils/theme";

export default function AddInvoiceScreen({ route, navigation }) {
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
  }, [invoiceId]);

  async function handleSave() {
    if (!customer.trim() || !amount.trim()) {
      Alert.alert("Missing info", "Customer name and amount are required.");
      return;
    }
    setSaving(true);
    const invoices = await loadInvoices();
    const invoice = {
      customer: customer.trim(),
      number: number.trim() || autoInvoiceNumber(invoices),
      amount: parseFloat(amount) || 0,
      due,
      email: email.trim(),
      phone: phone.trim(),
      desc: desc.trim(),
      paid: false,
    };

    let updated;
    if (isEditing) {
      updated = invoices.map((i) => (i.id === invoiceId ? { ...i, ...invoice } : i));
    } else {
      invoice.id = String(Date.now());
      updated = [...invoices, invoice];
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
          <Field label="Customer name *" value={customer} onChange={setCustomer} placeholder="Jane's Bakery" />
          <Field label="Invoice #" value={number} onChange={setNumber} placeholder="INV-0042 (auto if blank)" />
          <Row>
            <Field label="Amount ($) *" value={amount} onChange={setAmount} placeholder="1500" keyboardType="decimal-pad" flex />
            <View style={{ width: spacing.md }} />
            <Field label="Due date" value={due} onChange={setDue} placeholder="YYYY-MM-DD" flex />
          </Row>
          <Field label="Customer email" value={email} onChange={setEmail} placeholder="jane@example.com" keyboardType="email-address" autoCapitalize="none" />
          <Field label="Customer phone" value={phone} onChange={setPhone} placeholder="(555) 123-4567" keyboardType="phone-pad" />
          <Field label="Description of work" value={desc} onChange={setDesc} placeholder="Website redesign — Phase 2" />

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

function Field({ label, value, onChange, placeholder, keyboardType, autoCapitalize, flex }) {
  return (
    <View style={[styles.fieldGroup, flex && { flex: 1 }]}>
      <Text style={styles.label}>{label}</Text>
      <TextInput
        style={styles.input}
        value={value}
        onChangeText={onChange}
        placeholder={placeholder}
        placeholderTextColor={colors.textMuted}
        keyboardType={keyboardType || "default"}
        autoCapitalize={autoCapitalize || "words"}
        autoCorrect={false}
      />
    </View>
  );
}

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

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: colors.background },
  scroll: { padding: spacing.md, paddingTop: spacing.lg, paddingBottom: 160 },
  fieldGroup: { marginBottom: spacing.md },
  label: { fontSize: fontSize.sm, color: colors.textSecondary, marginBottom: 5, fontWeight: "500" },
  input: {
    backgroundColor: colors.surface,
    borderRadius: radius.md,
    height: 44,
    paddingHorizontal: spacing.md,
    fontSize: fontSize.md,
    color: colors.textPrimary,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: colors.border,
  },
  actions: { flexDirection: "row", marginTop: spacing.lg },
});
