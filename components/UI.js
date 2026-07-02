// components/UI.js
// Small reusable building blocks used throughout the app.
// React Native doesn't have HTML — View is like a div, Text is like a p,
// TouchableOpacity is like a button, ScrollView is like an overflow div.

import React from "react";
import {
  View,
  Text,
  TouchableOpacity,
  StyleSheet,
  ActivityIndicator,
} from "react-native";
import { colors, spacing, radius, fontSize, shadow } from "../utils/theme";

// ── Badge ──────────────────────────────────────────────────────────────────
// The colored pill labels like "7d overdue" or "Paid"
export function Badge({ label, color = "accent" }) {
  const bgMap = {
    danger: colors.dangerBg,
    warning: colors.warningBg,
    success: colors.successBg,
    accent: colors.accentBg,
    muted: "#f2f2f7",
  };
  const textMap = {
    danger: colors.danger,
    warning: colors.warning,
    success: colors.success,
    accent: colors.accent,
    muted: colors.textSecondary,
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
  const isPrimary = variant === "primary";
  return (
    <TouchableOpacity
      style={[styles.btn, isPrimary ? styles.btnPrimary : styles.btnGhost, style]}
      onPress={onPress}
      activeOpacity={0.75}
      disabled={loading}
    >
      {loading ? (
        <ActivityIndicator color={isPrimary ? "#fff" : colors.accent} size="small" />
      ) : (
        <Text style={[styles.btnText, isPrimary ? styles.btnTextPrimary : styles.btnTextGhost]}>
          {label}
        </Text>
      )}
    </TouchableOpacity>
  );
}

// ── Card ───────────────────────────────────────────────────────────────────
export function Card({ children, style, onPress }) {
  if (onPress) {
    return (
      <TouchableOpacity style={[styles.card, style]} onPress={onPress} activeOpacity={0.8}>
        {children}
      </TouchableOpacity>
    );
  }
  return <View style={[styles.card, style]}>{children}</View>;
}

// ── StatCard ───────────────────────────────────────────────────────────────
export function StatCard({ label, value, valueColor }) {
  return (
    <View style={styles.statCard}>
      <Text style={styles.statLabel}>{label}</Text>
      <Text style={[styles.statValue, valueColor && { color: valueColor }]}>{value}</Text>
    </View>
  );
}

// ── SectionHeader ──────────────────────────────────────────────────────────
export function SectionHeader({ title }) {
  return <Text style={styles.sectionHeader}>{title}</Text>;
}

// ── EmptyState ─────────────────────────────────────────────────────────────
export function EmptyState({ message }) {
  return (
    <View style={styles.empty}>
      <Text style={styles.emptyText}>{message}</Text>
    </View>
  );
}

// ── Divider ────────────────────────────────────────────────────────────────
export function Divider() {
  return <View style={styles.divider} />;
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
  btnPrimary: {
    backgroundColor: colors.accent,
  },
  btnGhost: {
    backgroundColor: "transparent",
    borderWidth: 1,
    borderColor: colors.borderStrong,
  },
  btnText: {
    fontSize: fontSize.md,
    fontWeight: "600",
  },
  btnTextPrimary: {
    color: "#fff",
  },
  btnTextGhost: {
    color: colors.textPrimary,
  },
  card: {
    backgroundColor: colors.surface,
    borderRadius: radius.lg,
    padding: spacing.md,
    ...shadow.card,
  },
  statCard: {
    flex: 1,
    backgroundColor: colors.surface,
    borderRadius: radius.md,
    padding: spacing.md,
    ...shadow.card,
  },
  statLabel: {
    fontSize: fontSize.xs,
    color: colors.textMuted,
    marginBottom: 4,
  },
  statValue: {
    fontSize: fontSize.xl,
    fontWeight: "600",
    color: colors.textPrimary,
  },
  sectionHeader: {
    fontSize: fontSize.xs,
    fontWeight: "600",
    color: colors.textSecondary,
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
    color: colors.textMuted,
    textAlign: "center",
    lineHeight: 24,
  },
  divider: {
    height: StyleSheet.hairlineWidth,
    backgroundColor: colors.border,
    marginVertical: spacing.md,
  },
});
