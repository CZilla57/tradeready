// screens/CustomerDetailScreen.tsx
// Full profile for a single customer — contact info, lifetime value, invoice history, job history, notes.

import React, { useState, useEffect, useLayoutEffect, useCallback, useMemo } from 'react';
import {
  View,
  Text,
  StyleSheet,
  ScrollView,
  TouchableOpacity,
  TextInput,
  Linking,
  Alert,
  Modal,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { Ionicons } from '@expo/vector-icons';
import { useFocusEffect } from '@react-navigation/native';
import { loadJobs, loadCustomers, saveCustomers, updateCustomerNotes } from '../utils/storage';
import { isArchived, withArchived } from '../utils/archive';
import { performCustomerMerge } from '../utils/customerMerge';
import { useUndo } from '../context/UndoContext';
import { spacing, radius, fontSize, fonts, layout } from '../utils/theme';
import type { ColorScheme, ShadowScheme } from '../utils/theme';
import { formatMoney } from '../utils/format';
import { useTheme } from '../hooks/useTheme';
import { KeyboardDoneBar } from '../components/KeyboardDoneBar';
import { isFullyPaid, isPartlyPaid, amountPaid, balanceDue } from '../utils/invoicePayments';
import type { Job, Invoice, Customer as CustomerRecord } from '../types/models';
import { reportError, track } from '../utils/analytics';
import type { CustomerStackScreenProps } from '../types/navigation';

// ─── HELPERS ──────────────────────────────────────────────────────────────────

const formatDate = (dateStr: string): string => {
  if (!dateStr) return '—';
  return new Date(dateStr + 'T00:00:00').toLocaleDateString('en-US', {
    month: 'short', day: 'numeric', year: 'numeric',
  });
};

interface InvoiceStatusResult {
  label: string;
  color: string;
}

const invoiceStatus = (inv: Invoice, colors: ColorScheme): InvoiceStatusResult => {
  if (isFullyPaid(inv)) return { label: 'Paid', color: colors.success };
  const due = new Date(inv.due);
  const now = new Date();
  if (due < now) return { label: 'Overdue', color: colors.danger };
  // Matches getStatus's precedence in utils/invoiceHelpers.ts: overdue wins
  // when both apply, because an invoice with a deposit on it that is past due
  // is still late.
  if (isPartlyPaid(inv)) return { label: 'Partly paid', color: colors.accent };
  return { label: 'Pending', color: colors.warning };
};

const JOB_STAGES: Record<string, string> = {
  lead:          'Lead',
  estimate_sent: 'Estimate Sent',
  approved:      'Approved',
  scheduled:     'Scheduled',
  in_progress:   'In Progress',
  complete:      'Complete',
  invoiced:      'Invoiced',
  paid:          'Paid',
};

// ─── SUB-COMPONENTS ───────────────────────────────────────────────────────────

interface InfoRowProps {
  icon: React.ComponentProps<typeof Ionicons>['name'];
  label: string;
  value?: string;
  onPress?: (() => void) | null;
  styles: ReturnType<typeof createStyles>;
  colors: ColorScheme;
}

const InfoRow = ({ icon, label, value, onPress, styles, colors }: InfoRowProps) => (
  <TouchableOpacity
    style={styles.infoRow}
    onPress={onPress ?? undefined}
    disabled={!onPress}
    activeOpacity={onPress ? 0.6 : 1}
    accessibilityRole={onPress ? 'button' : 'text'}
    accessibilityLabel={`${label}: ${value || 'not set'}`}
  >
    <Ionicons name={icon} size={18} color={colors.textSecondary} style={styles.infoIcon} />
    <View style={styles.infoContent}>
      <Text style={styles.infoLabel}>{label}</Text>
      <Text style={[styles.infoValue, onPress && styles.infoValueTappable]}>
        {value || '—'}
      </Text>
    </View>
    {onPress && <Text style={styles.infoChevron}>›</Text>}
  </TouchableOpacity>
);

interface InvoiceRowProps {
  invoice: Invoice;
  onPress: (inv: Invoice) => void;
  styles: ReturnType<typeof createStyles>;
  colors: ColorScheme;
}

const InvoiceRow = ({ invoice, onPress, styles, colors }: InvoiceRowProps) => {
  const status = invoiceStatus(invoice, colors);
  const partly = isPartlyPaid(invoice);
  const amountText = partly
    ? `${formatMoney(balanceDue(invoice))} due · ${formatMoney(amountPaid(invoice))} paid`
    : formatMoney(Number(invoice.amount) || 0);
  return (
    <TouchableOpacity
      style={styles.invoiceRow}
      onPress={() => onPress(invoice)}
      accessibilityRole="button"
      accessibilityLabel={`Invoice ${invoice.number || 'without number'}, ${amountText}, ${status.label}`}
    >
      <View style={styles.invoiceRowLeft}>
        <Text style={styles.invoiceNumber}>{invoice.number || 'No #'}</Text>
        <Text style={styles.invoiceDesc} numberOfLines={1}>{(invoice as any).desc || 'No description'}</Text>
        <Text style={styles.invoiceDate}>Due {formatDate(invoice.due)}</Text>
      </View>
      <View style={styles.invoiceRowRight}>
        <Text style={styles.invoiceAmount}>{amountText}</Text>
        <View style={[styles.statusBadge, { backgroundColor: status.color + '22' }]}>
          <Text style={[styles.statusBadgeText, { color: status.color }]}>{status.label}</Text>
        </View>
      </View>
    </TouchableOpacity>
  );
};

interface JobRowProps {
  job: Job;
  styles: ReturnType<typeof createStyles>;
}

const JobRow = ({ job, styles }: JobRowProps) => {
  const stageLabel = JOB_STAGES[job.status] || job.status || 'Unknown';
  return (
    <View style={styles.jobRow}>
      <View style={styles.jobRowLeft}>
        <Text style={styles.jobTitle} numberOfLines={1}>{job.title || 'Untitled Job'}</Text>
        <Text style={styles.jobMeta}>{stageLabel} · {formatDate(job.scheduledDate || '')}</Text>
      </View>
      {job.estimateTotal > 0 && (
        <Text style={styles.jobValue}>{formatMoney(job.estimateTotal)}</Text>
      )}
    </View>
  );
};

// ─── MAIN SCREEN ──────────────────────────────────────────────────────────────

export default function CustomerDetailScreen({ route, navigation }: CustomerStackScreenProps<'CustomerDetail'>) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  const { showUndo } = useUndo();

  const { customer } = route.params;

  const [displayCustomer, setDisplayCustomer] = useState<any>(customer);
  const [jobs, setJobs]               = useState<Job[]>([]);
  const [notes, setNotes]             = useState<string>('');
  const [notesChanged, setNotesChanged] = useState<boolean>(false);
  const [mergeVisible, setMergeVisible] = useState<boolean>(false);
  const [mergeSearch, setMergeSearch]   = useState<string>('');
  const [mergeCandidates, setMergeCandidates] = useState<CustomerRecord[]>([]);
  const [merging, setMerging]           = useState<boolean>(false);

  useLayoutEffect(() => {
    navigation.setOptions({
      title: displayCustomer.name,
      headerRight: () => (
        <TouchableOpacity
          onPress={() => navigation.navigate('AddCustomer', { customerId: displayCustomer.id, customer: displayCustomer })}
          hitSlop={{ top: 8, bottom: 8, left: 8, right: 8 }}
          style={{ alignSelf: 'center', marginRight: 8, paddingLeft: 10 }}
          accessibilityRole="button"
          accessibilityLabel="Edit customer"
        >
          <Text style={{ fontFamily: fonts.bodyRegular, color: colors.accent, fontSize: fontSize.md }}>Edit</Text>
        </TouchableOpacity>
      ),
    });
  }, [navigation, displayCustomer, colors.accent]);

  useFocusEffect(
    useCallback(() => {
      loadCustomers().then((custs) => {
        const fresh = custs.find((c: any) => c.id === customer.id);
        if (fresh) setDisplayCustomer((prev: any) => ({ ...prev, ...fresh }));
      });
    }, [customer.id])
  );

  useEffect(() => {
    async function loadJobsAndNotes() {
      try {
        const allJobs = await loadJobs();

        // Match by customerId first (proper relationship), fall back to name match
        // for invoice-derived customers that don't have a formal customerId yet.
        const customerJobs = allJobs.filter((j: any) =>
          j.customerId === customer.id ||
          j.customerName?.trim().toLowerCase() === customer.name.trim().toLowerCase()
        );
        setJobs(customerJobs);
        // Notes live on the customer record now (roadmap #5).
        setNotes(customer.notes || '');
      } catch (err: unknown) {
        console.error('CustomerDetailScreen: failed to load data', err);
        reportError(err, { context: 'customerDetailLoad' });
      }
    }
    loadJobsAndNotes();
  }, [customer.id, customer.name, customer.notes]);

  const handleNotesSave = useCallback(async () => {
    if (!notesChanged) return;
    try {
      await updateCustomerNotes(displayCustomer, notes);
      setNotesChanged(false);
    } catch (err: unknown) {
      console.error('CustomerDetailScreen: failed to save notes', err);
      reportError(err, { context: 'customerNotesSave' });
    }
  }, [notes, notesChanged, displayCustomer]);

  const handleInvoicePress = (invoice: Invoice) => {
    navigation.navigate('AddInvoice', { invoiceId: invoice.id });
  };

  const handleNewInvoice = () => {
    navigation.navigate('AddInvoice', {
      prefill: {
        customer: displayCustomer.name,
        email:    displayCustomer.email,
        phone:    displayCustomer.phone,
      },
    });
  };

  const openMerge = async () => {
    try {
      const custs = await loadCustomers();
      setMergeCandidates(custs.filter((c) => c.id !== displayCustomer.id));
      setMergeSearch('');
      setMergeVisible(true);
    } catch (err: unknown) {
      reportError(err, { context: 'customerMergeOpen' });
    }
  };

  const confirmMergeInto = (target: CustomerRecord) => {
    Alert.alert(
      `Merge into "${target.name}"?`,
      `"${displayCustomer.name}"'s jobs, invoices, and recurring plans move to ${target.name}, blank contact details carry over, and "${displayCustomer.name}" is removed. This can't be undone.`,
      [
        { text: 'Cancel', style: 'cancel' },
        {
          text: 'Merge',
          style: 'destructive',
          onPress: async () => {
            setMerging(true);
            try {
              const result = await performCustomerMerge(target.id, displayCustomer.id);
              track('customers_merged', {
                jobs: result.changed.jobs,
                invoices: result.changed.invoices,
              });
              setMergeVisible(false);
              navigation.goBack();
            } catch (err: unknown) {
              console.error('CustomerDetailScreen: merge failed', err);
              reportError(err, { context: 'customerMerge' });
              Alert.alert('Merge failed', 'Nothing was changed. Please try again.');
            } finally {
              setMerging(false);
            }
          },
        },
      ]
    );
  };

  const handleToggleArchive = async () => {
    try {
      const today = new Date().toISOString().split('T')[0];
      const archiving = !isArchived(displayCustomer);
      const custs = await loadCustomers();
      await saveCustomers(
        custs.map((c) => (c.id === displayCustomer.id ? withArchived(c, archiving, today) : c))
      );
      setDisplayCustomer((prev: any) => withArchived(prev, archiving, today));
      if (archiving) navigation.goBack();
    } catch (err: unknown) {
      console.error('CustomerDetailScreen: archive toggle failed', err);
      reportError(err, { context: 'customerArchiveToggle' });
    }
  };

  const handleDelete = () => {
    Alert.alert(
      'Delete customer?',
      `"${displayCustomer.name}" will be removed. Their invoices and jobs will remain but will no longer be linked to a customer record. You can undo for a few seconds after deleting.`,
      [
        { text: 'Cancel', style: 'cancel' },
        {
          text: 'Delete',
          style: 'destructive',
          onPress: async () => {
            try {
              const custs = await loadCustomers();
              const deleted = custs.find((c) => c.id === displayCustomer.id);
              await saveCustomers(custs.filter((c) => c.id !== displayCustomer.id));
              navigation.goBack();
              if (deleted) {
                showUndo('Customer deleted', async () => {
                  const current = await loadCustomers();
                  if (!current.some((c) => c.id === deleted.id)) {
                    await saveCustomers([...current, deleted]);
                  }
                });
              }
            } catch (err: unknown) {
              console.error('CustomerDetailScreen: delete failed', err);
              reportError(err, { context: 'customerDelete' });
            }
          },
        },
      ]
    );
  };

  const handleCall = () => {
    if (!displayCustomer.phone) return;
    Linking.openURL(`tel:${displayCustomer.phone.replace(/\D/g, '')}`);
  };

  const handleEmail = () => {
    if (!displayCustomer.email) return;
    Linking.openURL(`mailto:${displayCustomer.email}`);
  };

  const invoices: Invoice[]  = displayCustomer.invoices || [];
  const totalSpent: number   = displayCustomer.totalSpent || 0;
  const totalOwed: number    = displayCustomer.totalOwed || 0;
  const invoiceCount: number = invoices.length;

  const initials = displayCustomer.name
    .split(' ')
    .map((w: string) => w[0])
    .slice(0, 2)
    .join('')
    .toUpperCase();

  return (
    <SafeAreaView style={styles.container} edges={['bottom']}>
      <ScrollView showsVerticalScrollIndicator={false} contentContainerStyle={styles.scrollContent}>

        {/* Hero: avatar + name + quick actions */}
        <View style={styles.hero}>
          <View style={styles.heroAvatar}>
            <Text style={styles.heroAvatarText}>{initials}</Text>
          </View>
          <Text style={styles.heroName}>{displayCustomer.name}</Text>

          <View style={styles.heroActions}>
            {displayCustomer.phone ? (
              <TouchableOpacity style={styles.heroAction} onPress={handleCall} accessibilityRole="button" accessibilityLabel={`Call ${displayCustomer.name}`}>
                <Ionicons name="call-outline" size={22} color={colors.accent} style={styles.heroActionIcon} />
                <Text style={styles.heroActionLabel}>Call</Text>
              </TouchableOpacity>
            ) : null}
            {displayCustomer.email ? (
              <TouchableOpacity style={styles.heroAction} onPress={handleEmail} accessibilityRole="button" accessibilityLabel={`Email ${displayCustomer.name}`}>
                <Ionicons name="mail-outline" size={22} color={colors.accent} style={styles.heroActionIcon} />
                <Text style={styles.heroActionLabel}>Email</Text>
              </TouchableOpacity>
            ) : null}
            <TouchableOpacity style={styles.heroAction} onPress={handleNewInvoice} accessibilityRole="button" accessibilityLabel="New invoice for this customer">
              <Ionicons name="receipt-outline" size={22} color={colors.accent} style={styles.heroActionIcon} />
              <Text style={styles.heroActionLabel}>Invoice</Text>
            </TouchableOpacity>
          </View>
        </View>

        {/* Lifetime value stats */}
        <View style={styles.statsRow}>
          <View style={styles.statBox}>
            <Text style={styles.statValue}>{formatMoney(totalSpent)}</Text>
            <Text style={styles.statLabel}>Collected</Text>
          </View>
          <View style={styles.statDivider} />
          <View style={styles.statBox}>
            <Text style={[styles.statValue, totalOwed > 0 && { color: colors.danger }]}>
              {formatMoney(totalOwed)}
            </Text>
            <Text style={styles.statLabel}>Outstanding</Text>
          </View>
          <View style={styles.statDivider} />
          <View style={styles.statBox}>
            <Text style={styles.statValue}>{invoiceCount}</Text>
            <Text style={styles.statLabel}>{invoiceCount === 1 ? 'Invoice' : 'Invoices'}</Text>
          </View>
        </View>

        {/* Contact info */}
        <View style={styles.section}>
          <Text style={styles.sectionTitle}>Contact</Text>
          <View style={styles.card}>
            <InfoRow
              icon="call-outline"
              label="Phone"
              value={displayCustomer.phone}
              onPress={displayCustomer.phone ? handleCall : null}
              styles={styles}
              colors={colors}
            />
            <View style={styles.cardSeparator} />
            <InfoRow
              icon="mail-outline"
              label="Email"
              value={displayCustomer.email}
              onPress={displayCustomer.email ? handleEmail : null}
              styles={styles}
              colors={colors}
            />
          </View>
        </View>

        {/* Invoice history */}
        {invoices.length > 0 && (
          <View style={styles.section}>
            <Text style={styles.sectionTitle}>Invoice History</Text>
            <View style={styles.card}>
              {invoices
                .sort((a, b) => (new Date(b.due) as any) - (new Date(a.due) as any))
                .map((inv, idx) => (
                  <React.Fragment key={inv.id}>
                    {idx > 0 && <View style={styles.cardSeparator} />}
                    <InvoiceRow invoice={inv} onPress={handleInvoicePress} styles={styles} colors={colors} />
                  </React.Fragment>
                ))
              }
            </View>
          </View>
        )}

        {/* Job history */}
        {jobs.length > 0 && (
          <View style={styles.section}>
            <Text style={styles.sectionTitle}>Job History</Text>
            <View style={styles.card}>
              {jobs
                .sort((a, b) => (new Date(b.scheduledDate || 0) as any) - (new Date(a.scheduledDate || 0) as any))
                .map((job, idx) => (
                  <React.Fragment key={job.id || idx}>
                    {idx > 0 && <View style={styles.cardSeparator} />}
                    <JobRow job={job} styles={styles} />
                  </React.Fragment>
                ))
              }
            </View>
          </View>
        )}

        {/* Notes */}
        <View style={styles.section}>
          <Text style={styles.sectionTitle}>Notes</Text>
          <TextInput
            style={styles.notesInput}
            placeholder="Preferred contact times, job site access codes, parking info..."
            placeholderTextColor={colors.textMuted}
            value={notes}
            onChangeText={(text) => {
              setNotes(text);
              setNotesChanged(true);
            }}
            onBlur={handleNotesSave}
            multiline
            textAlignVertical="top"
            inputAccessoryViewID="customerNotesDone"
            accessibilityLabel="Customer notes"
          />
          <KeyboardDoneBar nativeID="customerNotesDone" />
          {notesChanged && (
            <TouchableOpacity style={styles.saveNotesButton} onPress={handleNotesSave} accessibilityRole="button" accessibilityLabel="Save notes">
              <Text style={styles.saveNotesButtonText}>Save notes</Text>
            </TouchableOpacity>
          )}
        </View>

        <TouchableOpacity
          style={styles.archiveBtn}
          onPress={openMerge}
          accessibilityRole="button"
          accessibilityLabel="Merge into another customer"
        >
          <Text style={styles.archiveBtnText}>Merge into another customer…</Text>
        </TouchableOpacity>

        <TouchableOpacity
          style={styles.archiveBtn}
          onPress={handleToggleArchive}
          accessibilityRole="button"
          accessibilityLabel={isArchived(displayCustomer) ? 'Unarchive customer' : 'Archive customer'}
        >
          <Text style={styles.archiveBtnText}>
            {isArchived(displayCustomer) ? 'Unarchive customer' : 'Archive customer'}
          </Text>
        </TouchableOpacity>

        <TouchableOpacity style={styles.deleteBtn} onPress={handleDelete} accessibilityRole="button" accessibilityLabel="Delete customer">
          <Text style={styles.deleteBtnText}>Delete customer</Text>
        </TouchableOpacity>

        <View style={{ height: 60 }} />
      </ScrollView>

      {/* Merge target picker */}
      <Modal
        visible={mergeVisible}
        animationType="slide"
        transparent
        onRequestClose={() => setMergeVisible(false)}
      >
        <TouchableOpacity
          style={styles.mergeBackdrop}
          activeOpacity={1}
          onPress={() => setMergeVisible(false)}
        />
        <View style={styles.mergeSheet}>
          <Text style={styles.mergeTitle}>Merge “{displayCustomer.name}” into…</Text>
          <TextInput
            style={styles.mergeSearch}
            value={mergeSearch}
            onChangeText={setMergeSearch}
            placeholder="Search customers…"
            placeholderTextColor={colors.textMuted}
            autoCapitalize="none"
            autoCorrect={false}
            accessibilityLabel="Search merge targets"
          />
          <ScrollView style={styles.mergeList} keyboardShouldPersistTaps="handled">
            {mergeCandidates
              .filter((c) => {
                const q = mergeSearch.toLowerCase();
                return c.name.toLowerCase().includes(q) || (c.phone || '').includes(q);
              })
              .map((c) => (
                <TouchableOpacity
                  key={c.id}
                  style={styles.mergeOption}
                  disabled={merging}
                  onPress={() => confirmMergeInto(c)}
                  accessibilityRole="button"
                  accessibilityLabel={`Merge into ${c.name}`}
                >
                  <Text style={styles.mergeOptionName}>{c.name}</Text>
                  {(c.phone || c.email) ? (
                    <Text style={styles.mergeOptionSub}>{c.phone || c.email}</Text>
                  ) : null}
                </TouchableOpacity>
              ))}
            {mergeCandidates.length === 0 && (
              <Text style={styles.mergeEmpty}>No other customers to merge into.</Text>
            )}
          </ScrollView>
        </View>
      </Modal>
    </SafeAreaView>
  );
}

// ─── STYLES ───────────────────────────────────────────────────────────────────

function createStyles(colors: ColorScheme, shadow: ShadowScheme) {
  return StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: colors.background,
  },
  scrollContent: {
    ...layout.contentColumn,
  },

  // Hero
  hero: {
    alignItems: 'center',
    paddingTop: spacing.lg,
    paddingBottom: spacing.lg,
    paddingHorizontal: spacing.md,
  },
  heroAvatar: {
    width: 80,
    height: 80,
    borderRadius: radius.full,
    backgroundColor: colors.accentBg,
    alignItems: 'center',
    justifyContent: 'center',
    marginBottom: spacing.md,
    borderWidth: 2,
    borderColor: colors.accent + '60',
  },
  heroAvatarText: {
    fontFamily: fonts.display,
    color: colors.accent,
    fontSize: 28,
  },
  heroName: {
    fontFamily: fonts.display,
    color: colors.textPrimary,
    fontSize: fontSize.xl,
    letterSpacing: -0.3,
    marginBottom: spacing.lg,
    textAlign: 'center',
  },
  heroActions: {
    flexDirection: 'row',
    gap: spacing.md,
  },
  heroAction: {
    alignItems: 'center',
    backgroundColor: colors.surface,
    borderRadius: radius.lg,
    paddingVertical: spacing.md,
    paddingHorizontal: spacing.lg,
    borderWidth: 1,
    borderColor: colors.border,
    minWidth: 72,
  },
  heroActionIcon: {
    marginBottom: 4,
  },
  heroActionLabel: {
    fontFamily: fonts.bodyMedium,
    color: colors.textSecondary,
    fontSize: fontSize.xs,
  },

  // Stats row
  statsRow: {
    flexDirection: 'row',
    backgroundColor: colors.surface,
    marginHorizontal: spacing.md,
    borderRadius: radius.lg,
    borderWidth: 1,
    borderColor: colors.border,
    marginBottom: spacing.lg,
    paddingVertical: spacing.md,
  },
  statBox: {
    flex: 1,
    alignItems: 'center',
  },
  statValue: {
    fontFamily: fonts.display,
    color: colors.success,
    fontSize: fontSize.lg,
    letterSpacing: -0.3,
    marginBottom: 4,
    fontVariant: ['tabular-nums'],
  },
  statLabel: {
    fontFamily: fonts.mono,
    color: colors.textSecondary,
    fontSize: 10,
    textTransform: 'uppercase',
    letterSpacing: 0.4,
  },
  statDivider: {
    width: 1,
    backgroundColor: colors.border,
    marginVertical: 4,
  },

  // Section
  section: {
    marginHorizontal: spacing.md,
    marginBottom: spacing.lg,
  },
  sectionTitle: {
    fontFamily: fonts.mono,
    color: colors.textSecondary,
    fontSize: fontSize.xs,
    textTransform: 'uppercase',
    letterSpacing: 0.8,
    marginBottom: spacing.sm,
  },
  card: {
    backgroundColor: colors.surface,
    borderRadius: radius.lg,
    borderWidth: 1,
    borderColor: colors.border,
    overflow: 'hidden',
  },
  cardSeparator: {
    height: 1,
    backgroundColor: colors.border,
    marginLeft: spacing.md,
  },

  // Info rows
  infoRow: {
    flexDirection: 'row',
    alignItems: 'center',
    padding: spacing.md,
  },
  infoIcon: {
    marginRight: spacing.md,
    width: 24,
    textAlign: 'center',
  },
  infoContent: {
    flex: 1,
  },
  infoLabel: {
    fontFamily: fonts.mono,
    color: colors.textMuted,
    fontSize: 10,
    textTransform: 'uppercase',
    letterSpacing: 0.4,
    marginBottom: 2,
  },
  infoValue: {
    fontFamily: fonts.bodyRegular,
    color: colors.textPrimary,
    fontSize: fontSize.md,
  },
  infoValueTappable: {
    color: colors.accent,
  },
  infoChevron: {
    color: colors.textMuted,
    fontSize: 20,
  },

  // Invoice rows
  invoiceRow: {
    flexDirection: 'row',
    alignItems: 'center',
    padding: spacing.md,
  },
  invoiceRowLeft: {
    flex: 1,
    marginRight: spacing.md,
  },
  invoiceNumber: {
    fontFamily: fonts.mono,
    color: colors.textSecondary,
    fontSize: 11,
    marginBottom: 2,
  },
  invoiceDesc: {
    fontFamily: fonts.bodyMedium,
    color: colors.textPrimary,
    fontSize: fontSize.md,
    marginBottom: 2,
  },
  invoiceDate: {
    fontFamily: fonts.mono,
    color: colors.textMuted,
    fontSize: 10,
  },
  invoiceRowRight: {
    alignItems: 'flex-end',
    gap: 6,
  },
  invoiceAmount: {
    fontFamily: fonts.display,
    color: colors.textPrimary,
    fontSize: fontSize.md,
    fontVariant: ['tabular-nums'],
  },
  statusBadge: {
    paddingHorizontal: spacing.sm,
    paddingVertical: 3,
    borderRadius: radius.sm,
  },
  statusBadgeText: {
    fontFamily: fonts.mono,
    fontSize: 10,
    textTransform: 'uppercase',
    letterSpacing: 0.2,
  },

  // Job rows
  jobRow: {
    flexDirection: 'row',
    alignItems: 'center',
    padding: spacing.md,
  },
  jobRowLeft: {
    flex: 1,
    marginRight: spacing.md,
  },
  jobTitle: {
    fontFamily: fonts.bodyMedium,
    color: colors.textPrimary,
    fontSize: fontSize.md,
    marginBottom: 3,
  },
  jobMeta: {
    fontFamily: fonts.bodyRegular,
    color: colors.textSecondary,
    fontSize: fontSize.sm,
  },
  jobValue: {
    fontFamily: fonts.display,
    color: colors.textSecondary,
    fontSize: fontSize.md,
    fontVariant: ['tabular-nums'],
  },

  // Notes
  notesInput: {
    fontFamily: fonts.bodyRegular,
    backgroundColor: colors.surface,
    borderRadius: radius.lg,
    borderWidth: 1,
    borderColor: colors.border,
    padding: spacing.md,
    color: colors.textPrimary,
    fontSize: fontSize.md,
    minHeight: 120,
    lineHeight: 22,
  },
  archiveBtn: {
    alignItems: 'center',
    paddingVertical: spacing.md,
    marginHorizontal: spacing.md,
    marginTop: spacing.sm,
  },
  mergeBackdrop: {
    flex: 1,
    backgroundColor: 'rgba(0,0,0,0.4)',
  },
  mergeSheet: {
    backgroundColor: colors.surface,
    borderTopLeftRadius: radius.lg,
    borderTopRightRadius: radius.lg,
    padding: spacing.md,
    maxHeight: '70%',
    ...shadow.card,
  },
  mergeTitle: {
    fontFamily: fonts.bodySemiBold,
    fontSize: fontSize.md,
    color: colors.textPrimary,
    marginBottom: spacing.sm,
  },
  mergeSearch: {
    fontFamily: fonts.bodyRegular,
    backgroundColor: colors.background,
    borderRadius: radius.sm,
    paddingHorizontal: spacing.md,
    paddingVertical: 8,
    fontSize: fontSize.md,
    color: colors.textPrimary,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: colors.border,
    marginBottom: spacing.sm,
  },
  mergeList: {
    maxHeight: 320,
  },
  mergeOption: {
    paddingVertical: spacing.sm,
    paddingHorizontal: spacing.xs,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: colors.border,
    minHeight: 48,
    justifyContent: 'center',
  },
  mergeOptionName: {
    fontFamily: fonts.bodyMedium,
    fontSize: fontSize.md,
    color: colors.textPrimary,
  },
  mergeOptionSub: {
    fontFamily: fonts.bodyRegular,
    fontSize: fontSize.sm,
    color: colors.textSecondary,
    marginTop: 1,
  },
  mergeEmpty: {
    fontFamily: fonts.bodyRegular,
    fontSize: fontSize.sm,
    color: colors.textMuted,
    paddingVertical: spacing.md,
    textAlign: 'center',
  },
  archiveBtnText: {
    fontFamily: fonts.bodyMedium,
    fontSize: fontSize.sm,
    color: colors.textSecondary,
  },
  deleteBtn: {
    alignItems: 'center',
    paddingVertical: spacing.md,
    marginHorizontal: spacing.md,
    marginTop: spacing.sm,
  },
  deleteBtnText: {
    fontFamily: fonts.bodyMedium,
    fontSize: fontSize.sm,
    color: colors.danger,
  },
  saveNotesButton: {
    marginTop: spacing.sm,
    alignSelf: 'flex-end',
    backgroundColor: colors.accent,
    paddingHorizontal: spacing.md,
    paddingVertical: spacing.sm,
    borderRadius: radius.full,
  },
  saveNotesButtonText: {
    fontFamily: fonts.bodyBold,
    color: colors.textOnAccent,
    fontSize: fontSize.sm,
  },
  });
}
