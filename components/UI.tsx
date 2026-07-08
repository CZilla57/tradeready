import React from "react";
import {
  View,
  Text,
  TouchableOpacity,
  StyleSheet,
  ActivityIndicator,
  type ViewStyle,
} from "react-native";
import { useTheme } from "../hooks/useTheme";
import { spacing, radius, fontSize } from "../utils/theme";

export type BadgeColor = "danger" | "warning" | "success" | "accent" | "muted";

export function Badge({ label, color = "accent" }: { label: string; color?: BadgeColor }) {
  const { colors } = useTheme();
  const bgMap: Record<BadgeColor, string> = {
    danger:  colors.dangerBg,
    warning: colors.warningBg,
    success: colors.successBg,
    accent:  colors.accentBg,
    muted:   colors.surfaceSecondary,
  };
  const textMap: Record<BadgeColor, string> = {
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

interface ButtonProps {
  label: string;
  onPress: () => void;
  variant?: "primary" | "secondary" | "ghost";
  style?: ViewStyle;
  loading?: boolean;
}

export function Button({ label, onPress, variant = "primary", style, loading }: ButtonProps) {
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

interface CardProps {
  children: React.ReactNode;
  style?: ViewStyle;
  onPress?: () => void;
}

export function Card({ children, style, onPress }: CardProps) {
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

export function StatCard({ label, value, valueColor }: { label: string; value: string; valueColor?: string }) {
  const { colors, shadow } = useTheme();
  return (
    <View style={[styles.statCard, { backgroundColor: colors.surface, ...shadow.card }]}>
      <Text style={[styles.statLabel, { color: colors.textMuted }]}>{label}</Text>
      <Text style={[styles.statValue, { color: valueColor || colors.textPrimary }]}>{value}</Text>
    </View>
  );
}

export function SectionHeader({ title }: { title: string }) {
  const { colors } = useTheme();
  return <Text style={[styles.sectionHeader, { color: colors.textSecondary }]}>{title}</Text>;
}

export function EmptyState({ message }: { message: string }) {
  const { colors } = useTheme();
  return (
    <View style={styles.empty}>
      <Text style={[styles.emptyText, { color: colors.textMuted }]}>{message}</Text>
    </View>
  );
}

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
