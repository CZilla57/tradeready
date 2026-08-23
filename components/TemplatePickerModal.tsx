// components/TemplatePickerModal.tsx
// Phase 4 — pick a trade-aware scope template to seed a new pricebook entry.
// Templates carry no numbers; selecting one seeds empty, editable lines and a
// scope checklist (see utils/tradeTemplates.ts).

import React, { useMemo, useRef, useEffect } from "react";
import { View, Text, TouchableOpacity, Modal, Animated, PanResponder, ScrollView, StyleSheet } from "react-native";
import { Ionicons } from "@expo/vector-icons";
import { templatesForTrade, type TradeTemplate } from "../utils/tradeTemplates";
import { spacing, radius, fontSize, fonts, layout, type ColorScheme, type ShadowScheme } from "../utils/theme";
import { useTheme } from "../hooks/useTheme";
import type { TradeId } from "../types/models";

interface Props {
  visible: boolean;
  trade: TradeId;
  onSelect: (template: TradeTemplate) => void;
  onDismiss: () => void;
}

export function TemplatePickerModal({ visible, trade, onSelect, onDismiss }: Props) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  const templates = useMemo(() => templatesForTrade(trade), [trade]);
  const relevantIds = useMemo(
    () => new Set(templates.filter((t) => t.trades.includes(trade)).map((t) => t.id)),
    [templates, trade],
  );
  const translateY = useRef(new Animated.Value(600)).current;

  useEffect(() => {
    if (visible) {
      Animated.spring(translateY, { toValue: 0, useNativeDriver: true, damping: 25, stiffness: 250 }).start();
    }
  }, [visible, translateY]);

  function dismiss() {
    Animated.timing(translateY, { toValue: 600, duration: 200, useNativeDriver: true }).start(onDismiss);
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

  return (
    <Modal visible={visible} animationType="none" transparent onRequestClose={dismiss}>
      <View style={styles.backdrop}>
        <TouchableOpacity style={{ flex: 1 }} activeOpacity={1} onPress={dismiss} accessibilityRole="button" accessibilityLabel="Close template picker" />
        <Animated.View style={[styles.sheet, { transform: [{ translateY }] }]}>
          <View {...panResponder.panHandlers} style={styles.handleArea}>
            <View style={styles.handle} />
          </View>
          <Text style={styles.title}>Start from a template</Text>
          <Text style={styles.subtitle}>
            Templates add scope reminders and empty lines to fill in. They never set prices — every number stays yours.
          </Text>
          <ScrollView style={{ maxHeight: 420 }} showsVerticalScrollIndicator={false}>
            {templates.map((t) => (
              <TouchableOpacity
                key={t.id}
                style={styles.row}
                onPress={() => { onSelect(t); dismiss(); }}
                activeOpacity={0.7}
                accessibilityRole="button"
                accessibilityLabel={`Use ${t.name} template`}
              >
                <View style={{ flex: 1 }}>
                  <Text style={styles.rowName}>{t.name}</Text>
                  <Text style={styles.rowMeta}>{t.scopeChecklist.length} scope reminders</Text>
                </View>
                {relevantIds.has(t.id) && <Text style={styles.badge}>For your trade</Text>}
                <Ionicons name="chevron-forward" size={18} color={colors.textMuted} />
              </TouchableOpacity>
            ))}
          </ScrollView>
        </Animated.View>
      </View>
    </Modal>
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
      ...layout.contentColumn,
    },
    handleArea: { alignItems: "center", paddingVertical: spacing.sm },
    handle: { width: 40, height: 4, borderRadius: 2, backgroundColor: colors.textMuted },
    title: { fontFamily: fonts.display, color: colors.textPrimary, fontSize: fontSize.lg, paddingHorizontal: spacing.lg },
    subtitle: { fontFamily: fonts.bodyRegular, color: colors.textSecondary, fontSize: fontSize.sm, paddingHorizontal: spacing.lg, marginTop: 4, marginBottom: spacing.sm, lineHeight: 20 },
    row: {
      flexDirection: "row", alignItems: "center", gap: spacing.sm,
      paddingHorizontal: spacing.lg, paddingVertical: spacing.md,
      borderBottomWidth: StyleSheet.hairlineWidth, borderBottomColor: colors.border,
    },
    rowName: { fontFamily: fonts.bodyMedium, color: colors.textPrimary, fontSize: fontSize.md },
    rowMeta: { fontFamily: fonts.bodyRegular, color: colors.textMuted, fontSize: fontSize.xs, marginTop: 2 },
    badge: {
      fontFamily: fonts.bodySemiBold, color: colors.accent, fontSize: fontSize.xs,
    },
  });
}
