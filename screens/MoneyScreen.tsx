import React, { useState, useMemo, useCallback } from 'react';
import {
  View,
  Text,
  StyleSheet,
  ScrollView,
  TouchableOpacity,
  FlatList,
  RefreshControl,
  ActivityIndicator,
} from 'react-native';
import { Ionicons } from '@expo/vector-icons';
import { spacing, radius, fontSize, fonts, layout } from '../utils/theme';
import type { ColorScheme, ShadowScheme } from '../utils/theme';
import { useTheme } from '../hooks/useTheme';
import { useRefresh } from '../hooks/useRefresh';
import {
  DATE_FILTERS,
  EXPENSE_CATEGORIES,
  getDateRange,
  getPreviousRange,
  isInRange,
} from '../utils/moneyUtils';
import { collectedInRange } from '../utils/invoicePayments';
import { formatMoney } from '../utils/format';
import { useMoneyData }      from '../hooks/useMoneyData';
import { SummaryCard }       from '../components/money/SummaryCard';
import { MonthlyChart }      from '../components/money/MonthlyChart';
import { ReceivablesCard }   from '../components/money/ReceivablesCard';
import { TopCustomersCard }  from '../components/money/TopCustomersCard';
import { MileageCard }       from '../components/money/MileageCard';
import { TaxSetAsideCard }   from '../components/money/TaxSetAsideCard';
import { PricebookCard }     from '../components/money/PricebookCard';
import { ConversionFunnelCard } from '../components/money/ConversionFunnelCard';
import { RevenueForecastCard } from '../components/money/RevenueForecastCard';
import { AvgJobValueCard }      from '../components/money/AvgJobValueCard';
import { InvoiceAgingCard }    from '../components/money/InvoiceAgingCard';
import { RevenueByTypeCard }   from '../components/money/RevenueByTypeCard';
import { SeasonalTrendsCard }  from '../components/money/SeasonalTrendsCard';
import { CustomerMixCard }     from '../components/money/CustomerMixCard';
import { ExpenseTrendsCard }  from '../components/money/ExpenseTrendsCard';
import { ExpenseRow }        from '../components/money/ExpenseRow';
import { AddExpenseModal }   from '../components/money/AddExpenseModal';
import { MoneySection }      from '../components/money/MoneySection';
import type { Invoice, Expense } from '../types/models';
import type { MoneyStackScreenProps } from '../types/navigation';

// ─── Inline sub-component: Expenses by Category breakdown ────────────────────

interface ExpenseCategoryCardProps {
  expensesByCategory: { id: string; icon: string; label: string; total: number }[];
  filteredExpenseTotal: number;
}

function ExpenseCategoryCard({ expensesByCategory, filteredExpenseTotal }: ExpenseCategoryCardProps) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  if (expensesByCategory.length === 0) return null;
  return (
    <View style={styles.categoryCard}>
      <Text style={styles.sectionTitle}>Expenses by Category</Text>
      {expensesByCategory.map((cat) => {
        const pct = filteredExpenseTotal > 0
          ? (cat.total / filteredExpenseTotal) * 100
          : 0;
        return (
          <View key={cat.id} style={styles.categoryBreakdownRow}>
            <View style={styles.categoryBreakdownIcon}>
              <Ionicons name={cat.icon as keyof typeof Ionicons.glyphMap} size={16} color={colors.textSecondary} />
            </View>
            <View style={styles.categoryBreakdownInfo}>
              <View style={styles.categoryBreakdownHeader}>
                <Text style={styles.categoryBreakdownLabel}>{cat.label}</Text>
                <Text style={styles.categoryBreakdownAmount}>
                  {formatMoney(cat.total)}
                </Text>
              </View>
              <View style={styles.categoryProgressBg}>
                <View style={[styles.categoryProgressFill, { width: `${pct}%` }]} />
              </View>
            </View>
          </View>
        );
      })}
    </View>
  );
}

// ─── MAIN SCREEN ─────────────────────────────────────────────────────────────

export default function MoneyScreen({ navigation }: MoneyStackScreenProps<'MoneyHome'>) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  const { invoices, expenses, jobs, loading, refresh, handleAddExpense, handleDeleteExpense } =
    useMoneyData();
  const { refreshing, onRefresh } = useRefresh(refresh, 'MoneyScreen');

  const [activeFilter, setActiveFilter] = useState<string>('this_month');
  const [showAddModal, setShowAddModal] = useState<boolean>(false);
  const [activeTab, setActiveTab]       = useState<'overview' | 'expenses'>('overview');

  // ── Derived filter values ─────────────────────────────────────────────────
  const { start, end } = useMemo(() => getDateRange(activeFilter), [activeFilter]);

  const filteredIncome: number = useMemo(() =>
    collectedInRange(invoices as Invoice[], start, end),
    [invoices, start, end]
  );

  const filteredExpenses: Expense[] = useMemo(() =>
    (expenses as Expense[])
      .filter((exp) => exp.date && isInRange(exp.date, start, end)),
    [expenses, start, end]
  );

  const filteredExpenseTotal: number = useMemo(() =>
    filteredExpenses.reduce((sum, exp) => sum + (exp.amount || 0), 0),
    [filteredExpenses]
  );

  const expensesByCategory = useMemo(() =>
    EXPENSE_CATEGORIES
      .map((cat) => ({
        ...cat,
        total: filteredExpenses
          .filter((exp) => exp.category === cat.id)
          .reduce((sum, exp) => sum + (exp.amount || 0), 0),
      }))
      .filter((cat) => cat.total > 0)
      .sort((a, b) => b.total - a.total),
    [filteredExpenses]
  );

  const sortedExpenses = useMemo(() =>
    [...filteredExpenses].sort((a, b) => new Date(b.date).getTime() - new Date(a.date).getTime()),
    [filteredExpenses]
  );

  const prevRange = useMemo(() => getPreviousRange(activeFilter), [activeFilter]);
  const prevFilteredIncome: number | null = useMemo(() =>
    prevRange
      ? collectedInRange(invoices as Invoice[], prevRange.start, prevRange.end)
      : null,
    [invoices, prevRange]
  );
  const prevFilteredExpenseTotal: number | null = useMemo(() =>
    prevRange
      ? (expenses as Expense[])
          .filter((exp) => exp.date && isInRange(exp.date, prevRange.start, prevRange.end))
          .reduce((sum, exp) => sum + (exp.amount || 0), 0)
      : null,
    [expenses, prevRange]
  );

  const activeFilterLabel = DATE_FILTERS.find((f) => f.id === activeFilter)?.label || '';

  const handleMileagePress = useCallback(
    () => navigation.navigate('MileageLog', { initialFilter: activeFilter }),
    [navigation, activeFilter]
  );

  const handlePricebookPress = useCallback(
    () => navigation.navigate('Pricebook'),
    [navigation]
  );

  const handleCloseModal = useCallback(() => setShowAddModal(false), []);

  const handleSaveExpense = useCallback(
    (fields: any) => {
      handleAddExpense(fields);
      setShowAddModal(false);
    },
    [handleAddExpense]
  );

  // ─────────────────────────────────────────────────────────────────────────
  if (loading) {
    return (
      <View style={styles.loadingContainer}>
        <ActivityIndicator size={36} color={colors.accent} />
        <Text style={styles.loadingText}>Loading finances...</Text>
      </View>
    );
  }

  // Plain View root: the tab bar already covers the bottom safe-area inset —
  // a bottom-edge SafeAreaView here pads a dead strip above the tabs.
  return (
    <View style={styles.container}>

      {/* ── Date Filter Chips ─────────────────────────────────────────────── */}
      <View style={styles.filterBar}>
        <ScrollView
          horizontal
          showsHorizontalScrollIndicator={false}
          style={styles.filterScroll}
          contentContainerStyle={styles.filterScrollContent}
        >
          {DATE_FILTERS.map((filter) => (
            <TouchableOpacity
              key={filter.id}
              style={[styles.filterChip, activeFilter === filter.id && styles.filterChipActive]}
              onPress={() => setActiveFilter(filter.id)}
              accessibilityRole="button"
              accessibilityLabel={filter.label}
              accessibilityState={{ selected: activeFilter === filter.id }}
            >
              <Text style={[
                styles.filterChipText,
                activeFilter === filter.id && styles.filterChipTextActive,
              ]}>
                {filter.label}
              </Text>
            </TouchableOpacity>
          ))}
        </ScrollView>
      </View>

      {/* ── Content Tabs ──────────────────────────────────────────────────── */}
      <View style={styles.tabBarColumn}>
        <View style={styles.tabBar}>
          <TouchableOpacity
            style={[styles.tabButton, activeTab === 'overview' && styles.tabButtonActive]}
            onPress={() => setActiveTab('overview')}
            accessibilityRole="tab"
            accessibilityLabel="Overview"
            accessibilityState={{ selected: activeTab === 'overview' }}
          >
            <Text style={[styles.tabButtonText, activeTab === 'overview' && styles.tabButtonTextActive]}>
              Overview
            </Text>
          </TouchableOpacity>
          <TouchableOpacity
            style={[styles.tabButton, activeTab === 'expenses' && styles.tabButtonActive]}
            onPress={() => setActiveTab('expenses')}
            accessibilityRole="tab"
            accessibilityLabel="Expenses"
            accessibilityState={{ selected: activeTab === 'expenses' }}
          >
            <Text style={[styles.tabButtonText, activeTab === 'expenses' && styles.tabButtonTextActive]}>
              Expenses
            </Text>
          </TouchableOpacity>
        </View>
      </View>

      {/* ── Overview Tab ──────────────────────────────────────────────────── */}
      {activeTab === 'overview' && (
        <ScrollView
          style={styles.scrollContent}
          contentContainerStyle={styles.overviewScrollContent}
          showsVerticalScrollIndicator={false}
          refreshControl={<RefreshControl refreshing={refreshing} onRefresh={onRefresh} />}
        >
          {/* ── The daily glance: money in & out, always visible ────────── */}
          <SummaryCard
            income={filteredIncome}
            expenses={filteredExpenseTotal}
            prevIncome={prevFilteredIncome}
            prevExpenses={prevFilteredExpenseTotal}
            label={activeFilterLabel}
          />

          {invoices.length === 0 && expenses.length === 0 && jobs.length === 0 ? (
            /* Nothing recorded anywhere yet — skip the section scaffolding. */
            <View style={styles.emptyState}>
              <Ionicons name="cash-outline" size={40} color={colors.textMuted} style={styles.emptyStateIcon} />
              <Text style={styles.emptyStateTitle}>No financial data yet</Text>
              <Text style={styles.emptyStateBody}>
                Mark invoices as paid and log your expenses to see your P&L here.
              </Text>
            </View>
          ) : (
            <>
              {/* Deeper analytics grouped behind collapsible headers so the
                  default view stays a short glance, not a 16-card scroll. */}
              <MoneySection title="Cash flow" defaultExpanded>
                <MonthlyChart invoices={invoices} expenses={expenses} />
                <SeasonalTrendsCard invoices={invoices} />
                <ExpenseCategoryCard
                  expensesByCategory={expensesByCategory}
                  filteredExpenseTotal={filteredExpenseTotal}
                />
                <ExpenseTrendsCard expenses={expenses} />
              </MoneySection>

              <MoneySection title="Customers & invoices">
                <TopCustomersCard invoices={invoices} start={start} end={end} />
                <CustomerMixCard invoices={invoices} start={start} end={end} />
                <InvoiceAgingCard invoices={invoices} />
              </MoneySection>

              <MoneySection title="Job pipeline">
                <ReceivablesCard invoices={invoices} jobs={jobs} />
                <ConversionFunnelCard jobs={jobs} />
                <RevenueForecastCard jobs={jobs} />
                <AvgJobValueCard
                  jobs={jobs}
                  start={start}
                  end={end}
                  prevStart={prevRange?.start ?? null}
                  prevEnd={prevRange?.end ?? null}
                />
                <RevenueByTypeCard jobs={jobs} />
              </MoneySection>

              <MoneySection title="Tools">
                <MileageCard start={start} end={end} onPress={handleMileagePress} />
                {/* Tax card ignores the screen's date filter on purpose: its
                    windows are the IRS payment periods + calendar YTD, not the
                    filter — and the card body states its own period range. */}
                <TaxSetAsideCard invoices={invoices as Invoice[]} expenses={expenses as Expense[]} />
                <PricebookCard onPress={handlePricebookPress} />
              </MoneySection>
            </>
          )}
          <View style={styles.bottomPadding} />
        </ScrollView>
      )}

      {/* ── Expenses Tab ──────────────────────────────────────────────────── */}
      {activeTab === 'expenses' && (
        <FlatList
          style={styles.scrollContent}
          refreshing={refreshing}
          onRefresh={onRefresh}
          data={sortedExpenses}
          keyExtractor={(item) => item.id}
          renderItem={({ item }) => (
            <ExpenseRow expense={item} onDelete={handleDeleteExpense} />
          )}
          contentContainerStyle={styles.expenseList}
          ListHeaderComponent={
            <View style={styles.expenseHeader}>
              <TouchableOpacity style={styles.addExpenseBtn} onPress={() => setShowAddModal(true)}>
                <Text style={styles.addExpenseBtnText}>+ Expense</Text>
              </TouchableOpacity>
            </View>
          }
          ListEmptyComponent={
            <View style={styles.emptyState}>
              <Ionicons name="receipt-outline" size={40} color={colors.textMuted} style={styles.emptyStateIcon} />
              <Text style={styles.emptyStateTitle}>No expenses logged</Text>
              <Text style={styles.emptyStateBody}>
                Tap "+ Expense" to log your first expense for this period.
              </Text>
            </View>
          }
          ListFooterComponent={<View style={styles.bottomPadding} />}
        />
      )}

      {/* ── Add Expense Modal ─────────────────────────────────────────────── */}
      <AddExpenseModal
        visible={showAddModal}
        onClose={handleCloseModal}
        onSave={handleSaveExpense}
      />
    </View>
  );
}

// ─── STYLES ──────────────────────────────────────────────────────────────────

function createStyles(colors: ColorScheme, shadow: ShadowScheme) {
  return StyleSheet.create({
    container: {
      flex: 1,
      backgroundColor: colors.background,
    },
    loadingContainer: {
      flex: 1,
      backgroundColor: colors.background,
      alignItems: 'center',
      justifyContent: 'center',
    },
    loadingText: {
      fontFamily: fonts.bodyRegular,
      color: colors.textSecondary,
      fontSize: fontSize.md,
      marginTop: spacing.md,
    },

    // ── Date filter chips
    // Fixed-height wrapper. A horizontal ScrollView left to size itself
    // stretches to fill the column's free vertical space on the New
    // Architecture (Fabric) — a `height` on the ScrollView's own style is
    // not honored — which pinned the chips to the top and pushed the whole
    // screen down. The wrapper pins the row to chip height.
    filterBar: {
      height: 44,
      marginBottom: spacing.md,
      ...layout.contentColumn,
    },
    filterScroll: {
      paddingLeft: spacing.lg,
    },
    filterScrollContent: {
      paddingRight: spacing.lg,
      paddingVertical: 4,
      gap: spacing.sm,
      alignItems: 'flex-start' as const,
    },
    filterChip: {
      paddingHorizontal: 14,
      paddingTop: 6,
      paddingBottom: 8,
      borderRadius: radius.full,
      backgroundColor: colors.surface,
      borderWidth: 1,
      borderColor: colors.border,
      marginRight: spacing.sm,
    },
    filterChipActive: {
      backgroundColor: colors.accentBg,
      borderColor: colors.accent,
    },
    filterChipText: {
      fontFamily: fonts.mono,
      color: colors.textSecondary,
      fontSize: 11,
      lineHeight: 18,
    },
    filterChipTextActive: {
      color: colors.accent,
    },

    // ── Content tabs (Overview / Expenses)
    // Bordered/filled segmented control: its horizontal inset must stay a
    // margin, so the column token goes on a plain wrapper. Spreading it onto
    // the bar itself would cancel `marginHorizontal` on phone (see the note on
    // `layout.contentColumn`).
    tabBarColumn: {
      ...layout.contentColumn,
    },
    tabBar: {
      flexDirection: 'row',
      marginHorizontal: spacing.lg,
      marginBottom: spacing.md,
      backgroundColor: colors.surface,
      borderRadius: radius.sm,
      padding: 3,
      borderWidth: 1,
      borderColor: colors.border,
    },
    tabButton: {
      flex: 1,
      paddingVertical: spacing.sm,
      alignItems: 'center' as const,
      borderRadius: radius.sm - 2,
    },
    tabButtonActive: {
      backgroundColor: colors.background,
    },
    tabButtonText: {
      fontFamily: fonts.mono,
      color: colors.textSecondary,
      fontSize: 11,
      textTransform: 'uppercase',
      letterSpacing: 0.3,
    },
    tabButtonTextActive: {
      color: colors.textPrimary,
    },
    scrollContent: {
      flex: 1,
    },
    overviewScrollContent: {
      ...layout.contentColumn,
    },

    // ── Expense Category Card (inline breakdown used only in this screen)
    categoryCard: {
      marginHorizontal: spacing.lg,
      marginBottom: spacing.md,
      backgroundColor: colors.surface,
      borderRadius: radius.lg,
      padding: spacing.lg,
      borderWidth: 1,
      borderColor: colors.border,
      ...shadow.card,
    },
    sectionTitle: {
      fontFamily: fonts.display,
      color: colors.textPrimary,
      fontSize: fontSize.md + 1,
      marginBottom: spacing.md,
    },
    categoryBreakdownRow: {
      flexDirection: 'row',
      alignItems: 'center',
      marginBottom: 14,
    },
    categoryBreakdownIcon: {
      marginRight: spacing.md,
      width: 28,
      alignItems: 'center',
    },
    categoryBreakdownInfo: {
      flex: 1,
    },
    categoryBreakdownHeader: {
      flexDirection: 'row',
      justifyContent: 'space-between',
      marginBottom: spacing.xs,
    },
    categoryBreakdownLabel: {
      fontFamily: fonts.bodySemiBold,
      color: colors.textPrimary,
      fontSize: fontSize.sm + 1,
    },
    categoryBreakdownAmount: {
      fontFamily: fonts.display,
      color: colors.danger,
      fontSize: fontSize.sm + 1,
      fontVariant: ['tabular-nums'],
    },
    categoryProgressBg: {
      height: 4,
      backgroundColor: colors.border,
      borderRadius: 2,
      overflow: 'hidden',
    },
    categoryProgressFill: {
      height: '100%',
      backgroundColor: colors.danger,
      borderRadius: 2,
      opacity: 0.7,
    },

    // ── Expense list (Expenses tab)
    expenseHeader: {
      flexDirection: 'row',
      justifyContent: 'flex-end',
      marginBottom: spacing.md,
    },
    addExpenseBtn: {
      backgroundColor: colors.accent,
      paddingHorizontal: 14,
      paddingVertical: 6,
      borderRadius: radius.full,
    },
    addExpenseBtnText: {
      fontFamily: fonts.bodyBold,
      color: colors.textOnAccent,
      fontSize: fontSize.sm,
    },
    expenseList: {
      paddingHorizontal: spacing.lg,
      paddingTop: spacing.sm,
      ...layout.contentColumn,
    },

    // ── Empty states
    emptyState: {
      alignItems: 'center',
      paddingVertical: 60,
      paddingHorizontal: 40,
    },
    emptyStateIcon: {
      marginBottom: spacing.md,
    },
    emptyStateTitle: {
      fontFamily: fonts.display,
      color: colors.textPrimary,
      fontSize: fontSize.lg + 1,
      marginBottom: spacing.sm,
      textAlign: 'center',
    },
    emptyStateBody: {
      fontFamily: fonts.bodyRegular,
      color: colors.textSecondary,
      fontSize: fontSize.sm + 1,
      textAlign: 'center',
      lineHeight: 20,
    },
    bottomPadding: {
      height: 100,
    },
  });
}
