import React, { useState, useMemo } from 'react';
import {
  View,
  Text,
  StyleSheet,
  ScrollView,
  TouchableOpacity,
  FlatList,
  RefreshControl,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { spacing, radius, fontSize } from '../utils/theme';
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
import { formatMoney } from '../utils/format';
import { useMoneyData }      from '../hooks/useMoneyData';
import { SummaryCard }       from '../components/money/SummaryCard';
import { MonthlyChart }      from '../components/money/MonthlyChart';
import { ReceivablesCard }   from '../components/money/ReceivablesCard';
import { TopCustomersCard }  from '../components/money/TopCustomersCard';
import { MileageCard }       from '../components/money/MileageCard';
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
import type { Invoice, Expense } from '../types/models';

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
            <Text style={styles.categoryBreakdownIcon}>{cat.icon}</Text>
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

export default function MoneyScreen({ navigation }: any) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  const { invoices, expenses, jobs, loading, refresh, handleAddExpense, handleDeleteExpense } =
    useMoneyData();
  const { refreshing, onRefresh } = useRefresh(refresh, 'MoneyScreen');

  const [activeFilter, setActiveFilter] = useState<string>('this_month');
  const [showAddModal, setShowAddModal] = useState<boolean>(false);
  const [activeTab, setActiveTab]       = useState<'overview' | 'expenses'>('overview');

  // ── Derived filter values ─────────────────────────────────────────────────
  const { start, end } = getDateRange(activeFilter);

  const filteredIncome: number = (invoices as Invoice[])
    .filter((inv) => inv.paid === true && isInRange((inv as any).paidAt || inv.due, start, end))
    .reduce((sum, inv) => sum + (parseFloat(String((inv as any).amount)) || 0), 0);

  const filteredExpenses: Expense[] = (expenses as Expense[])
    .filter((exp) => (exp as any).date && isInRange((exp as any).date, start, end));

  const filteredExpenseTotal: number = filteredExpenses
    .reduce((sum, exp) => sum + (parseFloat(String((exp as any).amount)) || 0), 0);

  const expensesByCategory = EXPENSE_CATEGORIES
    .map((cat: any) => ({
      ...cat,
      total: filteredExpenses
        .filter((exp) => (exp as any).category === cat.id)
        .reduce((sum, exp) => sum + (parseFloat(String((exp as any).amount)) || 0), 0),
    }))
    .filter((cat: any) => cat.total > 0)
    .sort((a: any, b: any) => b.total - a.total);

  const prevRange = getPreviousRange(activeFilter);
  const prevFilteredIncome: number | null = prevRange
    ? (invoices as Invoice[])
        .filter((inv) => inv.paid && isInRange((inv as any).paidAt || inv.due, prevRange.start, prevRange.end))
        .reduce((sum, inv) => sum + (parseFloat(String((inv as any).amount)) || 0), 0)
    : null;
  const prevFilteredExpenseTotal: number | null = prevRange
    ? (expenses as Expense[])
        .filter((exp) => (exp as any).date && isInRange((exp as any).date, prevRange.start, prevRange.end))
        .reduce((sum, exp) => sum + (parseFloat(String((exp as any).amount)) || 0), 0)
    : null;

  const activeFilterLabel = DATE_FILTERS.find((f: any) => f.id === activeFilter)?.label || '';

  // ─────────────────────────────────────────────────────────────────────────
  if (loading) {
    return (
      <View style={styles.loadingContainer}>
        <Text style={styles.loadingText}>Loading finances...</Text>
      </View>
    );
  }

  return (
    <SafeAreaView style={styles.container} edges={['bottom']}>

      {/* ── Date Filter Chips ─────────────────────────────────────────────── */}
      <ScrollView
        horizontal
        showsHorizontalScrollIndicator={false}
        style={styles.filterScroll}
        contentContainerStyle={styles.filterScrollContent}
      >
        {DATE_FILTERS.map((filter: any) => (
          <TouchableOpacity
            key={filter.id}
            style={[styles.filterChip, activeFilter === filter.id && styles.filterChipActive]}
            onPress={() => setActiveFilter(filter.id)}
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

      {/* ── Content Tabs ──────────────────────────────────────────────────── */}
      <View style={styles.tabBar}>
        <TouchableOpacity
          style={[styles.tabButton, activeTab === 'overview' && styles.tabButtonActive]}
          onPress={() => setActiveTab('overview')}
        >
          <Text style={[styles.tabButtonText, activeTab === 'overview' && styles.tabButtonTextActive]}>
            Overview
          </Text>
        </TouchableOpacity>
        <TouchableOpacity
          style={[styles.tabButton, activeTab === 'expenses' && styles.tabButtonActive]}
          onPress={() => setActiveTab('expenses')}
        >
          <Text style={[styles.tabButtonText, activeTab === 'expenses' && styles.tabButtonTextActive]}>
            Expenses
          </Text>
        </TouchableOpacity>
      </View>

      {/* ── Overview Tab ──────────────────────────────────────────────────── */}
      {activeTab === 'overview' && (
        <ScrollView
          style={styles.scrollContent}
          showsVerticalScrollIndicator={false}
          refreshControl={<RefreshControl refreshing={refreshing} onRefresh={onRefresh} />}
        >
          <SummaryCard
            income={filteredIncome}
            expenses={filteredExpenseTotal}
            prevIncome={prevFilteredIncome}
            prevExpenses={prevFilteredExpenseTotal}
            label={activeFilterLabel}
          />
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
          <MileageCard start={start} end={end} onPress={() => navigation.navigate('MileageLog', { initialFilter: activeFilter })} />
          <PricebookCard onPress={() => navigation.navigate('Pricebook')} />
          <MonthlyChart invoices={invoices} expenses={expenses} />
          <SeasonalTrendsCard invoices={invoices} />
          <ExpenseCategoryCard
            expensesByCategory={expensesByCategory}
            filteredExpenseTotal={filteredExpenseTotal}
          />
          <ExpenseTrendsCard expenses={expenses} />
          <TopCustomersCard invoices={invoices} start={start} end={end} />
          <CustomerMixCard invoices={invoices} start={start} end={end} />
          <RevenueByTypeCard jobs={jobs} />
          <InvoiceAgingCard invoices={invoices} />

          {filteredIncome === 0 && filteredExpenseTotal === 0 && (
            <View style={styles.emptyState}>
              <Text style={styles.emptyStateIcon}>💰</Text>
              <Text style={styles.emptyStateTitle}>No financial data yet</Text>
              <Text style={styles.emptyStateBody}>
                Mark invoices as paid and log your expenses to see your P&L here.
              </Text>
            </View>
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
          data={filteredExpenses.sort((a, b) => (new Date((b as any).date) as any) - (new Date((a as any).date) as any))}
          keyExtractor={(item) => (item as any).id}
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
              <Text style={styles.emptyStateIcon}>🧾</Text>
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
        onClose={() => setShowAddModal(false)}
        onSave={(fields: any) => {
          handleAddExpense(fields);
          setShowAddModal(false);
        }}
      />
    </SafeAreaView>
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
      color: colors.textSecondary,
      fontSize: fontSize.md,
    },

    // ── Date filter chips
    filterScroll: {
      paddingLeft: spacing.lg,
      marginBottom: spacing.md,
      height: 44,
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
      color: colors.textSecondary,
      fontSize: fontSize.sm,
      fontWeight: '500',
      lineHeight: 18,
    },
    filterChipTextActive: {
      color: colors.accent,
      fontWeight: '600',
    },

    // ── Content tabs (Overview / Expenses)
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
      color: colors.textSecondary,
      fontWeight: '500',
      fontSize: fontSize.sm + 1,
    },
    tabButtonTextActive: {
      color: colors.textPrimary,
      fontWeight: '600',
    },
    scrollContent: {
      flex: 1,
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
      color: colors.textPrimary,
      fontSize: fontSize.md + 1,
      fontWeight: '600',
      marginBottom: spacing.md,
    },
    categoryBreakdownRow: {
      flexDirection: 'row',
      alignItems: 'center',
      marginBottom: 14,
    },
    categoryBreakdownIcon: {
      fontSize: 20,
      marginRight: spacing.md,
      width: 28,
      textAlign: 'center',
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
      color: colors.textPrimary,
      fontSize: fontSize.sm + 1,
      fontWeight: '500',
    },
    categoryBreakdownAmount: {
      color: colors.danger,
      fontSize: fontSize.sm + 1,
      fontWeight: '600',
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
      color: colors.textOnAccent,
      fontWeight: '700',
      fontSize: fontSize.sm,
    },
    expenseList: {
      paddingHorizontal: spacing.lg,
      paddingTop: spacing.sm,
    },

    // ── Empty states
    emptyState: {
      alignItems: 'center',
      paddingVertical: 60,
      paddingHorizontal: 40,
    },
    emptyStateIcon: {
      fontSize: 48,
      marginBottom: spacing.md,
    },
    emptyStateTitle: {
      color: colors.textPrimary,
      fontSize: fontSize.lg + 1,
      fontWeight: '600',
      marginBottom: spacing.sm,
      textAlign: 'center',
    },
    emptyStateBody: {
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
