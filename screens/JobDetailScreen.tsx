// screens/JobDetailScreen.tsx
// Shows everything about a single job.
// The status pipeline at the top lets the worker advance the job one step at a time.
// Each status has a contextual primary action button at the bottom that changes based on pipeline position.

import React, { useState, useCallback, useEffect, useMemo } from "react";
import {
  View,
  Text,
  ScrollView,
  TouchableOpacity,
  StyleSheet,
  Alert,
  Linking,
  Platform,
  ActivityIndicator,
  Image,
  Modal,
} from "react-native";
import { Ionicons } from "@expo/vector-icons";
import * as ImagePicker from "expo-image-picker";
import { persistPhoto, deletePhoto } from "../utils/photoStorage";
import { SafeAreaView } from "react-native-safe-area-context";
import { useFocusEffect } from "@react-navigation/native";
import { loadJobs, saveJobs, loadCustomers, loadSettings } from "../utils/storage";
import { scheduleReviewRequest } from "../utils/reviewRequest";
import { JOB_STATUSES, computeEstimateBreakdown } from "../utils/pricingEngine";
import { formatQuote } from "../utils/format";
import { formatDisplayDate, formatTimeRange } from "../utils/dateHelpers";
import { computeTimeTracking, formatElapsed, TIME_TRACKING_STATUSES } from "../utils/timeTracking";
import { Button, Card, Divider } from "../components/UI";
import { spacing, radius, fontSize } from "../utils/theme";
import type { ColorScheme, ShadowScheme } from "../utils/theme";
import { useTheme } from "../hooks/useTheme";
import type { Job, Customer, JobStatus } from "../types/models";

// ── Pipeline ───────────────────────────────────────────────────────────────

const PIPELINE_STEPS = [
  "lead",
  "estimate_sent",
  "approved",
  "scheduled",
  "in_progress",
  "complete",
  "invoiced",
  "paid",
];

// ── Helpers ────────────────────────────────────────────────────────────────

function openMaps(address: string) {
  const encoded = encodeURIComponent(address);
  const url =
    Platform.OS === "ios"
      ? `maps://maps.apple.com/?q=${encoded}`
      : `geo:0,0?q=${encoded}`;

  Linking.canOpenURL(url).then((supported) => {
    if (supported) {
      Linking.openURL(url);
    } else {
      // Fallback for devices with no native maps app
      Linking.openURL(`https://maps.google.com/?q=${encoded}`);
    }
  });
}

// ── Sub-components ─────────────────────────────────────────────────────────

function PipelineBar({ currentStatus }: { currentStatus: JobStatus }) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);

  const currentStep = PIPELINE_STEPS.indexOf(currentStatus);
  const info = JOB_STATUSES[currentStatus];

  return (
    <Card style={styles.pipelineCard}>
      <View style={styles.pipeline}>
        {PIPELINE_STEPS.map((step, i) => {
          const isDone = i < currentStep;
          const isCurrent = i === currentStep;
          return (
            <React.Fragment key={step}>
              <View style={styles.pipelineStep}>
                <View
                  style={[
                    styles.pipelineDot,
                    isDone && styles.pipelineDotDone,
                    isCurrent && styles.pipelineDotCurrent,
                  ]}
                >
                  {isDone && <Text style={styles.pipelineCheck}>✓</Text>}
                </View>
              </View>
              {i < PIPELINE_STEPS.length - 1 && (
                <View
                  style={[
                    styles.pipelineLine,
                    isDone && styles.pipelineLineDone,
                  ]}
                />
              )}
            </React.Fragment>
          );
        })}
      </View>
      <Text style={styles.pipelineStatusLabel}>
        {info?.label ?? currentStatus}
        <Text style={styles.pipelineStepCount}>
          {"  ·  "}
          {currentStep + 1} of {PIPELINE_STEPS.length}
        </Text>
      </Text>
    </Card>
  );
}

function JobDetailsCard({ job, navigation }: { job: Job; navigation: any }) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);

  return (
    <Card style={styles.section}>
      <View style={styles.sectionHeader}>
        <Text style={styles.sectionTitle}>Job details</Text>
        <TouchableOpacity
          onPress={() => navigation.navigate("AddJob", { jobId: job.id })}
        >
          <Text style={styles.editLink}>Edit</Text>
        </TouchableOpacity>
      </View>
      <Text style={styles.jobTitle}>{job.title}</Text>
      {job.description ? (
        <Text style={styles.jobDesc}>{job.description}</Text>
      ) : null}
      {job.address ? (
        <TouchableOpacity onPress={() => openMaps(job.address)}>
          <Text style={styles.addressLink}>📍 {job.address}</Text>
        </TouchableOpacity>
      ) : null}
      {job.scheduledDate && (
        <Text style={styles.metaRow}>
          📅 {formatDisplayDate(job.scheduledDate)}
          {job.scheduledStartTime
            ? `  ·  ${formatTimeRange(job.scheduledStartTime, job.scheduledEndTime)}`
            : ""}
        </Text>
      )}
      {job.notes ? (
        <Text style={styles.notes}>💬 {job.notes}</Text>
      ) : null}
    </Card>
  );
}

function CustomerCard({ customer }: { customer: Customer }) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);

  return (
    <Card style={styles.section}>
      <Text style={styles.sectionTitle}>Customer</Text>
      <Text style={styles.customerName}>{customer.name}</Text>
      <View style={styles.contactRow}>
        <TouchableOpacity
          style={styles.contactBtn}
          onPress={() => Linking.openURL(`tel:${customer.phone}`)}
        >
          <Text style={styles.contactBtnText}>📞 Call</Text>
        </TouchableOpacity>
        <TouchableOpacity
          style={styles.contactBtn}
          onPress={() => Linking.openURL(`sms:${customer.phone}`)}
        >
          <Text style={styles.contactBtnText}>💬 Text</Text>
        </TouchableOpacity>
        <TouchableOpacity
          style={styles.contactBtn}
          onPress={() => Linking.openURL(`mailto:${customer.email}`)}
        >
          <Text style={styles.contactBtnText}>✉ Email</Text>
        </TouchableOpacity>
      </View>
    </Card>
  );
}

function EstimateCard({ job, navigation }: { job: Job; navigation: any }) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);

  const hasEstimate = job.estimateTotal > 0;

  if (!hasEstimate) {
    return (
      <Card style={styles.section}>
        <Text style={styles.sectionTitle}>Estimate</Text>
        <Text style={styles.noEstimateText}>No estimate built yet.</Text>
        <Button
          label="Build estimate →"
          onPress={() =>
            navigation.navigate("PricingCalculator", { jobId: job.id })
          }
          style={{ marginTop: spacing.sm }}
        />
      </Card>
    );
  }

  const { laborCost, materialCost, overheadLine, hasMaterials } = computeEstimateBreakdown(job);

  return (
    <Card style={styles.section}>
      <View style={styles.sectionHeader}>
        <Text style={styles.sectionTitle}>Estimate</Text>
        <View style={styles.estimateHeaderActions}>
          <TouchableOpacity
            onPress={() => navigation.navigate("PricingCalculator", { jobId: job.id })}
          >
            <Text style={styles.editLink}>Edit</Text>
          </TouchableOpacity>
          {job.status === "lead" && (
            <>
              <Text style={styles.editLinkSep}>·</Text>
              <TouchableOpacity
                onPress={() => navigation.navigate("SendEstimate", { jobId: job.id })}
              >
                <Text style={styles.editLink}>Send →</Text>
              </TouchableOpacity>
            </>
          )}
        </View>
      </View>

      <View style={styles.estimateRow}>
        <Text style={styles.estimateLabel}>
          Labor ({job.laborHours} hrs @ ${job.laborRate}/hr)
        </Text>
        <Text style={styles.estimateValue}>{formatQuote(laborCost)}</Text>
      </View>

      {hasMaterials && (
        <View style={styles.estimateRow}>
          <Text style={styles.estimateLabel}>
            Materials ({job.materials.length} item
            {job.materials.length !== 1 ? "s" : ""})
          </Text>
          <Text style={styles.estimateValue}>
            {formatQuote(materialCost)}
          </Text>
        </View>
      )}

      {overheadLine > 0 && (
        <View style={styles.estimateRow}>
          <Text style={styles.estimateLabel}>Overhead & operating costs</Text>
          <Text style={styles.estimateValue}>
            {formatQuote(overheadLine)}
          </Text>
        </View>
      )}

      <Divider />

      <View style={styles.estimateRow}>
        <Text style={[styles.estimateLabel, styles.estimateTotalLabel]}>
          Total estimate
        </Text>
        <Text style={[styles.estimateValue, styles.estimateTotalValue]}>
          {formatQuote(job.estimateTotal)}
        </Text>
      </View>
    </Card>
  );
}

function PhotosCard({ photos, onAdd, onDelete }: { photos: string[]; onAdd: () => void; onDelete: (uri: string) => void }) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);

  const [viewerUri, setViewerUri] = useState<string | null>(null);

  return (
    <Card style={styles.section}>
      <View style={styles.sectionHeader}>
        <Text style={styles.sectionTitle}>
          Photos{photos.length > 0 ? ` (${photos.length})` : ""}
        </Text>
        <TouchableOpacity onPress={onAdd}>
          <Text style={styles.editLink}>+ Add</Text>
        </TouchableOpacity>
      </View>

      {photos.length === 0 ? (
        <Text style={styles.noPhotosText}>
          No photos yet. Tap Add to document before/after.
        </Text>
      ) : (
        <ScrollView horizontal showsHorizontalScrollIndicator={false} style={styles.photoStrip}>
          {photos.map((uri, i) => (
            <TouchableOpacity
              key={i}
              onPress={() => setViewerUri(uri)}
              onLongPress={() =>
                Alert.alert("Delete photo?", "This cannot be undone.", [
                  { text: "Cancel", style: "cancel" },
                  { text: "Delete", style: "destructive", onPress: () => onDelete(uri) },
                ])
              }
              activeOpacity={0.85}
            >
              <Image source={{ uri }} style={styles.photoThumb} />
            </TouchableOpacity>
          ))}
        </ScrollView>
      )}

      <Modal
        visible={!!viewerUri}
        transparent
        animationType="fade"
        onRequestClose={() => setViewerUri(null)}
      >
        <View style={styles.viewerBg}>
          <TouchableOpacity style={styles.viewerClose} onPress={() => setViewerUri(null)}>
            <Text style={styles.viewerCloseText}>✕</Text>
          </TouchableOpacity>
          {viewerUri && (
            <Image source={{ uri: viewerUri }} style={styles.viewerImage} resizeMode="contain" />
          )}
        </View>
      </Modal>
    </Card>
  );
}

function TimeTrackingCard({ sessions, estimatedHours, onClockIn, onClockOut }: {
  sessions: any[];
  estimatedHours: number;
  onClockIn: () => void;
  onClockOut: () => void;
}) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);

  const [, setTick] = useState<number>(0);

  const { activeSession, isClocked, timerStr, overUnder, sessionCount } =
    computeTimeTracking(sessions, estimatedHours);

  // Re-render every second while clocked in so the live timer ticks.
  useEffect(() => {
    if (!isClocked) return;
    const id = setInterval(() => setTick((t) => t + 1), 1000);
    return () => clearInterval(id);
  }, [isClocked]);

  return (
    <Card style={styles.section}>
      <View style={styles.sectionHeader}>
        <Text style={styles.sectionTitle}>Time Tracking</Text>
        {sessionCount > 0 && (
          <Text style={styles.sessionCountText}>
            {sessionCount} session{sessionCount !== 1 ? "s" : ""}
          </Text>
        )}
      </View>

      <View style={styles.timerRow}>
        <View>
          <Text style={[styles.timerDisplay, isClocked && styles.timerDisplayActive]}>
            {timerStr}
          </Text>
          {estimatedHours > 0 && (
            <Text style={styles.timerSub}>
              est. {estimatedHours}h
              {overUnder !== null && Math.abs(overUnder) >= 0.05 ? (
                <Text
                  style={{
                    color: overUnder > 0 ? colors.danger : colors.success,
                  }}
                >
                  {"  "}
                  {overUnder > 0 ? "+" : ""}
                  {overUnder.toFixed(1)}h
                </Text>
              ) : null}
            </Text>
          )}
        </View>

        <TouchableOpacity
          style={[styles.clockBtn, isClocked && styles.clockBtnOut]}
          onPress={isClocked ? onClockOut : onClockIn}
          activeOpacity={0.8}
        >
          <Text style={[styles.clockBtnText, isClocked && styles.clockBtnTextOut]}>
            {isClocked ? "⏹  Clock Out" : "▶  Clock In"}
          </Text>
        </TouchableOpacity>
      </View>

      {isClocked && activeSession && (
        <Text style={styles.clockedSince}>
          Session started {formatElapsed(Date.now() - new Date(activeSession.start).getTime())} ago
        </Text>
      )}
    </Card>
  );
}

function PrimaryAction({ job, navigation, onAdvance }: { job: Job; navigation: any; onAdvance: () => void }) {
  const actions: Record<string, { label: string; onPress: () => void; variant: "primary" | "secondary" | "ghost" }> = {
    lead: job.estimateTotal > 0
      ? {
          label: "Send estimate →",
          onPress: () => navigation.navigate("SendEstimate", { jobId: job.id }),
          variant: "primary",
        }
      : {
          label: "Build estimate",
          onPress: () => navigation.navigate("PricingCalculator", { jobId: job.id }),
          variant: "primary",
        },
    estimate_sent: {
      label: "Mark as approved by customer",
      onPress: onAdvance,
      variant: "primary",
    },
    approved: {
      label: "Schedule this job",
      onPress: () =>
        navigation.navigate("AddJob", { jobId: job.id, focusSchedule: true }),
      variant: "primary",
    },
    scheduled: {
      label: "Start Job",
      onPress: onAdvance,
      variant: "primary",
    },
    in_progress: {
      label: "Mark job complete",
      onPress: onAdvance,
      variant: "primary",
    },
    complete: {
      label: "Create invoice",
      onPress: () =>
        navigation.navigate("CreateInvoiceFromJob", { jobId: job.id }),
      variant: "primary",
    },
    invoiced: {
      label: "View invoice & send outreach",
      onPress: () =>
        navigation.navigate("Outreach", { invoiceId: job.invoiceId }),
      variant: "primary",
    },
    paid: {
      label: "Job complete — Paid ✓",
      onPress: () => {},
      variant: "ghost",
    },
  };

  const action = actions[job.status];
  if (!action) return null;

  return (
    <Button
      label={action.label}
      onPress={action.onPress}
      variant={action.variant}
      style={{ marginBottom: spacing.sm }}
    />
  );
}

// ── Main Screen ────────────────────────────────────────────────────────────

export default function JobDetailScreen({ route, navigation }: { route: any; navigation: any }) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);

  const { jobId } = route.params;

  const [job, setJob] = useState<Job | null>(null);
  const [customer, setCustomer] = useState<Customer | null>(null);
  const [loading, setLoading] = useState<boolean>(true);
  const [loadError, setLoadError] = useState<boolean>(false);

  useFocusEffect(
    useCallback(() => {
      let active = true;

      async function load() {
        setLoading(true);
        setLoadError(false);
        try {
          const [jobs, customers] = await Promise.all([
            loadJobs(),
            loadCustomers(),
          ]);
          if (!active) return;

          const j = jobs.find((x: Job) => x.id === jobId);
          if (!j) {
            setLoadError(true);
            return;
          }

          setJob(j);
          const c = customers.find((x: Customer) => x.id === j.customerId);
          setCustomer(c || null);
        } catch (error: unknown) {
          console.error("JobDetailScreen: failed to load job", error);
          if (active) setLoadError(true);
        } finally {
          if (active) setLoading(false);
        }
      }

      load();
      return () => {
        active = false;
      };
    }, [jobId])
  );

  async function advanceStatus() {
    if (!job) return;
    const current = JOB_STATUSES[job.status];
    if (!current?.next) return;
    await updateJob({ status: current.next });

    if (current.next === "complete" && customer) {
      loadSettings()
        .then((settings) => scheduleReviewRequest(job, customer, settings))
        .catch(() => {});
    }
  }

  async function updateJob(changes: Partial<Job>) {
    const jobs = await loadJobs();
    const updated = jobs.map((j: Job) =>
      j.id === jobId ? { ...j, ...changes } : j
    );
    await saveJobs(updated);
    setJob((prev) => prev ? ({ ...prev, ...changes }) : prev);
  }

  async function handleDelete() {
    Alert.alert("Delete job?", "This cannot be undone.", [
      { text: "Cancel", style: "cancel" },
      {
        text: "Delete",
        style: "destructive",
        onPress: async () => {
          const jobs = await loadJobs();
          await saveJobs(jobs.filter((j: Job) => j.id !== jobId));
          navigation.goBack();
        },
      },
    ]);
  }

  async function handleAddPhoto() {
    Alert.alert("Add Photo", undefined, [
      {
        text: "Take Photo",
        onPress: async () => {
          const { status } = await ImagePicker.requestCameraPermissionsAsync();
          if (status !== "granted") {
            Alert.alert("Permission needed", "Camera access is required to take a photo.");
            return;
          }
          const result = await ImagePicker.launchCameraAsync({ mediaTypes: ["images"] as any, quality: 0.8 });
          if (!result.canceled) {
            const uri = await persistPhoto(result.assets[0].uri, "job-photos");
            await updateJob({ photos: [...((job as any).photos || []), uri] } as any);
          }
        },
      },
      {
        text: "Choose from Library",
        onPress: async () => {
          const { status } = await ImagePicker.requestMediaLibraryPermissionsAsync();
          if (status !== "granted") {
            Alert.alert("Permission needed", "Photo library access is required.");
            return;
          }
          const result = await ImagePicker.launchImageLibraryAsync({ mediaTypes: ["images"] as any, quality: 0.8 });
          if (!result.canceled) {
            const uri = await persistPhoto(result.assets[0].uri, "job-photos");
            await updateJob({ photos: [...((job as any).photos || []), uri] } as any);
          }
        },
      },
      { text: "Cancel", style: "cancel" },
    ]);
  }

  async function handleDeletePhoto(uri: string) {
    await updateJob({ photos: ((job as any).photos || []).filter((p: string) => p !== uri) } as any);
    await deletePhoto(uri);
  }

  async function handleClockIn() {
    if (!job) return;
    const newSession = { start: new Date().toISOString(), end: null };
    const timeSessions = [...((job as any).timeSessions || []), newSession];
    const changes: any = { timeSessions };
    if (job.status === "scheduled") changes.status = "in_progress";
    await updateJob(changes);
  }

  async function handleClockOut() {
    if (!job) return;
    const now = new Date().toISOString();
    const timeSessions = ((job as any).timeSessions || []).map((s: any, i: number, arr: any[]) =>
      i === arr.length - 1 && !s.end ? { ...s, end: now } : s
    );
    await updateJob({ timeSessions } as any);
  }

  // ── Loading state ──────────────────────────────────────────────────────

  if (loading) {
    return (
      <SafeAreaView style={[styles.container, styles.centered]}>
        <ActivityIndicator size={36} color={colors.accent} />
      </SafeAreaView>
    );
  }

  // ── Error state ────────────────────────────────────────────────────────

  if (loadError || !job) {
    return (
      <SafeAreaView style={[styles.container, styles.centered]}>
        <Text style={styles.errorTitle}>Couldn't load this job</Text>
        <Text style={styles.errorSubtext}>
          It may have been deleted or something went wrong.
        </Text>
        <TouchableOpacity
          style={styles.errorButton}
          onPress={() => navigation.goBack()}
        >
          <Text style={styles.errorButtonText}>Go back</Text>
        </TouchableOpacity>
      </SafeAreaView>
    );
  }

  // ── Main render ────────────────────────────────────────────────────────

  return (
    <SafeAreaView style={styles.container} edges={["bottom"]}>
      <ScrollView
        contentContainerStyle={styles.scroll}
        showsVerticalScrollIndicator={false}
      >
        <PipelineBar currentStatus={job.status} />
        {job.recurringJobId ? (
          <TouchableOpacity
            style={styles.recurringBanner}
            onPress={() => navigation.navigate('RecurringJobs')}
            activeOpacity={0.7}
          >
            <Ionicons name="repeat-outline" size={14} color={colors.accent} />
            <Text style={styles.recurringBannerText}>Part of a recurring series</Text>
          </TouchableOpacity>
        ) : null}
        <JobDetailsCard job={job} navigation={navigation} />
        {customer && <CustomerCard customer={customer} />}
        <EstimateCard job={job} navigation={navigation} />
        {TIME_TRACKING_STATUSES.has(job.status) && (
          <TimeTrackingCard
            sessions={(job as any).timeSessions || []}
            estimatedHours={job.laborHours || 0}
            onClockIn={handleClockIn}
            onClockOut={handleClockOut}
          />
        )}
        <PhotosCard
          photos={(job as any).photos || []}
          onAdd={handleAddPhoto}
          onDelete={handleDeletePhoto}
        />

        <Divider />

        <PrimaryAction
          job={job}
          navigation={navigation}
          onAdvance={advanceStatus}
        />

        <TouchableOpacity style={styles.deleteBtn} onPress={handleDelete}>
          <Text style={styles.deleteBtnText}>Delete job</Text>
        </TouchableOpacity>
      </ScrollView>
    </SafeAreaView>
  );
}

// ── Styles ─────────────────────────────────────────────────────────────────

function createStyles(colors: ColorScheme, shadow: ShadowScheme) {
  return StyleSheet.create({
    container: { flex: 1, backgroundColor: colors.background },
    scroll: { padding: spacing.md, paddingBottom: 40 },

    centered: { justifyContent: "center", alignItems: "center", padding: spacing.md },

    // Pipeline
    pipelineCard: { marginBottom: spacing.sm, paddingVertical: spacing.md },
    pipeline: { flexDirection: "row", alignItems: "center", justifyContent: "space-between" },
    pipelineStep: { alignItems: "center" },
    pipelineDot: {
      width: 20, height: 20, borderRadius: 10,
      backgroundColor: colors.border,
      alignItems: "center", justifyContent: "center",
    },
    pipelineDotDone: { backgroundColor: colors.success },
    pipelineDotCurrent: { backgroundColor: colors.accent },
    pipelineCheck: { color: colors.textOnAccent, fontSize: 10, fontWeight: "700" },
    pipelineLine: {
      height: 2, flex: 1, backgroundColor: colors.border,
    },
    pipelineLineDone: { backgroundColor: colors.success },
    pipelineStatusLabel: {
      marginTop: spacing.sm, textAlign: "center",
      fontSize: fontSize.sm, fontWeight: "600", color: colors.accent,
    },
    pipelineStepCount: { fontSize: fontSize.xs, fontWeight: "400", color: colors.textMuted },

    recurringBanner: {
      flexDirection: 'row',
      alignItems: 'center',
      gap: 6,
      paddingHorizontal: spacing.md,
      paddingVertical: spacing.xs,
      backgroundColor: colors.surface,
      borderRadius: radius.sm,
      marginHorizontal: spacing.md,
      marginBottom: spacing.sm,
      borderWidth: StyleSheet.hairlineWidth,
      borderColor: colors.border,
    },
    recurringBannerText: {
      fontSize: fontSize.sm,
      color: colors.accent,
    },

    // Sections
    section: { marginBottom: spacing.sm },
    sectionHeader: {
      flexDirection: "row", justifyContent: "space-between",
      alignItems: "center", marginBottom: spacing.sm,
    },
    sectionTitle: {
      fontSize: fontSize.sm, fontWeight: "600", color: colors.textSecondary,
      textTransform: "uppercase", letterSpacing: 0.5,
    },
    editLink: { fontSize: fontSize.sm, color: colors.accent },
    estimateHeaderActions: { flexDirection: "row", alignItems: "center", gap: 6 },
    editLinkSep: { fontSize: fontSize.sm, color: colors.textMuted },

    // Job details
    jobTitle: { fontSize: fontSize.lg, fontWeight: "700", color: colors.textPrimary, marginBottom: 6 },
    jobDesc: { fontSize: fontSize.md, color: colors.textSecondary, lineHeight: 22, marginBottom: 8 },
    addressLink: { fontSize: fontSize.sm, color: colors.accent, marginBottom: 6 },
    metaRow: { fontSize: fontSize.sm, color: colors.textSecondary, marginBottom: 4 },
    notes: { fontSize: fontSize.sm, color: colors.textSecondary, marginTop: 4, fontStyle: "italic" },

    // Customer
    customerName: { fontSize: fontSize.md, fontWeight: "600", color: colors.textPrimary, marginBottom: spacing.sm },
    contactRow: { flexDirection: "row", gap: 8 },
    contactBtn: {
      flex: 1, paddingVertical: 8, borderRadius: radius.md,
      backgroundColor: colors.accentBg, alignItems: "center",
    },
    contactBtnText: { fontSize: fontSize.sm, color: colors.accent, fontWeight: "500" },

    // Estimate
    estimateRow: {
      flexDirection: "row", justifyContent: "space-between",
      alignItems: "center", marginBottom: 6,
    },
    estimateLabel: { fontSize: fontSize.sm, color: colors.textSecondary, flex: 1, marginRight: spacing.sm },
    estimateValue: { fontSize: fontSize.sm, color: colors.textPrimary, fontWeight: "500" },
    estimateTotalLabel: { fontWeight: "700", color: colors.textPrimary },
    estimateTotalValue: { fontWeight: "700", fontSize: fontSize.lg },
    noEstimateText: { fontSize: fontSize.sm, color: colors.textMuted, marginBottom: 4 },

    // Photos
    photoStrip: { marginTop: spacing.xs },
    photoThumb: {
      width: 88,
      height: 88,
      borderRadius: radius.md,
      marginRight: spacing.sm,
      backgroundColor: colors.border,
    },
    noPhotosText: { fontSize: fontSize.sm, color: colors.textMuted },
    viewerBg: {
      flex: 1,
      backgroundColor: "rgba(0,0,0,0.95)",
      justifyContent: "center",
      alignItems: "center",
    },
    viewerImage: { width: "100%", height: "80%" },
    viewerClose: {
      position: "absolute",
      top: 56,
      right: 20,
      width: 36,
      height: 36,
      borderRadius: 18,
      backgroundColor: "rgba(255,255,255,0.15)",
      alignItems: "center",
      justifyContent: "center",
      zIndex: 10,
    },
    viewerCloseText: { color: "#fff", fontSize: 16, fontWeight: "600" },

    // Time tracking
    sessionCountText: { fontSize: fontSize.xs, color: colors.textMuted },
    timerRow: {
      flexDirection: "row",
      justifyContent: "space-between",
      alignItems: "center",
      marginBottom: 6,
    },
    timerDisplay: {
      fontSize: 32,
      fontWeight: "700",
      color: colors.textPrimary,
      letterSpacing: -0.5,
      fontVariant: ["tabular-nums"],
    },
    timerDisplayActive: { color: colors.accent },
    timerSub: { fontSize: fontSize.xs, color: colors.textMuted, marginTop: 2 },
    clockBtn: {
      paddingHorizontal: 16,
      paddingVertical: 10,
      borderRadius: radius.md,
      backgroundColor: colors.accentBg,
      borderWidth: 1,
      borderColor: colors.accent,
    },
    clockBtnOut: {
      backgroundColor: colors.dangerBg,
      borderColor: colors.danger,
    },
    clockBtnText: {
      fontSize: fontSize.sm,
      fontWeight: "600",
      color: colors.accent,
    },
    clockBtnTextOut: { color: colors.danger },
    clockedSince: { fontSize: fontSize.xs, color: colors.textMuted, marginTop: 4 },

    // Delete
    deleteBtn: { alignItems: "center", paddingVertical: spacing.md, marginTop: spacing.sm },
    deleteBtnText: { fontSize: fontSize.sm, color: colors.danger },

    // Error state
    errorTitle: { fontSize: fontSize.lg, fontWeight: "700", color: colors.textPrimary, marginBottom: 8, textAlign: "center" },
    errorSubtext: { fontSize: fontSize.sm, color: colors.textMuted, textAlign: "center", marginBottom: 32 },
    errorButton: { backgroundColor: colors.accent, paddingHorizontal: 32, paddingVertical: 14, borderRadius: radius.md },
    errorButtonText: { color: colors.textOnAccent, fontSize: fontSize.md, fontWeight: "700" },
  });
}
