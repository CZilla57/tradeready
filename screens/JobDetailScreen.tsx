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
  Modal,
} from "react-native";
import { Image } from "expo-image";
import { Ionicons } from "@expo/vector-icons";
import * as ImagePicker from "expo-image-picker";
import { persistPhotoSafe, deletePhoto } from "../utils/photoStorage";
import { useFocusEffect } from "@react-navigation/native";
import { loadJobs, saveJobs, loadCustomers, loadSettings, loadInvoices, resolveCustomer } from "../utils/storage";
import { scheduleReviewRequest, getReviewRequestRecord } from "../utils/reviewRequest";
import { sendAppointmentMessage } from "../utils/appointmentSend";
import { ACTIVE_STATUSES } from "../utils/appointmentMessages";
import { stampEstimateSent } from "../utils/estimateFollowUps";
import { track, reportError } from '../utils/analytics';
import { JOB_STATUSES, computeEstimateBreakdown } from "../utils/pricingEngine";
import { canSendEstimate, canRequestDeposit, advanceJobsForPaidInvoices, jobChangesAfterInvoiceSave } from "../utils/jobStatus";
import { createAutoInvoiceForJob } from "../utils/autoInvoice";
import { formatQuote } from "../utils/format";
import { formatDisplayDate, formatTimeRange } from "../utils/dateHelpers";
import { computeTimeTracking, formatElapsed, TIME_TRACKING_STATUSES, applyClockIn, applyClockOut } from "../utils/timeTracking";
import { approvedChangeOrderTotal, jobBillableTotal } from "../utils/changeOrders";
import ChangeOrdersSection from "../components/ChangeOrdersSection";
import { Button, Card, Divider } from "../components/UI";
import { spacing, radius, fontSize, fonts, layout } from "../utils/theme";
import type { ColorScheme, ShadowScheme } from "../utils/theme";
import { useTheme } from "../hooks/useTheme";
import { useUndo } from "../context/UndoContext";
import { isArchived, withArchived } from "../utils/archive";
import type { Job, Customer, JobStatus } from "../types/models";
import type { JobStackScreenProps } from "../types/navigation";

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

  // Declined sits outside the linear pipeline (indexOf = -1 would render an
  // all-grey bar reading "0 of 8") — show a distinct terminal state instead.
  if (currentStatus === "declined") {
    return (
      <Card style={styles.declinedCard}>
        <View style={styles.declinedRow}>
          <Ionicons name="close-circle" size={20} color={colors.danger} />
          <View style={styles.declinedTextWrap}>
            <Text style={styles.declinedTitle}>Estimate declined</Text>
            <Text style={styles.declinedSub}>
              Revise the estimate and re-send it to restart this job.
            </Text>
          </View>
        </View>
      </Card>
    );
  }

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

function JobDetailsCard({ job, navigation, customer, onAppointmentSend }: {
  job: Job;
  navigation: JobStackScreenProps<'JobDetail'>['navigation'];
  customer: Customer | null;
  onAppointmentSend: (kind: "confirm" | "on_my_way") => void;
}) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);

  return (
    <Card style={styles.section}>
      <View style={styles.sectionHeader}>
        <Text style={styles.sectionTitle}>Job details</Text>
        <TouchableOpacity
          onPress={() => navigation.navigate("AddJob", { jobId: job.id })}
          accessibilityRole="button"
          accessibilityLabel="Edit job details"
        >
          <Text style={styles.editLink}>Edit</Text>
        </TouchableOpacity>
      </View>
      <Text style={styles.jobTitle}>{job.title}</Text>
      {job.description ? (
        <Text style={styles.jobDesc}>{job.description}</Text>
      ) : null}
      {job.address ? (
        <TouchableOpacity onPress={() => openMaps(job.address)} accessibilityRole="button" accessibilityLabel={`Open ${job.address} in Maps`}>
          <View style={styles.iconRow}>
            <Ionicons name="location-outline" size={13} color={colors.accent} />
            <Text style={styles.addressLink}>{job.address}</Text>
          </View>
        </TouchableOpacity>
      ) : null}
      {job.scheduledDate && (
        <View style={styles.iconRow}>
          <Ionicons name="calendar-outline" size={12} color={colors.textSecondary} />
          <Text style={styles.scheduleText}>
            {formatDisplayDate(job.scheduledDate)}
            {job.scheduledStartTime
              ? `  ·  ${formatTimeRange(job.scheduledStartTime, job.scheduledEndTime)}`
              : ""}
          </Text>
        </View>
      )}
      {job.scheduledDate && customer && ACTIVE_STATUSES.has(job.status) && (
        <View style={styles.apptActions}>
          <Button
            label="Send confirmation"
            variant="secondary"
            onPress={() => onAppointmentSend("confirm")}
            style={{ flex: 1 }}
          />
          <Button
            label="I'm on my way"
            variant="primary"
            onPress={() => onAppointmentSend("on_my_way")}
            style={{ flex: 1 }}
          />
        </View>
      )}
      {job.notes ? (
        <View style={styles.notesRow}>
          <Ionicons name="chatbubble-ellipses-outline" size={13} color={colors.textSecondary} style={styles.notesIcon} />
          <Text style={styles.notes}>{job.notes}</Text>
        </View>
      ) : null}
      {job.approval?.decision === "approved" && (
        <Text style={styles.metaRow}>
          ✓ Approved{job.approval.consentAt ? ` ${new Date(job.approval.consentAt).toLocaleDateString()}` : ""}
          {job.approval.signerName ? ` by ${job.approval.signerName}` : ""}
        </Text>
      )}
      {job.approval?.decision === "declined" && (
        <Text style={styles.metaRow}>
          ✗ Declined{job.approval.consentAt ? ` ${new Date(job.approval.consentAt).toLocaleDateString()}` : ""}
          {job.approval.declineReason ? ` — “${job.approval.declineReason}”` : ""}
        </Text>
      )}
      {job.approval && !job.approval.decision && (
        <Text style={styles.metaRow}>⧗ Sent for approval {new Date(job.approval.sentAt).toLocaleDateString()}</Text>
      )}
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
          accessibilityRole="button"
          accessibilityLabel={`Call ${customer.name}`}
        >
          <Ionicons name="call-outline" size={14} color={colors.accent} />
          <Text style={styles.contactBtnText}>Call</Text>
        </TouchableOpacity>
        <TouchableOpacity
          style={styles.contactBtn}
          onPress={() => Linking.openURL(`sms:${customer.phone}`)}
          accessibilityRole="button"
          accessibilityLabel={`Text ${customer.name}`}
        >
          <Ionicons name="chatbubble-outline" size={14} color={colors.accent} />
          <Text style={styles.contactBtnText}>Text</Text>
        </TouchableOpacity>
        <TouchableOpacity
          style={styles.contactBtn}
          onPress={() => Linking.openURL(`mailto:${customer.email}`)}
          accessibilityRole="button"
          accessibilityLabel={`Email ${customer.name}`}
        >
          <Ionicons name="mail-outline" size={14} color={colors.accent} />
          <Text style={styles.contactBtnText}>Email</Text>
        </TouchableOpacity>
      </View>
    </Card>
  );
}

function EstimateCard({ job, navigation }: { job: Job; navigation: JobStackScreenProps<'JobDetail'>['navigation'] }) {
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
            accessibilityRole="button"
            accessibilityLabel="Edit estimate"
          >
            <Text style={styles.editLink}>Edit</Text>
          </TouchableOpacity>
          {canSendEstimate(job.status, job.estimateTotal) && (
            <>
              <Text style={styles.editLinkSep}>·</Text>
              <TouchableOpacity
                onPress={() => navigation.navigate("SendEstimate", { jobId: job.id })}
                accessibilityRole="button"
                accessibilityLabel={job.status === "estimate_sent" ? "Re-send estimate" : "Send estimate"}
              >
                <Text style={styles.editLink}>{job.status === "estimate_sent" ? "Re-send →" : "Send →"}</Text>
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

      {approvedChangeOrderTotal(job) !== 0 && (
        <>
          <View style={styles.estimateRow}>
            <Text style={styles.estimateLabel}>Approved changes</Text>
            <Text style={styles.estimateValue}>
              {approvedChangeOrderTotal(job) > 0 ? "+" : ""}{formatQuote(approvedChangeOrderTotal(job))}
            </Text>
          </View>
          <View style={styles.estimateRow}>
            <Text style={[styles.estimateLabel, styles.estimateTotalLabel]}>Total incl. changes</Text>
            <Text style={[styles.estimateValue, styles.estimateTotalValue]}>
              {formatQuote(jobBillableTotal(job))}
            </Text>
          </View>
        </>
      )}
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
        <TouchableOpacity onPress={onAdd} accessibilityRole="button" accessibilityLabel="Add photo">
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
            <View key={i} style={styles.photoThumbWrap}>
              <TouchableOpacity
                onPress={() => setViewerUri(uri)}
                activeOpacity={0.85}
                accessibilityRole="imagebutton"
                accessibilityLabel={`View photo ${i + 1} of ${photos.length}`}
              >
                <Image source={{ uri }} style={styles.photoThumb} contentFit="cover" />
              </TouchableOpacity>
              <TouchableOpacity
                style={styles.photoDeleteBtn}
                onPress={() =>
                  Alert.alert("Delete photo?", "This cannot be undone.", [
                    { text: "Cancel", style: "cancel" },
                    { text: "Delete", style: "destructive", onPress: () => onDelete(uri) },
                  ])
                }
                accessibilityLabel="Delete photo"
                accessibilityRole="button"
              >
                <View style={styles.photoDeleteCircle}>
                  <Ionicons name="close" size={13} color="#fff" />
                </View>
              </TouchableOpacity>
            </View>
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
          {viewerUri && (
            <Image source={{ uri: viewerUri }} style={styles.viewerImage} contentFit="contain" />
          )}
          {/* Rendered after the full-viewport Image: a later sibling wins
              hit-testing, so the other order leaves the ✕ visible through the
              letterbox but untappable. */}
          <TouchableOpacity style={styles.viewerClose} onPress={() => setViewerUri(null)} hitSlop={{ top: 4, bottom: 4, left: 4, right: 4 }} accessibilityRole="button" accessibilityLabel="Close photo viewer">
            <Ionicons name="close" size={20} color="#fff" />
          </TouchableOpacity>
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
          accessibilityRole="button"
          accessibilityLabel={isClocked ? "Clock out" : "Clock in"}
        >
          <Ionicons
            name={isClocked ? "stop" : "play"}
            size={12}
            color={isClocked ? colors.danger : colors.accent}
          />
          <Text style={[styles.clockBtnText, isClocked && styles.clockBtnTextOut]}>
            {isClocked ? "Clock Out" : "Clock In"}
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

function PrimaryAction({ job, reviewSent, navigation, onAdvance }: { job: Job; reviewSent: boolean; navigation: JobStackScreenProps<'JobDetail'>['navigation']; onAdvance: () => void }) {
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
      label: job.invoiceId ? "Finalize invoice" : "Create invoice",
      onPress: () =>
        navigation.navigate("CreateInvoiceFromJob", { jobId: job.id }),
      variant: "primary",
    },
    invoiced: {
      label: "View invoice & send outreach",
      onPress: () => {
        if (job.invoiceId) {
          navigation.navigate("Outreach", { invoiceId: job.invoiceId });
        }
      },
      variant: "primary",
    },
    paid: {
      label: reviewSent ? "Review request sent ✓" : "Request a review",
      onPress: () =>
        navigation.navigate("ReviewRequest", { jobId: job.id, source: "job_detail" }),
      variant: reviewSent ? "ghost" : "primary",
    },
  };

  const action = actions[job.status];
  if (!action) return null;

  return (
    <>
      <Button
        label={action.label}
        onPress={action.onPress}
        variant={action.variant}
        style={{ marginBottom: spacing.sm }}
      />
      {job.status === "estimate_sent" && (
        <Button
          label="Send follow-up"
          variant="secondary"
          onPress={() => {
            track("estimate_follow_up_opened", { source: "job_detail" });
            navigation.navigate("EstimateFollowUp", { jobId: job.id, source: "job_detail" });
          }}
          style={{ marginBottom: spacing.sm }}
        />
      )}
    </>
  );
}

function DepositAction({ job, navigation }: { job: Job; navigation: JobStackScreenProps<'JobDetail'>['navigation'] }) {
  if (!canRequestDeposit(job.status)) return null;

  if (job.invoiceId) {
    const invoiceId = job.invoiceId;
    return (
      <Button
        label="View deposit →"
        variant="secondary"
        onPress={() => navigation.navigate("Outreach", { invoiceId })}
        style={{ marginBottom: spacing.sm }}
      />
    );
  }

  return (
    <Button
      label="Request deposit →"
      variant="secondary"
      onPress={() => navigation.navigate("CreateInvoiceFromJob", { jobId: job.id })}
      style={{ marginBottom: spacing.sm }}
    />
  );
}

// Manual review-request path for jobs that finished but aren't paid yet —
// covers asking before payment and recovering a missed auto-notification.
// Paid jobs get the PrimaryAction CTA instead; once sent, this hides.
function ReviewRequestAction({ job, reviewSent, navigation }: { job: Job; reviewSent: boolean; navigation: JobStackScreenProps<'JobDetail'>['navigation'] }) {
  if (job.status !== "complete" && job.status !== "invoiced") return null;
  if (reviewSent) return null;

  return (
    <Button
      label="Request review →"
      variant="secondary"
      onPress={() =>
        navigation.navigate("ReviewRequest", { jobId: job.id, source: "job_detail" })
      }
      style={{ marginBottom: spacing.sm }}
    />
  );
}

// ── Main Screen ────────────────────────────────────────────────────────────

export default function JobDetailScreen({ route, navigation }: JobStackScreenProps<'JobDetail'>) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  const { showUndo } = useUndo();

  const { jobId } = route.params;

  const [job, setJob] = useState<Job | null>(null);
  const [customer, setCustomer] = useState<Customer | null>(null);
  const [loading, setLoading] = useState<boolean>(true);
  const [loadError, setLoadError] = useState<boolean>(false);
  const [reviewSent, setReviewSent] = useState<boolean>(false);

  useFocusEffect(
    useCallback(() => {
      let active = true;

      async function load() {
        setLoading(true);
        setLoadError(false);
        try {
          const [jobs, customers, invoices, reviewRecord] = await Promise.all([
            loadJobs(),
            loadCustomers(),
            loadInvoices(),
            // Unlike the collection loads, this read can throw (raw
            // getItem + JSON.parse); a bad review record must not fail
            // the whole job load — degrade to "not sent yet".
            getReviewRequestRecord(jobId).catch(() => null),
          ]);
          if (!active) return;

          // Read-side sweep (FA-038) — same reconcile as JobsScreen, so a
          // webhook-paid invoice is reflected even when the user deep-links
          // straight here without visiting the Jobs list.
          const advanced = advanceJobsForPaidInvoices(jobs, invoices);
          if (advanced !== jobs) {
            // The sweep's write must not fail the load — the reads above all
            // succeeded. Degrade to the advanced state in memory; the next
            // focus retries the save.
            try {
              await saveJobs(advanced);
            } catch (error: unknown) {
              reportError(error, { context: 'jobDetailSweepSave' });
            }
          }

          const j = advanced.find((x: Job) => x.id === jobId);
          if (!j) {
            setLoadError(true);
            return;
          }

          setJob(j);
          // Name-join fallback keeps contact links working when the id dangles
          // (e.g. recurring-rule jobs created before a sample-id remap).
          setCustomer(resolveCustomer(customers, j));
          setReviewSent(!!reviewRecord?.sentAt);
        } catch (error: unknown) {
          console.error("JobDetailScreen: failed to load job", error);
          reportError(error, { context: 'jobDetailLoad' });
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

  // useCallback (not a plain function) because the on-my-way deep-link
  // effect just below calls this directly and needs a stable-per-job/
  // customer reference for its dependency array — a plain function would be
  // a new identity every render and force that effect to re-run constantly.
  const handleAppointmentSend = useCallback(
    async (kind: "confirm" | "on_my_way") => {
      if (!job || !customer) return;
      const settings = await loadSettings();
      const opened = await sendAppointmentMessage({ job, customer, settings, kind });
      if (opened) {
        track(kind === "confirm" ? "appointment_confirm_sent" : "on_my_way_sent", {});
      }
    },
    [job, customer]
  );

  // "On my way" auto-action — tradeready://onmyway/<jobId> (produced by the
  // Siri OnMyWayIntent only, no widget button for this one; consumed in
  // App.tsx's consumeDeepLink) lands here with autoAction: "onmyway".
  // Reuses the SAME handler the in-app "I'm on my way" button
  // calls (handleAppointmentSend, above) — the existing template-driven,
  // channel-aware (SMS/email via resolveChannel) composer. This deep link
  // must NOT re-introduce a second local message composer (that was this
  // task's original mistake — a job/customer's on-my-way message has exactly
  // one implementation). Fires exactly once per arrival, gated on `loading`
  // rather than just `job` so it waits for the SAME focus load that settles
  // `customer` too (both are set together — see load() above) before
  // deciding; then clears the param so a later focus (tab switch and back)
  // doesn't reopen it — same "consume once" pattern as openInvoiceId in
  // InvoicesScreen/TodayScreen. Unlike the button (which only renders for
  // ACTIVE_STATUSES + a schedule), the deep link applies to any status —
  // handleAppointmentSend itself only requires job+customer, and a
  // tradesperson saying "I'm on my way" to a lead is fine. No linked
  // customer → handleAppointmentSend's own `!customer` guard no-ops.
  const autoAction = route.params.autoAction;
  useEffect(() => {
    if (autoAction !== "onmyway" || loading || !job) return;
    navigation.setParams({ autoAction: undefined });
    handleAppointmentSend("on_my_way");
  }, [autoAction, loading, job, navigation, handleAppointmentSend]);

  async function advanceStatus() {
    if (!job) return;
    const current = JOB_STATUSES[job.status];
    if (!current?.next) return;
    await updateJob({ status: current.next });
    track('job_status_changed', { from: job.status, to: current.next });

    if (current.next === "complete") {
      if (customer) {
        loadSettings()
          .then((settings) => scheduleReviewRequest(job, customer, settings))
          .catch(() => {});
      }

      // Opt-in auto-invoice (utils/autoInvoice): create the final bill and
      // jump straight to the send screen. Any unmet gate — toggle off, deposit
      // invoice pending, no estimate — returns null, and any failure degrades
      // to the manual flow (the "Create invoice →" primary action below).
      try {
        const result = await createAutoInvoiceForJob(job.id);
        if (result) {
          setJob((prev) =>
            prev ? { ...prev, ...jobChangesAfterInvoiceSave("create", result.invoiceId, false) } : prev
          );
          if (result.autoEmailQueued) {
            // Fully-automatic mode (2026-08-06 spec): no send screen. The
            // backend sweep emails the stamped invoice within ~15 minutes;
            // deleting the invoice before then cancels the send.
            Alert.alert(
              "Invoice on its way",
              `Invoice ${result.number} created — it'll be emailed to ${result.email} within about 15 minutes.`,
              [
                {
                  text: "View invoice",
                  onPress: () => navigation.navigate("Outreach", { invoiceId: result.invoiceId }),
                },
                { text: "OK" },
              ]
            );
          } else {
            navigation.navigate("Outreach", { invoiceId: result.invoiceId });
          }
        }
      } catch (error: unknown) {
        reportError(error, { context: "autoInvoiceOnComplete" });
      }
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

  // ChangeOrdersSection owns its own storage writes (send/decide/cancel/
  // delete all go straight through loadJobs/saveJobs, not updateJob above),
  // so it needs a plain re-read afterward rather than a `changes` patch.
  // Deliberately narrower than the useFocusEffect load() above (no invoice
  // sweep / review-record refetch) — this only needs to reflect what a CO
  // action can actually change: the job's changeOrders and, in principle,
  // its linked customer.
  const reloadJob = useCallback(async () => {
    try {
      const [jobs, customers] = await Promise.all([loadJobs(), loadCustomers()]);
      const j = jobs.find((x: Job) => x.id === jobId);
      if (!j) return;
      setJob(j);
      setCustomer(resolveCustomer(customers, j));
    } catch (error: unknown) {
      reportError(error, { context: "jobDetailChangeOrderReload" });
    }
  }, [jobId]);

  async function handleToggleArchive() {
    if (!job) return;
    const today = new Date().toISOString().split("T")[0];
    const archiving = !isArchived(job);
    const jobs = await loadJobs();
    const updated = jobs.map((j) => (j.id === job.id ? withArchived(j, archiving, today) : j));
    await saveJobs(updated);
    setJob(withArchived(job, archiving, today));
    if (archiving) navigation.goBack();
  }

  async function handleDelete() {
    Alert.alert("Delete job?", "You can undo for a few seconds after deleting.", [
      { text: "Cancel", style: "cancel" },
      {
        text: "Delete",
        style: "destructive",
        onPress: async () => {
          const jobs = await loadJobs();
          const deleted = jobs.find((j: Job) => j.id === jobId);
          await saveJobs(jobs.filter((j: Job) => j.id !== jobId));
          navigation.goBack();
          if (deleted) {
            showUndo("Job deleted", async () => {
              const current = await loadJobs();
              if (!current.some((j) => j.id === deleted.id)) {
                await saveJobs([...current, deleted]);
              }
            });
          }
        },
      },
    ]);
  }

  async function handleReviseAndResend() {
    if (!job) return;
    const jobs = await loadJobs();
    const reset = jobs.map((j): Job =>
      j.id === job.id ? { ...stampEstimateSent(j, new Date()), approval: j.approval ? { ...j.approval, decision: undefined, consentAt: undefined, declineReason: undefined, signerName: undefined } : undefined } : j
    );
    await saveJobs(reset);
    navigation.navigate("SendEstimate", { jobId: job.id });
  }

  async function handleAddPhoto() {
    if (!job) return;
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
          if (!result.canceled && job) {
            const uri = await persistPhotoSafe(result.assets[0].uri, "job-photos");
            if (!uri) {
              Alert.alert("Couldn't save that photo", "The photo wasn't added to this job. Please try again.");
              return;
            }
            await updateJob({ photos: [...(job.photos || []), uri] });
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
          if (!result.canceled && job) {
            const uri = await persistPhotoSafe(result.assets[0].uri, "job-photos");
            if (!uri) {
              Alert.alert("Couldn't save that photo", "The photo wasn't added to this job. Please try again.");
              return;
            }
            await updateJob({ photos: [...(job.photos || []), uri] });
          }
        },
      },
      { text: "Cancel", style: "cancel" },
    ]);
  }

  async function handleDeletePhoto(uri: string) {
    if (!job) return;
    await updateJob({ photos: (job.photos || []).filter((p) => p !== uri) });
    await deletePhoto(uri);
  }

  async function handleClockIn() {
    if (!job) return;
    const updated = applyClockIn(job, new Date().toISOString());
    if (!updated) return;
    await updateJob({ timeSessions: updated.timeSessions, status: updated.status });
    track('time_tracking_started', { jobId });
  }

  async function handleClockOut() {
    if (!job) return;
    const updated = applyClockOut(job, new Date().toISOString());
    if (!updated) return;
    await updateJob({ timeSessions: updated.timeSessions });
  }

  // ── Loading state ──────────────────────────────────────────────────────

  if (loading) {
    return (
      <View style={[styles.container, styles.centered]}>
        <ActivityIndicator size={36} color={colors.accent} />
      </View>
    );
  }

  // ── Error state ────────────────────────────────────────────────────────

  if (loadError || !job) {
    return (
      <View style={[styles.container, styles.centered]}>
        <Text style={styles.errorTitle}>Couldn't load this job</Text>
        <Text style={styles.errorSubtext}>
          It may have been deleted or something went wrong.
        </Text>
        <TouchableOpacity
          style={styles.errorButton}
          onPress={() => navigation.goBack()}
          accessibilityRole="button"
          accessibilityLabel="Go back"
        >
          <Text style={styles.errorButtonText}>Go back</Text>
        </TouchableOpacity>
      </View>
    );
  }

  // ── Main render ────────────────────────────────────────────────────────

  return (
    <View style={styles.container}>
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
            accessibilityRole="button"
            accessibilityLabel="Part of a recurring series. View recurring jobs"
          >
            <Ionicons name="repeat-outline" size={14} color={colors.accent} />
            <Text style={styles.recurringBannerText}>Part of a recurring series</Text>
          </TouchableOpacity>
        ) : null}
        <JobDetailsCard
          job={job}
          navigation={navigation}
          customer={customer}
          onAppointmentSend={handleAppointmentSend}
        />
        {customer && <CustomerCard customer={customer} />}
        <EstimateCard job={job} navigation={navigation} />
        <ChangeOrdersSection
          job={job}
          onChanged={reloadJob}
          onAdd={() => navigation.navigate("AddChangeOrder", { jobId: job.id })}
          onEdit={(changeOrderId) => navigation.navigate("AddChangeOrder", { jobId: job.id, changeOrderId })}
        />
        {TIME_TRACKING_STATUSES.has(job.status) && (
          <TimeTrackingCard
            sessions={job.timeSessions || []}
            estimatedHours={job.laborHours || 0}
            onClockIn={handleClockIn}
            onClockOut={handleClockOut}
          />
        )}
        <PhotosCard
          photos={job.photos || []}
          onAdd={handleAddPhoto}
          onDelete={handleDeletePhoto}
        />

        <Divider />

        <PrimaryAction
          job={job}
          reviewSent={reviewSent}
          navigation={navigation}
          onAdvance={advanceStatus}
        />

        <DepositAction job={job} navigation={navigation} />

        <ReviewRequestAction job={job} reviewSent={reviewSent} navigation={navigation} />

        {job.status === "declined" && (
          <Button
            label="Revise & re-send estimate"
            variant="secondary"
            onPress={handleReviseAndResend}
            style={{ marginBottom: spacing.sm }}
          />
        )}

        <Button
          label="Duplicate job"
          variant="secondary"
          onPress={() => navigation.navigate("AddJob", { duplicateFromJobId: job.id })}
          style={{ marginBottom: spacing.sm }}
        />

        <Button
          label={isArchived(job) ? "Unarchive job" : "Archive job"}
          variant="secondary"
          onPress={handleToggleArchive}
          style={{ marginBottom: spacing.sm }}
        />

        <TouchableOpacity style={styles.deleteBtn} onPress={handleDelete} accessibilityRole="button" accessibilityLabel="Delete job">
          <Text style={styles.deleteBtnText}>Delete job</Text>
        </TouchableOpacity>
      </ScrollView>
    </View>
  );
}

// ── Styles ─────────────────────────────────────────────────────────────────

function createStyles(colors: ColorScheme, shadow: ShadowScheme) {
  return StyleSheet.create({
    container: { flex: 1, backgroundColor: colors.background },
    scroll: { padding: spacing.md, paddingBottom: 40, ...layout.contentColumn },

    centered: { justifyContent: "center", alignItems: "center", padding: spacing.md },

    // Pipeline
    pipelineCard: { marginBottom: spacing.sm, paddingVertical: spacing.md },
    declinedCard: {
      marginBottom: spacing.sm,
      backgroundColor: colors.dangerBg,
      borderWidth: 1,
      borderColor: colors.danger + "40",
    },
    declinedRow: { flexDirection: "row", alignItems: "center", gap: spacing.sm },
    declinedTextWrap: { flex: 1 },
    declinedTitle: {
      fontFamily: fonts.display,
      fontSize: fontSize.md,
      color: colors.danger,
      marginBottom: 2,
    },
    declinedSub: {
      fontFamily: fonts.bodyRegular,
      fontSize: fontSize.sm,
      color: colors.textSecondary,
    },
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
      fontFamily: fonts.mono, fontSize: 11, color: colors.accent,
      textTransform: "uppercase", letterSpacing: 0.6,
    },
    pipelineStepCount: { fontFamily: fonts.mono, fontSize: 10, color: colors.textMuted },

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
      fontFamily: fonts.bodyMedium,
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
      fontFamily: fonts.mono, fontSize: fontSize.xs, color: colors.textSecondary,
      textTransform: "uppercase", letterSpacing: 0.8,
    },
    editLink: {
      fontFamily: fonts.mono, fontSize: 11, color: colors.accent,
      textTransform: "uppercase", letterSpacing: 0.4,
    },
    estimateHeaderActions: { flexDirection: "row", alignItems: "center", gap: 6 },
    editLinkSep: { fontSize: fontSize.sm, color: colors.textMuted },

    // Job details
    jobTitle: { fontFamily: fonts.bodyBold, fontSize: fontSize.lg, color: colors.textPrimary, marginBottom: 6 },
    jobDesc: { fontFamily: fonts.bodyRegular, fontSize: fontSize.md, color: colors.textSecondary, lineHeight: 22, marginBottom: 8 },
    iconRow: { flexDirection: "row", alignItems: "center", gap: 5, marginBottom: 6 },
    addressLink: { fontFamily: fonts.bodyMedium, fontSize: fontSize.sm, color: colors.accent },
    scheduleText: { fontFamily: fonts.mono, fontSize: 11, color: colors.textSecondary },
    metaRow: { fontFamily: fonts.bodyRegular, fontSize: fontSize.sm, color: colors.textSecondary, marginBottom: 4 },
    apptActions: { flexDirection: "row", gap: spacing.sm, marginTop: spacing.sm },
    notesRow: { flexDirection: "row", alignItems: "flex-start", gap: 5, marginTop: 4 },
    notesIcon: { marginTop: 2 },
    notes: { fontFamily: fonts.bodyRegular, flex: 1, fontSize: fontSize.sm, color: colors.textSecondary, fontStyle: "italic" },

    // Customer
    customerName: { fontFamily: fonts.bodySemiBold, fontSize: fontSize.md, color: colors.textPrimary, marginBottom: spacing.sm },
    contactRow: { flexDirection: "row", gap: 8 },
    contactBtn: {
      flex: 1, paddingVertical: 8, borderRadius: radius.md,
      backgroundColor: colors.accentBg, alignItems: "center",
      flexDirection: "row", justifyContent: "center", gap: 5,
    },
    contactBtnText: { fontFamily: fonts.bodyMedium, fontSize: fontSize.sm, color: colors.accent },

    // Estimate
    estimateRow: {
      flexDirection: "row", justifyContent: "space-between",
      alignItems: "center", marginBottom: 6,
    },
    estimateLabel: { fontFamily: fonts.bodyRegular, fontSize: fontSize.sm, color: colors.textSecondary, flex: 1, marginRight: spacing.sm },
    estimateValue: { fontFamily: fonts.mono, fontSize: 12, color: colors.textPrimary },
    estimateTotalLabel: { fontFamily: fonts.bodySemiBold, color: colors.textPrimary },
    estimateTotalValue: { fontFamily: fonts.display, fontSize: fontSize.lg, fontVariant: ["tabular-nums"] },
    noEstimateText: { fontFamily: fonts.bodyRegular, fontSize: fontSize.sm, color: colors.textMuted, marginBottom: 4 },

    // Photos
    photoStrip: { marginTop: spacing.xs },
    photoThumbWrap: {
      position: 'relative' as const,
      marginRight: spacing.sm,
    },
    photoThumb: {
      width: 88,
      height: 88,
      borderRadius: radius.md,
      backgroundColor: colors.border,
    },
    // The 44pt target sits fully inside the 88pt thumb: RN clips hit-testing
    // to the parent's bounds, so the old corner-overhang badge (top/right -6
    // plus hitSlop) only ever got a ~27pt effective target.
    photoDeleteBtn: {
      position: 'absolute' as const,
      top: 0,
      right: 0,
      width: 44,
      height: 44,
      alignItems: 'flex-end' as const,
      padding: 6,
    },
    photoDeleteCircle: {
      width: 22,
      height: 22,
      borderRadius: 11,
      backgroundColor: colors.danger,
      alignItems: 'center' as const,
      justifyContent: 'center' as const,
    },
    noPhotosText: { fontFamily: fonts.bodyRegular, fontSize: fontSize.sm, color: colors.textMuted },
    viewerBg: {
      flex: 1,
      backgroundColor: "rgba(0,0,0,0.95)",
      justifyContent: "center",
      alignItems: "center",
    },
    // The viewer Image uses contentFit="contain", so it letterboxes itself
    // inside whatever box this style gives it — the box should therefore be
    // the whole viewport on BOTH axes and let containment do the fitting.
    // The old `height: "80%"` was a portrait-tuned constant: in portrait the
    // scarce axis is width (so the cap cost nothing), but in landscape height
    // is the scarce axis and the cap threw away 20% of it while width stayed
    // at 100%. Phone portrait is unaffected for ordinary photos — anything
    // with an aspect ratio wider than the viewport's own is width-limited, so
    // its rendered size never depended on the box height.
    viewerImage: { width: "100%", height: "100%" },
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
    // Time tracking
    sessionCountText: { fontFamily: fonts.mono, fontSize: 10, color: colors.textMuted, textTransform: "uppercase", letterSpacing: 0.4 },
    timerRow: {
      flexDirection: "row",
      justifyContent: "space-between",
      alignItems: "center",
      marginBottom: 6,
    },
    timerDisplay: {
      fontFamily: fonts.display,
      fontSize: 32,
      color: colors.textPrimary,
      letterSpacing: -0.5,
      fontVariant: ["tabular-nums"],
    },
    timerDisplayActive: { color: colors.accent },
    timerSub: { fontFamily: fonts.mono, fontSize: 10, color: colors.textMuted, marginTop: 2 },
    clockBtn: {
      paddingHorizontal: 16,
      paddingVertical: 10,
      borderRadius: radius.md,
      backgroundColor: colors.accentBg,
      borderWidth: 1,
      borderColor: colors.accent,
      flexDirection: "row",
      alignItems: "center",
      gap: 6,
    },
    clockBtnOut: {
      backgroundColor: colors.dangerBg,
      borderColor: colors.danger,
    },
    clockBtnText: {
      fontFamily: fonts.bodySemiBold,
      fontSize: fontSize.sm,
      color: colors.accent,
    },
    clockBtnTextOut: { color: colors.danger },
    clockedSince: { fontFamily: fonts.bodyRegular, fontSize: fontSize.xs, color: colors.textMuted, marginTop: 4 },

    // Delete
    deleteBtn: { alignItems: "center", paddingVertical: spacing.md, marginTop: spacing.sm },
    deleteBtnText: { fontFamily: fonts.bodyMedium, fontSize: fontSize.sm, color: colors.danger },

    // Error state
    errorTitle: { fontFamily: fonts.display, fontSize: fontSize.lg, color: colors.textPrimary, marginBottom: 8, textAlign: "center" },
    errorSubtext: { fontFamily: fonts.bodyRegular, fontSize: fontSize.sm, color: colors.textMuted, textAlign: "center", marginBottom: 32 },
    errorButton: { backgroundColor: colors.accent, paddingHorizontal: 32, paddingVertical: 14, borderRadius: radius.md },
    errorButtonText: { fontFamily: fonts.bodyBold, color: colors.textOnAccent, fontSize: fontSize.md },
  });
}
