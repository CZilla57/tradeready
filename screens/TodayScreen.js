import React, { useState, useCallback } from 'react';
import {
  View,
  Text,
  StyleSheet,
  ScrollView,
  TouchableOpacity,
  ActivityIndicator,
} from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { useFocusEffect } from '@react-navigation/native';
import { colors, spacing, radius, fontSize, shadow } from '../utils/theme';
import {
  loadJobsForDate,
  getExpectedEarningsForDate,
  loadOverdueInvoices,
  loadLeadJobs,
} from '../utils/storage';
import { daysPastDue } from '../utils/invoiceHelpers';

// ─── Helpers ─────────────────────────────────────────────────────────────────

function getTodayDateString() {
  const now = new Date();
  const y = now.getFullYear();
  const m = String(now.getMonth() + 1).padStart(2, '0');
  const d = String(now.getDate()).padStart(2, '0');
  return `${y}-${m}-${d}`;
}

function formatDisplayDate(dateString) {
  const [year, month, day] = dateString.split('-').map(Number);
  return new Date(year, month - 1, day).toLocaleDateString('en-US', {
    weekday: 'long',
    month: 'long',
    day: 'numeric',
  });
}

function getGreeting() {
  const h = new Date().getHours();
  if (h < 12) return 'Good morning';
  if (h < 17) return 'Good afternoon';
  return 'Good evening';
}

function formatCurrency(amount) {
  return new Intl.NumberFormat('en-US', {
    style: 'currency',
    currency: 'USD',
    minimumFractionDigits: 0,
    maximumFractionDigits: 0,
  }).format(amount);
}

function formatTimeRange(startTime, endTime) {
  if (!startTime) return 'Unscheduled';
  const fmt = (t) => {
    const [h, m] = t.split(':').map(Number);
    const period = h >= 12 ? 'PM' : 'AM';
    const hour = h % 12 === 0 ? 12 : h % 12;
    return `${hour}:${String(m).padStart(2, '0')} ${period}`;
  };
  return endTime ? `${fmt(startTime)} – ${fmt(endTime)}` : fmt(startTime);
}

function daysAgo(dateString) {
  if (!dateString) return 'recently';
  const diff = Math.floor((Date.now() - new Date(dateString)) / 86400000);
  if (diff === 0) return 'today';
  if (diff === 1) return '1 day ago';
  return `${diff} days ago`;
}

const JOB_STATUS_CONFIG = {
  scheduled:     { label: 'Scheduled',     color: colors.statusScheduled },
  in_progress:   { label: 'In Progress',   color: colors.statusInProgress },
  completed:     { label: 'Completed',     color: colors.statusComplete },
  estimate_sent: { label: 'Estimate Sent', color: colors.statusEstimate },
  lead:          { label: 'Lead',          color: colors.statusLead },
};

function getJobStatusConfig(status) {
  return JOB_STATUS_CONFIG[status] ?? { label: status, color: colors.statusLead };
}

// ─── Sub-components ──────────────────────────────────────────────────────────

function BriefingSection({ title, actionLabel, onAction, children }) {
  return (
    <View style={styles.section}>
      <View style={styles.sectionHeaderRow}>
        <Text style={styles.sectionTitle}>{title}</Text>
        {actionLabel ? (
          <TouchableOpacity onPress={onAction} hitSlop={{ top: 8, bottom: 8, left: 8, right: 8 }}>
            <Text style={styles.sectionAction}>{actionLabel}</Text>
          </TouchableOpacity>
        ) : null}
      </View>
      {children}
    </View>
  );
}

function StatsRow({ earnings, overdueTotal, overdueCount, leadCount, loading, onEarningsTap, onOverdueTap, onLeadsTap }) {
  return (
    <View style={styles.statsRow}>
      {/* Today's earnings */}
      <TouchableOpacity style={styles.statCard} onPress={onEarningsTap} activeOpacity={0.75}>
        <Text style={styles.statLabel}>TODAY</Text>
        {loading
          ? <ActivityIndicator color={colors.accent} size="small" style={styles.statSpinner} />
          : <Text style={[styles.statValue, { color: colors.accent }]}>{formatCurrency(earnings)}</Text>
        }
        <Text style={styles.statSub}>Expected</Text>
      </TouchableOpacity>

      {/* Overdue invoices */}
      <TouchableOpacity
        style={[styles.statCard, !loading && overdueCount > 0 && styles.statCardDanger]}
        onPress={onOverdueTap}
        activeOpacity={0.75}
      >
        <Text style={[styles.statLabel, !loading && overdueCount > 0 && { color: colors.danger }]}>
          OVERDUE
        </Text>
        {loading
          ? <ActivityIndicator color={colors.textMuted} size="small" style={styles.statSpinner} />
          : <Text style={[styles.statValue, { color: overdueCount > 0 ? colors.danger : colors.textMuted }]}>
              {overdueCount > 0 ? formatCurrency(overdueTotal) : '—'}
            </Text>
        }
        <Text style={[styles.statSub, !loading && overdueCount > 0 && { color: colors.danger }]}>
          {loading ? ' ' : overdueCount > 0 ? `${overdueCount} invoice${overdueCount !== 1 ? 's' : ''}` : 'All clear'}
        </Text>
      </TouchableOpacity>

      {/* Leads */}
      <TouchableOpacity
        style={[styles.statCard, !loading && leadCount > 0 && styles.statCardWarning]}
        onPress={onLeadsTap}
        activeOpacity={0.75}
      >
        <Text style={[styles.statLabel, !loading && leadCount > 0 && { color: colors.warning }]}>
          LEADS
        </Text>
        {loading
          ? <ActivityIndicator color={colors.textMuted} size="small" style={styles.statSpinner} />
          : <Text style={[styles.statValue, { color: leadCount > 0 ? colors.warning : colors.textMuted }]}>
              {leadCount > 0 ? String(leadCount) : '—'}
            </Text>
        }
        <Text style={[styles.statSub, !loading && leadCount > 0 && { color: colors.warning }]}>
          {loading ? ' ' : leadCount > 0 ? 'follow up' : 'None pending'}
        </Text>
      </TouchableOpacity>
    </View>
  );
}

function OverdueInvoiceRow({ invoice, isLast, onPress }) {
  const days = daysPastDue(invoice.due);
  const isSerious = days > 14;
  const tagColor = isSerious ? colors.danger : colors.warning;
  const tagBg = isSerious ? colors.dangerBg : colors.warningBg;

  return (
    <TouchableOpacity
      style={[styles.listRow, !isLast && styles.listRowBorder]}
      onPress={onPress}
      activeOpacity={0.7}
    >
      <View style={styles.listRowMain}>
        <Text style={styles.listRowTitle} numberOfLines={1}>{invoice.customer}</Text>
        <Text style={styles.listRowSub}>{invoice.number}</Text>
      </View>
      <View style={styles.listRowRight}>
        <Text style={[styles.listRowAmount, { color: tagColor }]}>{formatCurrency(invoice.amount)}</Text>
        <View style={[styles.overdueTag, { backgroundColor: tagBg }]}>
          <Text style={[styles.overdueTagText, { color: tagColor }]}>{days}d overdue</Text>
        </View>
      </View>
    </TouchableOpacity>
  );
}

function LeadRow({ job, isLast, onPress }) {
  return (
    <TouchableOpacity
      style={[styles.listRow, !isLast && styles.listRowBorder]}
      onPress={onPress}
      activeOpacity={0.7}
    >
      <View style={styles.listRowMain}>
        <Text style={styles.listRowTitle} numberOfLines={1}>{job.title}</Text>
        <Text style={styles.listRowSub}>{job.customerName} · added {daysAgo(job.createdAt)}</Text>
      </View>
      <Text style={styles.listRowChevron}>›</Text>
    </TouchableOpacity>
  );
}

function SeeMoreRow({ label, onPress }) {
  return (
    <TouchableOpacity style={styles.seeMoreRow} onPress={onPress} activeOpacity={0.7}>
      <Text style={styles.seeMoreText}>{label}</Text>
    </TouchableOpacity>
  );
}

function JobCard({ job, onPress }) {
  const { label, color } = getJobStatusConfig(job.status);

  return (
    <TouchableOpacity style={styles.jobCard} onPress={onPress} activeOpacity={0.7}>
      <View style={[styles.jobTimeColumn, { borderRightColor: colors.border }]}>
        <Text style={styles.jobStartTime}>
          {job.scheduledStartTime ? formatTimeRange(job.scheduledStartTime, null) : '—'}
        </Text>
        {job.scheduledEndTime && (
          <Text style={styles.jobEndTime}>{formatTimeRange(job.scheduledEndTime, null)}</Text>
        )}
      </View>
      <View style={styles.jobDetailsColumn}>
        <Text style={styles.jobTitle} numberOfLines={1}>{job.title}</Text>
        <Text style={styles.jobCustomer} numberOfLines={1}>
          {job.customerName}{job.address ? ` · ${job.address}` : ''}
        </Text>
        <View style={[styles.statusBadge, { backgroundColor: color + '22' }]}>
          <Text style={[styles.statusText, { color }]}>{label}</Text>
        </View>
      </View>
    </TouchableOpacity>
  );
}

function EmptySchedule({ onScheduleJob }) {
  return (
    <View style={styles.emptyState}>
      <Text style={styles.emptyTitle}>No jobs scheduled today</Text>
      <Text style={styles.emptySubtitle}>
        Tap below to schedule your first job for today.
      </Text>
      <TouchableOpacity style={styles.emptyButton} onPress={onScheduleJob} activeOpacity={0.8}>
        <Text style={styles.emptyButtonText}>+ Schedule a Job</Text>
      </TouchableOpacity>
    </View>
  );
}

// ─── Main Screen ─────────────────────────────────────────────────────────────

const INVOICE_LIMIT = 3;
const LEAD_LIMIT = 3;

export default function TodayScreen({ navigation }) {
  const insets = useSafeAreaInsets();
  const todayString = getTodayDateString();

  const [jobs, setJobs] = useState([]);
  const [earnings, setEarnings] = useState(0);
  const [overdueInvoices, setOverdueInvoices] = useState([]);
  const [leadJobs, setLeadJobs] = useState([]);
  const [loading, setLoading] = useState(true);

  useFocusEffect(
    useCallback(() => {
      let active = true;

      async function fetchTodayData() {
        setLoading(true);
        try {
          const [todaysJobs, expectedEarnings, overdue, leads] = await Promise.all([
            loadJobsForDate(todayString),
            getExpectedEarningsForDate(todayString),
            loadOverdueInvoices(),
            loadLeadJobs(),
          ]);
          if (active) {
            setJobs(todaysJobs);
            setEarnings(expectedEarnings);
            setOverdueInvoices(overdue);
            setLeadJobs(leads);
          }
        } catch (error) {
          console.error('TodayScreen: failed to load daily data', error);
        } finally {
          if (active) setLoading(false);
        }
      }

      fetchTodayData();
      return () => { active = false; };
    }, [todayString])
  );

  function goToInvoices() {
    navigation.getParent()?.navigate('Invoices');
  }

  function goToJobs() {
    navigation.getParent()?.navigate('Jobs');
  }

  function handleJobPress(job) {
    navigation.getParent()?.navigate('Jobs', { screen: 'JobDetail', params: { jobId: job.id } });
  }

  function handleScheduleJob() {
    navigation.getParent()?.navigate('Jobs', { screen: 'AddJob' });
  }

  function handlePlanRoute() {
    navigation.navigate('Route');
  }

  const overdueTotal = overdueInvoices.reduce((s, inv) => s + (Number(inv.amount) || 0), 0);
  const visibleInvoices = overdueInvoices.slice(0, INVOICE_LIMIT);
  const visibleLeads = leadJobs.slice(0, LEAD_LIMIT);
  const extraInvoices = overdueInvoices.length - INVOICE_LIMIT;
  const extraLeads = leadJobs.length - LEAD_LIMIT;

  return (
    <ScrollView
      style={[styles.container, { paddingTop: insets.top }]}
      contentContainerStyle={styles.scrollContent}
    >
      {/* Header */}
      <View style={styles.header}>
        <Text style={styles.greeting}>{getGreeting()}</Text>
        <Text style={styles.dateText}>{formatDisplayDate(todayString)}</Text>
      </View>

      {/* 3-stat summary row */}
      <StatsRow
        earnings={earnings}
        overdueTotal={overdueTotal}
        overdueCount={overdueInvoices.length}
        leadCount={leadJobs.length}
        loading={loading}
        onEarningsTap={goToJobs}
        onOverdueTap={goToInvoices}
        onLeadsTap={goToJobs}
      />

      {/* Overdue Invoices — only show once loaded and there's something to show */}
      {!loading && overdueInvoices.length > 0 && (
        <BriefingSection
          title="Overdue Invoices"
          actionLabel="View all"
          onAction={goToInvoices}
        >
          <View style={[styles.listCard, styles.listCardDanger]}>
            {visibleInvoices.map((inv, i) => (
              <OverdueInvoiceRow
                key={inv.id}
                invoice={inv}
                isLast={i === visibleInvoices.length - 1 && extraInvoices <= 0}
                onPress={goToInvoices}
              />
            ))}
            {extraInvoices > 0 && (
              <SeeMoreRow
                label={`See ${extraInvoices} more →`}
                onPress={goToInvoices}
              />
            )}
          </View>
        </BriefingSection>
      )}

      {/* Leads Follow-Up — only show once loaded and there's something to show */}
      {!loading && leadJobs.length > 0 && (
        <BriefingSection
          title="Follow Up"
          actionLabel="View all"
          onAction={goToJobs}
        >
          <View style={styles.listCard}>
            {visibleLeads.map((job, i) => (
              <LeadRow
                key={job.id}
                job={job}
                isLast={i === visibleLeads.length - 1 && extraLeads <= 0}
                onPress={() => handleJobPress(job)}
              />
            ))}
            {extraLeads > 0 && (
              <SeeMoreRow
                label={`See ${extraLeads} more →`}
                onPress={goToJobs}
              />
            )}
          </View>
        </BriefingSection>
      )}

      {/* Today's Schedule */}
      <BriefingSection
        title="Today's Schedule"
        actionLabel={!loading && jobs.length > 0 ? "Plan Route" : undefined}
        onAction={handlePlanRoute}
      >
        {loading && (
          <ActivityIndicator color={colors.accent} size={36} style={{ marginTop: 24 }} />
        )}
        {!loading && jobs.length === 0 && (
          <EmptySchedule onScheduleJob={handleScheduleJob} />
        )}
        {!loading && jobs.map((job) => (
          <JobCard key={job.id} job={job} onPress={() => handleJobPress(job)} />
        ))}
      </BriefingSection>

      <View style={{ height: 40 }} />
    </ScrollView>
  );
}

// ─── Styles ──────────────────────────────────────────────────────────────────

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: colors.background,
  },
  scrollContent: {
    flexGrow: 1,
  },

  // Header
  header: {
    paddingHorizontal: spacing.lg,
    paddingTop: spacing.md,
    paddingBottom: spacing.sm,
  },
  greeting: {
    fontSize: fontSize.sm,
    fontWeight: '600',
    color: colors.textMuted,
    letterSpacing: 0.3,
    marginBottom: 2,
  },
  dateText: {
    fontSize: fontSize.xxl,
    fontWeight: '700',
    color: colors.textPrimary,
    letterSpacing: -0.5,
  },

  // Stats row
  statsRow: {
    flexDirection: 'row',
    paddingHorizontal: spacing.md,
    gap: spacing.sm,
    marginTop: spacing.sm,
    marginBottom: spacing.xs,
  },
  statCard: {
    flex: 1,
    backgroundColor: colors.surface,
    borderRadius: radius.lg,
    padding: spacing.md,
    borderWidth: 1,
    borderColor: colors.border,
    ...shadow.card,
  },
  statCardDanger: {
    borderColor: colors.danger + '40',
    backgroundColor: colors.dangerBg,
  },
  statCardWarning: {
    borderColor: colors.warning + '40',
    backgroundColor: colors.warningBg,
  },
  statLabel: {
    fontSize: 10,
    fontWeight: '700',
    color: colors.textMuted,
    letterSpacing: 0.8,
  },
  statSpinner: {
    marginTop: 6,
    marginBottom: 2,
    alignSelf: 'flex-start',
  },
  statValue: {
    fontSize: fontSize.lg,
    fontWeight: '700',
    color: colors.textPrimary,
    marginTop: 4,
  },
  statSub: {
    fontSize: fontSize.xs,
    color: colors.textMuted,
    marginTop: 2,
  },

  // Section layout
  section: {
    marginTop: spacing.lg,
    paddingHorizontal: spacing.md,
  },
  sectionHeaderRow: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    marginBottom: spacing.sm,
  },
  sectionTitle: {
    fontSize: fontSize.xl,
    fontWeight: '700',
    color: colors.textPrimary,
  },
  sectionAction: {
    fontSize: fontSize.sm,
    fontWeight: '600',
    color: colors.accent,
  },

  // Shared list card
  listCard: {
    backgroundColor: colors.surface,
    borderRadius: radius.lg,
    borderWidth: 1,
    borderColor: colors.border,
    overflow: 'hidden',
    ...shadow.card,
  },
  listCardDanger: {
    borderLeftWidth: 3,
    borderLeftColor: colors.danger,
  },

  // List rows
  listRow: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingHorizontal: spacing.md,
    paddingVertical: 14,
  },
  listRowBorder: {
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: colors.border,
  },
  listRowMain: {
    flex: 1,
    marginRight: spacing.sm,
  },
  listRowTitle: {
    fontSize: fontSize.md,
    fontWeight: '600',
    color: colors.textPrimary,
    marginBottom: 2,
  },
  listRowSub: {
    fontSize: fontSize.sm,
    color: colors.textMuted,
  },
  listRowRight: {
    alignItems: 'flex-end',
  },
  listRowAmount: {
    fontSize: fontSize.md,
    fontWeight: '700',
    marginBottom: 4,
  },
  listRowChevron: {
    fontSize: 22,
    color: colors.textMuted,
    lineHeight: 24,
  },

  // Overdue badge
  overdueTag: {
    paddingHorizontal: 7,
    paddingVertical: 2,
    borderRadius: radius.full,
  },
  overdueTagText: {
    fontSize: fontSize.xs,
    fontWeight: '700',
  },

  // See more row
  seeMoreRow: {
    paddingVertical: 12,
    paddingHorizontal: spacing.md,
    borderTopWidth: StyleSheet.hairlineWidth,
    borderTopColor: colors.border,
    alignItems: 'center',
  },
  seeMoreText: {
    fontSize: fontSize.sm,
    fontWeight: '600',
    color: colors.accent,
  },

  // Job cards
  jobCard: {
    backgroundColor: colors.surface,
    borderRadius: radius.lg,
    padding: spacing.md,
    marginBottom: spacing.sm,
    flexDirection: 'row',
    borderWidth: 1,
    borderColor: colors.border,
    ...shadow.card,
  },
  jobTimeColumn: {
    width: 76,
    borderRightWidth: 1,
    marginRight: 14,
    justifyContent: 'center',
    paddingRight: 10,
  },
  jobStartTime: {
    fontSize: fontSize.md,
    fontWeight: '700',
    color: colors.textPrimary,
  },
  jobEndTime: {
    fontSize: fontSize.xs,
    color: colors.textMuted,
    marginTop: 2,
  },
  jobDetailsColumn: {
    flex: 1,
  },
  jobTitle: {
    fontSize: fontSize.lg,
    fontWeight: '700',
    color: colors.textPrimary,
    marginBottom: 3,
  },
  jobCustomer: {
    fontSize: fontSize.sm,
    color: colors.textMuted,
    marginBottom: spacing.sm,
  },
  statusBadge: {
    alignSelf: 'flex-start',
    paddingHorizontal: spacing.sm,
    paddingVertical: 3,
    borderRadius: radius.sm,
  },
  statusText: {
    fontSize: fontSize.xs,
    fontWeight: '700',
  },

  // Empty schedule state
  emptyState: {
    alignItems: 'center',
    paddingVertical: 40,
  },
  emptyTitle: {
    fontSize: fontSize.lg - 1,
    fontWeight: '700',
    color: colors.textPrimary,
    marginBottom: spacing.sm,
  },
  emptySubtitle: {
    fontSize: fontSize.sm,
    color: colors.textMuted,
    textAlign: 'center',
    marginBottom: spacing.lg,
    paddingHorizontal: spacing.lg,
  },
  emptyButton: {
    backgroundColor: colors.accent,
    paddingHorizontal: spacing.lg,
    paddingVertical: 14,
    borderRadius: radius.md,
  },
  emptyButtonText: {
    color: colors.textOnAccent,
    fontSize: fontSize.md,
    fontWeight: '700',
  },
});
