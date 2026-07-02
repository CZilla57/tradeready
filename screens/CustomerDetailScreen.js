// screens/CustomerDetailScreen.js
// Full profile for a single customer — contact info, lifetime value, invoice history, job history, notes.

import React, { useState, useEffect, useCallback } from 'react';
import {
  View,
  Text,
  StyleSheet,
  ScrollView,
  TouchableOpacity,
  TextInput,
  Linking,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { loadJobs, loadNoteForCustomer, saveNoteForCustomer } from '../utils/storage';
import { colors, spacing, radius, fontSize } from '../utils/theme';

// ─── HELPERS ──────────────────────────────────────────────────────────────────

const formatCurrency = (amount) =>
  '$' + amount.toLocaleString('en-US', { minimumFractionDigits: 0, maximumFractionDigits: 0 });

const formatDate = (dateStr) => {
  if (!dateStr) return '—';
  return new Date(dateStr + 'T00:00:00').toLocaleDateString('en-US', {
    month: 'short', day: 'numeric', year: 'numeric',
  });
};

const invoiceStatus = (inv) => {
  if (inv.paid) return { label: 'Paid', color: colors.success };
  const due = new Date(inv.due);
  const now = new Date();
  if (due < now) return { label: 'Overdue', color: colors.danger };
  return { label: 'Pending', color: colors.warning };
};

const JOB_STAGES = {
  lead:        'Lead',
  estimate_sent: 'Estimate Sent',
  approved:    'Approved',
  scheduled:   'Scheduled',
  in_progress: 'In Progress',
  complete:    'Complete',
  invoiced:    'Invoiced',
  paid:        'Paid',
};

// ─── SUB-COMPONENTS ───────────────────────────────────────────────────────────

const InfoRow = ({ icon, label, value, onPress }) => (
  <TouchableOpacity
    style={styles.infoRow}
    onPress={onPress}
    disabled={!onPress}
    activeOpacity={onPress ? 0.6 : 1}
  >
    <Text style={styles.infoIcon}>{icon}</Text>
    <View style={styles.infoContent}>
      <Text style={styles.infoLabel}>{label}</Text>
      <Text style={[styles.infoValue, onPress && styles.infoValueTappable]}>
        {value || '—'}
      </Text>
    </View>
    {onPress && <Text style={styles.infoChevron}>›</Text>}
  </TouchableOpacity>
);

const InvoiceRow = ({ invoice, onPress }) => {
  const status = invoiceStatus(invoice);
  return (
    <TouchableOpacity style={styles.invoiceRow} onPress={() => onPress(invoice)}>
      <View style={styles.invoiceRowLeft}>
        <Text style={styles.invoiceNumber}>{invoice.number || 'No #'}</Text>
        <Text style={styles.invoiceDesc} numberOfLines={1}>{invoice.desc || 'No description'}</Text>
        <Text style={styles.invoiceDate}>Due {formatDate(invoice.due)}</Text>
      </View>
      <View style={styles.invoiceRowRight}>
        <Text style={styles.invoiceAmount}>{formatCurrency(parseFloat(invoice.amount) || 0)}</Text>
        <View style={[styles.statusBadge, { backgroundColor: status.color + '22' }]}>
          <Text style={[styles.statusBadgeText, { color: status.color }]}>{status.label}</Text>
        </View>
      </View>
    </TouchableOpacity>
  );
};

const JobRow = ({ job }) => {
  const stageLabel = JOB_STAGES[job.status] || job.status || 'Unknown';
  return (
    <View style={styles.jobRow}>
      <View style={styles.jobRowLeft}>
        <Text style={styles.jobTitle} numberOfLines={1}>{job.title || 'Untitled Job'}</Text>
        <Text style={styles.jobMeta}>{stageLabel} · {formatDate(job.scheduledDate)}</Text>
      </View>
      {job.estimateTotal > 0 && (
        <Text style={styles.jobValue}>{formatCurrency(job.estimateTotal)}</Text>
      )}
    </View>
  );
};

// ─── MAIN SCREEN ──────────────────────────────────────────────────────────────

export default function CustomerDetailScreen({ route, navigation }) {
  const { customer } = route.params;

  const [jobs, setJobs]               = useState([]);
  const [notes, setNotes]             = useState('');
  const [notesChanged, setNotesChanged] = useState(false);

  useEffect(() => {
    navigation.setOptions({ title: customer.name });
  }, [customer.name]);

  useEffect(() => {
    loadJobsAndNotes();
  }, []);

  const loadJobsAndNotes = async () => {
    try {
      const [allJobs, savedNote] = await Promise.all([
        loadJobs(),
        loadNoteForCustomer(customer.name),
      ]);

      // Match by customerId first (proper relationship), fall back to name match
      // for invoice-derived customers that don't have a formal customerId yet.
      const customerJobs = allJobs.filter(j =>
        j.customerId === customer.id ||
        j.customerName?.trim().toLowerCase() === customer.name.trim().toLowerCase()
      );
      setJobs(customerJobs);
      setNotes(savedNote);
    } catch (err) {
      console.error('CustomerDetailScreen: failed to load data', err);
    }
  };

  const handleNotesSave = useCallback(async () => {
    if (!notesChanged) return;
    try {
      await saveNoteForCustomer(customer.name, notes);
      setNotesChanged(false);
    } catch (err) {
      console.error('CustomerDetailScreen: failed to save notes', err);
    }
  }, [notes, notesChanged, customer.name]);

  const handleInvoicePress = (invoice) => {
    navigation.navigate('AddInvoice', { invoiceId: invoice.id });
  };

  const handleNewInvoice = () => {
    navigation.navigate('AddInvoice', {
      prefill: {
        customer: customer.name,
        email:    customer.email,
        phone:    customer.phone,
      },
    });
  };

  const handleCall = () => {
    if (!customer.phone) return;
    Linking.openURL(`tel:${customer.phone.replace(/\D/g, '')}`);
  };

  const handleEmail = () => {
    if (!customer.email) return;
    Linking.openURL(`mailto:${customer.email}`);
  };

  const invoices     = customer.invoices || [];
  const totalSpent   = customer.totalSpent || 0;
  const totalOwed    = customer.totalOwed || 0;
  const invoiceCount = invoices.length;

  const initials = customer.name
    .split(' ')
    .map(w => w[0])
    .slice(0, 2)
    .join('')
    .toUpperCase();

  return (
    <SafeAreaView style={styles.container} edges={['bottom']}>
      <ScrollView showsVerticalScrollIndicator={false}>

        {/* Hero: avatar + name + quick actions */}
        <View style={styles.hero}>
          <View style={styles.heroAvatar}>
            <Text style={styles.heroAvatarText}>{initials}</Text>
          </View>
          <Text style={styles.heroName}>{customer.name}</Text>

          <View style={styles.heroActions}>
            {customer.phone ? (
              <TouchableOpacity style={styles.heroAction} onPress={handleCall}>
                <Text style={styles.heroActionIcon}>📞</Text>
                <Text style={styles.heroActionLabel}>Call</Text>
              </TouchableOpacity>
            ) : null}
            {customer.email ? (
              <TouchableOpacity style={styles.heroAction} onPress={handleEmail}>
                <Text style={styles.heroActionIcon}>✉️</Text>
                <Text style={styles.heroActionLabel}>Email</Text>
              </TouchableOpacity>
            ) : null}
            <TouchableOpacity style={styles.heroAction} onPress={handleNewInvoice}>
              <Text style={styles.heroActionIcon}>🧾</Text>
              <Text style={styles.heroActionLabel}>Invoice</Text>
            </TouchableOpacity>
          </View>
        </View>

        {/* Lifetime value stats */}
        <View style={styles.statsRow}>
          <View style={styles.statBox}>
            <Text style={styles.statValue}>{formatCurrency(totalSpent)}</Text>
            <Text style={styles.statLabel}>Collected</Text>
          </View>
          <View style={styles.statDivider} />
          <View style={styles.statBox}>
            <Text style={[styles.statValue, totalOwed > 0 && { color: colors.danger }]}>
              {formatCurrency(totalOwed)}
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
              icon="📞"
              label="Phone"
              value={customer.phone}
              onPress={customer.phone ? handleCall : null}
            />
            <View style={styles.cardSeparator} />
            <InfoRow
              icon="✉️"
              label="Email"
              value={customer.email}
              onPress={customer.email ? handleEmail : null}
            />
          </View>
        </View>

        {/* Invoice history */}
        {invoices.length > 0 && (
          <View style={styles.section}>
            <Text style={styles.sectionTitle}>Invoice History</Text>
            <View style={styles.card}>
              {invoices
                .sort((a, b) => new Date(b.due) - new Date(a.due))
                .map((inv, idx) => (
                  <React.Fragment key={inv.id}>
                    {idx > 0 && <View style={styles.cardSeparator} />}
                    <InvoiceRow invoice={inv} onPress={handleInvoicePress} />
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
                .sort((a, b) => new Date(b.scheduledDate || 0) - new Date(a.scheduledDate || 0))
                .map((job, idx) => (
                  <React.Fragment key={job.id || idx}>
                    {idx > 0 && <View style={styles.cardSeparator} />}
                    <JobRow job={job} />
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
          />
          {notesChanged && (
            <TouchableOpacity style={styles.saveNotesButton} onPress={handleNotesSave}>
              <Text style={styles.saveNotesButtonText}>Save notes</Text>
            </TouchableOpacity>
          )}
        </View>

        <View style={{ height: 60 }} />
      </ScrollView>
    </SafeAreaView>
  );
}

// ─── STYLES ───────────────────────────────────────────────────────────────────

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: colors.background,
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
    color: colors.accent,
    fontSize: 28,
    fontWeight: '700',
  },
  heroName: {
    color: colors.textPrimary,
    fontSize: fontSize.xl,
    fontWeight: '700',
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
    fontSize: 22,
    marginBottom: 4,
  },
  heroActionLabel: {
    color: colors.textSecondary,
    fontSize: fontSize.xs,
    fontWeight: '500',
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
    color: colors.success,
    fontSize: fontSize.lg,
    fontWeight: '700',
    letterSpacing: -0.3,
    marginBottom: 4,
  },
  statLabel: {
    color: colors.textSecondary,
    fontSize: fontSize.xs,
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
    color: colors.textSecondary,
    fontSize: fontSize.xs,
    fontWeight: '600',
    textTransform: 'uppercase',
    letterSpacing: 0.5,
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
    fontSize: 18,
    marginRight: spacing.md,
    width: 24,
    textAlign: 'center',
  },
  infoContent: {
    flex: 1,
  },
  infoLabel: {
    color: colors.textMuted,
    fontSize: fontSize.xs,
    fontWeight: '500',
    textTransform: 'uppercase',
    letterSpacing: 0.3,
    marginBottom: 2,
  },
  infoValue: {
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
    color: colors.textSecondary,
    fontSize: fontSize.xs,
    fontWeight: '600',
    marginBottom: 2,
  },
  invoiceDesc: {
    color: colors.textPrimary,
    fontSize: fontSize.md,
    fontWeight: '500',
    marginBottom: 2,
  },
  invoiceDate: {
    color: colors.textMuted,
    fontSize: fontSize.xs,
  },
  invoiceRowRight: {
    alignItems: 'flex-end',
    gap: 6,
  },
  invoiceAmount: {
    color: colors.textPrimary,
    fontSize: fontSize.md,
    fontWeight: '700',
  },
  statusBadge: {
    paddingHorizontal: spacing.sm,
    paddingVertical: 3,
    borderRadius: radius.sm,
  },
  statusBadgeText: {
    fontSize: fontSize.xs,
    fontWeight: '600',
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
    color: colors.textPrimary,
    fontSize: fontSize.md,
    fontWeight: '500',
    marginBottom: 3,
  },
  jobMeta: {
    color: colors.textSecondary,
    fontSize: fontSize.sm,
  },
  jobValue: {
    color: colors.textSecondary,
    fontSize: fontSize.md,
    fontWeight: '600',
  },

  // Notes
  notesInput: {
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
  saveNotesButton: {
    marginTop: spacing.sm,
    alignSelf: 'flex-end',
    backgroundColor: colors.accent,
    paddingHorizontal: spacing.md,
    paddingVertical: spacing.sm,
    borderRadius: radius.full,
  },
  saveNotesButtonText: {
    color: colors.textOnAccent,
    fontWeight: '700',
    fontSize: fontSize.sm,
  },
});
