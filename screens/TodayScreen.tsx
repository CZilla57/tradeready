import React, { useState, useCallback, useMemo } from 'react';
import {
  View,
  Text,
  StyleSheet,
  ScrollView,
  TouchableOpacity,
  ActivityIndicator,
  RefreshControl,
  Alert,
} from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { useFocusEffect } from '@react-navigation/native';
import { spacing, radius, fontSize } from '../utils/theme';
import type { ColorScheme, ShadowScheme } from '../utils/theme';
import { useTheme } from '../hooks/useTheme';
import { useRefresh } from '../hooks/useRefresh';
import {
  loadJobs,
  getExpectedEarningsForDate,
  loadOverdueInvoices,
  loadLeadJobs,
  loadCustomers,
  loadSettings,
  resolveCustomer,
} from '../utils/storage';
import { sendAppointmentMessage } from '../utils/appointmentSend';
import { ACTIVE_STATUSES } from '../utils/appointmentMessages';
import { daysPastDue } from '../utils/invoiceHelpers';
import { formatMoney } from '../utils/format';
import {
  getTodayDateString,
  formatDisplayDate,
  getGreeting,
  formatTimeRange,
  daysAgo,
  getWeekDates,
  weekMonthLabel,
  shiftDate,
} from '../utils/dateHelpers';
import { getJobStatusDisplay } from '../utils/jobStatusDisplay';
import type { Job, Invoice } from '../types/models';
import { reportError, track } from '../utils/analytics';
import type { TodayStackScreenProps } from '../types/navigation';

// ─── Sub-components ──────────────────────────────────────────────────────────

interface BriefingSectionProps {
  title: string;
  actionLabel?: string;
  onAction?: () => void;
  children: React.ReactNode;
}

function BriefingSection({ title, actionLabel, onAction, children }: BriefingSectionProps) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);

  return (
    <View style={styles.section}>
      <View style={styles.sectionHeaderRow}>
        <Text style={styles.sectionTitle}>{title}</Text>
        {actionLabel ? (
          <TouchableOpacity onPress={onAction} hitSlop={{ top: 8, bottom: 8, left: 8, right: 8 }} accessibilityRole="button" accessibilityLabel={actionLabel}>
            <Text style={styles.sectionAction}>{actionLabel}</Text>
          </TouchableOpacity>
        ) : null}
      </View>
      {children}
    </View>
  );
}

interface StatsRowProps {
  earnings: number;
  overdueTotal: number;
  overdueCount: number;
  leadCount: number;
  loading: boolean;
  onEarningsTap: () => void;
  onOverdueTap: () => void;
  onLeadsTap: () => void;
}

function StatsRow({ earnings, overdueTotal, overdueCount, leadCount, loading, onEarningsTap, onOverdueTap, onLeadsTap }: StatsRowProps) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);

  return (
    <View style={styles.statsRow}>
      {/* Today's earnings */}
      <TouchableOpacity style={styles.statCard} onPress={onEarningsTap} activeOpacity={0.75} accessibilityRole="button" accessibilityLabel={`Today's expected earnings: ${formatMoney(earnings)}`}>
        <Text style={styles.statLabel}>TODAY</Text>
        {loading
          ? <ActivityIndicator color={colors.accent} size="small" style={styles.statSpinner} />
          : <Text style={[styles.statValue, { color: colors.accent }]}>{formatMoney(earnings)}</Text>
        }
        <Text style={styles.statSub}>Expected</Text>
      </TouchableOpacity>

      {/* Overdue invoices */}
      <TouchableOpacity
        style={[styles.statCard, !loading && overdueCount > 0 && styles.statCardDanger]}
        onPress={onOverdueTap}
        activeOpacity={0.75}
        accessibilityRole="button"
        accessibilityLabel={`Overdue invoices: ${overdueCount > 0 ? `${overdueCount}, ${formatMoney(overdueTotal)}` : 'none'}`}
      >
        <Text style={[styles.statLabel, !loading && overdueCount > 0 && { color: colors.danger }]}>
          OVERDUE
        </Text>
        {loading
          ? <ActivityIndicator color={colors.textMuted} size="small" style={styles.statSpinner} />
          : <Text style={[styles.statValue, { color: overdueCount > 0 ? colors.danger : colors.textMuted }]}>
              {overdueCount > 0 ? formatMoney(overdueTotal) : '—'}
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
        accessibilityRole="button"
        accessibilityLabel={`Leads: ${leadCount > 0 ? `${leadCount} to follow up` : 'none pending'}`}
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

interface OverdueInvoiceRowProps {
  invoice: Invoice;
  isLast: boolean;
  onPress: () => void;
}

function OverdueInvoiceRow({ invoice, isLast, onPress }: OverdueInvoiceRowProps) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);

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
        <Text style={[styles.listRowAmount, { color: tagColor }]}>{formatMoney(invoice.amount)}</Text>
        <View style={[styles.overdueTag, { backgroundColor: tagBg }]}>
          <Text style={[styles.overdueTagText, { color: tagColor }]}>{days}d overdue</Text>
        </View>
      </View>
    </TouchableOpacity>
  );
}

interface LeadRowProps {
  job: Job;
  isLast: boolean;
  onPress: () => void;
}

function LeadRow({ job, isLast, onPress }: LeadRowProps) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);

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

interface SeeMoreRowProps {
  label: string;
  onPress: () => void;
}

function SeeMoreRow({ label, onPress }: SeeMoreRowProps) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);

  return (
    <TouchableOpacity style={styles.seeMoreRow} onPress={onPress} activeOpacity={0.7}>
      <Text style={styles.seeMoreText}>{label}</Text>
    </TouchableOpacity>
  );
}

interface JobCardProps {
  job: Job;
  onPress: () => void;
  onOnMyWay: () => void;
}

function JobCard({ job, onPress, onOnMyWay }: JobCardProps) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);

  const { label, color } = getJobStatusDisplay(job.status);
  const canSendOnMyWay = !!job.scheduledDate && ACTIVE_STATUSES.has(job.status);

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
        <View style={styles.jobCardFooter}>
          <View style={[styles.statusBadge, { backgroundColor: color + '22' }]}>
            <Text style={[styles.statusText, { color }]}>{label}</Text>
          </View>
          {canSendOnMyWay && (
            <TouchableOpacity
              style={styles.onMyWayButton}
              onPress={onOnMyWay}
              hitSlop={{ top: 8, bottom: 8, left: 8, right: 8 }}
              accessibilityRole="button"
              accessibilityLabel={`On my way to ${job.customerName}`}
            >
              <Text style={styles.onMyWayButtonText}>On my way</Text>
            </TouchableOpacity>
          )}
        </View>
      </View>
    </TouchableOpacity>
  );
}

interface EmptyScheduleProps {
  onScheduleJob: () => void;
}

function EmptySchedule({ onScheduleJob }: EmptyScheduleProps) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);

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

const DAY_LETTERS = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];

interface WeekStripProps {
  weekDates: string[];
  selectedDate: string;
  today: string;
  jobDateSet: Set<string>;
  onSelectDay: (date: string) => void;
  onPrevWeek: () => void;
  onNextWeek: () => void;
}

function WeekStrip({ weekDates, selectedDate, today, jobDateSet, onSelectDay, onPrevWeek, onNextWeek }: WeekStripProps) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);

  return (
    <View style={styles.weekStripWrapper}>
      <Text style={styles.weekMonthLabel}>{weekMonthLabel(weekDates)}</Text>
      <View style={styles.weekStrip}>
        <TouchableOpacity onPress={onPrevWeek} style={styles.weekNavBtn} hitSlop={{ top: 10, bottom: 10, left: 10, right: 10 }} accessibilityRole="button" accessibilityLabel="Previous week">
          <Text style={styles.weekNavText}>‹</Text>
        </TouchableOpacity>

        {weekDates.map((dateStr, i) => {
          const dayNum = parseInt(dateStr.split('-')[2], 10);
          const isSelected = dateStr === selectedDate;
          const isToday    = dateStr === today;
          const hasJobs    = jobDateSet.has(dateStr);

          return (
            <TouchableOpacity
              key={dateStr}
              onPress={() => onSelectDay(dateStr)}
              style={styles.dayCell}
              activeOpacity={0.7}
              accessibilityRole="button"
              accessibilityLabel={`${DAY_LETTERS[i]}, ${dayNum}${hasJobs ? ', has jobs' : ''}`}
              accessibilityState={{ selected: isSelected }}
            >
              <Text style={[styles.dayLetter, isSelected && styles.dayLetterSelected]}>
                {DAY_LETTERS[i]}
              </Text>
              <View style={[
                styles.dayNumCircle,
                isSelected && styles.dayNumCircleSelected,
                isToday && !isSelected && styles.dayNumCircleToday,
              ]}>
                <Text style={[
                  styles.dayNum,
                  isSelected && styles.dayNumSelected,
                  isToday && !isSelected && styles.dayNumToday,
                ]}>
                  {dayNum}
                </Text>
              </View>
              <View style={[styles.dayDot, hasJobs && styles.dayDotActive]} />
            </TouchableOpacity>
          );
        })}

        <TouchableOpacity onPress={onNextWeek} style={styles.weekNavBtn} hitSlop={{ top: 10, bottom: 10, left: 10, right: 10 }} accessibilityRole="button" accessibilityLabel="Next week">
          <Text style={styles.weekNavText}>›</Text>
        </TouchableOpacity>
      </View>
    </View>
  );
}

// ─── Main Screen ─────────────────────────────────────────────────────────────

const INVOICE_LIMIT = 3;
const LEAD_LIMIT = 3;

export default function TodayScreen({ navigation }: TodayStackScreenProps<'TodayHome'>) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);

  const insets = useSafeAreaInsets();
  const todayString = getTodayDateString();

  const [allJobs, setAllJobs] = useState<Job[]>([]);
  const [selectedDate, setSelectedDate] = useState<string>(todayString);
  const [earnings, setEarnings] = useState<number>(0);
  const [overdueInvoices, setOverdueInvoices] = useState<Invoice[]>([]);
  const [leadJobs, setLeadJobs] = useState<Job[]>([]);
  const [loading, setLoading] = useState<boolean>(true);

  useFocusEffect(
    useCallback(() => {
      let active = true;

      async function fetchTodayData() {
        setLoading(true);
        try {
          const [allJobsList, expectedEarnings, overdue, leads] = await Promise.all([
            loadJobs(),
            getExpectedEarningsForDate(todayString),
            loadOverdueInvoices(),
            loadLeadJobs(),
          ]);
          if (active) {
            setAllJobs(allJobsList);
            setEarnings(expectedEarnings);
            setOverdueInvoices(overdue);
            setLeadJobs(leads);
          }
        } catch (error: unknown) {
          console.error('TodayScreen: failed to load daily data', error);
          reportError(error, { context: 'todayScreenLoad' });
        } finally {
          if (active) setLoading(false);
        }
      }

      fetchTodayData();
      return () => { active = false; };
    }, [todayString])
  );

  const { refreshing, onRefresh } = useRefresh(async () => {
    const [allJobsList, expectedEarnings, overdue, leads] = await Promise.all([
      loadJobs(),
      getExpectedEarningsForDate(todayString),
      loadOverdueInvoices(),
      loadLeadJobs(),
    ]);
    setAllJobs(allJobsList);
    setEarnings(expectedEarnings);
    setOverdueInvoices(overdue);
    setLeadJobs(leads);
  }, 'TodayScreen');

  function goToInvoices() {
    navigation.getParent()?.navigate('Invoices');
  }

  function goToJobs() {
    navigation.getParent()?.navigate('Jobs');
  }

  function handleJobPress(job: Job) {
    navigation.getParent()?.navigate('Jobs', { screen: 'JobDetail', params: { jobId: job.id } });
  }

  async function handleOnMyWay(job: Job) {
    const [customers, settings] = await Promise.all([loadCustomers(), loadSettings()]);
    const customer = resolveCustomer(customers, job);
    if (!customer) {
      Alert.alert('No customer', 'This job has no linked customer to message.');
      return;
    }
    const opened = await sendAppointmentMessage({ job, customer, settings, kind: 'on_my_way' });
    if (opened) track('on_my_way_sent', {});
  }

  function handleScheduleJob() {
    navigation.getParent()?.navigate('Jobs', { screen: 'AddJob' });
  }

  function handlePlanRoute() {
    navigation.navigate('Route');
  }

  // ── Week strip derived values ──────────────────────────────────────────────
  const weekDates      = getWeekDates(selectedDate);
  const jobDateSet     = new Set(allJobs.filter(j => j.scheduledDate).map(j => j.scheduledDate as string));
  const selectedDayJobs = allJobs
    .filter(j => j.scheduledDate === selectedDate)
    .sort((a, b) => {
      if (!a.scheduledStartTime) return 1;
      if (!b.scheduledStartTime) return -1;
      return a.scheduledStartTime.localeCompare(b.scheduledStartTime);
    });

  const isToday = selectedDate === todayString;
  const scheduleSectionTitle = isToday
    ? "Today's Schedule"
    : new Date(selectedDate + 'T00:00:00').toLocaleDateString('en-US', { weekday: 'long', month: 'short', day: 'numeric' });

  function prevWeek() { setSelectedDate(d => shiftDate(d, -7)); }
  function nextWeek() { setSelectedDate(d => shiftDate(d, 7)); }

  const overdueTotal = overdueInvoices.reduce((s, inv) => s + (Number(inv.amount) || 0), 0);
  const visibleInvoices = overdueInvoices.slice(0, INVOICE_LIMIT);
  const visibleLeads = leadJobs.slice(0, LEAD_LIMIT);
  const extraInvoices = overdueInvoices.length - INVOICE_LIMIT;
  const extraLeads = leadJobs.length - LEAD_LIMIT;

  return (
    <ScrollView
      style={[styles.container, { paddingTop: insets.top }]}
      contentContainerStyle={styles.scrollContent}
      refreshControl={<RefreshControl refreshing={refreshing} onRefresh={onRefresh} />}
    >
      {/* Header */}
      <View style={styles.header}>
        <Text style={styles.greeting}>{getGreeting()}</Text>
        <Text style={styles.dateText}>{formatDisplayDate(todayString)}</Text>
      </View>

      {/* Week strip */}
      <WeekStrip
        weekDates={weekDates}
        selectedDate={selectedDate}
        today={todayString}
        jobDateSet={jobDateSet}
        onSelectDay={setSelectedDate}
        onPrevWeek={prevWeek}
        onNextWeek={nextWeek}
      />

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

      {/* Schedule for selected day */}
      <BriefingSection
        title={scheduleSectionTitle}
        actionLabel={!loading && isToday && selectedDayJobs.length > 0 ? "Plan Route" : undefined}
        onAction={handlePlanRoute}
      >
        {loading && (
          <ActivityIndicator color={colors.accent} size={36} style={{ marginTop: 24 }} />
        )}
        {!loading && selectedDayJobs.length === 0 && (
          <EmptySchedule onScheduleJob={handleScheduleJob} />
        )}
        {!loading && selectedDayJobs.map((job) => (
          <JobCard
            key={job.id}
            job={job}
            onPress={() => handleJobPress(job)}
            onOnMyWay={() => handleOnMyWay(job)}
          />
        ))}
      </BriefingSection>

      <View style={{ height: 40 }} />
    </ScrollView>
  );
}

// ─── Styles ──────────────────────────────────────────────────────────────────

function createStyles(colors: ColorScheme, shadow: ShadowScheme) {
  return StyleSheet.create({
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

    // Week strip
    weekStripWrapper: {
      marginHorizontal: spacing.md,
      marginTop: spacing.sm,
      marginBottom: spacing.xs,
      backgroundColor: colors.surface,
      borderRadius: radius.lg,
      borderWidth: 1,
      borderColor: colors.border,
      paddingVertical: spacing.sm,
      paddingHorizontal: spacing.xs,
      ...shadow.card,
    },
    weekMonthLabel: {
      fontSize: 10,
      fontWeight: '700',
      color: colors.textMuted,
      letterSpacing: 0.8,
      textAlign: 'center',
      textTransform: 'uppercase',
      marginBottom: 6,
    },
    weekStrip: {
      flexDirection: 'row',
      alignItems: 'center',
    },
    weekNavBtn: {
      paddingHorizontal: spacing.sm,
      alignItems: 'center',
      justifyContent: 'center',
    },
    weekNavText: {
      fontSize: 22,
      color: colors.accent,
      lineHeight: 26,
    },
    dayCell: {
      flex: 1,
      alignItems: 'center',
      paddingVertical: 4,
    },
    dayLetter: {
      fontSize: 10,
      fontWeight: '600',
      color: colors.textMuted,
      marginBottom: 4,
    },
    dayLetterSelected: {
      color: colors.accent,
    },
    dayNumCircle: {
      width: 30,
      height: 30,
      borderRadius: 15,
      alignItems: 'center',
      justifyContent: 'center',
    },
    dayNumCircleSelected: {
      backgroundColor: colors.accent,
    },
    dayNumCircleToday: {
      borderWidth: 1.5,
      borderColor: colors.accent,
    },
    dayNum: {
      fontSize: fontSize.sm,
      fontWeight: '600',
      color: colors.textPrimary,
    },
    dayNumSelected: {
      color: colors.textOnAccent,
    },
    dayNumToday: {
      color: colors.accent,
    },
    dayDot: {
      width: 4,
      height: 4,
      borderRadius: 2,
      backgroundColor: 'transparent',
      marginTop: 3,
    },
    dayDotActive: {
      backgroundColor: colors.accent,
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
    jobCardFooter: {
      flexDirection: 'row',
      alignItems: 'center',
      justifyContent: 'space-between',
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
    onMyWayButton: {
      alignSelf: 'flex-start',
      paddingHorizontal: spacing.sm,
      paddingVertical: 3,
      borderRadius: radius.sm,
      backgroundColor: colors.accent + '1a',
    },
    onMyWayButtonText: {
      fontSize: fontSize.xs,
      fontWeight: '700',
      color: colors.accent,
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
}
