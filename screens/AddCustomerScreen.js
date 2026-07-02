// screens/AddCustomerScreen.js
// Lets a tradesperson add a customer manually — before any invoice exists.
// Fields: name (required), phone, email, address, notes.
// Saves to AsyncStorage under the canonical 'tradeready_customers' key.
// Duplicate detection by normalized name prevents accidental doubles.
 
import React, { useState, useEffect } from "react";
import {
  View,
  Text,
  TextInput,
  ScrollView,
  TouchableOpacity,
  StyleSheet,
  Alert,
  KeyboardAvoidingView,
  Platform,
} from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";
import { loadCustomers, saveCustomers } from "../utils/storage";
import { colors, spacing, radius, fontSize } from "../utils/theme";
 
export default function AddCustomerScreen({ navigation }) {
  const [name, setName]       = useState("");
  const [phone, setPhone]     = useState("");
  const [email, setEmail]     = useState("");
  const [address, setAddress] = useState("");
  const [notes, setNotes]     = useState("");
  const [saving, setSaving]   = useState(false);
 
  useEffect(() => {
    navigation.setOptions({ title: "New Customer" });
  }, []);
 
  async function handleSave() {
    const trimmedName = name.trim();
    if (!trimmedName) {
      Alert.alert("Name required", "Please enter the customer's name.");
      return;
    }
 
    setSaving(true);
    try {
      const existing = await loadCustomers();
 
      // Duplicate check — normalize both sides to catch "Mike Smith" vs "mike smith"
      const normalizedNew = trimmedName.toLowerCase();
      const duplicate = existing.find(
        (c) => c.name.trim().toLowerCase() === normalizedNew
      );
      if (duplicate) {
        Alert.alert(
          "Customer already exists",
          `"${duplicate.name}" is already in your customer list.`,
          [{ text: "OK" }]
        );
        setSaving(false);
        return;
      }
 
      const newCustomer = {
        id:        `c${Date.now()}`,
        name:      trimmedName,
        phone:     phone.trim(),
        email:     email.trim(),
        address:   address.trim(),
        notes:     notes.trim(),
        createdAt: new Date().toISOString(),
      };
 
      await saveCustomers([...existing, newCustomer]);
      navigation.goBack();
    } catch (err) {
      console.error("AddCustomerScreen: save failed", err);
      Alert.alert("Error", "Could not save customer. Please try again.");
    } finally {
      setSaving(false);
    }
  }
 
  return (
    <SafeAreaView style={styles.container} edges={["bottom"]}>
      <KeyboardAvoidingView
        behavior={Platform.OS === "ios" ? "padding" : undefined}
        style={{ flex: 1 }}
      >
        <ScrollView
          contentContainerStyle={styles.scroll}
          keyboardShouldPersistTaps="handled"
        >
          <Field
            label="Full name *"
            value={name}
            onChange={setName}
            placeholder="Jane Smith"
            autoFocus
          />
          <Field
            label="Phone"
            value={phone}
            onChange={setPhone}
            placeholder="(555) 123-4567"
            keyboardType="phone-pad"
          />
          <Field
            label="Email"
            value={email}
            onChange={setEmail}
            placeholder="jane@example.com"
            keyboardType="email-address"
            autoCapitalize="none"
          />
          <Field
            label="Address"
            value={address}
            onChange={setAddress}
            placeholder="123 Main St, City, ST 00000"
          />
          <Field
            label="Notes"
            value={notes}
            onChange={setNotes}
            placeholder="Gate code, parking, referral source..."
            multiline
          />
 
          <View style={styles.actions}>
            <TouchableOpacity
              style={styles.cancelBtn}
              onPress={() => navigation.goBack()}
            >
              <Text style={styles.cancelBtnText}>Cancel</Text>
            </TouchableOpacity>
            <TouchableOpacity
              style={[styles.saveBtn, saving && styles.saveBtnDisabled]}
              onPress={handleSave}
              disabled={saving}
            >
              <Text style={styles.saveBtnText}>
                {saving ? "Saving..." : "Add customer"}
              </Text>
            </TouchableOpacity>
          </View>
        </ScrollView>
      </KeyboardAvoidingView>
    </SafeAreaView>
  );
}
 
function Field({ label, value, onChange, placeholder, keyboardType, autoCapitalize, multiline, autoFocus }) {
  return (
    <View style={styles.fieldGroup}>
      <Text style={styles.label}>{label}</Text>
      <TextInput
        style={[styles.input, multiline && styles.inputMulti]}
        value={value}
        onChangeText={onChange}
        placeholder={placeholder}
        placeholderTextColor={colors.textMuted}
        keyboardType={keyboardType || "default"}
        autoCapitalize={autoCapitalize || "words"}
        autoCorrect={false}
        multiline={multiline}
        numberOfLines={multiline ? 3 : 1}
        autoFocus={autoFocus}
      />
    </View>
  );
}
 
const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: colors.background },
  scroll:    { padding: spacing.md, paddingTop: spacing.lg, paddingBottom: 160 },
 
  fieldGroup:  { marginBottom: spacing.md },
  label: {
    fontSize: fontSize.sm,
    color: colors.textSecondary,
    marginBottom: 5,
    fontWeight: "500",
  },
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
  inputMulti: {
    height: 88,
    paddingTop: spacing.sm,
    textAlignVertical: "top",
  },
 
  actions: {
    flexDirection: "row",
    gap: spacing.sm,
    marginTop: spacing.lg,
  },
  cancelBtn: {
    flex: 1,
    height: 48,
    borderRadius: radius.md,
    borderWidth: 1,
    borderColor: colors.border,
    alignItems: "center",
    justifyContent: "center",
  },
  cancelBtnText: {
    fontSize: fontSize.md,
    color: colors.textSecondary,
    fontWeight: "500",
  },
  saveBtn: {
    flex: 2,
    height: 48,
    borderRadius: radius.md,
    backgroundColor: colors.accent,
    alignItems: "center",
    justifyContent: "center",
  },
  saveBtnDisabled: {
    opacity: 0.6,
  },
  saveBtnText: {
    fontSize: fontSize.md,
    color: colors.textOnAccent,
    fontWeight: "700",
  },
});
