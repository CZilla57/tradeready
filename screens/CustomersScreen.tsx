// screens/CustomersScreen.tsx
// Searchable list of all customers, derived from invoices + manually added entries.

import React, { useState, useMemo, useCallback } from 'react';
import {
  View,
  Text,
  StyleSheet,
  FlatList,
  TouchableOpacity,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { Ionicons } from '@expo/vector-icons';
import { useFocusEffect } from '@react-navigation/native';
import { loadInvoices, loadCustomers } from '../utils/storage';
import { buildCustomerList, type CustomerListEntry } from '../utils/customerList';
import { SearchField } from '../components/SearchField';
import { Fab } from '../components/Fab';
import { spacing, radius, fontSize, fonts } from '../utils/theme';
import type { ColorScheme, ShadowScheme } from '../utils/theme';
import { formatMoney } from '../utils/format';
import { useTheme } from '../hooks/useTheme';
import { useRefresh } from '../hooks/useRefresh';
import type { Invoice, Customer } from '../types/models';
import { reportError } from '../utils/analytics';
import type { CustomerStackScreenProps } from '../types/navigation';

// ─── CUSTOMER ROW ─────────────────────────────────────────────────────────────

interface CustomerRowProps {
  customer: CustomerListEntry;
  onPress: (c: CustomerListEntry) => void;
}

const CustomerRow = ({ customer, onPress }: CustomerRowProps) => {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);

  const invoiceCount = customer.invoices.length;
  const hasOwed = customer.totalOwed > 0;

  const initials = customer.name
    .split(' ')
    .map((w: string) => w[0])
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
          {hasOwed ? ` · ${formatMoney(customer.totalOwed)} owed` : ''}
        </Text>
      </View>

      <View style={styles.rowRight}>
        {customer.totalSpent > 0 && (
          <Text style={styles.rowSpent}>{formatMoney(customer.totalSpent)}</Text>
        )}
        <Text style={styles.rowChevron}>›</Text>
      </View>
    </TouchableOpacity>
  );
};

// ─── MAIN SCREEN ──────────────────────────────────────────────────────────────

export default function CustomersScreen({ navigation }: CustomerStackScreenProps<'CustomerList'>) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);

  const [invoices, setInvoices]               = useState<Invoice[]>([]);
  const [manualCustomers, setManualCustomers]  = useState<Customer[]>([]);
  const [searchText, setSearchText]            = useState<string>('');

  useFocusEffect(
    useCallback(() => {
      loadData();
    }, [])
  );

  const { refreshing, onRefresh } = useRefresh(async () => {
    await loadData();
  }, 'CustomersScreen');

  const loadData = async () => {
    try {
      const [invs, custs] = await Promise.all([loadInvoices(), loadCustomers()]);
      setInvoices(invs || []);
      setManualCustomers(custs || []);
    } catch (err: unknown) {
      console.error('CustomersScreen: failed to load data', err);
      reportError(err, { context: 'customersScreenLoad' });
    }
  };

  const allCustomers = useMemo(
    () => buildCustomerList(invoices, manualCustomers),
    [invoices, manualCustomers]
  );

  const filteredCustomers = useMemo(() => {
    if (!searchText.trim()) return allCustomers;
    const q = searchText.toLowerCase();
    return allCustomers.filter((c) =>
      c.name.toLowerCase().includes(q) ||
      c.email.toLowerCase().includes(q) ||
      c.phone.includes(q)
    );
  }, [allCustomers, searchText]);

  const handlePress = useCallback((customer: CustomerListEntry) => {
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
            {totalRevenue > 0 ? ` · ${formatMoney(totalRevenue)} collected` : ''}
          </Text>
        </View>
      </View>

      <View style={styles.searchRow}>
        <SearchField
          value={searchText}
          onChangeText={setSearchText}
          placeholder="Search by name, email, or phone"
          accessibilityLabel="Search customers"
        />
      </View>

      <FlatList
        refreshing={refreshing}
        onRefresh={onRefresh}
        data={filteredCustomers}
        keyExtractor={(item) => item.id}
        renderItem={({ item }) => (
          <CustomerRow customer={item} onPress={handlePress} />
        )}
        ItemSeparatorComponent={() => <View style={styles.separator} />}
        contentContainerStyle={styles.listContent}
        ListEmptyComponent={
          <View style={styles.emptyState}>
            <Ionicons name="people-outline" size={44} color={colors.textMuted} style={styles.emptyIcon} />
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

      {/* FAB — matches the add pattern on Jobs and Invoices */}
      <Fab onPress={() => navigation.navigate('AddCustomer', {})} accessibilityLabel="Add new customer" />
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
    fontFamily: fonts.display,
    fontSize: fontSize.xxl,
    color: colors.textPrimary,
    letterSpacing: -0.3,
  },
  headerSub: {
    fontFamily: fonts.mono,
    fontSize: 11,
    color: colors.textSecondary,
    marginTop: 3,
  },
  // Search
  searchRow: {
    marginHorizontal: spacing.md,
    marginBottom: spacing.md,
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
    fontFamily: fonts.display,
    color: colors.accent,
    fontSize: fontSize.md,
  },
  rowInfo: {
    flex: 1,
  },
  rowName: {
    fontFamily: fonts.bodySemiBold,
    color: colors.textPrimary,
    fontSize: fontSize.md,
    marginBottom: 3,
  },
  rowMeta: {
    fontFamily: fonts.bodyRegular,
    color: colors.textSecondary,
    fontSize: fontSize.sm,
  },
  rowRight: {
    alignItems: 'flex-end',
    gap: 2,
  },
  rowSpent: {
    fontFamily: fonts.display,
    color: colors.success,
    fontSize: fontSize.md,
    fontVariant: ['tabular-nums'],
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
    marginBottom: spacing.md,
  },
  emptyTitle: {
    fontFamily: fonts.display,
    color: colors.textPrimary,
    fontSize: fontSize.lg,
    marginBottom: spacing.sm,
    textAlign: 'center',
  },
  emptyBody: {
    fontFamily: fonts.bodyRegular,
    color: colors.textSecondary,
    fontSize: fontSize.sm,
    textAlign: 'center',
    lineHeight: 20,
  },
  });
}
