import React from "react";
import {
  View,
  Text,
  TouchableOpacity,
  StyleSheet,
  ActivityIndicator,
  type ViewStyle,
} from "react-native";
import { Ionicons } from "@expo/vector-icons";
import { useTheme } from "../hooks/useTheme";
import { spacing, radius, fontSize, fonts } from "../utils/theme";

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
    <View
      style={[styles.badge, { backgroundColor: bgMap[color] || bgMap.muted }]}
      accessibilityRole="text"
      accessibilityLabel={label}
    >
      <Text
        style={[styles.badgeText, { color: textMap[color] || textMap.muted }]}
        maxFontSizeMultiplier={1.2}
      >
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
      accessibilityRole="button"
      accessibilityLabel={label}
      accessibilityState={{ disabled: !!loading, busy: !!loading }}
    >
      {loading ? (
        <ActivityIndicator color={isPrimary ? "#fff" : colors.accent} size="small" />
      ) : (
        <Text
          style={[styles.btnText, { color: isPrimary ? "#fff" : colors.textPrimary }]}
          maxFontSizeMultiplier={1.4}
        >
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
      <TouchableOpacity style={cardStyle} onPress={onPress} activeOpacity={0.8} accessibilityRole="button">
        {children}
      </TouchableOpacity>
    );
  }
  return <View style={cardStyle}>{children}</View>;
}

interface StatCardProps {
  label: string;
  value: string;
  valueColor?: string;
  /** When set, the card is tappable (e.g. stat taps drive a list filter). */
  onPress?: () => void;
  /** Extra hint appended to the accessibility label when tappable. */
  accessibilityHint?: string;
}

export function StatCard({ label, value, valueColor, onPress, accessibilityHint }: StatCardProps) {
  const { colors, shadow } = useTheme();
  const cardStyle = [styles.statCard, { backgroundColor: colors.surface, ...shadow.card }];
  const content = (
    <>
      <Text style={[styles.statLabel, { color: colors.textSecondary }]} maxFontSizeMultiplier={1.4}>{label}</Text>
      <Text style={[styles.statValue, { color: valueColor || colors.textPrimary }]} maxFontSizeMultiplier={1.4}>{value}</Text>
    </>
  );
  if (onPress) {
    return (
      <TouchableOpacity
        style={cardStyle}
        onPress={onPress}
        activeOpacity={0.75}
        accessibilityRole="button"
        accessibilityLabel={`${label}: ${value}`}
        accessibilityHint={accessibilityHint}
      >
        {content}
      </TouchableOpacity>
    );
  }
  return (
    <View style={cardStyle} accessible={true} accessibilityLabel={`${label}: ${value}`}>
      {content}
    </View>
  );
}

export function SectionHeader({ title }: { title: string }) {
  const { colors } = useTheme();
  return (
    <Text
      style={[styles.sectionHeader, { color: colors.textSecondary }]}
      accessibilityRole="header"
    >
      {title}
    </Text>
  );
}

interface EmptyStateProps {
  message: string;
  /** Ionicons glyph shown above the message. */
  icon?: keyof typeof Ionicons.glyphMap;
  /** Optional CTA — prefer offering the action over telling users where to tap. */
  actionLabel?: string;
  onAction?: () => void;
}

export function EmptyState({ message, icon, actionLabel, onAction }: EmptyStateProps) {
  const { colors } = useTheme();
  return (
    <View style={styles.empty}>
      {icon ? (
        <Ionicons name={icon} size={40} color={colors.textMuted} style={styles.emptyIcon} />
      ) : null}
      <Text style={[styles.emptyText, { color: colors.textSecondary }]}>{message}</Text>
      {actionLabel && onAction ? (
        <TouchableOpacity
          style={[styles.emptyAction, { backgroundColor: colors.accent }]}
          onPress={onAction}
          activeOpacity={0.8}
          accessibilityRole="button"
          accessibilityLabel={actionLabel}
        >
          <Text style={[styles.emptyActionText, { color: colors.textOnAccent }]} maxFontSizeMultiplier={1.4}>
            {actionLabel}
          </Text>
        </TouchableOpacity>
      ) : null}
    </View>
  );
}

export function Divider() {
  const { colors } = useTheme();
  return (
    <View
      style={[styles.divider, { backgroundColor: colors.border }]}
      accessibilityElementsHidden={true}
      importantForAccessibility="no"
    />
  );
}

const styles = StyleSheet.create({
  badge: {
    paddingHorizontal: 8,
    paddingVertical: 2,
    borderRadius: radius.full,
    alignSelf: "flex-start",
  },
  badgeText: {
    fontFamily: fonts.mono,
    fontSize: 10,
    textTransform: "uppercase",
    letterSpacing: 0.2,
  },
  btn: {
    // minHeight (not height) so clamped-but-larger accessibility text can
    // still grow the button instead of clipping.
    minHeight: 44,
    borderRadius: radius.md,
    alignItems: "center",
    justifyContent: "center",
    paddingHorizontal: spacing.md,
    paddingVertical: 10,
  },
  btnText: {
    fontFamily: fonts.bodySemiBold,
    fontSize: fontSize.md,
  },
  statCard: {
    flex: 1,
    borderRadius: radius.md,
    padding: spacing.md,
  },
  statLabel: {
    fontFamily: fonts.mono,
    fontSize: 10,
    textTransform: "uppercase",
    letterSpacing: 0.6,
    marginBottom: 4,
  },
  statValue: {
    fontFamily: fonts.display,
    fontSize: fontSize.xl,
    fontVariant: ["tabular-nums"],
  },
  sectionHeader: {
    fontFamily: fonts.mono,
    fontSize: fontSize.xs,
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
    fontFamily: fonts.bodyRegular,
    fontSize: fontSize.md,
    textAlign: "center",
    lineHeight: 24,
  },
  emptyIcon: {
    marginBottom: spacing.md,
  },
  emptyAction: {
    marginTop: spacing.lg,
    paddingHorizontal: spacing.lg,
    paddingVertical: 14,
    borderRadius: radius.md,
  },
  emptyActionText: {
    fontFamily: fonts.bodyBold,
    fontSize: fontSize.md,
  },
  divider: {
    height: StyleSheet.hairlineWidth,
    marginVertical: spacing.md,
  },
});
