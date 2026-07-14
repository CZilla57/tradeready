import React, { useState, useEffect, useMemo } from "react";
import {
  View, Text, TextInput, ScrollView, TouchableOpacity,
  Alert, StyleSheet, KeyboardAvoidingView, Platform,
} from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";
import { loadPricebook, savePricebook, loadSettings } from "../utils/storage";
import { calculateEstimate, buildEstimateInput } from "../utils/pricingEngine";
import { formatQuote } from "../utils/format";
import { Button, Card } from "../components/UI";
import { spacing, radius, fontSize } from "../utils/theme";
import type { ColorScheme, ShadowScheme } from "../utils/theme";
import { useTheme } from "../hooks/useTheme";
import type { PricebookEntry, Settings, AIPricingSuggestion } from "../types/models";
import { getAIPricingSuggestion } from "../utils/pricebookAI";
import { track } from '../utils/analytics';
import type { MoneyStackScreenProps } from "../types/navigation";

interface LocalMaterial {
  id: string;
  name: string;
  quantity: number | string;
  unitCost: number | string;
}

export default function PricebookEntryScreen({
  route,
  navigation,
}: MoneyStackScreenProps<'PricebookEntry'>) {
  const entryId = route.params?.entryId as string | undefined;
  const isEditing = Boolean(entryId);
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);

  const [name, setName] = useState("");
  const [description, setDescription] = useState("");
  const [category, setCategory] = useState("");
  const [laborHours, setLaborHours] = useState("2");
  const [laborRate, setLaborRate] = useState("85");
  const [materials, setMaterials] = useState<LocalMaterial[]>([]);
  const [materialMarkup, setMaterialMarkup] = useState("20");
  const [overheadPercent, setOverheadPercent] = useState("15");
  const [marginPercent, setMarginPercent] = useState("20");
  const [existingCategories, setExistingCategories] = useState<string[]>([]);
  const [showCategorySuggestions, setShowCategorySuggestions] = useState(false);
  const [saving, setSaving] = useState(false);
  const [settings, setSettings] = useState<Settings | null>(null);
  const [aiLoading, setAiLoading] = useState(false);
  const [aiSuggestion, setAiSuggestion] = useState<AIPricingSuggestion | null>(null);

  useEffect(() => {
    async function load() {
      const [entries, s] = await Promise.all([loadPricebook(), loadSettings()]);
      setSettings(s);

      const cats = [...new Set(entries.map((e) => e.category).filter(Boolean))] as string[];
      setExistingCategories(cats);

      if (entryId) {
        const entry = entries.find((e) => e.id === entryId);
        if (entry) {
          setName(entry.name);
          setDescription(entry.description || "");
          setCategory(entry.category || "");
          setLaborHours(String(entry.laborHours));
          setLaborRate(String(entry.laborRate));
          setMaterials(entry.materials as LocalMaterial[]);
          setMaterialMarkup(String(entry.materialMarkup));
          setOverheadPercent(String(entry.overhead));
          setMarginPercent(String(entry.margin));
        }
      } else if (s) {
        setLaborRate(String(s.laborRate || 85));
        setMaterialMarkup(String(s.materialMarkup ?? 20));
        setOverheadPercent(String(s.overheadPercent ?? 15));
        setMarginPercent(String(s.marginPercent ?? 20));
      }
    }
    load();
  }, [entryId]);

  const params = buildEstimateInput(
    { laborHours, laborRate, materials: materials as any, materialMarkup, overheadPercent, marginPercent, travelMiles: "0", isEmergency: false, taxPercent: "0" },
    settings,
  );
  const breakdown = calculateEstimate(params);

  function addMaterial() {
    setMaterials((prev) => [
      ...prev,
      { id: `m${Date.now()}`, name: "", quantity: 1, unitCost: 0 },
    ]);
  }

  function updateMaterial(id: string, field: keyof LocalMaterial, value: string | number) {
    setMaterials((prev) =>
      prev.map((m) => (m.id === id ? { ...m, [field]: value } : m)),
    );
  }

  function removeMaterial(id: string) {
    setMaterials((prev) => prev.filter((m) => m.id !== id));
  }

  async function handleSave() {
    if (!name.trim()) {
      Alert.alert("Name required", "Give this service a name so you can find it later.");
      return;
    }
    setSaving(true);
    const entries = await loadPricebook();
    const now = new Date().toISOString();

    const entry: PricebookEntry = {
      id: entryId || `pb-${Date.now()}`,
      name: name.trim(),
      description: description.trim() || undefined,
      category: category.trim() || undefined,
      laborHours: params.laborHours,
      laborRate: params.laborRate,
      materials: materials.map((m) => ({
        id: m.id,
        name: String(m.name),
        quantity: parseFloat(String(m.quantity)) || 0,
        unitCost: parseFloat(String(m.unitCost)) || 0,
      })),
      materialMarkup: params.materialMarkup,
      overhead: params.overheadPercent,
      margin: params.marginPercent,
      estimateTotal: breakdown.total,
      createdAt: entryId
        ? entries.find((e) => e.id === entryId)?.createdAt || now
        : now,
      updatedAt: now,
    };

    const updated = entryId
      ? entries.map((e) => (e.id === entryId ? entry : e))
      : [...entries, entry];

    await savePricebook(updated);
    track('pricebook_entry_saved');
    setSaving(false);
    navigation.goBack();
  }

  async function handleAISuggest() {
    if (!name.trim()) {
      Alert.alert("Name required", "Enter a service name so the AI knows what to price.");
      return;
    }
    setAiLoading(true);
    setAiSuggestion(null);
    const result = await getAIPricingSuggestion({
      serviceName: name.trim(),
      description: description.trim() || undefined,
      category: category.trim() || undefined,
      materials: materials.map((m) => ({
        id: m.id,
        name: String(m.name),
        quantity: parseFloat(String(m.quantity)) || 0,
        unitCost: parseFloat(String(m.unitCost)) || 0,
      })),
      laborHours: parseFloat(laborHours) || 0,
      laborRate: parseFloat(laborRate) || 0,
      settings,
    });
    setAiLoading(false);
    if (result) {
      setAiSuggestion(result);
    } else {
      Alert.alert("Couldn't get suggestions", "AI pricing is unavailable right now. Try again later.");
    }
  }

  const filteredCategories = existingCategories.filter(
    (c) => c.toLowerCase().includes(category.toLowerCase()) && c.toLowerCase() !== category.toLowerCase(),
  );

  return (
    <SafeAreaView style={styles.container} edges={["bottom"]}>
      <KeyboardAvoidingView
        behavior={Platform.OS === "ios" ? "padding" : undefined}
        style={{ flex: 1 }}
      >
        <ScrollView contentContainerStyle={styles.scroll} keyboardShouldPersistTaps="handled">
          <Card>
            <Text style={styles.label}>Service name *</Text>
            <TextInput
              style={styles.input}
              placeholder="e.g. Water Heater Install"
              placeholderTextColor={colors.textMuted}
              value={name}
              onChangeText={setName}
              accessibilityLabel="Service name"
            />

            <Text style={styles.label}>Description</Text>
            <TextInput
              style={[styles.input, { minHeight: 60 }]}
              placeholder="Optional notes about this service"
              placeholderTextColor={colors.textMuted}
              value={description}
              onChangeText={setDescription}
              multiline
              accessibilityLabel="Description"
            />

            <Text style={styles.label}>Category</Text>
            <TextInput
              style={styles.input}
              placeholder="e.g. Plumbing, Electrical"
              placeholderTextColor={colors.textMuted}
              value={category}
              onChangeText={(v) => {
                setCategory(v);
                setShowCategorySuggestions(v.length > 0);
              }}
              onFocus={() => setShowCategorySuggestions(category.length > 0)}
              onBlur={() => setTimeout(() => setShowCategorySuggestions(false), 200)}
              accessibilityLabel="Category"
            />
            {showCategorySuggestions && filteredCategories.length > 0 && (
              <View style={styles.suggestions}>
                {filteredCategories.map((c) => (
                  <TouchableOpacity
                    key={c}
                    style={styles.suggestionRow}
                    onPress={() => {
                      setCategory(c);
                      setShowCategorySuggestions(false);
                    }}
                    accessibilityRole="button"
                    accessibilityLabel={`Use category ${c}`}
                  >
                    <Text style={styles.suggestionText}>{c}</Text>
                  </TouchableOpacity>
                ))}
              </View>
            )}
          </Card>

          <Card style={{ marginTop: spacing.md }}>
            <Text style={styles.sectionTitle}>Pricing</Text>
            <View style={styles.fieldRow}>
              <View style={{ flex: 1 }}>
                <Text style={styles.label}>Labor hours</Text>
                <TextInput
                  style={styles.input}
                  value={laborHours}
                  onChangeText={setLaborHours}
                  keyboardType="decimal-pad"
                  accessibilityLabel="Labor hours"
                />
              </View>
              <View style={{ width: spacing.sm }} />
              <View style={{ flex: 1 }}>
                <Text style={styles.label}>Labor rate ($/hr)</Text>
                <TextInput
                  style={styles.input}
                  value={laborRate}
                  onChangeText={setLaborRate}
                  keyboardType="decimal-pad"
                  accessibilityLabel="Labor rate in dollars per hour"
                />
              </View>
            </View>

            <Text style={[styles.label, { marginTop: spacing.md }]}>Materials</Text>
            {materials.map((m) => (
              <View key={m.id} style={styles.materialRow}>
                <TextInput
                  style={[styles.matInput, { flex: 2 }]}
                  placeholder="Item name"
                  placeholderTextColor={colors.textMuted}
                  value={String(m.name)}
                  onChangeText={(v) => updateMaterial(m.id, "name", v)}
                  accessibilityLabel="Material name"
                />
                <TextInput
                  style={styles.matInput}
                  placeholder="Qty"
                  placeholderTextColor={colors.textMuted}
                  value={String(m.quantity)}
                  onChangeText={(v) => updateMaterial(m.id, "quantity", v)}
                  keyboardType="decimal-pad"
                  accessibilityLabel="Material quantity"
                />
                <TextInput
                  style={styles.matInput}
                  placeholder="$ each"
                  placeholderTextColor={colors.textMuted}
                  value={String(m.unitCost)}
                  onChangeText={(v) => updateMaterial(m.id, "unitCost", v)}
                  keyboardType="decimal-pad"
                  accessibilityLabel="Material cost each"
                />
                <TouchableOpacity
                  onPress={() => removeMaterial(m.id)}
                  style={styles.removeBtn}
                  accessibilityRole="button"
                  accessibilityLabel={`Remove material ${String(m.name) || "item"}`}
                >
                  <Text style={styles.removeBtnText}>✕</Text>
                </TouchableOpacity>
              </View>
            ))}
            <TouchableOpacity style={styles.addMaterialBtn} onPress={addMaterial} accessibilityRole="button" accessibilityLabel="Add material">
              <Text style={styles.addMaterialText}>+ Add material</Text>
            </TouchableOpacity>

            <View style={[styles.fieldRow, { marginTop: spacing.md }]}>
              <View style={{ flex: 1 }}>
                <Text style={styles.label}>Markup %</Text>
                <TextInput style={styles.input} value={materialMarkup} onChangeText={setMaterialMarkup} keyboardType="decimal-pad" accessibilityLabel="Material markup percent" />
              </View>
              <View style={{ width: spacing.sm }} />
              <View style={{ flex: 1 }}>
                <Text style={styles.label}>Overhead %</Text>
                <TextInput style={styles.input} value={overheadPercent} onChangeText={setOverheadPercent} keyboardType="decimal-pad" accessibilityLabel="Overhead percent" />
              </View>
              <View style={{ width: spacing.sm }} />
              <View style={{ flex: 1 }}>
                <Text style={styles.label}>Margin %</Text>
                <TextInput style={styles.input} value={marginPercent} onChangeText={setMarginPercent} keyboardType="decimal-pad" accessibilityLabel="Profit margin percent" />
              </View>
            </View>
          </Card>

          <Card style={{ marginTop: spacing.md }}>
            <View style={styles.totalRow}>
              <Text style={styles.totalLabel}>Estimated Total</Text>
              <Text style={styles.totalValue}>{formatQuote(breakdown.total)}</Text>
            </View>
          </Card>

          <Card style={{ marginTop: spacing.md }}>
            <Button
              label={aiLoading ? "Getting suggestions..." : "🤖 Get AI Pricing Suggestions"}
              variant="secondary"
              onPress={handleAISuggest}
              loading={aiLoading}
            />
          </Card>

          {aiSuggestion && (
            <Card style={{ marginTop: spacing.md }}>
              <Text style={styles.sectionTitle}>AI Suggestions</Text>

              {aiSuggestion.laborHours && (
                <View style={styles.suggestionItem}>
                  <View style={{ flex: 1 }}>
                    <Text style={styles.suggestionLabel}>Labor: {aiSuggestion.laborHours.suggested} hrs</Text>
                    <Text style={styles.suggestionReasoning}>{aiSuggestion.laborHours.reasoning}</Text>
                  </View>
                  <TouchableOpacity
                    style={styles.applyBtn}
                    onPress={() => setLaborHours(String(aiSuggestion.laborHours!.suggested))}
                    accessibilityRole="button"
                    accessibilityLabel={`Apply suggested labor hours: ${aiSuggestion.laborHours.suggested}`}
                  >
                    <Text style={styles.applyBtnText}>Apply</Text>
                  </TouchableOpacity>
                </View>
              )}

              {aiSuggestion.laborRate && (
                <View style={styles.suggestionItem}>
                  <View style={{ flex: 1 }}>
                    <Text style={styles.suggestionLabel}>Rate: ${aiSuggestion.laborRate.suggested}/hr</Text>
                    <Text style={styles.suggestionReasoning}>{aiSuggestion.laborRate.reasoning}</Text>
                  </View>
                  <TouchableOpacity
                    style={styles.applyBtn}
                    onPress={() => setLaborRate(String(aiSuggestion.laborRate!.suggested))}
                    accessibilityRole="button"
                    accessibilityLabel={`Apply suggested labor rate: ${aiSuggestion.laborRate.suggested} dollars per hour`}
                  >
                    <Text style={styles.applyBtnText}>Apply</Text>
                  </TouchableOpacity>
                </View>
              )}

              {aiSuggestion.materials?.map((m, i) => (
                <View key={i} style={styles.suggestionItem}>
                  <View style={{ flex: 1 }}>
                    <Text style={styles.suggestionLabel}>{m.name}: ${m.suggestedUnitCost}</Text>
                    <Text style={styles.suggestionReasoning}>{m.reasoning}</Text>
                  </View>
                  <TouchableOpacity
                    style={styles.applyBtn}
                    accessibilityRole="button"
                    accessibilityLabel={`Apply suggested cost for ${m.name}: ${m.suggestedUnitCost} dollars`}
                    onPress={() => {
                      const existing = materials.find(
                        (mat) => String(mat.name).toLowerCase() === m.name.toLowerCase(),
                      );
                      if (existing) {
                        updateMaterial(existing.id, "unitCost", m.suggestedUnitCost);
                      } else {
                        setMaterials((prev) => [
                          ...prev,
                          { id: `m${Date.now()}-${i}`, name: m.name, quantity: 1, unitCost: m.suggestedUnitCost },
                        ]);
                      }
                    }}
                  >
                    <Text style={styles.applyBtnText}>Apply</Text>
                  </TouchableOpacity>
                </View>
              ))}

              {aiSuggestion.overallRange && (
                <View style={[styles.suggestionItem, { borderBottomWidth: 0 }]}>
                  <View style={{ flex: 1 }}>
                    <Text style={styles.suggestionLabel}>
                      Market range: {formatQuote(aiSuggestion.overallRange.low)} – {formatQuote(aiSuggestion.overallRange.high)}
                    </Text>
                    <Text style={styles.suggestionReasoning}>
                      Mid: {formatQuote(aiSuggestion.overallRange.mid)} · {aiSuggestion.overallRange.reasoning}
                    </Text>
                  </View>
                </View>
              )}
            </Card>
          )}

          <View style={styles.actions}>
            <Button
              label={saving ? "Saving..." : isEditing ? "Update Service" : "Save Service"}
              onPress={handleSave}
              loading={saving}
              style={{ flex: 1 }}
            />
          </View>
        </ScrollView>
      </KeyboardAvoidingView>
    </SafeAreaView>
  );
}

function createStyles(colors: ColorScheme, shadow: ShadowScheme) {
  return StyleSheet.create({
    container: { flex: 1, backgroundColor: colors.background },
    scroll: { padding: spacing.lg, paddingBottom: 40 },
    label: { color: colors.textSecondary, fontSize: fontSize.sm, fontWeight: "500", marginBottom: 4 },
    sectionTitle: { color: colors.textPrimary, fontSize: fontSize.md, fontWeight: "700", marginBottom: spacing.sm },
    input: {
      backgroundColor: colors.background,
      borderRadius: radius.md,
      padding: spacing.sm + 2,
      color: colors.textPrimary,
      fontSize: fontSize.md,
      borderWidth: 1,
      borderColor: colors.border,
      marginBottom: spacing.sm,
    },
    fieldRow: { flexDirection: "row" },
    materialRow: {
      flexDirection: "row",
      alignItems: "center",
      marginBottom: spacing.xs,
      gap: 4,
    },
    matInput: {
      flex: 1,
      backgroundColor: colors.background,
      borderRadius: radius.sm,
      padding: spacing.sm,
      color: colors.textPrimary,
      fontSize: fontSize.sm,
      borderWidth: 1,
      borderColor: colors.border,
    },
    removeBtn: {
      padding: spacing.xs,
      marginLeft: 2,
    },
    removeBtnText: { color: colors.danger, fontSize: fontSize.md, fontWeight: "600" },
    addMaterialBtn: { paddingVertical: spacing.sm },
    addMaterialText: { color: colors.accent, fontSize: fontSize.sm, fontWeight: "600" },
    suggestions: {
      backgroundColor: colors.surface,
      borderRadius: radius.sm,
      borderWidth: 1,
      borderColor: colors.border,
      marginBottom: spacing.sm,
      marginTop: -spacing.sm + 2,
    },
    suggestionRow: { padding: spacing.sm, borderBottomWidth: 1, borderBottomColor: colors.border },
    suggestionText: { color: colors.textPrimary, fontSize: fontSize.md },
    totalRow: {
      flexDirection: "row",
      justifyContent: "space-between",
      alignItems: "center",
    },
    totalLabel: { color: colors.textPrimary, fontSize: fontSize.md, fontWeight: "600" },
    totalValue: { color: colors.accent, fontSize: fontSize.xl, fontWeight: "700" },
    actions: { marginTop: spacing.lg },
    suggestionItem: {
      flexDirection: "row",
      alignItems: "center",
      paddingVertical: spacing.sm,
      borderBottomWidth: 1,
      borderBottomColor: colors.border,
    },
    suggestionLabel: { color: colors.textPrimary, fontSize: fontSize.md, fontWeight: "600" },
    suggestionReasoning: { color: colors.textSecondary, fontSize: fontSize.sm, marginTop: 2 },
    applyBtn: {
      backgroundColor: colors.accent,
      borderRadius: radius.sm,
      paddingHorizontal: spacing.md,
      paddingVertical: spacing.xs + 2,
      marginLeft: spacing.sm,
    },
    applyBtnText: { color: "#fff", fontSize: fontSize.sm, fontWeight: "600" },
  });
}
