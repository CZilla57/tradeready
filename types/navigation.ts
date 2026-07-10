import type { NativeStackScreenProps } from '@react-navigation/native-stack';
import type { BottomTabScreenProps } from '@react-navigation/bottom-tabs';
import type { CompositeScreenProps, NavigatorScreenParams } from '@react-navigation/native';
import type { Customer } from './models';
import type { CustomerListEntry } from '../utils/customerList';

// ── Root Stack ──────────────────────────────────────────────────────────────

export type RootStackParamList = {
  Auth: undefined;
  Onboarding: undefined;
  Paywall: undefined;
  Main: NavigatorScreenParams<MainTabParamList>;
  PaywallModal: { canDismiss?: boolean };
};

// ── Bottom Tabs ─────────────────────────────────────────────────────────────

export type MainTabParamList = {
  Today: NavigatorScreenParams<TodayStackParamList>;
  Jobs: NavigatorScreenParams<JobStackParamList>;
  Invoices: NavigatorScreenParams<InvoiceStackParamList>;
  Customers: NavigatorScreenParams<CustomerStackParamList>;
  Money: NavigatorScreenParams<MoneyStackParamList>;
  AI: NavigatorScreenParams<ChatStackParamList>;
  Settings: undefined;
};

// ── Tab Stacks ──────────────────────────────────────────────────────────────

export type TodayStackParamList = {
  TodayHome: undefined;
  Route: undefined;
};

export type JobStackParamList = {
  JobList: undefined;
  JobDetail: { jobId: string };
  AddJob: { jobId?: string; focusSchedule?: boolean };
  PricingCalculator: { jobId: string };
  CreateInvoiceFromJob: { jobId: string };
  SendEstimate: { jobId: string };
  AddCustomer: { customerId?: string; customer?: Customer };
  Outreach: { invoiceId: string };
  RecurringJobs: undefined;
  ReviewRequest: { jobId: string };
};

export type InvoiceStackParamList = {
  InvoiceList: undefined;
  AddInvoice: { invoiceId?: string; prefill?: Record<string, unknown> };
  Outreach: { invoiceId: string };
};

export type CustomerStackParamList = {
  CustomerList: undefined;
  // CustomerDetailScreen consumes the customer-list rollup shape (invoices,
  // totalSpent, totalOwed) produced by utils/customerList.ts's
  // buildCustomerList — not the bare Customer record — so that's what
  // actually flows through this route's params.
  CustomerDetail: { customer: CustomerListEntry };
  AddCustomer: { customerId?: string; customer?: Customer };
  AddInvoice: { invoiceId?: string; prefill?: Record<string, unknown> };
  Outreach: { invoiceId: string };
};

export type MoneyStackParamList = {
  MoneyHome: undefined;
  MileageLog: { initialFilter?: string };
  AddTrip: { tripId?: string };
  Pricebook: undefined;
  PricebookEntry: { entryId?: string };
};

export type ChatStackParamList = {
  ChatHome: undefined;
};

// ── Global augmentation (enables useNavigation() without type param) ────────

declare global {
  namespace ReactNavigation {
    // This is the official React Navigation TS pattern: an `interface` (not `type`) is
    // required here so it declaration-merges with the ambient
    // ReactNavigation.RootParamList, which is what lets useNavigation()/Link/etc. be
    // typed app-wide without an explicit generic.
    // eslint-disable-next-line @typescript-eslint/no-empty-object-type -- see comment above
    interface RootParamList extends RootStackParamList {}
  }
}

// ── Screen prop helpers ─────────────────────────────────────────────────────

export type RootStackScreenProps<T extends keyof RootStackParamList> =
  NativeStackScreenProps<RootStackParamList, T>;

export type TodayStackScreenProps<T extends keyof TodayStackParamList> =
  CompositeScreenProps<
    NativeStackScreenProps<TodayStackParamList, T>,
    BottomTabScreenProps<MainTabParamList>
  >;

export type JobStackScreenProps<T extends keyof JobStackParamList> =
  CompositeScreenProps<
    NativeStackScreenProps<JobStackParamList, T>,
    BottomTabScreenProps<MainTabParamList>
  >;

export type InvoiceStackScreenProps<T extends keyof InvoiceStackParamList> =
  CompositeScreenProps<
    NativeStackScreenProps<InvoiceStackParamList, T>,
    BottomTabScreenProps<MainTabParamList>
  >;

export type CustomerStackScreenProps<T extends keyof CustomerStackParamList> =
  CompositeScreenProps<
    NativeStackScreenProps<CustomerStackParamList, T>,
    BottomTabScreenProps<MainTabParamList>
  >;

export type MoneyStackScreenProps<T extends keyof MoneyStackParamList> =
  CompositeScreenProps<
    NativeStackScreenProps<MoneyStackParamList, T>,
    BottomTabScreenProps<MainTabParamList>
  >;

export type ChatStackScreenProps<T extends keyof ChatStackParamList> =
  CompositeScreenProps<
    NativeStackScreenProps<ChatStackParamList, T>,
    BottomTabScreenProps<MainTabParamList>
  >;
