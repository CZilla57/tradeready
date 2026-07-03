// MoneyScreen.js
// The Money tab — gives tradespeople a real-time view of income, expenses, and profit.
//
// WHAT THIS FILE DOES:
// - Shows a P&L summary at the top (income, expenses, net profit)
// - Displays a bar chart of monthly income vs expenses
// - Lets users log expenses with categories, amounts, dates, and notes
// - Filters everything by time period (this month, last month, this year, all time)
// - Pulls invoice data from AsyncStorage to calculate income automatically
//
// REACT NATIVE CONCEPTS IN THIS FILE:
// - useState: local state for expenses, filters, modal visibility
// - useEffect: runs code when the screen loads or when filters change
// - AsyncStorage: reads saved invoices (income) and writes/reads expenses
// - ScrollView + FlatList: scrollable content and efficient list rendering
// - Modal: the "Add Expense" overlay sheet
// - TouchableOpacity: pressable buttons and list items

import React, { useState, useCallback, useEffect, useRef } from 'react';
import { useFocusEffect } from '@react-navigation/native';
import {
  View,
  Text,
  Image,
  Animated,
  StyleSheet,
  ScrollView,
  TouchableOpacity,
  Modal,
  TextInput,
  FlatList,
  Alert,
  PanResponder,
  KeyboardAvoidingView,
  Platform,
  Dimensions,
} from 'react-native';
import * as ImagePicker from 'expo-image-picker';
import DateTimePicker from '@react-native-community/datetimepicker';
import { SafeAreaView } from 'react-native-safe-area-context';
import { loadInvoices, loadExpenses, saveExpenses, loadJobs } from '../utils/storage';
import { colors, spacing, radius, fontSize, shadow } from '../utils/theme';

// ─── CONSTANTS ───────────────────────────────────────────────────────────────

const SCREEN_WIDTH = Dimensions.get('window').width;

// Expense categories — trades-specific, not generic accounting jargon
const EXPENSE_CATEGORIES = [
  { id: 'materials', label: 'Materials', icon: '🪵' },
  { id: 'tools',     label: 'Tools & Equipment', icon: '🔧' },
  { id: 'fuel',      label: 'Fuel & Transport', icon: '⛽' },
  { id: 'labor',     label: 'Subcontractors', icon: '👷' },
  { id: 'insurance', label: 'Insurance', icon: '🛡️' },
  { id: 'software',  label: 'Software & Apps', icon: '💻' },
  { id: 'marketing', label: 'Marketing', icon: '📣' },
  { id: 'other',     label: 'Other', icon: '📦' },
];

// Date filter options
const DATE_FILTERS = [
  { id: 'this_month', label: 'This Month' },
  { id: 'last_month', label: 'Last Month' },
  { id: 'this_year',  label: 'This Year' },
  { id: 'all_time',   label: 'All Time' },
];

// ─── HELPER FUNCTIONS ────────────────────────────────────────────────────────

// Format a number as currency: 1234.5 → "$1,234.50"
const formatCurrency = (amount) => {
  return '$' + Math.abs(amount).toLocaleString('en-US', {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  });
};

// Get start and end Date objects for a given filter period
const getDateRange = (filterId) => {
  const now = new Date();
  const year = now.getFullYear();
  const month = now.getMonth(); // 0-indexed

  switch (filterId) {
    case 'this_month':
      return {
        start: new Date(year, month, 1),
        end:   new Date(year, month + 1, 0, 23, 59, 59),
      };
    case 'last_month':
      return {
        start: new Date(year, month - 1, 1),
        end:   new Date(year, month, 0, 23, 59, 59),
      };
    case 'this_year':
      return {
        start: new Date(year, 0, 1),
        end:   new Date(year, 11, 31, 23, 59, 59),
      };
    case 'all_time':
    default:
      return { start: new Date(0), end: new Date(9999, 11, 31) };
  }
};

// Get the comparison period immediately before the active filter
const getPreviousRange = (filterId) => {
  const now = new Date();
  const year = now.getFullYear();
  const month = now.getMonth();
  switch (filterId) {
    case 'this_month':
      return { start: new Date(year, month - 1, 1), end: new Date(year, month, 0, 23, 59, 59) };
    case 'last_month':
      return { start: new Date(year, month - 2, 1), end: new Date(year, month - 1, 0, 23, 59, 59) };
    case 'this_year':
      return { start: new Date(year - 1, 0, 1), end: new Date(year - 1, 11, 31, 23, 59, 59) };
    default:
      return null;
  }
};

// Check if a date string falls within a range
const isInRange = (dateString, start, end) => {
  const d = new Date(dateString);
  return d >= start && d <= end;
};

// Get the last 6 months as labels for the chart
// Returns array like ["Jan", "Feb", "Mar", "Apr", "May", "Jun"]
const getLast6MonthLabels = () => {
  const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
  const now = new Date();
  const result = [];
  for (let i = 5; i >= 0; i--) {
    const d = new Date(now.getFullYear(), now.getMonth() - i, 1);
    result.push({ label: months[d.getMonth()], year: d.getFullYear(), month: d.getMonth() });
  }
  return result;
};

// Generate a unique ID for new expenses
const generateId = () => Date.now().toString() + Math.random().toString(36).substr(2, 5);

// ─── SUB-COMPONENTS ──────────────────────────────────────────────────────────

// P&L summary card at the top of the screen
// Shows income, expenses, and net profit with color coding
const SummaryCard = ({ income, expenses, prevIncome, prevExpenses, label, onAddExpense }) => {
  const profit = income - expenses;
  const prevProfit = prevIncome !== null && prevExpenses !== null ? prevIncome - prevExpenses : null;
  const isPositive = profit >= 0;

  function changePct(current, prev) {
    if (prev === null || prev === 0) return null;
    return Math.round(((current - prev) / Math.abs(prev)) * 100);
  }

  function ChangeLabel({ pct, inverse }) {
    if (pct === null || pct === 0) return null;
    const isUp = pct > 0;
    const isGood = inverse ? !isUp : isUp;
    return (
      <Text style={[styles.changeLabel, { color: isGood ? colors.success : colors.danger }]}>
        {isUp ? '↑' : '↓'} {Math.abs(pct)}%
      </Text>
    );
  }

  const incomeChange   = changePct(income, prevIncome);
  const expensesChange = changePct(expenses, prevExpenses);
  const profitChange   = changePct(profit, prevProfit);

  return (
    <View style={styles.summaryCard}>
      <View style={styles.summaryCardHeader}>
        <Text style={styles.summaryPeriodLabel}>{label}</Text>
        <TouchableOpacity style={styles.addExpenseBtn} onPress={onAddExpense}>
          <Text style={styles.addExpenseBtnText}>+ Expense</Text>
        </TouchableOpacity>
      </View>

      {/* Three columns: Income | Expenses | Net */}
      <View style={styles.summaryRow}>
        <View style={styles.summaryColumn}>
          <Text style={styles.summaryColumnLabel}>Income</Text>
          <Text style={[styles.summaryAmount, { color: colors.success }]}>
            {formatCurrency(income)}
          </Text>
          <ChangeLabel pct={incomeChange} inverse={false} />
        </View>

        <View style={styles.summaryDivider} />

        <View style={styles.summaryColumn}>
          <Text style={styles.summaryColumnLabel}>Expenses</Text>
          <Text style={[styles.summaryAmount, { color: colors.danger }]}>
            {formatCurrency(expenses)}
          </Text>
          <ChangeLabel pct={expensesChange} inverse={true} />
        </View>

        <View style={styles.summaryDivider} />

        <View style={styles.summaryColumn}>
          <Text style={styles.summaryColumnLabel}>Net Profit</Text>
          <Text style={[styles.summaryAmount, {
            color: isPositive ? colors.success : colors.danger,
          }]}>
            {isPositive ? '' : '-'}{formatCurrency(profit)}
          </Text>
          <ChangeLabel pct={profitChange} inverse={false} />
        </View>
      </View>

      {/* Profit margin bar — shows what % of income is profit */}
      {income > 0 && (
        <View style={styles.marginBarContainer}>
          <View style={styles.marginBarBg}>
            <View style={[
              styles.marginBarFill,
              {
                width: `${Math.max(0, Math.min(100, (profit / income) * 100))}%`,
                backgroundColor: isPositive ? colors.success : colors.danger,
              }
            ]} />
          </View>
          <Text style={styles.marginLabel}>
            {income > 0 ? `${Math.round((profit / income) * 100)}% margin` : ''}
          </Text>
        </View>
      )}
    </View>
  );
};

// Simple bar chart showing income vs expenses for last 6 months
// Built without any charting library — just View components with calculated heights
const MonthlyChart = ({ invoices, expenses }) => {
  const months = getLast6MonthLabels();

  // For each month, calculate total income (from paid invoices) and total expenses
  const chartData = months.map(({ label, year, month }) => {
    const monthIncome = invoices
      .filter(inv => {
        if (!inv.paid || !inv.due) return false;
        const d = new Date(inv.due);
        return d.getFullYear() === year && d.getMonth() === month;
      })
      .reduce((sum, inv) => sum + (parseFloat(inv.amount) || 0), 0);

    const monthExpenses = expenses
      .filter(exp => {
        const d = new Date(exp.date);
        return d.getFullYear() === year && d.getMonth() === month;
      })
      .reduce((sum, exp) => sum + (parseFloat(exp.amount) || 0), 0);

    return { label, income: monthIncome, expenses: monthExpenses };
  });

  // Find the max value across all months so we can scale bar heights
  const maxValue = Math.max(
    ...chartData.map(d => Math.max(d.income, d.expenses)),
    1 // avoid division by zero
  );

  const BAR_MAX_HEIGHT = 80; // max bar height in pixels

  return (
    <View style={styles.chartCard}>
      <Text style={styles.sectionTitle}>Last 6 Months</Text>

      {/* Legend */}
      <View style={styles.chartLegend}>
        <View style={styles.legendItem}>
          <View style={[styles.legendDot, { backgroundColor: colors.success }]} />
          <Text style={styles.legendLabel}>Income</Text>
        </View>
        <View style={styles.legendItem}>
          <View style={[styles.legendDot, { backgroundColor: colors.danger }]} />
          <Text style={styles.legendLabel}>Expenses</Text>
        </View>
      </View>

      {/* Bar chart — two bars per month (income + expenses) */}
      <View style={styles.chartArea}>
        {chartData.map((month, index) => (
          <View key={index} style={styles.chartMonthGroup}>
            {/* Income bar */}
            <View style={[styles.chartBarWrapper, { height: BAR_MAX_HEIGHT }]}>
              <View style={[
                styles.chartBar,
                {
                  height: (month.income / maxValue) * BAR_MAX_HEIGHT,
                  backgroundColor: colors.success,
                }
              ]} />
            </View>

            {/* Expenses bar */}
            <View style={[styles.chartBarWrapper, { height: BAR_MAX_HEIGHT }]}>
              <View style={[
                styles.chartBar,
                {
                  height: (month.expenses / maxValue) * BAR_MAX_HEIGHT,
                  backgroundColor: colors.danger,
                }
              ]} />
            </View>

            {/* Month label */}
            <Text style={styles.chartMonthLabel}>{month.label}</Text>
          </View>
        ))}
      </View>
    </View>
  );
};

// Accounts receivable + pipeline card — always reflects current state, not period-filtered
const ReceivablesCard = ({ invoices, jobs }) => {
  const today = new Date();
  today.setHours(0, 0, 0, 0);

  const unpaid = invoices.filter(inv => !inv.paid);
  const totalOutstanding = unpaid.reduce((s, inv) => s + (parseFloat(inv.amount) || 0), 0);
  const overdue = unpaid.filter(inv => inv.due && new Date(inv.due) < today);
  const totalOverdue = overdue.reduce((s, inv) => s + (parseFloat(inv.amount) || 0), 0);

  const pipelineJobs = jobs.filter(
    j => ['lead','estimate_sent','approved','scheduled','in_progress','complete'].includes(j.status) && j.estimateTotal > 0
  );
  const pipelineValue = pipelineJobs.reduce((s, j) => s + j.estimateTotal, 0);

  if (totalOutstanding === 0 && pipelineValue === 0) return null;

  return (
    <View style={styles.receivablesCard}>
      <Text style={styles.receivablesTitle}>Money owed to you</Text>
      <View style={styles.summaryRow}>
        <View style={styles.summaryColumn}>
          <Text style={styles.summaryColumnLabel}>Outstanding</Text>
          <Text style={styles.summaryAmount}>{formatCurrency(totalOutstanding)}</Text>
          <Text style={styles.receivablesSub}>{unpaid.length} invoice{unpaid.length !== 1 ? 's' : ''}</Text>
        </View>
        <View style={styles.summaryDivider} />
        <View style={styles.summaryColumn}>
          <Text style={styles.summaryColumnLabel}>Overdue</Text>
          <Text style={[styles.summaryAmount, { color: overdue.length > 0 ? colors.danger : colors.textMuted }]}>
            {formatCurrency(totalOverdue)}
          </Text>
          <Text style={styles.receivablesSub}>{overdue.length} invoice{overdue.length !== 1 ? 's' : ''}</Text>
        </View>
        <View style={styles.summaryDivider} />
        <View style={styles.summaryColumn}>
          <Text style={styles.summaryColumnLabel}>Pipeline</Text>
          <Text style={[styles.summaryAmount, { color: colors.accent }]}>{formatCurrency(pipelineValue)}</Text>
          <Text style={styles.receivablesSub}>{pipelineJobs.length} job{pipelineJobs.length !== 1 ? 's' : ''}</Text>
        </View>
      </View>
    </View>
  );
};

// Top customers by revenue for the selected period
const TopCustomersCard = ({ invoices, start, end }) => {
  const revenueByCustomer = {};
  invoices
    .filter(inv => inv.paid && inv.due && isInRange(inv.due, start, end))
    .forEach(inv => {
      revenueByCustomer[inv.customer] = (revenueByCustomer[inv.customer] || 0) + (parseFloat(inv.amount) || 0);
    });

  const top = Object.entries(revenueByCustomer)
    .map(([name, amount]) => ({ name, amount }))
    .sort((a, b) => b.amount - a.amount)
    .slice(0, 5);

  if (top.length === 0) return null;

  const maxAmount = top[0].amount;

  return (
    <View style={styles.categoryCard}>
      <Text style={styles.sectionTitle}>Top Customers</Text>
      {top.map((c, i) => (
        <View key={c.name} style={styles.categoryBreakdownRow}>
          <Text style={styles.topCustomerRank}>{i + 1}</Text>
          <View style={styles.categoryBreakdownInfo}>
            <View style={styles.categoryBreakdownHeader}>
              <Text style={styles.categoryBreakdownLabel} numberOfLines={1}>{c.name}</Text>
              <Text style={[styles.categoryBreakdownAmount, { color: colors.success }]}>
                {formatCurrency(c.amount)}
              </Text>
            </View>
            <View style={styles.categoryProgressBg}>
              <View style={[
                styles.categoryProgressFill,
                { width: `${(c.amount / maxAmount) * 100}%`, backgroundColor: colors.success, opacity: 1 },
              ]} />
            </View>
          </View>
        </View>
      ))}
    </View>
  );
};

// A single expense row in the list
const ExpenseRow = ({ expense, onDelete }) => {
  const category = EXPENSE_CATEGORIES.find(c => c.id === expense.category) || EXPENSE_CATEGORIES[7];
  const dateStr = new Date(expense.date).toLocaleDateString('en-US', { month: 'short', day: 'numeric' });

  return (
    <TouchableOpacity
      style={styles.expenseRow}
      onLongPress={() => {
        // Long press to delete — common mobile pattern
        Alert.alert(
          'Delete Expense',
          `Remove "${expense.description}"?`,
          [
            { text: 'Cancel', style: 'cancel' },
            { text: 'Delete', style: 'destructive', onPress: () => onDelete(expense.id) },
          ]
        );
      }}
    >
      <View style={styles.expenseIcon}>
        <Text style={styles.expenseIconText}>{category.icon}</Text>
      </View>

      <View style={styles.expenseDetails}>
        <Text style={styles.expenseDescription} numberOfLines={1}>
          {expense.description}
        </Text>
        <Text style={styles.expenseMeta}>
          {category.label} · {dateStr}{expense.receiptUri ? ' · 📷' : ''}
        </Text>
        {expense.notes ? (
          <Text style={styles.expenseNotes} numberOfLines={1}>{expense.notes}</Text>
        ) : null}
      </View>

      <Text style={styles.expenseAmount}>{formatCurrency(expense.amount)}</Text>
    </TouchableOpacity>
  );
};

// ─── ADD EXPENSE MODAL ────────────────────────────────────────────────────────
// This is the bottom sheet that slides up when you tap "Add Expense"

const AddExpenseModal = ({ visible, onClose, onSave }) => {
  // Form state — one piece of state per field
  const [description, setDescription] = useState('');
  const [amount, setAmount]           = useState('');
  const [category, setCategory]       = useState('materials');
  const [date, setDate]               = useState(new Date().toISOString().split('T')[0]);
  const [notes, setNotes]             = useState('');
  const [receiptUri, setReceiptUri]   = useState(null);
  const [showDatePicker, setShowDatePicker] = useState(false);

  // Reset form when modal opens
  useEffect(() => {
    if (visible) {
      setDescription('');
      setAmount('');
      setCategory('materials');
      setDate(new Date().toISOString().split('T')[0]);
      setNotes('');
      setReceiptUri(null);
      setShowDatePicker(false);
    }
  }, [visible]);

  async function pickReceipt() {
    Alert.alert('Add Receipt Photo', null, [
      {
        text: 'Take Photo',
        onPress: async () => {
          const { status } = await ImagePicker.requestCameraPermissionsAsync();
          if (status !== 'granted') {
            Alert.alert('Permission needed', 'Camera access is required to take a photo.');
            return;
          }
          const result = await ImagePicker.launchCameraAsync({
            mediaTypes: ['images'],
            quality: 0.7,
            allowsEditing: true,
            aspect: [4, 3],
          });
          if (!result.canceled) setReceiptUri(result.assets[0].uri);
        },
      },
      {
        text: 'Choose from Library',
        onPress: async () => {
          const { status } = await ImagePicker.requestMediaLibraryPermissionsAsync();
          if (status !== 'granted') {
            Alert.alert('Permission needed', 'Photo library access is required.');
            return;
          }
          const result = await ImagePicker.launchImageLibraryAsync({
            mediaTypes: ['images'],
            quality: 0.7,
            allowsEditing: true,
            aspect: [4, 3],
          });
          if (!result.canceled) setReceiptUri(result.assets[0].uri);
        },
      },
      { text: 'Cancel', style: 'cancel' },
    ]);
  }

  const handleSave = () => {
    // Validate required fields
    if (!description.trim()) {
      Alert.alert('Missing Info', 'Please enter a description.');
      return;
    }
    if (!amount || isNaN(parseFloat(amount)) || parseFloat(amount) <= 0) {
      Alert.alert('Missing Info', 'Please enter a valid amount.');
      return;
    }

    onSave({
      id:          generateId(),
      description: description.trim(),
      amount:      parseFloat(amount),
      category,
      date:        date || new Date().toISOString().split('T')[0],
      notes:       notes.trim(),
      receiptUri:  receiptUri || null,
      createdAt:   new Date().toISOString(),
    });
  };

  const onCloseRef = useRef(onClose);
  onCloseRef.current = onClose;

  const translateY = useRef(new Animated.Value(600)).current;

  // Slide the sheet in when the modal becomes visible, reset form fields
  useEffect(() => {
    if (visible) {
      translateY.setValue(600);
      Animated.spring(translateY, {
        toValue: 0,
        useNativeDriver: true,
        damping: 25,
        stiffness: 250,
      }).start();
      setDescription('');
      setAmount('');
      setCategory('materials');
      setDate(new Date().toISOString().split('T')[0]);
      setNotes('');
      setReceiptUri(null);
      setShowDatePicker(false);
    }
  }, [visible]);

  // Single dismiss path — slide sheet out, then close. Used by every close trigger
  // so there is never a competing animation from the Modal itself.
  const dismissRef = useRef(null);
  dismissRef.current = () => {
    Animated.timing(translateY, {
      toValue: 600,
      duration: 220,
      useNativeDriver: true,
    }).start(() => {
      translateY.setValue(600);
      onCloseRef.current();
    });
  };
  const dismiss = () => dismissRef.current();

  const panResponder = useRef(
    PanResponder.create({
      onStartShouldSetPanResponder: () => true,
      onPanResponderTerminationRequest: () => false,
      onPanResponderMove: (_, { dy }) => {
        if (dy > 0) translateY.setValue(dy);
      },
      onPanResponderRelease: (_, { dy, vy }) => {
        if (dy > 80 || vy > 0.5) {
          dismissRef.current();
        } else {
          Animated.spring(translateY, {
            toValue: 0,
            useNativeDriver: true,
            bounciness: 6,
          }).start();
        }
      },
    })
  ).current;

  return (
    <Modal visible={visible} animationType="none" transparent onRequestClose={dismiss}>
      <View style={styles.modalBackdrop}>
        {/* Tappable dark area above the sheet closes it */}
        <TouchableOpacity style={{ flex: 1 }} activeOpacity={1} onPress={dismiss} />

        {/* Sheet slides with the drag gesture */}
        <Animated.View style={[styles.modalSheet, { transform: [{ translateY }] }]}>

          {/* Drag handle — pan responder lives here, outside the ScrollView */}
          <View {...panResponder.panHandlers} style={styles.modalHandleArea}>
            <View style={styles.modalHandle} />
          </View>

          <ScrollView
            showsVerticalScrollIndicator={false}
            keyboardShouldPersistTaps="handled"
            onScrollEndDrag={({ nativeEvent }) => {
              if (Platform.OS === 'ios' && nativeEvent.contentOffset.y < -60) {
                dismiss();
              }
            }}
          >
            <Text style={styles.modalTitle}>Log Expense</Text>

            {/* Description field */}
            <Text style={styles.fieldLabel}>What was it?</Text>
            <TextInput
              style={styles.textInput}
              placeholder="e.g. PVC fittings from Home Depot"
              placeholderTextColor={colors.textMuted}
              value={description}
              onChangeText={setDescription}
            />

            {/* Amount field */}
            <Text style={styles.fieldLabel}>Amount</Text>
            <TextInput
              style={styles.textInput}
              placeholder="0.00"
              placeholderTextColor={colors.textMuted}
              value={amount}
              onChangeText={setAmount}
              keyboardType="decimal-pad"
            />

            {/* Date field */}
            <Text style={styles.fieldLabel}>Date</Text>
            <TouchableOpacity style={styles.expenseDateBtn} onPress={() => setShowDatePicker(true)}>
              <Text style={styles.expenseDateBtnText}>
                {new Date(date + 'T00:00:00').toLocaleDateString('en-US', {
                  weekday: 'long', month: 'long', day: 'numeric',
                })}
              </Text>
              <Text>📅</Text>
            </TouchableOpacity>

            {showDatePicker && (
              Platform.OS === 'ios' ? (
                <Modal transparent animationType="slide">
                  <View style={styles.expenseDateOverlay}>
                    <View style={styles.expenseDateSheet}>
                      <View style={styles.expenseDateHeader}>
                        <Text style={styles.expenseDateTitle}>Select Date</Text>
                        <TouchableOpacity onPress={() => setShowDatePicker(false)}>
                          <Text style={styles.expenseDateDone}>Done</Text>
                        </TouchableOpacity>
                      </View>
                      <DateTimePicker
                        value={new Date(date + 'T00:00:00')}
                        mode="date"
                        display="inline"
                        themeVariant="light"
                        accentColor={colors.accent}
                        onChange={(_, d) => { if (d) setDate(d.toISOString().split('T')[0]); }}
                        style={{ alignSelf: 'center' }}
                      />
                    </View>
                  </View>
                </Modal>
              ) : (
                <DateTimePicker
                  value={new Date(date + 'T00:00:00')}
                  mode="date"
                  display="default"
                  themeVariant="light"
                  onChange={(event, d) => {
                    setShowDatePicker(false);
                    if (event.type === 'set' && d) setDate(d.toISOString().split('T')[0]);
                  }}
                />
              )
            )}

            {/* Category picker */}
            <Text style={styles.fieldLabel}>Category</Text>
            <ScrollView horizontal showsHorizontalScrollIndicator={false} style={styles.categoryScroll}>
              {EXPENSE_CATEGORIES.map(cat => (
                <TouchableOpacity
                  key={cat.id}
                  style={[styles.categoryChip, category === cat.id && styles.categoryChipSelected]}
                  onPress={() => setCategory(cat.id)}
                >
                  <Text style={styles.categoryChipIcon}>{cat.icon}</Text>
                  <Text style={[styles.categoryChipLabel, category === cat.id && styles.categoryChipLabelSelected]}>
                    {cat.label}
                  </Text>
                </TouchableOpacity>
              ))}
            </ScrollView>

            {/* Notes */}
            <Text style={styles.fieldLabel}>Notes <Text style={styles.optionalLabel}>(optional)</Text></Text>
            <TextInput
              style={[styles.textInput, styles.textInputMultiline]}
              placeholder="Job number, vendor, receipt #..."
              placeholderTextColor={colors.textMuted}
              value={notes}
              onChangeText={setNotes}
              multiline
              numberOfLines={3}
            />

            {/* Receipt photo */}
            <Text style={styles.fieldLabel}>
              Receipt photo <Text style={styles.optionalLabel}>(optional)</Text>
            </Text>
            {receiptUri ? (
              <View style={styles.receiptPreview}>
                <Image source={{ uri: receiptUri }} style={styles.receiptImage} />
                <TouchableOpacity style={styles.receiptRemoveRow} onPress={() => setReceiptUri(null)}>
                  <Text style={styles.receiptRemoveText}>✕  Remove photo</Text>
                </TouchableOpacity>
              </View>
            ) : (
              <TouchableOpacity style={styles.receiptBtn} onPress={pickReceipt}>
                <Text style={styles.receiptBtnText}>📷  Add receipt photo</Text>
              </TouchableOpacity>
            )}

            {/* Action buttons */}
            <View style={styles.modalActions}>
              <TouchableOpacity style={styles.cancelButton} onPress={dismiss}>
                <Text style={styles.cancelButtonText}>Cancel</Text>
              </TouchableOpacity>
              <TouchableOpacity style={styles.saveButton} onPress={handleSave}>
                <Text style={styles.saveButtonText}>Save Expense</Text>
              </TouchableOpacity>
            </View>
          </ScrollView>
        </Animated.View>
      </View>
    </Modal>
  );
};

// ─── MAIN SCREEN ─────────────────────────────────────────────────────────────

export default function MoneyScreen() {
  // Core data state
  const [invoices, setInvoices]   = useState([]);
  const [expenses, setExpenses]   = useState([]);
  const [jobs, setJobs]           = useState([]);
  const [loading, setLoading]     = useState(true);

  // UI state
  const [activeFilter, setActiveFilter] = useState('this_month');
  const [showAddModal, setShowAddModal] = useState(false);
  const [activeTab, setActiveTab]       = useState('overview'); // 'overview' | 'expenses'


  // Reload data every time this tab comes into focus, not just on first mount.
  // This ensures the P&L updates immediately after logging an expense elsewhere.
  useFocusEffect(
    useCallback(() => {
      loadData();
    }, [])
  );

  const loadData = async () => {
    try {
      const [invs, exps, jbs] = await Promise.all([loadInvoices(), loadExpenses(), loadJobs()]);
      setInvoices(invs);
      setExpenses(exps);
      setJobs(jbs);
    } catch (error) {
      console.error('MoneyScreen: failed to load data', error);
    } finally {
      setLoading(false);
    }
  };

  // ── Save expenses to AsyncStorage whenever the list changes ────────────────
  // useCallback memoizes the function so it doesn't get recreated unnecessarily
  const persistExpenses = useCallback(async (updatedExpenses) => {
    try {
      await saveExpenses(updatedExpenses);
    } catch (error) {
      console.error('MoneyScreen: failed to save expenses', error);
    }
  }, []);

  // ── Add a new expense ──────────────────────────────────────────────────────
  const handleAddExpense = (newExpense) => {
    const updated = [newExpense, ...expenses]; // newest first
    setExpenses(updated);
    persistExpenses(updated);
    setShowAddModal(false);
  };

  // ── Delete an expense ──────────────────────────────────────────────────────
  const handleDeleteExpense = (id) => {
    const updated = expenses.filter(e => e.id !== id);
    setExpenses(updated);
    persistExpenses(updated);
  };

  // ── Filter calculations ────────────────────────────────────────────────────
  // These recalculate whenever the filter or data changes
  const { start, end } = getDateRange(activeFilter);

  // Income = sum of paid invoice amounts within the date range
  // NOTE: invoices use paid:true (boolean) and inv.due for the date
  const filteredIncome = invoices
    .filter(inv => {
      const isPaid = inv.paid === true;
      const dateToCheck = inv.due;
      return isPaid && dateToCheck && isInRange(dateToCheck, start, end);
    })
    .reduce((sum, inv) => sum + (parseFloat(inv.amount) || 0), 0);

  // Expenses = sum of all logged expenses within the date range
  const filteredExpenses = expenses
    .filter(exp => exp.date && isInRange(exp.date, start, end));

  const filteredExpenseTotal = filteredExpenses
    .reduce((sum, exp) => sum + (parseFloat(exp.amount) || 0), 0);

  // Expenses grouped by category — for the breakdown view
  const expensesByCategory = EXPENSE_CATEGORIES.map(cat => {
    const total = filteredExpenses
      .filter(exp => exp.category === cat.id)
      .reduce((sum, exp) => sum + (parseFloat(exp.amount) || 0), 0);
    return { ...cat, total };
  }).filter(cat => cat.total > 0)
    .sort((a, b) => b.total - a.total);

  // Previous period — for MoM/YoY comparison badges
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

  // Active filter label for the summary card
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
      {/* ── Date Filter Tabs ────────────────────────────────────────────── */}
      <ScrollView
        horizontal
        showsHorizontalScrollIndicator={false}
        style={styles.filterScroll}
        contentContainerStyle={styles.filterScrollContent}
      >
        {DATE_FILTERS.map(filter => (
          <TouchableOpacity
            key={filter.id}
            style={[
              styles.filterChip,
              activeFilter === filter.id && styles.filterChipActive,
            ]}
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

      {/* ── Main Content Tabs ───────────────────────────────────────────── */}
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

      {/* ── Overview Tab ────────────────────────────────────────────────── */}
      {activeTab === 'overview' && (
        <ScrollView style={styles.scrollContent} showsVerticalScrollIndicator={false}>
          {/* P&L Summary */}
          <SummaryCard
            income={filteredIncome}
            expenses={filteredExpenseTotal}
            prevIncome={prevFilteredIncome}
            prevExpenses={prevFilteredExpenseTotal}
            label={activeFilterLabel}
            onAddExpense={() => setShowAddModal(true)}
          />

          {/* Receivables + Pipeline */}
          <ReceivablesCard invoices={invoices} jobs={jobs} />

          {/* Monthly Chart */}
          <MonthlyChart invoices={invoices} expenses={expenses} />

          {/* Expense Breakdown by Category */}
          {expensesByCategory.length > 0 && (
            <View style={styles.categoryCard}>
              <Text style={styles.sectionTitle}>Expenses by Category</Text>
              {expensesByCategory.map(cat => {
                // Calculate what % of total expenses this category represents
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
                      {/* Mini progress bar */}
                      <View style={styles.categoryProgressBg}>
                        <View style={[
                          styles.categoryProgressFill,
                          { width: `${pct}%` }
                        ]} />
                      </View>
                    </View>
                  </View>
                );
              })}
            </View>
          )}

          {/* Top Customers */}
          <TopCustomersCard invoices={invoices} start={start} end={end} />

          {/* Empty state — no data yet */}
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

      {/* ── Expenses Tab ────────────────────────────────────────────────── */}
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

      {/* ── Add Expense Modal ────────────────────────────────────────────── */}
      <AddExpenseModal
        visible={showAddModal}
        onClose={() => setShowAddModal(false)}
        onSave={handleAddExpense}
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
  addExpenseBtn: {
    backgroundColor: colors.accent,
    paddingHorizontal: 14,
    paddingVertical: 6,
    borderRadius: radius.full,
    alignItems: 'center',
    justifyContent: 'center',
  },
  addExpenseBtnText: {
    color: colors.textOnAccent,
    fontWeight: '700',
    fontSize: fontSize.sm,
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
    // accentBg is the light blue tint — semantic equivalent of the old dark accentDim
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
    // Active pill sits on the grouped background — subtle lift effect
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

  // ── Summary card
  summaryCard: {
    marginHorizontal: spacing.lg,
    marginBottom: spacing.md,
    backgroundColor: colors.surface,
    borderRadius: radius.lg,
    padding: spacing.lg,
    borderWidth: 1,
    borderColor: colors.border,
    ...shadow.card,
  },
  summaryCardHeader: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    marginBottom: spacing.md,
  },
  summaryPeriodLabel: {
    color: colors.textSecondary,
    fontSize: fontSize.sm,
    fontWeight: '500',
    textTransform: 'uppercase',
    letterSpacing: 0.5,
  },
  summaryRow: {
    flexDirection: 'row',
    alignItems: 'center',
  },
  summaryColumn: {
    flex: 1,
    alignItems: 'center',
  },
  summaryColumnLabel: {
    color: colors.textSecondary,
    fontSize: fontSize.xs,
    marginBottom: 6,
  },
  summaryAmount: {
    fontSize: fontSize.xl - 4,
    fontWeight: '700',
    letterSpacing: -0.3,
  },
  summaryDivider: {
    width: 1,
    height: 40,
    backgroundColor: colors.border,
    marginHorizontal: spacing.sm,
  },
  marginBarContainer: {
    marginTop: spacing.md,
    flexDirection: 'row',
    alignItems: 'center',
    gap: 10,
  },
  marginBarBg: {
    flex: 1,
    height: 6,
    backgroundColor: colors.border,
    borderRadius: 3,
    overflow: 'hidden',
  },
  marginBarFill: {
    height: '100%',
    borderRadius: 3,
  },
  marginLabel: {
    color: colors.textSecondary,
    fontSize: fontSize.xs,
    minWidth: 70,
    textAlign: 'right',
  },

  // ── Monthly chart
  chartCard: {
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
  chartLegend: {
    flexDirection: 'row',
    gap: spacing.md,
    marginBottom: spacing.md,
  },
  legendItem: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 6,
  },
  legendDot: {
    width: 8,
    height: 8,
    borderRadius: 4,
  },
  legendLabel: {
    color: colors.textSecondary,
    fontSize: fontSize.xs,
  },
  chartArea: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'flex-end',
  },
  chartMonthGroup: {
    alignItems: 'center',
    flex: 1,
  },
  chartBarWrapper: {
    width: 12,
    justifyContent: 'flex-end',
    marginHorizontal: 2,
  },
  chartBar: {
    width: '100%',
    borderRadius: 3,
    minHeight: 2,
  },
  chartMonthLabel: {
    color: colors.textMuted,
    fontSize: fontSize.xs,
    marginTop: 6,
  },

  // ── MoM change label
  changeLabel: {
    fontSize: fontSize.xs,
    fontWeight: '600',
    marginTop: 2,
  },

  // ── Receivables card
  receivablesCard: {
    marginHorizontal: spacing.lg,
    marginBottom: spacing.md,
    backgroundColor: colors.surface,
    borderRadius: radius.lg,
    padding: spacing.lg,
    borderWidth: 1,
    borderColor: colors.border,
    ...shadow.card,
  },
  receivablesTitle: {
    color: colors.textSecondary,
    fontSize: fontSize.sm,
    fontWeight: '500',
    textTransform: 'uppercase',
    letterSpacing: 0.5,
    marginBottom: spacing.md,
  },
  receivablesSub: {
    color: colors.textMuted,
    fontSize: fontSize.xs,
    marginTop: 2,
  },

  // ── Top customers rank number
  topCustomerRank: {
    fontSize: fontSize.sm,
    fontWeight: '700',
    color: colors.textMuted,
    width: 20,
    marginRight: spacing.sm,
    textAlign: 'center',
  },

  // ── Category breakdown
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
  expenseRow: {
    flexDirection: 'row',
    alignItems: 'center',
    backgroundColor: colors.surface,
    borderRadius: radius.md,
    padding: 14,
    marginBottom: spacing.sm,
    borderWidth: 1,
    borderColor: colors.border,
    ...shadow.card,
  },
  expenseIcon: {
    width: 40,
    height: 40,
    borderRadius: radius.sm + 2,
    // surfaceSecondary is the light theme equivalent of the old dark inputBg
    backgroundColor: colors.surfaceSecondary,
    alignItems: 'center',
    justifyContent: 'center',
    marginRight: spacing.md,
  },
  expenseIconText: {
    fontSize: 18,
  },
  expenseDetails: {
    flex: 1,
    marginRight: spacing.md,
  },
  expenseDescription: {
    color: colors.textPrimary,
    fontSize: fontSize.md,
    fontWeight: '600',
    marginBottom: 2,
  },
  expenseMeta: {
    color: colors.textSecondary,
    fontSize: fontSize.xs,
  },
  expenseNotes: {
    color: colors.textMuted,
    fontSize: fontSize.xs - 1,
    marginTop: 2,
  },
  expenseAmount: {
    color: colors.danger,
    fontSize: fontSize.md,
    fontWeight: '700',
  },

  // ── Add Expense Modal
  modalBackdrop: {
    flex: 1,
    backgroundColor: 'rgba(0,0,0,0.4)',
  },
  modalSheet: {
    backgroundColor: colors.surface,
    borderTopLeftRadius: radius.lg + 8,
    borderTopRightRadius: radius.lg + 8,
    padding: spacing.lg,
    maxHeight: '90%',
  },
  modalHandleArea: {
    paddingVertical: 14,
    alignItems: 'center',
  },
  modalHandle: {
    width: 40,
    height: 4,
    backgroundColor: colors.borderStrong,
    borderRadius: 2,
  },
  modalTitle: {
    color: colors.textPrimary,
    fontSize: fontSize.xl,
    fontWeight: '700',
    marginBottom: spacing.lg,
  },
  fieldLabel: {
    color: colors.textSecondary,
    fontSize: fontSize.sm,
    fontWeight: '500',
    marginBottom: spacing.sm,
    marginTop: spacing.xs,
  },
  optionalLabel: {
    color: colors.textMuted,
    fontWeight: '400',
  },
  textInput: {
    // surfaceSecondary gives inputs a subtle inset feel on a white modal
    backgroundColor: colors.surfaceSecondary,
    borderRadius: radius.sm + 2,
    padding: 14,
    color: colors.textPrimary,
    fontSize: fontSize.md,
    marginBottom: spacing.md,
    borderWidth: 1,
    borderColor: colors.border,
  },
  textInputMultiline: {
    minHeight: 80,
    textAlignVertical: 'top',
  },
  categoryScroll: {
    marginBottom: spacing.md,
  },
  categoryChip: {
    flexDirection: 'row',
    alignItems: 'center',
    backgroundColor: colors.surfaceSecondary,
    borderRadius: radius.full,
    paddingHorizontal: spacing.md,
    paddingVertical: spacing.sm,
    marginRight: spacing.sm,
    borderWidth: 1,
    borderColor: colors.border,
    gap: 6,
  },
  categoryChipSelected: {
    backgroundColor: colors.accentBg,
    borderColor: colors.accent,
  },
  categoryChipIcon: {
    fontSize: fontSize.sm,
  },
  categoryChipLabel: {
    color: colors.textSecondary,
    fontSize: fontSize.sm,
    fontWeight: '500',
  },
  categoryChipLabelSelected: {
    color: colors.accent,
    fontWeight: '600',
  },
  modalActions: {
    flexDirection: 'row',
    gap: spacing.md,
    marginTop: spacing.sm,
    paddingBottom: spacing.md,
  },
  cancelButton: {
    flex: 1,
    padding: spacing.md,
    borderRadius: radius.md,
    backgroundColor: colors.surfaceSecondary,
    alignItems: 'center',
    borderWidth: 1,
    borderColor: colors.border,
  },
  cancelButtonText: {
    color: colors.textSecondary,
    fontWeight: '600',
    fontSize: fontSize.md,
  },
  saveButton: {
    flex: 2,
    padding: spacing.md,
    borderRadius: radius.md,
    backgroundColor: colors.accent,
    alignItems: 'center',
  },
  saveButtonText: {
    color: colors.textOnAccent,
    fontWeight: '700',
    fontSize: fontSize.md,
  },

  // ── Expense date picker
  expenseDateBtn: {
    backgroundColor: colors.surfaceSecondary,
    borderRadius: radius.sm + 2,
    padding: 14,
    borderWidth: 1,
    borderColor: colors.border,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    marginBottom: spacing.md,
  },
  expenseDateBtnText: {
    fontSize: fontSize.md,
    color: colors.textPrimary,
  },
  expenseDateOverlay: {
    flex: 1,
    justifyContent: 'flex-end',
    backgroundColor: 'rgba(0,0,0,0.35)',
  },
  expenseDateSheet: {
    backgroundColor: colors.surface,
    borderTopLeftRadius: radius.lg,
    borderTopRightRadius: radius.lg,
    paddingHorizontal: spacing.md,
    paddingBottom: 40,
  },
  expenseDateHeader: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    paddingVertical: spacing.md,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: colors.border,
    marginBottom: spacing.sm,
  },
  expenseDateTitle: { fontSize: fontSize.md, fontWeight: '600', color: colors.textPrimary },
  expenseDateDone:  { fontSize: fontSize.md, fontWeight: '600', color: colors.accent },

  // ── Receipt photo
  receiptBtn: {
    backgroundColor: colors.surfaceSecondary,
    borderRadius: radius.sm + 2,
    padding: 14,
    borderWidth: 1,
    borderColor: colors.border,
    alignItems: 'center',
    marginBottom: spacing.md,
  },
  receiptBtnText: {
    color: colors.textSecondary,
    fontSize: fontSize.md,
  },
  receiptPreview: {
    borderRadius: radius.sm + 2,
    overflow: 'hidden',
    borderWidth: 1,
    borderColor: colors.border,
    marginBottom: spacing.md,
  },
  receiptImage: {
    width: '100%',
    height: 180,
    resizeMode: 'cover',
  },
  receiptRemoveRow: {
    padding: spacing.sm,
    alignItems: 'center',
    backgroundColor: colors.surfaceSecondary,
  },
  receiptRemoveText: {
    color: colors.danger,
    fontSize: fontSize.sm,
    fontWeight: '500',
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
