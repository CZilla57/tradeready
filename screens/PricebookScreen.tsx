import React, { useState, useCallback, useMemo } from "react";
import {
  View, Text, SectionList, TextInput, TouchableOpacity,
  Alert, StyleSheet,
} from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";
import { useFocusEffect } from "@react-navigation/native";
import { Ionicons } from "@expo/vector-icons";
import { loadPricebook, savePricebook } from "../utils/storage";
import { formatQuote } from "../utils/format";
import { Button } from "../components/UI";
import { spacing, radius, fontSize, fonts, layout } from "../utils/theme";
import type { ColorScheme, ShadowScheme } from "../utils/theme";
import { useTheme } from "../hooks/useTheme";
import { useRefresh } from "../hooks/useRefresh";
import type { PricebookEntry } from "../types/models";
import type { MoneyStackScreenProps } from "../types/navigation";

export default function PricebookScreen({ navigation }: MoneyStackScreenProps<'Pricebook'>) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  const [entries, setEntries] = useState<PricebookEntry[]>([]);
  const [search, setSearch] = useState("");

  useFocusEffect(
    useCallback(() => {
      loadPricebook().then(setEntries);
    }, []),
  );

  const { refreshing, onRefresh } = useRefresh(async () => {
    setEntries(await loadPricebook());
  }, 'PricebookScreen');

  const sections = useMemo(() => {
    const filtered = entries.filter(
      (e) => e.name.toLowerCase().includes(search.toLowerCase()),
    );
    const grouped: Record<string, PricebookEntry[]> = {};
    for (const e of filtered) {
      const key = e.category || "Uncategorized";
      (grouped[key] ??= []).push(e);
    }
    return Object.keys(grouped)
      .sort((a, b) => (a === "Uncategorized" ? 1 : b === "Uncategorized" ? -1 : a.localeCompare(b)))
      .map((title) => ({ title, data: grouped[title] }));
  }, [entries, search]);

  function confirmDelete(entry: PricebookEntry) {
    Alert.alert("Delete Service", `Remove "${entry.name}" from your Pricebook?`, [
      { text: "Cancel", style: "cancel" },
      {
        text: "Delete",
        style: "destructive",
        onPress: async () => {
          const updated = entries.filter((e) => e.id !== entry.id);
          setEntries(updated);
          await savePricebook(updated);
        },
      },
    ]);
  }

  if (entries.length === 0) {
    return (
      <SafeAreaView style={styles.container} edges={["bottom"]}>
        <View style={styles.emptyContainer}>
          <Ionicons name="list-outline" size={44} color={colors.textMuted} style={styles.emptyIcon} />
          <Text style={styles.emptyTitle}>No services yet</Text>
          <Text style={styles.emptyBody}>
            Your Pricebook saves your standard services so you can load them into
            estimates with one tap instead of typing everything from scratch.
          </Text>
          <Button
            label="Add your first service"
            onPress={() => navigation.navigate("PricebookEntry", {})}
            style={{ marginTop: spacing.lg }}
          />
        </View>
      </SafeAreaView>
    );
  }

  return (
    <SafeAreaView style={styles.container} edges={["bottom"]}>
      <View style={styles.searchRow}>
        <Ionicons name="search" size={18} color={colors.textMuted} />
        <TextInput
          style={styles.searchInput}
          placeholder="Search services..."
          placeholderTextColor={colors.textMuted}
          value={search}
          onChangeText={setSearch}
          returnKeyType="search"
        />
        {search.length > 0 && (
          <TouchableOpacity onPress={() => setSearch("")}>
            <Ionicons name="close-circle" size={18} color={colors.textMuted} />
          </TouchableOpacity>
        )}
      </View>

      <SectionList
        refreshing={refreshing}
        onRefresh={onRefresh}
        sections={sections}
        keyExtractor={(item) => item.id}
        renderSectionHeader={({ section: { title } }) => (
          <Text style={styles.sectionHeader}>{title}</Text>
        )}
        renderItem={({ item }) => (
          <TouchableOpacity
            style={styles.row}
            onPress={() => navigation.navigate("PricebookEntry", { entryId: item.id })}
            activeOpacity={0.7}
          >
            <View style={{ flex: 1 }}>
              <Text style={styles.rowName}>{item.name}</Text>
              {item.description ? (
                <Text style={styles.rowDesc} numberOfLines={1}>{item.description}</Text>
              ) : null}
            </View>
            <Text style={styles.rowPrice}>{formatQuote(item.estimateTotal)}</Text>
            <TouchableOpacity
              style={styles.rowDeleteBtn}
              onPress={() => confirmDelete(item)}
              hitSlop={{ top: 8, bottom: 8, left: 8, right: 8 }}
              accessibilityLabel={`Delete ${item.name}`}
              accessibilityRole="button"
            >
              <Ionicons name="close" size={14} color={colors.danger} />
            </TouchableOpacity>
          </TouchableOpacity>
        )}
        contentContainerStyle={styles.listContent}
        showsVerticalScrollIndicator={false}
      />

      <View style={styles.fab}>
        <Button
          label="+ Add Service"
          onPress={() => navigation.navigate("PricebookEntry", {})}
        />
      </View>
    </SafeAreaView>
  );
}

function createStyles(colors: ColorScheme, shadow: ShadowScheme) {
  return StyleSheet.create({
    container: { flex: 1, backgroundColor: colors.background },
    searchRow: {
      flexDirection: "row",
      alignItems: "center",
      backgroundColor: colors.surface,
      marginHorizontal: spacing.lg,
      marginTop: spacing.md,
      marginBottom: spacing.sm,
      borderRadius: radius.md,
      paddingHorizontal: spacing.md,
      borderWidth: 1,
      borderColor: colors.border,
      ...layout.contentColumn,
    },
    searchInput: {
      fontFamily: fonts.bodyRegular,
      flex: 1,
      paddingVertical: spacing.sm + 2,
      paddingHorizontal: spacing.sm,
      color: colors.textPrimary,
      fontSize: fontSize.md,
    },
    sectionHeader: {
      fontFamily: fonts.mono,
      color: colors.textSecondary,
      fontSize: fontSize.xs,
      textTransform: "uppercase",
      letterSpacing: 0.8,
      paddingHorizontal: spacing.lg,
      paddingTop: spacing.md,
      paddingBottom: spacing.xs,
    },
    row: {
      flexDirection: "row",
      alignItems: "center",
      backgroundColor: colors.surface,
      marginHorizontal: spacing.lg,
      marginBottom: spacing.xs,
      borderRadius: radius.md,
      padding: spacing.md,
      borderWidth: 1,
      borderColor: colors.border,
      ...shadow.card,
    },
    rowName: { fontFamily: fonts.bodySemiBold, color: colors.textPrimary, fontSize: fontSize.md },
    rowDesc: { fontFamily: fonts.bodyRegular, color: colors.textSecondary, fontSize: fontSize.sm, marginTop: 2 },
    rowPrice: { fontFamily: fonts.display, color: colors.accent, fontSize: fontSize.md, marginLeft: spacing.sm, fontVariant: ["tabular-nums"] },
    rowDeleteBtn: {
      marginLeft: 10,
      width: 28,
      height: 28,
      borderRadius: 14,
      backgroundColor: colors.dangerBg,
      alignItems: "center" as const,
      justifyContent: "center" as const,
    },
    listContent: { paddingBottom: 100, ...layout.contentColumn },
    // NOTE (iPad Tier 1, Phase 4): audit §4.6 flags this footer bar as
    // non-mechanical — its left/right absolute offsets don't compose with
    // alignSelf:'center'+maxWidth the way a contentContainerStyle swap does.
    // Left untouched here; a bespoke centering technique is deferred to a
    // later phase per the audit's own guidance ("Phase 4/5 needs a bespoke
    // centering approach for this one style").
    fab: {
      position: "absolute",
      bottom: spacing.lg,
      left: spacing.lg,
      right: spacing.lg,
    },
    emptyContainer: {
      flex: 1,
      justifyContent: "center",
      alignItems: "center",
      paddingHorizontal: spacing.xl,
    },
    emptyIcon: { marginBottom: spacing.md },
    emptyTitle: { fontFamily: fonts.display, color: colors.textPrimary, fontSize: fontSize.lg, marginBottom: spacing.sm },
    emptyBody: { fontFamily: fonts.bodyRegular, color: colors.textSecondary, fontSize: fontSize.md, textAlign: "center", lineHeight: 22 },
  });
}
