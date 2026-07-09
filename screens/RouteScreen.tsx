import React, { useState, useCallback, useMemo } from "react";
import {
  View,
  Text,
  ScrollView,
  TouchableOpacity,
  StyleSheet,
  Linking,
  Alert,
  Platform,
  RefreshControl,
} from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";
import { useFocusEffect } from "@react-navigation/native";
import { loadJobsForDate, loadSettings } from "../utils/storage";
import { spacing, radius, fontSize, type ColorScheme, type ShadowScheme } from "../utils/theme";
import { useTheme } from "../hooks/useTheme";
import { useRefresh } from "../hooks/useRefresh";
import type { Job } from "../types/models";

function getTodayDateString(): string {
  const now = new Date();
  return `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, "0")}-${String(now.getDate()).padStart(2, "0")}`;
}

function formatTime(t: string | undefined | null): string | null {
  if (!t) return null;
  const [h, m] = t.split(":").map(Number);
  const period = h >= 12 ? "PM" : "AM";
  const hour = h % 12 === 0 ? 12 : h % 12;
  return `${hour}:${String(m).padStart(2, "0")} ${period}`;
}

function mapsUrlForAddress(address: string): string {
  const encoded = encodeURIComponent(address);
  if (Platform.OS === "ios") return `maps://maps.apple.com/?daddr=${encoded}&dirflg=d`;
  return `geo:0,0?q=${encoded}`;
}

async function navigateTo(address: string | undefined) {
  if (!address) {
    Alert.alert("No address", "This job doesn't have an address set.");
    return;
  }
  const url = mapsUrlForAddress(address);
  const canOpen = await Linking.canOpenURL(url).catch(() => false);
  if (canOpen) {
    Linking.openURL(url);
  } else {
    Linking.openURL(`https://maps.google.com/?daddr=${encodeURIComponent(address)}`);
  }
}

function openFullRoute(stops: Job[], businessAddress: string) {
  const addresses = stops.filter((s) => s.address).map((s) => s.address as string);
  if (addresses.length === 0) {
    Alert.alert("No addresses", "None of today's jobs have an address set.");
    return;
  }
  const origin = businessAddress?.trim() || addresses[0];
  const allStops = [origin, ...addresses];
  const url =
    "https://www.google.com/maps/dir/" +
    allStops.map((a) => encodeURIComponent(a)).join("/");
  Linking.openURL(url);
}

// ── Stop card ──────────────────────────────────────────────────────────────────

interface StopCardProps {
  stop: Job;
  index: number;
  total: number;
  onUp: () => void;
  onDown: () => void;
}

function StopCard({ stop, index, total, onUp, onDown }: StopCardProps) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  const isFirst = index === 0;
  const isLast = index === total - 1;
  const startTime = formatTime(stop.scheduledStartTime);
  const endTime = formatTime(stop.scheduledEndTime);

  return (
    <View style={styles.stopRow}>
      <View style={styles.timeline}>
        <View style={styles.numberBadge}>
          <Text style={styles.numberText}>{index + 1}</Text>
        </View>
        {!isLast && <View style={styles.connector} />}
      </View>

      <View style={[styles.stopCard, isLast && { marginBottom: 0 }]}>
        <View style={styles.stopTop}>
          <View style={styles.stopInfo}>
            <Text style={styles.stopTitle} numberOfLines={1}>{stop.title}</Text>
            <Text style={styles.stopCustomer} numberOfLines={1}>{stop.customerName}</Text>
            {startTime ? (
              <Text style={styles.stopTime}>
                {startTime}{endTime ? ` – ${endTime}` : ""}
              </Text>
            ) : null}
            {stop.address ? (
              <Text style={styles.stopAddress} numberOfLines={2}>{stop.address}</Text>
            ) : (
              <Text style={styles.noAddress}>No address — tap job to add one</Text>
            )}
          </View>

          <View style={styles.reorderCol}>
            <TouchableOpacity
              style={[styles.reorderBtn, isFirst && styles.reorderBtnDisabled]}
              onPress={onUp}
              disabled={isFirst}
              hitSlop={{ top: 6, bottom: 6, left: 6, right: 6 }}
            >
              <Text style={[styles.reorderBtnText, isFirst && styles.reorderBtnTextDisabled]}>↑</Text>
            </TouchableOpacity>
            <TouchableOpacity
              style={[styles.reorderBtn, isLast && styles.reorderBtnDisabled]}
              onPress={onDown}
              disabled={isLast}
              hitSlop={{ top: 6, bottom: 6, left: 6, right: 6 }}
            >
              <Text style={[styles.reorderBtnText, isLast && styles.reorderBtnTextDisabled]}>↓</Text>
            </TouchableOpacity>
          </View>
        </View>

        {stop.address ? (
          <TouchableOpacity
            style={styles.navigateBtn}
            onPress={() => navigateTo(stop.address)}
            activeOpacity={0.8}
          >
            <Text style={styles.navigateBtnText}>Navigate to this stop →</Text>
          </TouchableOpacity>
        ) : null}
      </View>
    </View>
  );
}

// ── Empty state ───────────────────────────────────────────────────────────────

function EmptyState({ onBack }: { onBack: () => void }) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  return (
    <View style={styles.emptyWrap}>
      <Text style={styles.emptyTitle}>No jobs today</Text>
      <Text style={styles.emptySub}>
        Schedule some jobs for today in the Jobs tab and they'll appear here.
      </Text>
      <TouchableOpacity style={styles.emptyBtn} onPress={onBack} activeOpacity={0.8}>
        <Text style={styles.emptyBtnText}>Go back</Text>
      </TouchableOpacity>
    </View>
  );
}

// ── Main screen ───────────────────────────────────────────────────────────────

export default function RouteScreen({ navigation }: { navigation: any }) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  const [stops, setStops] = useState<Job[]>([]);
  const [businessAddress, setBusinessAddress] = useState("");

  useFocusEffect(
    useCallback(() => {
      const today = getTodayDateString();
      Promise.all([loadJobsForDate(today), loadSettings()]).then(([jobs, settings]) => {
        setStops(jobs);
        setBusinessAddress(settings?.address || "");
      });
    }, [])
  );

  const { refreshing, onRefresh } = useRefresh(async () => {
    const today = getTodayDateString();
    const [jobs, settings] = await Promise.all([loadJobsForDate(today), loadSettings()]);
    setStops(jobs);
    setBusinessAddress(settings?.address || '');
  }, 'RouteScreen');

  function moveUp(index: number) {
    if (index === 0) return;
    setStops((prev) => {
      const next = [...prev];
      [next[index - 1], next[index]] = [next[index], next[index - 1]];
      return next;
    });
  }

  function moveDown(index: number) {
    setStops((prev) => {
      if (index === prev.length - 1) return prev;
      const next = [...prev];
      [next[index], next[index + 1]] = [next[index + 1], next[index]];
      return next;
    });
  }

  function resetOrder() {
    setStops((prev) =>
      [...prev].sort((a, b) => {
        if (!a.scheduledStartTime) return 1;
        if (!b.scheduledStartTime) return -1;
        return a.scheduledStartTime.localeCompare(b.scheduledStartTime);
      })
    );
  }

  const hasAddresses = stops.some((s) => s.address);

  if (stops.length === 0) {
    return (
      <SafeAreaView style={styles.container} edges={["bottom"]}>
        <EmptyState onBack={() => navigation.goBack()} />
      </SafeAreaView>
    );
  }

  return (
    <SafeAreaView style={styles.container} edges={["bottom"]}>
      <ScrollView
        contentContainerStyle={styles.scroll}
        showsVerticalScrollIndicator={false}
        refreshControl={<RefreshControl refreshing={refreshing} onRefresh={onRefresh} />}
      >
        <Text style={styles.hint}>
          Use ↑↓ to reorder your stops, then navigate one at a time or open the full route.
        </Text>

        <View style={styles.stopList}>
          {stops.map((stop, index) => (
            <StopCard
              key={stop.id}
              stop={stop}
              index={index}
              total={stops.length}
              onUp={() => moveUp(index)}
              onDown={() => moveDown(index)}
            />
          ))}
        </View>

        <View style={styles.actions}>
          <TouchableOpacity style={styles.resetBtn} onPress={resetOrder} activeOpacity={0.8}>
            <Text style={styles.resetBtnText}>Reset to scheduled time order</Text>
          </TouchableOpacity>

          {hasAddresses && (
            <TouchableOpacity
              style={styles.fullRouteBtn}
              onPress={() => openFullRoute(stops, businessAddress)}
              activeOpacity={0.8}
            >
              <Text style={styles.fullRouteBtnText}>Open Full Route in Maps</Text>
            </TouchableOpacity>
          )}
        </View>

        <View style={{ height: 32 }} />
      </ScrollView>
    </SafeAreaView>
  );
}

// ── Styles ────────────────────────────────────────────────────────────────────

const BADGE_SIZE = 28;
const CONNECTOR_WIDTH = 2;

function createStyles(colors: ColorScheme, shadow: ShadowScheme) {
  return StyleSheet.create({
    container: { flex: 1, backgroundColor: colors.background },
    scroll: { padding: spacing.md },
    hint: { fontSize: fontSize.sm, color: colors.textMuted, marginBottom: spacing.lg, lineHeight: 20 },
    stopList: { marginBottom: spacing.lg },
    stopRow: { flexDirection: "row", alignItems: "flex-start" },
    timeline: { width: BADGE_SIZE + spacing.md, alignItems: "center" },
    numberBadge: {
      width: BADGE_SIZE, height: BADGE_SIZE, borderRadius: BADGE_SIZE / 2,
      backgroundColor: colors.accent, alignItems: "center", justifyContent: "center", zIndex: 1,
    },
    numberText: { color: "#fff", fontSize: fontSize.sm, fontWeight: "700" },
    connector: { width: CONNECTOR_WIDTH, flex: 1, minHeight: 24, backgroundColor: colors.border, marginTop: 0 },
    stopCard: {
      flex: 1, backgroundColor: colors.surface, borderRadius: radius.lg,
      padding: spacing.md, marginLeft: spacing.sm, marginBottom: spacing.md,
      borderWidth: StyleSheet.hairlineWidth, borderColor: colors.border, ...shadow.card,
    },
    stopTop: { flexDirection: "row", alignItems: "flex-start" },
    stopInfo: { flex: 1, marginRight: spacing.sm },
    stopTitle: { fontSize: fontSize.md, fontWeight: "700", color: colors.textPrimary, marginBottom: 2 },
    stopCustomer: { fontSize: fontSize.sm, color: colors.textSecondary, marginBottom: 2 },
    stopTime: { fontSize: fontSize.sm, color: colors.accent, fontWeight: "500", marginBottom: 4 },
    stopAddress: { fontSize: fontSize.sm, color: colors.textMuted, lineHeight: 18 },
    noAddress: { fontSize: fontSize.sm, color: colors.textMuted, fontStyle: "italic" },
    reorderCol: { gap: 6 },
    reorderBtn: {
      width: 32, height: 32, borderRadius: radius.sm,
      backgroundColor: colors.background, borderWidth: 1, borderColor: colors.border,
      alignItems: "center", justifyContent: "center",
    },
    reorderBtnDisabled: { opacity: 0.3 },
    reorderBtnText: { fontSize: 16, color: colors.textPrimary, lineHeight: 18 },
    reorderBtnTextDisabled: { color: colors.textMuted },
    navigateBtn: {
      marginTop: spacing.sm, paddingVertical: 8, paddingHorizontal: spacing.md,
      backgroundColor: colors.accentBg, borderRadius: radius.md, alignItems: "center",
    },
    navigateBtnText: { fontSize: fontSize.sm, fontWeight: "600", color: colors.accent },
    actions: { gap: spacing.sm },
    resetBtn: {
      paddingVertical: 12, alignItems: "center", borderRadius: radius.md,
      borderWidth: 1, borderColor: colors.border, borderStyle: "dashed",
    },
    resetBtnText: { fontSize: fontSize.sm, color: colors.textMuted, fontWeight: "500" },
    fullRouteBtn: { paddingVertical: 14, alignItems: "center", backgroundColor: colors.accent, borderRadius: radius.md },
    fullRouteBtnText: { fontSize: fontSize.md, fontWeight: "700", color: "#fff" },
    emptyWrap: { flex: 1, alignItems: "center", justifyContent: "center", padding: spacing.xl },
    emptyTitle: { fontSize: fontSize.xl, fontWeight: "700", color: colors.textPrimary, marginBottom: spacing.sm },
    emptySub: { fontSize: fontSize.md, color: colors.textMuted, textAlign: "center", lineHeight: 22, marginBottom: spacing.xl },
    emptyBtn: { paddingHorizontal: spacing.xl, paddingVertical: 12, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border },
    emptyBtnText: { fontSize: fontSize.md, color: colors.textSecondary, fontWeight: "500" },
  });
}
