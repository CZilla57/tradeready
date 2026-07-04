// screens/AddCustomerScreen.js
// Lets a tradesperson add a customer manually — before any invoice exists.
// Fields: name (required), phone, email, address, notes.
// Saves to AsyncStorage under the canonical 'tradeready_customers' key.
// Duplicate detection by normalized name prevents accidental doubles.
 
import React, { useState, useLayoutEffect, useEffect, useRef } from "react";
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
  ActivityIndicator,
} from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";
import { loadCustomers, saveCustomers } from "../utils/storage";
import { colors, spacing, radius, fontSize } from "../utils/theme";
 
function buildAddress(item) {
  const a = item.address || {};
  const street = [a.house_number, a.road].filter(Boolean).join(" ");
  const city = a.city || a.town || a.village || a.hamlet || "";
  const region = a.state || "";
  const zip = a.postcode || "";
  const parts = [
    street,
    city,
    region && zip ? `${region} ${zip}` : region || zip,
  ].filter(Boolean);
  return parts.join(", ");
}

function formatPhone(raw) {
  const digits = raw.replace(/\D/g, "").slice(0, 10);
  if (digits.length <= 3) return digits;
  if (digits.length <= 6) return `(${digits.slice(0, 3)}) ${digits.slice(3)}`;
  return `(${digits.slice(0, 3)}) ${digits.slice(3, 6)}-${digits.slice(6)}`;
}

export default function AddCustomerScreen({ route, navigation }) {
  const { customerId } = route.params || {};
  const isEditing = !!customerId;

  const [name, setName]       = useState("");
  const [phone, setPhone]     = useState("");
  const [email, setEmail]     = useState("");
  const [address, setAddress]               = useState("");
  const [addressSuggestions, setAddressSuggestions] = useState([]);
  const [addressLoading, setAddressLoading] = useState(false);
  const [notes, setNotes]     = useState("");
  const [saving, setSaving]   = useState(false);
  const addressTimer = useRef(null);

  useLayoutEffect(() => {
    navigation.setOptions({
      title: isEditing ? "Edit Customer" : "New Customer",
      headerLeft: () => (
        <TouchableOpacity onPress={() => navigation.goBack()} hitSlop={{ top: 8, bottom: 8, left: 8, right: 8 }}>
          <Text style={{ color: colors.accent, fontSize: fontSize.md }}>Cancel</Text>
        </TouchableOpacity>
      ),
    });
  }, [navigation, isEditing]);

  useEffect(() => {
    if (!isEditing) return;
    loadCustomers().then((custs) => {
      const c = custs.find((x) => x.id === customerId);
      if (c) {
        setName(c.name || "");
        setPhone(c.phone || "");
        setEmail(c.email || "");
        setAddress(c.address || "");
        setNotes(c.notes || "");
      }
    });
  }, [customerId, isEditing]);
 
  function handleAddressChange(text) {
    setAddress(text);
    if (addressTimer.current) clearTimeout(addressTimer.current);
    if (text.trim().length < 4) {
      setAddressSuggestions([]);
      return;
    }
    addressTimer.current = setTimeout(async () => {
      setAddressLoading(true);
      try {
        const url =
          `https://nominatim.openstreetmap.org/search` +
          `?q=${encodeURIComponent(text)}&format=json&addressdetails=1&limit=5&countrycodes=us`;
        const res = await fetch(url, { headers: { "User-Agent": "TradeReadyApp/1.0" } });
        const data = await res.json();
        setAddressSuggestions(data.map(buildAddress).filter(Boolean));
      } catch {
        setAddressSuggestions([]);
      } finally {
        setAddressLoading(false);
      }
    }, 400);
  }

  function selectSuggestion(addr) {
    setAddress(addr);
    setAddressSuggestions([]);
  }

  async function handleSave() {
    const trimmedName = name.trim();
    if (!trimmedName) {
      Alert.alert("Name required", "Please enter the customer's name.");
      return;
    }
 
    setSaving(true);
    try {
      const existing = await loadCustomers();

      if (isEditing) {
        const updated = existing.map((c) =>
          c.id === customerId
            ? { ...c, name: trimmedName, phone: phone.trim(), email: email.trim(), address: address.trim(), notes: notes.trim() }
            : c
        );
        await saveCustomers(updated);
      } else {
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
      }

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
            autoFocus={!isEditing}
          />
          <Field
            label="Phone"
            value={phone}
            onChange={(v) => setPhone(formatPhone(v))}
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
          <View style={styles.fieldGroup}>
            <Text style={styles.label}>Address</Text>
            <TextInput
              style={styles.input}
              value={address}
              onChangeText={handleAddressChange}
              placeholder="123 Main St, City, ST 00000"
              placeholderTextColor={colors.textMuted}
              autoCapitalize="words"
              autoCorrect={false}
            />
            {(addressLoading || addressSuggestions.length > 0) && (
              <View style={styles.suggestions}>
                {addressLoading && (
                  <ActivityIndicator
                    size="small"
                    color={colors.textMuted}
                    style={styles.suggestionsSpinner}
                  />
                )}
                {addressSuggestions.map((addr, i) => (
                  <TouchableOpacity
                    key={i}
                    style={[
                      styles.suggestionRow,
                      i < addressSuggestions.length - 1 && styles.suggestionBorder,
                    ]}
                    onPress={() => selectSuggestion(addr)}
                  >
                    <Text style={styles.suggestionText}>{addr}</Text>
                  </TouchableOpacity>
                ))}
              </View>
            )}
          </View>
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

  suggestions: {
    marginTop: 4,
    backgroundColor: colors.surface,
    borderRadius: radius.md,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: colors.border,
    overflow: "hidden",
  },
  suggestionsSpinner: {
    paddingVertical: spacing.sm,
  },
  suggestionRow: {
    paddingHorizontal: spacing.md,
    paddingVertical: 12,
  },
  suggestionBorder: {
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: colors.border,
  },
  suggestionText: {
    fontSize: fontSize.sm,
    color: colors.textPrimary,
    lineHeight: 18,
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
