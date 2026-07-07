// components/UI.js
// Small reusable building blocks used throughout the app.
// React Native doesn't have HTML — View is like a div, Text is like a p,
// TouchableOpacity is like a button, ScrollView is like an overflow div.

import React, { useMemo } from "react";
import {
  View,
  Text,
  TouchableOpacity,
  StyleSheet,
  ActivityIndicator,
} from "react-native";
import { useTheme } from "../hooks/useTheme";
import { spacing, radius, fontSize } from "../utils/theme";

// ── Badge ──────────────────────────────────────────────────────────────────
// The colored pill labels like "7d overdue" or "Paid"
export function Badge({ label, color = "accent" }) {
  const { colors } = useTheme();
  const bgMap = {
    danger:  colors.dangerBg,
    warning: colors.warningBg,
    success: colors.successBg,
    accent:  colors.accentBg,
    muted:   colors.surfaceSecondary,
  };
  const textMap = {
    danger:  colors.danger,
    warning: colors.warning,
    success: colors.success,
    accent:  colors.accent,
    muted:   colors.textSecondary,
  };
  return (
    <View style={[styles.badge, { backgroundColor: bgMap[color] || bgMap.muted }]}>
      <Text style={[styles.badgeText, { color: textMap[color] || textMap.muted }]}>
        {label}
      </Text>
    </View>
  );
}

// ── Button ─────────────────────────────────────────────────────────────────
export function Button({ label, onPress, variant = "primary", style, loading }) {
  const { colors } = useTheme();
  const isPrimary = variant === "primary";
  return (
    <TouchableOpacity
      style={[
        styles.btn,
        isPrimary
          ? { backgroundColor: colors.accent }
          : { backgroundColor: "transparent", borderWidth: 1, borderColor: colors.borderStrong },
        style,
      ]}
      onPress={onPress}
      activeOpacity={0.75}
      disabled={loading}
    >
      {loading ? (
        <ActivityIndicator color={isPrimary ? "#fff" : colors.accent} size="small" />
      ) : (
        <Text style={[styles.btnText, { color: isPrimary ? "#fff" : colors.textPrimary }]}>
          {label}
        </Text>
      )}
    </TouchableOpacity>
  );
}

// ── Card ───────────────────────────────────────────────────────────────────
export function Card({ children, style, onPress }) {
  const { colors, shadow } = useTheme();
  const cardStyle = [{ backgroundColor: colors.surface, borderRadius: radius.lg, padding: spacing.md, ...shadow.card }, style];
  if (onPress) {
    return (
      <TouchableOpacity style={cardStyle} onPress={onPress} activeOpacity={0.8}>
        {children}
      </TouchableOpacity>
    );
  }
  return <View style={cardStyle}>{children}</View>;
}

// ── StatCard ───────────────────────────────────────────────────────────────
export function StatCard({ label, value, valueColor }) {
  const { colors, shadow } = useTheme();
  return (
    <View style={[styles.statCard, { backgroundColor: colors.surface, ...shadow.card }]}>
      <Text style={[styles.statLabel, { color: colors.textMuted }]}>{label}</Text>
      <Text style={[styles.statValue, { color: valueColor || colors.textPrimary }]}>{value}</Text>
    </View>
  );
}

// ── SectionHeader ──────────────────────────────────────────────────────────
export function SectionHeader({ title }) {
  const { colors } = useTheme();
  return <Text style={[styles.sectionHeader, { color: colors.textSecondary }]}>{title}</Text>;
}

// ── EmptyState ─────────────────────────────────────────────────────────────
export function EmptyState({ message }) {
  const { colors } = useTheme();
  return (
    <View style={styles.empty}>
      <Text style={[styles.emptyText, { color: colors.textMuted }]}>{message}</Text>
    </View>
  );
}

// ── Divider ────────────────────────────────────────────────────────────────
export function Divider() {
  const { colors } = useTheme();
  return <View style={[styles.divider, { backgroundColor: colors.border }]} />;
}

const styles = StyleSheet.create({
  badge: {
    paddingHorizontal: 8,
    paddingVertical: 2,
    borderRadius: radius.full,
    alignSelf: "flex-start",
  },
  badgeText: {
    fontSize: fontSize.xs,
    fontWeight: "600",
  },
  btn: {
    height: 44,
    borderRadius: radius.md,
    alignItems: "center",
    justifyContent: "center",
    paddingHorizontal: spacing.md,
  },
  btnText: {
    fontSize: fontSize.md,
    fontWeight: "600",
  },
  statCard: {
    flex: 1,
    borderRadius: radius.md,
    padding: spacing.md,
  },
  statLabel: {
    fontSize: fontSize.xs,
    marginBottom: 4,
  },
  statValue: {
    fontSize: fontSize.xl,
    fontWeight: "600",
  },
  sectionHeader: {
    fontSize: fontSize.xs,
    fontWeight: "600",
    textTransform: "uppercase",
    letterSpacing: 0.8,
    marginBottom: spacing.sm,
    marginTop: spacing.md,
    marginLeft: spacing.xs,
  },
  empty: {
    flex: 1,
    alignItems: "center",
    justifyContent: "center",
    paddingVertical: 60,
    paddingHorizontal: spacing.xl,
  },
  emptyText: {
    fontSize: fontSize.md,
    textAlign: "center",
    lineHeight: 24,
  },
  divider: {
    height: StyleSheet.hairlineWidth,
    marginVertical: spacing.md,
  },
});
