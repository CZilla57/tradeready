import React, { useState, useEffect, useMemo, useRef } from "react";
import {
  View, Text, TextInput, SectionList, TouchableOpacity,
  Modal, Animated, PanResponder, StyleSheet,
} from "react-native";
import { Ionicons } from "@expo/vector-icons";
import { loadPricebook } from "../utils/storage";
import { formatQuote } from "../utils/format";
import { spacing, radius, fontSize } from "../utils/theme";
import type { ColorScheme, ShadowScheme } from "../utils/theme";
import { useTheme } from "../hooks/useTheme";
import type { PricebookEntry } from "../types/models";

interface Props {
  visible: boolean;
  hasExistingData: boolean;
  onSelect: (entry: PricebookEntry, mode: "replace" | "add") => void;
  onDismiss: () => void;
}

export function PricebookPickerModal({ visible, hasExistingData, onSelect, onDismiss }: Props) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  const [entries, setEntries] = useState<PricebookEntry[]>([]);
  const [search, setSearch] = useState("");
  const [pendingEntry, setPendingEntry] = useState<PricebookEntry | null>(null);
  const translateY = useRef(new Animated.Value(600)).current;

  useEffect(() => {
    if (visible) {
      loadPricebook().then(setEntries);
      setSearch("");
      setPendingEntry(null);
      Animated.spring(translateY, { toValue: 0, useNativeDriver: true, damping: 25, stiffness: 250 }).start();
    }
  }, [visible, translateY]);

  function dismiss() {
    Animated.timing(translateY, { toValue: 600, duration: 200, useNativeDriver: true }).start(() => {
      setPendingEntry(null);
      onDismiss();
    });
  }

  const panResponder = useRef(
    PanResponder.create({
      onStartShouldSetPanResponder: () => true,
      onPanResponderMove: (_, { dy }) => { if (dy > 0) translateY.setValue(dy); },
      onPanResponderRelease: (_, { dy, vy }) => {
        if (dy > 80 || vy > 0.5) dismiss();
        else Animated.spring(translateY, { toValue: 0, useNativeDriver: true, damping: 25, stiffness: 250 }).start();
      },
    }),
  ).current;

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

  function handleSelect(entry: PricebookEntry) {
    if (hasExistingData) {
      setPendingEntry(entry);
    } else {
      onSelect(entry, "replace");
      dismiss();
    }
  }

  function handleConfirm(mode: "replace" | "add") {
    if (pendingEntry) {
      onSelect(pendingEntry, mode);
      dismiss();
    }
  }

  return (
    <Modal visible={visible} animationType="none" transparent onRequestClose={dismiss}>
      <View style={styles.backdrop}>
        <TouchableOpacity
          style={{ flex: 1 }}
          activeOpacity={1}
          onPress={dismiss}
          accessibilityRole="button"
          accessibilityLabel="Close pricebook picker"
        />
        <Animated.View style={[styles.sheet, { transform: [{ translateY }] }]}>
          <View {...panResponder.panHandlers} style={styles.handleArea}>
            <View style={styles.handle} />
          </View>

          {pendingEntry ? (
            <View style={styles.confirmContainer}>
              <Text style={styles.confirmTitle}>
                Loading &quot;{pendingEntry.name}&quot;
              </Text>
              <Text style={styles.confirmBody}>
                The calculator already has pricing data. What would you like to do?
              </Text>
              <ModalButton label="Replace current estimate" onPress={() => handleConfirm("replace")} style={{ marginBottom: spacing.sm }} />
              <ModalButton label="Add to existing estimate" variant="secondary" onPress={() => handleConfirm("add")} style={{ marginBottom: spacing.sm }} />
              <ModalButton label="Cancel" variant="ghost" onPress={() => setPendingEntry(null)} />
            </View>
          ) : (
            <>
              <View style={styles.searchRow}>
                <Ionicons name="search" size={18} color={colors.textMuted} />
                <TextInput
                  style={styles.searchInput}
                  placeholder="Search services..."
                  placeholderTextColor={colors.textMuted}
                  value={search}
                  onChangeText={setSearch}
                  returnKeyType="search"
                  accessibilityLabel="Search services"
                />
              </View>

              {entries.length === 0 ? (
                <View style={styles.emptyContainer}>
                  <Text style={styles.emptyText}>No services in your Pricebook yet.</Text>
                </View>
              ) : (
                <SectionList
                  sections={sections}
                  keyExtractor={(item) => item.id}
                  renderSectionHeader={({ section: { title } }) => (
                    <Text style={styles.sectionHeader}>{title}</Text>
                  )}
                  renderItem={({ item }) => (
                    <TouchableOpacity
                      style={styles.row}
                      onPress={() => handleSelect(item)}
                      activeOpacity={0.7}
                      accessibilityRole="button"
                      accessibilityLabel={`${item.name}, ${formatQuote(item.estimateTotal)}`}
                    >
                      <View style={{ flex: 1 }}>
                        <Text style={styles.rowName}>{item.name}</Text>
                      </View>
                      <Text style={styles.rowPrice}>{formatQuote(item.estimateTotal)}</Text>
                    </TouchableOpacity>
                  )}
                  style={{ maxHeight: 400 }}
                  showsVerticalScrollIndicator={false}
                />
              )}
            </>
          )}
        </Animated.View>
      </View>
    </Modal>
  );
}

interface ModalButtonProps {
  label: string;
  onPress: () => void;
  variant?: "primary" | "secondary" | "ghost";
  style?: object;
}

function ModalButton({ label, onPress, variant = "primary", style }: ModalButtonProps) {
  const { colors } = useTheme();
  const isPrimary = variant === "primary";
  const isGhost = variant === "ghost";
  return (
    <TouchableOpacity
      onPress={onPress}
      style={[{
        backgroundColor: isPrimary ? colors.accent : isGhost ? "transparent" : colors.surface,
        borderRadius: radius.md,
        padding: spacing.md,
        alignItems: "center" as const,
        borderWidth: isGhost ? 0 : 1,
        borderColor: colors.border,
      }, style]}
      activeOpacity={0.8}
      accessibilityRole="button"
      accessibilityLabel={label}
    >
      <Text style={{
        color: isPrimary ? "#fff" : colors.textPrimary,
        fontWeight: "600" as const,
        fontSize: fontSize.md,
      }}>
        {label}
      </Text>
    </TouchableOpacity>
  );
}

function createStyles(colors: ColorScheme, shadow: ShadowScheme) {
  return StyleSheet.create({
    backdrop: { flex: 1, backgroundColor: "rgba(0,0,0,0.4)", justifyContent: "flex-end" },
    sheet: {
      backgroundColor: colors.surface,
      borderTopLeftRadius: radius.lg + 8,
      borderTopRightRadius: radius.lg + 8,
      maxHeight: "80%",
      paddingBottom: spacing.xl,
      ...shadow.card,
    },
    handleArea: { alignItems: "center", paddingVertical: spacing.sm },
    handle: { width: 40, height: 4, borderRadius: 2, backgroundColor: colors.textMuted },
    searchRow: {
      flexDirection: "row",
      alignItems: "center",
      backgroundColor: colors.background,
      marginHorizontal: spacing.lg,
      marginBottom: spacing.sm,
      borderRadius: radius.md,
      paddingHorizontal: spacing.md,
      borderWidth: 1,
      borderColor: colors.border,
    },
    searchInput: {
      flex: 1,
      paddingVertical: spacing.sm + 2,
      paddingHorizontal: spacing.sm,
      color: colors.textPrimary,
      fontSize: fontSize.md,
    },
    sectionHeader: {
      color: colors.textSecondary,
      fontSize: fontSize.sm,
      fontWeight: "600",
      textTransform: "uppercase",
      paddingHorizontal: spacing.lg,
      paddingTop: spacing.sm,
      paddingBottom: spacing.xs,
    },
    row: {
      flexDirection: "row",
      alignItems: "center",
      paddingHorizontal: spacing.lg,
      paddingVertical: spacing.md,
      borderBottomWidth: 1,
      borderBottomColor: colors.border,
    },
    rowName: { color: colors.textPrimary, fontSize: fontSize.md, fontWeight: "500" },
    rowPrice: { color: colors.accent, fontSize: fontSize.md, fontWeight: "700", marginLeft: spacing.sm },
    emptyContainer: { padding: spacing.xl, alignItems: "center" },
    emptyText: { color: colors.textSecondary, fontSize: fontSize.md },
    confirmContainer: { padding: spacing.lg },
    confirmTitle: { color: colors.textPrimary, fontSize: fontSize.lg, fontWeight: "700", marginBottom: spacing.sm },
    confirmBody: { color: colors.textSecondary, fontSize: fontSize.md, marginBottom: spacing.lg, lineHeight: 22 },
  });
}
