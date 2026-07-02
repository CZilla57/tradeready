// screens/CustomersScreen.js
// Searchable list of all customers, derived from invoices + manually added entries.

import React, { useState, useMemo, useCallback } from 'react';
import {
  View,
  Text,
  StyleSheet,
  FlatList,
  TouchableOpacity,
  TextInput,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { useFocusEffect } from '@react-navigation/native';
import { loadInvoices, loadCustomers } from '../utils/storage';
import { colors, spacing, radius, fontSize } from '../utils/theme';

// ─── HELPERS ──────────────────────────────────────────────────────────────────

const formatCurrency = (amount) =>
  '$' + amount.toLocaleString('en-US', { minimumFractionDigits: 0, maximumFractionDigits: 0 });

// Derives a unified customer list from invoices + manually added customers.
// Groups invoices by customer name, merges with manual entries, sorts by revenue.
const buildCustomerList = (invoices, manualCustomers) => {
  const map = {};

  invoices.forEach(inv => {
    const key = inv.customer?.trim().toLowerCase();
    if (!key) return;

    if (!map[key]) {
      map[key] = {
        id:         key,
        name:       inv.customer.trim(),
        email:      inv.email || '',
        phone:      inv.phone || '',
        invoices:   [],
        totalSpent: 0,
        totalOwed:  0,
        isManual:   false,
      };
    }

    map[key].invoices.push(inv);
    map[key].totalSpent += inv.paid ? (parseFloat(inv.amount) || 0) : 0;
    map[key].totalOwed  += !inv.paid ? (parseFloat(inv.amount) || 0) : 0;

    if (inv.email) map[key].email = inv.email;
    if (inv.phone) map[key].phone = inv.phone;
  });

  manualCustomers.forEach(mc => {
    const key = mc.name?.trim().toLowerCase();
    if (!key) return;

    if (map[key]) {
      if (!map[key].email && mc.email) map[key].email = mc.email;
      if (!map[key].phone && mc.phone) map[key].phone = mc.phone;
      if (mc.notes) map[key].notes = mc.notes;
      // Preserve the proper ID from the manual record so CustomerDetail can match jobs
      map[key].id = mc.id || map[key].id;
    } else {
      map[key] = {
        id:         mc.id || key,
        name:       mc.name.trim(),
        email:      mc.email || '',
        phone:      mc.phone || '',
        notes:      mc.notes || '',
        invoices:   [],
        totalSpent: 0,
        totalOwed:  0,
        isManual:   true,
      };
    }
  });

  return Object.values(map).sort((a, b) => b.totalSpent - a.totalSpent);
};

// ─── CUSTOMER ROW ─────────────────────────────────────────────────────────────

const CustomerRow = ({ customer, onPress }) => {
  const invoiceCount = customer.invoices.length;
  const hasOwed = customer.totalOwed > 0;

  const initials = customer.name
    .split(' ')
    .map(w => w[0])
    .slice(0, 2)
    .join('')
    .toUpperCase();

  return (
    <TouchableOpacity style={styles.row} onPress={() => onPress(customer)} activeOpacity={0.7}>
      <View style={styles.avatar}>
        <Text style={styles.avatarText}>{initials}</Text>
      </View>

      <View style={styles.rowInfo}>
        <Text style={styles.rowName} numberOfLines={1}>{customer.name}</Text>
        <Text style={styles.rowMeta}>
          {invoiceCount === 0
            ? 'No invoices yet'
            : `${invoiceCount} invoice${invoiceCount !== 1 ? 's' : ''}`}
          {hasOwed ? ` · ${formatCurrency(customer.totalOwed)} owed` : ''}
        </Text>
      </View>

      <View style={styles.rowRight}>
        {customer.totalSpent > 0 && (
          <Text style={styles.rowSpent}>{formatCurrency(customer.totalSpent)}</Text>
        )}
        <Text style={styles.rowChevron}>›</Text>
      </View>
    </TouchableOpacity>
  );
};

// ─── MAIN SCREEN ──────────────────────────────────────────────────────────────

export default function CustomersScreen({ navigation }) {
  const [invoices, setInvoices]             = useState([]);
  const [manualCustomers, setManualCustomers] = useState([]);
  const [searchText, setSearchText]         = useState('');
  const [loading, setLoading]               = useState(true);

  useFocusEffect(
    useCallback(() => {
      loadData();
    }, [])
  );

  const loadData = async () => {
    try {
      const [invs, custs] = await Promise.all([loadInvoices(), loadCustomers()]);
      setInvoices(invs || []);
      setManualCustomers(custs || []);
    } catch (err) {
      console.error('CustomersScreen: failed to load data', err);
    } finally {
      setLoading(false);
    }
  };

  const allCustomers = useMemo(
    () => buildCustomerList(invoices, manualCustomers),
    [invoices, manualCustomers]
  );

  const filteredCustomers = useMemo(() => {
    if (!searchText.trim()) return allCustomers;
    const q = searchText.toLowerCase();
    return allCustomers.filter(c =>
      c.name.toLowerCase().includes(q) ||
      c.email.toLowerCase().includes(q) ||
      c.phone.includes(q)
    );
  }, [allCustomers, searchText]);

  const handlePress = useCallback((customer) => {
    navigation.navigate('CustomerDetail', { customer });
  }, [navigation]);

  const totalCustomers = allCustomers.length;
  const totalRevenue   = allCustomers.reduce((sum, c) => sum + c.totalSpent, 0);

  return (
    <SafeAreaView style={styles.container} edges={['bottom']}>
      <View style={styles.header}>
        <View>
          <Text style={styles.headerTitle}>Customers</Text>
          <Text style={styles.headerSub}>
            {totalCustomers} {totalCustomers === 1 ? 'customer' : 'customers'}
            {totalRevenue > 0 ? ` · ${formatCurrency(totalRevenue)} collected` : ''}
          </Text>
        </View>
        <TouchableOpacity
          style={styles.addButton}
          onPress={() => navigation.navigate('AddCustomer')}
        >
          <Text style={styles.addButtonText}>+ Add</Text>
        </TouchableOpacity>
      </View>

      <View style={styles.searchContainer}>
        <Text style={styles.searchIcon}>🔍</Text>
        <TextInput
          style={styles.searchInput}
          placeholder="Search by name, email, or phone"
          placeholderTextColor={colors.textMuted}
          value={searchText}
          onChangeText={setSearchText}
          autoCorrect={false}
          clearButtonMode="while-editing"
        />
      </View>

      <FlatList
        data={filteredCustomers}
        keyExtractor={item => item.id}
        renderItem={({ item }) => (
          <CustomerRow customer={item} onPress={handlePress} />
        )}
        ItemSeparatorComponent={() => <View style={styles.separator} />}
        contentContainerStyle={styles.listContent}
        ListEmptyComponent={
          <View style={styles.emptyState}>
            <Text style={styles.emptyIcon}>👷</Text>
            <Text style={styles.emptyTitle}>
              {searchText ? 'No customers found' : 'No customers yet'}
            </Text>
            <Text style={styles.emptyBody}>
              {searchText
                ? 'Try a different name, email, or phone number.'
                : 'Customers appear here automatically when you create invoices.'}
            </Text>
          </View>
        }
      />
    </SafeAreaView>
  );
}

// ─── STYLES ───────────────────────────────────────────────────────────────────

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: colors.background,
  },

  // Header
  header: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingHorizontal: spacing.md,
    paddingTop: spacing.sm,
    paddingBottom: spacing.md,
  },
  headerTitle: {
    fontSize: fontSize.xxl,
    fontWeight: '700',
    color: colors.textPrimary,
    letterSpacing: -0.5,
  },
  headerSub: {
    fontSize: fontSize.sm,
    color: colors.textSecondary,
    marginTop: 2,
  },
  addButton: {
    backgroundColor: colors.accent,
    paddingHorizontal: spacing.md,
    paddingVertical: spacing.sm,
    borderRadius: radius.full,
  },
  addButtonText: {
    color: colors.textOnAccent,
    fontWeight: '700',
    fontSize: fontSize.sm,
  },

  // Search
  searchContainer: {
    flexDirection: 'row',
    alignItems: 'center',
    backgroundColor: colors.surface,
    marginHorizontal: spacing.md,
    marginBottom: spacing.md,
    borderRadius: radius.md,
    paddingHorizontal: spacing.md,
    borderWidth: 1,
    borderColor: colors.border,
  },
  searchIcon: {
    fontSize: 16,
    marginRight: spacing.sm,
  },
  searchInput: {
    flex: 1,
    height: 44,
    color: colors.textPrimary,
    fontSize: fontSize.md,
  },

  // List
  listContent: {
    paddingHorizontal: spacing.md,
    paddingBottom: 100,
  },
  separator: {
    height: 1,
    backgroundColor: colors.border,
  },

  // Customer row
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingVertical: spacing.md,
  },
  avatar: {
    width: 44,
    height: 44,
    borderRadius: radius.full,
    backgroundColor: colors.accentBg,
    alignItems: 'center',
    justifyContent: 'center',
    marginRight: spacing.md,
    borderWidth: 1,
    borderColor: colors.accent + '40',
  },
  avatarText: {
    color: colors.accent,
    fontSize: fontSize.md,
    fontWeight: '700',
  },
  rowInfo: {
    flex: 1,
  },
  rowName: {
    color: colors.textPrimary,
    fontSize: fontSize.md,
    fontWeight: '600',
    marginBottom: 3,
  },
  rowMeta: {
    color: colors.textSecondary,
    fontSize: fontSize.sm,
  },
  rowRight: {
    alignItems: 'flex-end',
    gap: 2,
  },
  rowSpent: {
    color: colors.success,
    fontSize: fontSize.md,
    fontWeight: '700',
  },
  rowChevron: {
    color: colors.textMuted,
    fontSize: 20,
    lineHeight: 22,
  },

  // Empty state
  emptyState: {
    alignItems: 'center',
    paddingTop: 80,
    paddingHorizontal: 40,
  },
  emptyIcon: {
    fontSize: 48,
    marginBottom: spacing.md,
  },
  emptyTitle: {
    color: colors.textPrimary,
    fontSize: fontSize.lg,
    fontWeight: '600',
    marginBottom: spacing.sm,
    textAlign: 'center',
  },
  emptyBody: {
    color: colors.textSecondary,
    fontSize: fontSize.sm,
    textAlign: 'center',
    lineHeight: 20,
  },
});
