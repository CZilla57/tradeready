import React, { useState } from 'react';
import {
  View,
  Text,
  StyleSheet,
  ScrollView,
  TouchableOpacity,
  FlatList,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { colors, spacing, radius, fontSize, shadow } from '../utils/theme';
import {
  DATE_FILTERS,
  EXPENSE_CATEGORIES,
  formatCurrency,
  getDateRange,
  getPreviousRange,
  isInRange,
} from '../utils/moneyUtils';
import { useMoneyData }      from '../hooks/useMoneyData';
import { SummaryCard }       from '../components/money/SummaryCard';
import { MonthlyChart }      from '../components/money/MonthlyChart';
import { ReceivablesCard }   from '../components/money/ReceivablesCard';
import { TopCustomersCard }  from '../components/money/TopCustomersCard';
import { ExpenseRow }        from '../components/money/ExpenseRow';
import { AddExpenseModal }   from '../components/money/AddExpenseModal';

// ─── Inline sub-component: Expenses by Category breakdown ────────────────────

function ExpenseCategoryCard({ expensesByCategory, filteredExpenseTotal }) {
  if (expensesByCategory.length === 0) return null;
  return (
    <View style={styles.categoryCard}>
      <Text style={styles.sectionTitle}>Expenses by Category</Text>
      {expensesByCategory.map(cat => {
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
                  {formatCurrency(cat.total)}
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

export default function MoneyScreen() {
  const { invoices, expenses, jobs, loading, handleAddExpense, handleDeleteExpense } =
    useMoneyData();

  const [activeFilter, setActiveFilter] = useState('this_month');
  const [showAddModal, setShowAddModal] = useState(false);
  const [activeTab, setActiveTab]       = useState('overview'); // 'overview' | 'expenses'

  // ── Derived filter values ─────────────────────────────────────────────────
  const { start, end } = getDateRange(activeFilter);

  const filteredIncome = invoices
    .filter(inv => inv.paid === true && inv.due && isInRange(inv.due, start, end))
    .reduce((sum, inv) => sum + (parseFloat(inv.amount) || 0), 0);

  const filteredExpenses = expenses
    .filter(exp => exp.date && isInRange(exp.date, start, end));

  const filteredExpenseTotal = filteredExpenses
    .reduce((sum, exp) => sum + (parseFloat(exp.amount) || 0), 0);

  const expensesByCategory = EXPENSE_CATEGORIES
    .map(cat => ({
      ...cat,
      total: filteredExpenses
        .filter(exp => exp.category === cat.id)
        .reduce((sum, exp) => sum + (parseFloat(exp.amount) || 0), 0),
    }))
    .filter(cat => cat.total > 0)
    .sort((a, b) => b.total - a.total);

  const prevRange = getPreviousRange(activeFilter);
  const prevFilteredIncome = prevRange
    ? invoices
        .filter(inv => inv.paid && inv.due && isInRange(inv.due, prevRange.start, prevRange.end))
        .reduce((sum, inv) => sum + (parseFloat(inv.amount) || 0), 0)
    : null;
  const prevFilteredExpenseTotal = prevRange
    ? expenses
        .filter(exp => exp.date && isInRange(exp.date, prevRange.start, prevRange.end))
        .reduce((sum, exp) => sum + (parseFloat(exp.amount) || 0), 0)
    : null;

  const activeFilterLabel = DATE_FILTERS.find(f => f.id === activeFilter)?.label || '';

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
        {DATE_FILTERS.map(filter => (
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
        <ScrollView style={styles.scrollContent} showsVerticalScrollIndicator={false}>
          <SummaryCard
            income={filteredIncome}
            expenses={filteredExpenseTotal}
            prevIncome={prevFilteredIncome}
            prevExpenses={prevFilteredExpenseTotal}
            label={activeFilterLabel}
            onAddExpense={() => setShowAddModal(true)}
          />
          <ReceivablesCard invoices={invoices} jobs={jobs} />
          <MonthlyChart invoices={invoices} expenses={expenses} />
          <ExpenseCategoryCard
            expensesByCategory={expensesByCategory}
            filteredExpenseTotal={filteredExpenseTotal}
          />
          <TopCustomersCard invoices={invoices} start={start} end={end} />

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
          data={filteredExpenses.sort((a, b) => new Date(b.date) - new Date(a.date))}
          keyExtractor={item => item.id}
          renderItem={({ item }) => (
            <ExpenseRow expense={item} onDelete={handleDeleteExpense} />
          )}
          contentContainerStyle={styles.expenseList}
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
        onSave={(fields) => {
          handleAddExpense(fields);
          setShowAddModal(false);
        }}
      />
    </SafeAreaView>
  );
}

// ─── STYLES ──────────────────────────────────────────────────────────────────

const styles = StyleSheet.create({
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
    alignItems: 'flex-start',
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
    alignItems: 'center',
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
  expenseList: {
    paddingHorizontal: spacing.lg,
    paddingTop: spacing.xs,
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
