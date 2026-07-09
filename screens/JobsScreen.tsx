// screens/JobsScreen.tsx
// Lists all jobs with a status filter across the top.
// Tapping a job opens JobDetailScreen.
// The + button opens AddJobScreen.

import React, { useState, useCallback, useMemo } from "react";
import {
  View,
  Text,
  FlatList,
  TextInput,
  TouchableOpacity,
  StyleSheet,
} from "react-native";
import { Ionicons } from "@expo/vector-icons";
import { SafeAreaView } from "react-native-safe-area-context";
import { useFocusEffect } from "@react-navigation/native";
import { loadJobs } from "../utils/storage";
import { JOB_STATUSES } from "../utils/pricingEngine";
import { formatQuote } from "../utils/format";
import { Badge, EmptyState, StatCard } from "../components/UI";
import { spacing, radius, fontSize } from "../utils/theme";
import type { ColorScheme, ShadowScheme } from "../utils/theme";
import { useTheme } from "../hooks/useTheme";
import { useRefresh } from "../hooks/useRefresh";
import type { Job } from "../types/models";

// Which filter tabs to show across the top
const FILTERS = [
  { key: "active",    label: "Active",    statuses: ["lead", "estimate_sent", "approved", "scheduled"] },
  { key: "complete",  label: "Complete",  statuses: ["complete", "invoiced"] },
  { key: "paid",      label: "Paid",      statuses: ["paid"] },
  { key: "all",       label: "All",       statuses: null as string[] | null },
];

export default function JobsScreen({ navigation }: { navigation: any }) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);

  const [jobs, setJobs] = useState<Job[]>([]);
  const [filter, setFilter] = useState<string>("active");
  const [search, setSearch] = useState<string>("");

  useFocusEffect(
    useCallback(() => {
      loadJobs().then(setJobs);
    }, [])
  );

  const { refreshing, onRefresh } = useRefresh(async () => {
    setJobs(await loadJobs());
  }, 'JobsScreen');

  const activeFilter = FILTERS.find((f) => f.key === filter);
  const filtered = jobs.filter((j) => {
    const matchesStatus = !activeFilter?.statuses || activeFilter.statuses.includes(j.status);
    const matchesSearch =
      j.customerName.toLowerCase().includes(search.toLowerCase()) ||
      j.title.toLowerCase().includes(search.toLowerCase());
    return matchesStatus && matchesSearch;
  });

  // Top stats
  const activeJobs = jobs.filter((j) => !["paid", "invoiced"].includes(j.status));
  const pendingEstimates = jobs.filter((j) => ["lead", "estimate_sent"].includes(j.status));
  const pendingValue = pendingEstimates.reduce((s, j) => s + (j.estimateTotal || 0), 0);

  function renderJob({ item: job }: { item: Job }) {
    const status = JOB_STATUSES[job.status] || JOB_STATUSES.lead;
    return (
      <TouchableOpacity
        style={styles.jobCard}
        onPress={() => navigation.navigate("JobDetail", { jobId: job.id })}
        activeOpacity={0.8}
      >
        <View style={styles.cardTop}>
          <View style={{ flex: 1, marginRight: spacing.sm }}>
            <View style={{ flexDirection: 'row', alignItems: 'center', gap: 4 }}>
              <Text style={[styles.jobTitle, { flex: 1 }]} numberOfLines={1}>{job.title}</Text>
              {job.recurringJobId ? (
                <Ionicons name="repeat-outline" size={14} color={colors.textMuted} />
              ) : null}
            </View>
            <Text style={styles.jobCustomer}>{job.customerName}</Text>
          </View>
          <View style={{ alignItems: "flex-end", gap: 5 }}>
            {job.estimateTotal > 0 && (
              <Text style={styles.jobAmount}>{formatQuote(job.estimateTotal)}</Text>
            )}
            <Badge label={status.label} color={status.color} />
          </View>
        </View>

        {/* Date line if scheduled */}
        {job.scheduledDate && (
          <Text style={styles.jobMeta}>
            📅 {formatDate(job.scheduledDate)}
            {job.scheduledStartTime ? `  ·  ${formatTime(job.scheduledStartTime)}` : ""}
          </Text>
        )}

        {/* Description preview */}
        {job.description ? (
          <Text style={styles.jobDesc} numberOfLines={1}>{job.description}</Text>
        ) : null}

        {/* Quick action based on status */}
        <View style={styles.quickActions}>
          <QuickAction job={job} navigation={navigation} />
        </View>
      </TouchableOpacity>
    );
  }

  return (
    <SafeAreaView style={styles.container} edges={["bottom"]}>
      {/* Stats */}
      <View style={styles.statsRow}>
        <StatCard label="Active jobs" value={String(activeJobs.length)} />
        <View style={{ width: spacing.sm }} />
        <StatCard label="Open estimates" value={String(pendingEstimates.length)} />
        <View style={{ width: spacing.sm }} />
        <StatCard label="Pending value" value={formatQuote(pendingValue)} valueColor={colors.accent} />
      </View>

      {/* Search */}
      <View style={styles.searchRow}>
        <TextInput
          style={styles.searchInput}
          placeholder="Search jobs or customers..."
          placeholderTextColor={colors.textMuted}
          value={search}
          onChangeText={setSearch}
          clearButtonMode="while-editing"
        />
      </View>

      {/* Filter tabs */}
      <View style={styles.filterRow}>
        {FILTERS.map((f) => {
          const count = jobs.filter((j) => !f.statuses || f.statuses.includes(j.status)).length;
          return (
            <TouchableOpacity
              key={f.key}
              style={[styles.filterTab, filter === f.key && styles.filterTabActive]}
              onPress={() => setFilter(f.key)}
            >
              <Text style={[styles.filterTabText, filter === f.key && styles.filterTabTextActive]}>
                {f.label} {count > 0 ? `(${count})` : ""}
              </Text>
            </TouchableOpacity>
          );
        })}
      </View>

      {/* Job list */}
      <FlatList
        refreshing={refreshing}
        onRefresh={onRefresh}
        data={filtered}
        keyExtractor={(item) => item.id}
        renderItem={renderJob}
        contentContainerStyle={styles.listContent}
        ListEmptyComponent={
          <EmptyState message={
            filter === "active"
              ? "No active jobs.\nTap + to add your first job."
              : "No jobs in this category."
          } />
        }
        showsVerticalScrollIndicator={false}
      />

      {/* FAB */}
      <TouchableOpacity
        style={styles.fab}
        onPress={() => navigation.navigate("AddJob", {})}
        activeOpacity={0.85}
      >
        <Text style={styles.fabText}>+</Text>
      </TouchableOpacity>
    </SafeAreaView>
  );
}

// Quick action button that changes based on the job's current status
function QuickAction({ job, navigation }: { job: Job; navigation: any }) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);

  const actions: Record<string, { label: string; screen: string }> = {
    lead:          { label: "Build estimate →", screen: "PricingCalculator" },
    estimate_sent: { label: "Mark approved →",  screen: "JobDetail" },
    approved:      { label: "Schedule →",        screen: "JobDetail" },
    scheduled:     { label: "Mark complete →",   screen: "JobDetail" },
    complete:      { label: "Create invoice →",  screen: "JobDetail" },
    invoiced:      { label: "View invoice →",    screen: "JobDetail" },
    paid:          { label: "View details",      screen: "JobDetail" },
  };

  const action = actions[job.status];
  if (!action) return null;

  return (
    <TouchableOpacity
      onPress={() => navigation.navigate(action.screen, { jobId: job.id })}
      style={styles.quickActionBtn}
    >
      <Text style={styles.quickActionText}>{action.label}</Text>
    </TouchableOpacity>
  );
}

function formatDate(dateStr: string): string {
  const d = new Date(dateStr + "T00:00:00");
  return d.toLocaleDateString("en-US", { weekday: "short", month: "short", day: "numeric" });
}

function formatTime(timeStr: string): string {
  const [h, m] = timeStr.split(":");
  const hour = parseInt(h);
  return `${hour > 12 ? hour - 12 : hour}:${m} ${hour >= 12 ? "PM" : "AM"}`;
}

function createStyles(colors: ColorScheme, shadow: ShadowScheme) {
  return StyleSheet.create({
    container: { flex: 1, backgroundColor: colors.background },
    statsRow: {
      flexDirection: "row",
      paddingHorizontal: spacing.md,
      paddingTop: spacing.md,
      paddingBottom: spacing.sm,
    },
    searchRow: { paddingHorizontal: spacing.md, paddingBottom: spacing.sm },
    searchInput: {
      backgroundColor: colors.surface,
      borderRadius: radius.md,
      height: 40,
      paddingHorizontal: spacing.md,
      fontSize: fontSize.md,
      color: colors.textPrimary,
      ...shadow.card,
    },
    filterRow: {
      flexDirection: "row",
      paddingHorizontal: spacing.md,
      gap: 6,
      marginBottom: spacing.sm,
    },
    filterTab: {
      paddingHorizontal: 12,
      paddingVertical: 6,
      borderRadius: radius.full,
      backgroundColor: colors.surface,
      borderWidth: 1,
      borderColor: colors.border,
    },
    filterTabActive: {
      backgroundColor: colors.accent,
      borderColor: colors.accent,
    },
    filterTabText: { fontSize: fontSize.sm, color: colors.textSecondary },
    filterTabTextActive: { color: colors.textOnAccent, fontWeight: "600" },
    listContent: { paddingHorizontal: spacing.md, paddingBottom: 100 },
    jobCard: {
      backgroundColor: colors.surface,
      borderRadius: radius.lg,
      padding: spacing.md,
      marginBottom: spacing.sm,
      ...shadow.card,
    },
    cardTop: { flexDirection: "row", justifyContent: "space-between", marginBottom: 6 },
    jobTitle: { fontSize: fontSize.md, fontWeight: "600", color: colors.textPrimary },
    jobCustomer: { fontSize: fontSize.sm, color: colors.textSecondary, marginTop: 2 },
    jobAmount: { fontSize: fontSize.md, fontWeight: "600", color: colors.textPrimary },
    jobMeta: { fontSize: fontSize.sm, color: colors.textSecondary, marginBottom: 4 },
    jobDesc: { fontSize: fontSize.sm, color: colors.textMuted, marginBottom: 8 },
    quickActions: { flexDirection: "row", justifyContent: "flex-end" },
    quickActionBtn: {
      paddingHorizontal: 12,
      paddingVertical: 5,
      borderRadius: radius.sm,
      backgroundColor: colors.accentBg,
    },
    quickActionText: { fontSize: fontSize.sm, color: colors.accent, fontWeight: "600" },
    fab: {
      position: "absolute",
      right: spacing.lg,
      bottom: spacing.xl,
      width: 56,
      height: 56,
      borderRadius: 28,
      backgroundColor: colors.accent,
      alignItems: "center",
      justifyContent: "center",
      shadowColor: colors.accent,
      shadowOffset: { width: 0, height: 4 },
      shadowOpacity: 0.35,
      shadowRadius: 8,
      elevation: 6,
    },
    fabText: { color: colors.textOnAccent, fontSize: 28, lineHeight: 32, fontWeight: "300" },
  });
}
