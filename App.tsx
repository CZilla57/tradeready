import React, { useState, useEffect } from "react";
import { NavigationContainer, createNavigationContainerRef } from "@react-navigation/native";
import { createBottomTabNavigator } from "@react-navigation/bottom-tabs";
import { createNativeStackNavigator } from "@react-navigation/native-stack";
import { SafeAreaProvider } from "react-native-safe-area-context";
import { Text, View, ActivityIndicator, TouchableOpacity, Alert, Dimensions, Linking } from "react-native";
import { Ionicons } from "@expo/vector-icons";
import { useFonts } from "expo-font";
import { AuthProvider, useAuth } from "./context/AuthContext";
import { SubscriptionProvider, useSubscription } from "./context/SubscriptionContext";
import { ThemeProvider, useThemeContext } from "./context/ThemeContext";
import { SyncStatusProvider } from "./context/SyncStatusContext";
import { UndoProvider } from "./context/UndoContext";
import { SyncBanner } from "./components/SyncBanner";
import AuthScreen from "./screens/AuthScreen";
import OnboardingScreen from "./screens/OnboardingScreen";
import PaywallScreen from "./screens/PaywallScreen";
import StartingPointScreen from "./screens/StartingPointScreen";
import { isOnboardingComplete, isStartChoiceComplete } from "./utils/storage";
import { parseWidgetDeepLink, parsePendingOpenUrl } from "./utils/deepLinks";
import {
  getWidgetSharedItem,
  removeWidgetSharedItem,
  PENDING_OPEN_URL_KEY,
} from "./utils/widgetBridge";
// Side-effect import: registers the background-refresh task definition at
// module scope (TaskManager.defineTask must run before the OS can invoke it —
// see utils/backgroundRefresh.ts). AuthContext calls registerBackgroundRefresh().
import "./utils/backgroundRefresh";
import type {
  RootStackParamList,
  MainTabParamList,
  TodayStackParamList,
  JobStackParamList,
  InvoiceStackParamList,
  CustomerStackParamList,
  MoneyStackParamList,
  ChatStackParamList,
} from "./types/navigation";
import type { Invoice } from "./types/models";

import InvoicesScreen             from "./screens/InvoicesScreen";
import AddInvoiceScreen           from "./screens/AddInvoiceScreen";
import OutreachScreen             from "./screens/OutreachScreen";
import JobsScreen                 from "./screens/JobsScreen";
import JobDetailScreen            from "./screens/JobDetailScreen";
import AddJobScreen               from "./screens/AddJobScreen";
import AddChangeOrderScreen       from "./screens/AddChangeOrderScreen";
import PricingCalculatorScreen    from "./screens/PricingCalculatorScreen";
import CreateInvoiceFromJobScreen from "./screens/CreateInvoiceFromJobScreen";
import SendEstimateScreen         from "./screens/SendEstimateScreen";
import CustomersScreen            from "./screens/CustomersScreen";
import CustomerDetailScreen       from "./screens/CustomerDetailScreen";
import AddCustomerScreen          from "./screens/AddCustomerScreen";
import SettingsHubScreen from "./screens/SettingsHubScreen";
import SettingsBusinessScreen     from "./screens/SettingsBusinessScreen";
import SettingsAppearanceScreen   from "./screens/SettingsAppearanceScreen";
import SettingsPricingScreen      from "./screens/SettingsPricingScreen";
import SettingsInvoiceNumberingScreen from "./screens/SettingsInvoiceNumberingScreen";
import SettingsAIScreen           from "./screens/SettingsAIScreen";
import SettingsReviewsScreen      from "./screens/SettingsReviewsScreen";
import SettingsNotificationsScreen from "./screens/SettingsNotificationsScreen";
import SettingsPaymentsScreen      from "./screens/SettingsPaymentsScreen";
import SettingsBookingScreen       from "./screens/SettingsBookingScreen";
import SettingsSubscriptionScreen  from "./screens/SettingsSubscriptionScreen";
import SettingsAccountScreen       from "./screens/SettingsAccountScreen";
import SettingsImportScreen        from "./screens/SettingsImportScreen";
import TodayScreen                from "./screens/TodayScreen";
import MoneyScreen                from "./screens/MoneyScreen";
import ChatScreen                 from "./screens/ChatScreen";
import RouteScreen                from "./screens/RouteScreen";
import RecurringJobsScreen        from "./screens/RecurringJobsScreen";
import MileageLogScreen           from "./screens/MileageLogScreen";
import AddTripScreen              from "./screens/AddTripScreen";
import ReviewRequestScreen        from "./screens/ReviewRequestScreen";
import EstimateFollowUpScreen     from "./screens/EstimateFollowUpScreen";
import PricebookScreen            from "./screens/PricebookScreen";
import PricebookEntryScreen       from "./screens/PricebookEntryScreen";
import ExportDataScreen           from "./screens/ExportDataScreen";
import RecurringInvoicesScreen    from "./screens/RecurringInvoicesScreen";
import AddRecurringInvoiceScreen  from "./screens/AddRecurringInvoiceScreen";
import GlobalSearchScreen         from "./screens/GlobalSearchScreen";

import * as Notifications from "expo-notifications";

import { colors as staticColors, fontSize } from "./utils/theme";
import { loadSettings, loadInvoices, migrateCustomerIdentity, migrateSampleDataIds, applyEstimateDecisions, applyBookingRequests, scrubLegacySquareToken } from "./utils/storage";
import { migrateLegacyJobPhotos } from "./utils/photoSync";
import { registerPushToken } from "./utils/pushToken";
import { rootGateLoading } from "./utils/rootGate";
import { fontScaleChanged } from "./utils/fontScaleRestart";
import { getTradeNickname } from "./utils/pricingEngine";

import * as Sentry from "@sentry/react-native";
import { PostHogProvider, usePostHog, useNavigationTracker } from "posthog-react-native";
import Constants from "expo-constants";
import { posthogRef, track, reportError } from "./utils/analytics";

const SENTRY_DSN = Constants.expoConfig?.extra?.sentryDsn ?? "";
const POSTHOG_API_KEY = Constants.expoConfig?.extra?.posthogApiKey ?? "";
const POSTHOG_ENABLED = Boolean(POSTHOG_API_KEY) && !POSTHOG_API_KEY.startsWith("PLACEHOLDER");

if (SENTRY_DSN && !SENTRY_DSN.startsWith("PLACEHOLDER")) {
  Sentry.init({
    dsn: SENTRY_DSN,
    tracesSampleRate: 0.2,
    enableAutoSessionTracking: true,
    enabled: !__DEV__,
  });
}

const navigationRef = createNavigationContainerRef<RootStackParamList>();

const RootStack     = createNativeStackNavigator<RootStackParamList>();
const TodayStack    = createNativeStackNavigator<TodayStackParamList>();
const Tab           = createBottomTabNavigator<MainTabParamList>();
const JobStack      = createNativeStackNavigator<JobStackParamList>();
const InvoiceStack  = createNativeStackNavigator<InvoiceStackParamList>();
const CustomerStack = createNativeStackNavigator<CustomerStackParamList>();
const MoneyStack    = createNativeStackNavigator<MoneyStackParamList>();
const ChatStack     = createNativeStackNavigator<ChatStackParamList>();

// ── Tab stacks ────────────────────────────────────────────────────────────────

function TodayTab() {
  const { colors } = useThemeContext();
  const navOpts = {
    headerStyle:           { backgroundColor: colors.surface },
    headerTintColor:       colors.accent,
    headerTitleStyle:      { color: colors.textPrimary, fontWeight: "600" as const },
    headerBackTitleVisible: false,
  };
  return (
    <TodayStack.Navigator screenOptions={navOpts}>
      <TodayStack.Screen name="TodayHome" component={TodayScreen} options={{ headerShown: false }} />
      <TodayStack.Screen name="Route" component={RouteScreen} options={{ title: "Today's Route" }} />
      <TodayStack.Screen name="Settings" component={SettingsHubScreen} options={{ title: "Settings" }} />
      <TodayStack.Screen name="SettingsBusiness" component={SettingsBusinessScreen} options={{ title: "Business profile" }} />
      <TodayStack.Screen name="SettingsAppearance" component={SettingsAppearanceScreen} options={{ title: "Appearance" }} />
      <TodayStack.Screen name="SettingsPricing" component={SettingsPricingScreen} options={{ title: "Pricing defaults" }} />
      <TodayStack.Screen name="SettingsInvoiceNumbering" component={SettingsInvoiceNumberingScreen} options={{ title: "Invoice numbering" }} />
      <TodayStack.Screen name="SettingsAI" component={SettingsAIScreen} options={{ title: "AI Assistant" }} />
      <TodayStack.Screen name="SettingsReviews" component={SettingsReviewsScreen} options={{ title: "Review requests" }} />
      <TodayStack.Screen name="SettingsNotifications" component={SettingsNotificationsScreen} options={{ title: "Notifications" }} />
      <TodayStack.Screen name="SettingsPayments" component={SettingsPaymentsScreen} options={{ title: "Payments" }} />
      <TodayStack.Screen name="SettingsBooking" component={SettingsBookingScreen} options={{ title: "Booking link" }} />
      <TodayStack.Screen name="SettingsSubscription" component={SettingsSubscriptionScreen} options={{ title: "Subscription" }} />
      <TodayStack.Screen name="SettingsAccount" component={SettingsAccountScreen} options={{ title: "Account" }} />
      <TodayStack.Screen name="SettingsImport" component={SettingsImportScreen} options={{ title: "Import data" }} />
      <TodayStack.Screen name="Search" component={GlobalSearchScreen} options={{ title: "Search" }} />
    </TodayStack.Navigator>
  );
}

function JobsTab() {
  const { colors } = useThemeContext();
  const navOpts = {
    headerStyle:           { backgroundColor: colors.surface },
    headerTintColor:       colors.accent,
    headerTitleStyle:      { color: colors.textPrimary, fontWeight: "600" as const },
    headerBackTitleVisible: false,
  };
  return (
    <JobStack.Navigator screenOptions={navOpts}>
      <JobStack.Screen
        name="JobList"
        component={JobsScreen}
        options={({ navigation }) => ({
          title: "Jobs",
          headerRight: () => (
            <TouchableOpacity
              onPress={() => navigation.navigate("RecurringJobs")}
              hitSlop={{ top: 8, bottom: 8, left: 8, right: 8 }}
              style={{ paddingLeft: 8 }}
              accessibilityRole="button"
              accessibilityLabel="Recurring jobs"
            >
              <Ionicons name="repeat-outline" size={22} color={colors.accent} />
            </TouchableOpacity>
          ),
        })}
      />
      <JobStack.Screen name="JobDetail"           component={JobDetailScreen}           options={{ title: "Job" }} />
      <JobStack.Screen name="AddJob"              component={AddJobScreen}              options={{ presentation: "modal" }} />
      <JobStack.Screen name="AddChangeOrder"      component={AddChangeOrderScreen}      options={{ presentation: "modal", title: "Add Change Order" }} />
      <JobStack.Screen name="PricingCalculator"   component={PricingCalculatorScreen}   options={{ title: "Price this job" }} />
      <JobStack.Screen name="CreateInvoiceFromJob" component={CreateInvoiceFromJobScreen} options={{ title: "Create Invoice" }} />
      <JobStack.Screen name="SendEstimate"        component={SendEstimateScreen}        options={{ title: "Send Estimate" }} />
      <JobStack.Screen name="AddCustomer"         component={AddCustomerScreen}         options={{ presentation: "modal" }} />
      <JobStack.Screen name="Outreach"            component={OutreachScreen}            options={{ title: "Outreach" }} />
      <JobStack.Screen
        name="RecurringJobs"
        component={RecurringJobsScreen}
        options={{ title: "Recurring Jobs" }}
      />
      <JobStack.Screen
        name="ReviewRequest"
        component={ReviewRequestScreen}
        options={{ title: "Review Request" }}
      />
      <JobStack.Screen
        name="EstimateFollowUp"
        component={EstimateFollowUpScreen}
        options={{ title: "Estimate Follow-Up" }}
      />
    </JobStack.Navigator>
  );
}

function InvoicesTab() {
  const { colors } = useThemeContext();
  const navOpts = {
    headerStyle:           { backgroundColor: colors.surface },
    headerTintColor:       colors.accent,
    headerTitleStyle:      { color: colors.textPrimary, fontWeight: "600" as const },
    headerBackTitleVisible: false,
  };
  return (
    <InvoiceStack.Navigator screenOptions={navOpts}>
      <InvoiceStack.Screen
        name="InvoiceList"
        component={InvoicesScreen}
        options={({ navigation }) => ({
          title: "Invoices",
          headerRight: () => (
            <TouchableOpacity
              onPress={() => navigation.navigate("RecurringInvoices")}
              hitSlop={{ top: 8, bottom: 8, left: 8, right: 8 }}
              style={{ paddingLeft: 8 }}
              accessibilityRole="button"
              accessibilityLabel="Recurring invoices"
            >
              <Ionicons name="repeat-outline" size={22} color={colors.accent} />
            </TouchableOpacity>
          ),
        })}
      />
      <InvoiceStack.Screen name="AddInvoice"  component={AddInvoiceScreen} options={{ presentation: "modal" }} />
      <InvoiceStack.Screen name="Outreach"    component={OutreachScreen}   options={{ title: "Outreach" }} />
      <InvoiceStack.Screen
        name="RecurringInvoices"
        component={RecurringInvoicesScreen}
        options={{ title: "Recurring Invoices" }}
      />
      <InvoiceStack.Screen
        name="AddRecurringInvoice"
        component={AddRecurringInvoiceScreen}
        options={{ presentation: "modal" }}
      />
    </InvoiceStack.Navigator>
  );
}

function CustomersTab() {
  const { colors } = useThemeContext();
  const navOpts = {
    headerStyle:           { backgroundColor: colors.surface },
    headerTintColor:       colors.accent,
    headerTitleStyle:      { color: colors.textPrimary, fontWeight: "600" as const },
    headerBackTitleVisible: false,
  };
  return (
    <CustomerStack.Navigator screenOptions={navOpts}>
      <CustomerStack.Screen name="CustomerList"   component={CustomersScreen}      options={{ title: "Customers" }} />
      <CustomerStack.Screen name="CustomerDetail" component={CustomerDetailScreen} options={{ title: "Customer" }} />
      <CustomerStack.Screen name="AddCustomer"    component={AddCustomerScreen}    options={{ presentation: "modal" }} />
      <CustomerStack.Screen name="AddInvoice"     component={AddInvoiceScreen}     options={{ presentation: "modal" }} />
      <CustomerStack.Screen name="Outreach"       component={OutreachScreen}       options={{ title: "Outreach" }} />
    </CustomerStack.Navigator>
  );
}

function MoneyTab() {
  const { colors } = useThemeContext();
  const navOpts = {
    headerStyle:           { backgroundColor: colors.surface },
    headerTintColor:       colors.accent,
    headerTitleStyle:      { color: colors.textPrimary, fontWeight: "600" as const },
    headerBackTitleVisible: false,
  };
  return (
    <MoneyStack.Navigator screenOptions={navOpts}>
      <MoneyStack.Screen
        name="MoneyHome"
        component={MoneyScreen}
        options={({ navigation }) => ({
          title: "Money",
          headerRight: () => (
            <TouchableOpacity
              onPress={() => navigation.navigate("ExportData")}
              hitSlop={{ top: 8, bottom: 8, left: 8, right: 8 }}
              style={{ paddingLeft: 8 }}
              accessibilityRole="button"
              accessibilityLabel="Export data"
            >
              <Ionicons name="download-outline" size={22} color={colors.accent} />
            </TouchableOpacity>
          ),
        })}
      />
      <MoneyStack.Screen name="MileageLog"  component={MileageLogScreen}  options={{ title: "Mileage" }} />
      <MoneyStack.Screen name="AddTrip"     component={AddTripScreen}     options={{ presentation: "modal" }} />
      <MoneyStack.Screen name="Pricebook"      component={PricebookScreen}      options={{ title: "Pricebook" }} />
      <MoneyStack.Screen name="PricebookEntry" component={PricebookEntryScreen} options={{ title: "Service" }} />
      <MoneyStack.Screen
        name="ExportData"
        component={ExportDataScreen}
        options={{ presentation: "modal", title: "Export Data" }}
      />
    </MoneyStack.Navigator>
  );
}

function ChatTab() {
  const { colors } = useThemeContext();
  const navOpts = {
    headerStyle:           { backgroundColor: colors.surface },
    headerTintColor:       colors.accent,
    headerTitleStyle:      { color: colors.textPrimary, fontWeight: "600" as const },
    headerBackTitleVisible: false,
  };
  return (
    <ChatStack.Navigator screenOptions={navOpts}>
      <ChatStack.Screen name="ChatHome" component={ChatScreen} options={{ title: "AI Assistant" }} />
    </ChatStack.Navigator>
  );
}

// ── Tab icons ─────────────────────────────────────────────────────────────────

const TAB_ICONS: Record<keyof MainTabParamList, { active: string; inactive: string }> = {
  Today:     { active: "calendar",             inactive: "calendar-outline" },
  Jobs:      { active: "hammer",               inactive: "hammer-outline" },
  Invoices:  { active: "receipt",              inactive: "receipt-outline" },
  Customers: { active: "people",               inactive: "people-outline" },
  Money:     { active: "cash",                 inactive: "cash-outline" },
  AI:        { active: "chatbubble-ellipses",  inactive: "chatbubble-ellipses-outline" },
};

// ── Root ──────────────────────────────────────────────────────────────────────

function MainTabs() {
  const [nickname, setNickname] = useState("Tradie");
  const { colors } = useThemeContext();

  useEffect(() => {
    loadSettings().then(s => setNickname(getTradeNickname(s?.trade)));
  }, []);

  return (
    <Tab.Navigator
      screenOptions={({ route }) => ({
        headerShown: false,
        tabBarIcon: ({ focused, color }) => (
          <Ionicons
            name={(focused ? TAB_ICONS[route.name]?.active : TAB_ICONS[route.name]?.inactive) as keyof typeof Ionicons.glyphMap}
            size={22}
            color={color}
          />
        ),
        tabBarActiveTintColor:   colors.accent,
        tabBarInactiveTintColor: colors.textMuted,
        tabBarStyle: { backgroundColor: colors.surface, borderTopColor: colors.border },
        tabBarLabelStyle: { fontSize: fontSize.xs, fontWeight: "500" as const },
        // Tab labels are the most space-constrained text in the app; native
        // tab bars conventionally don't scale them (VoiceOver reads them).
        tabBarAllowFontScaling: false,
      })}
    >
      <Tab.Screen name="Today"     component={TodayTab} />
      <Tab.Screen name="Jobs"      component={JobsTab} />
      <Tab.Screen name="Invoices"  component={InvoicesTab} />
      <Tab.Screen name="Customers" component={CustomersTab} />
      <Tab.Screen name="Money"     component={MoneyTab} />
      <Tab.Screen name="AI" component={ChatTab} options={{ tabBarHideOnKeyboard: true, tabBarLabel: nickname }} />
    </Tab.Navigator>
  );
}

function RootNavigator() {
  const { session, initializing, bootstrapping } = useAuth();
  const { isSubscribed, isLoading: subLoading } = useSubscription();
  const { colors, isDark }                      = useThemeContext();
  const [onboardingDone, setOnboardingDone]     = useState<boolean | null>(null);
  // Post-paywall sample-vs-fresh gate (2026-08-03 flow restructure). Same
  // null-until-evaluated contract as onboardingDone.
  const [startChoiceDone, setStartChoiceDone]   = useState<boolean | null>(null);
  // Mirrors `session` for the notification listener, which registers once and
  // would otherwise close over the value from the first render.
  const sessionRef = React.useRef(session);

  useEffect(() => {
    sessionRef.current = session;
    if (!session) { setOnboardingDone(null); setStartChoiceDone(null); return; }
    // Wait for initialSync: after a sign-out wipe, local state says "new
    // user" until the cloud pull lands — evaluating early re-onboarded
    // returning users, and their onboarding save clobbered the pulled
    // settings (2026-07-16). onboardingDone stays null meanwhile, which the
    // loading gate below renders as a spinner; mid-session token refreshes
    // keep their previous value, so no flash.
    if (bootstrapping) return;
    isOnboardingComplete().then(setOnboardingDone);
    isStartChoiceComplete().then(setStartChoiceDone);
    // Identity first (may backfill invoice.customerId with a legacy sample
    // id), then the sample-id migration remaps those to namespaced ids.
    migrateCustomerIdentity()
      .catch(() => {})
      .then(() => migrateSampleDataIds())
      .catch(() => {})
      .then(() => applyEstimateDecisions())
      .catch(() => {})
      .then(() => applyBookingRequests())
      .catch(() => {})
      .then(() => scrubLegacySquareToken())
      .catch(() => {})
      .then(() => migrateLegacyJobPhotos())
      .catch(() => {})
      .then(() => registerPushToken())
      .catch(() => {});
  }, [session, bootstrapping]);

  useEffect(() => {
    const sub = Notifications.addNotificationResponseReceivedListener((response) => {
      const data = response.notification.request.content.data;
      // Signed out: the Main route isn't mounted, so navigating would be an
      // unhandled action (a warning in dev, a silent no-op in prod). Ignore
      // the tap explicitly instead.
      if (!sessionRef.current) return;
      if (data?.type === "review_request" && data?.jobId && navigationRef.isReady()) {
        navigationRef.navigate("Main", {
          screen: "Jobs",
          params: { screen: "ReviewRequest", params: { jobId: String(data.jobId), source: "notification" } },
        });
      }
      if (data?.type === "estimate_follow_up" && data?.jobId && navigationRef.isReady()) {
        track("estimate_follow_up_opened", { source: "notification" });
        navigationRef.navigate("Main", {
          screen: "Jobs",
          params: { screen: "EstimateFollowUp", params: { jobId: String(data.jobId), source: "notification" } },
        });
      }
      if (data?.type === "overdue_outreach" && data?.invoiceId && navigationRef.isReady()) {
        track("overdue_outreach_opened", { daysPastDue: data.daysPastDue });
        navigationRef.navigate("Main", {
          screen: "Invoices",
          params: { screen: "Outreach", params: { invoiceId: String(data.invoiceId) } },
        });
      }
      if (data?.type === "appointment_confirm" && data?.jobId && navigationRef.isReady()) {
        track("appointment_confirm_opened", {});
        navigationRef.navigate("Main", {
          screen: "Jobs",
          params: { screen: "JobDetail", params: { jobId: String(data.jobId) } },
        });
      }
      if (data?.type === "recurring_invoice" && data?.ruleId && navigationRef.isReady()) {
        const ruleId = String(data.ruleId);
        // Generation happens on app open (AuthContext), not at tap time — by
        // the time this runs the invoice usually exists; fall back to the
        // plain list when it doesn't yet.
        loadInvoices()
          .then((invoices) => {
            const latest = invoices
              .filter((inv) => inv.recurringInvoiceId === ruleId)
              .reduce<Invoice | null>(
                (best, inv) =>
                  !best || (inv.occurrenceNumber ?? 0) > (best.occurrenceNumber ?? 0) ? inv : best,
                null
              );
            if (!navigationRef.isReady()) return;
            navigationRef.navigate("Main", {
              screen: "Invoices",
              params: {
                screen: "InvoiceList",
                params: latest ? { openInvoiceId: latest.id } : undefined,
              },
            });
          })
          .catch(() => {});
      }
      if (data?.type === "booking_request" && navigationRef.isReady()) {
        track("booking_request_opened", {});
        navigationRef.navigate("Main", {
          screen: "Jobs",
          params: { screen: "JobList" },
        });
      }
    });
    return () => sub.remove();
  }, []);

  // Widget deep links: tradeready://job/<id> (produced by targets/widget) and
  // tradeready://onmyway/<id> (produced by the Siri "on my way" intent only —
  // there is no widget button for this one).
  // Warm taps navigate immediately; a cold-start tap arrives via
  // getInitialURL before the container and auth gates are ready, so it parks
  // in pendingDeepLinkRef and replays from onReady / the session effect.
  const pendingDeepLinkRef = React.useRef<string | null>(null);
  const consumeDeepLink = React.useCallback((url: string | null) => {
    const link = parseWidgetDeepLink(url);
    if (!link) return;
    if (!sessionRef.current || !navigationRef.isReady()) {
      pendingDeepLinkRef.current = url;
      return;
    }
    pendingDeepLinkRef.current = null;
    // type distinguishes Siri on-my-way usage from widget job taps.
    track("widget_deep_link_opened", { type: link.type });
    if (link.type === "onmyway") {
      // The Siri intent stashes this same link for the cold-launch path (see
      // drainPendingOpenUrl). Having navigated from the live url event instead,
      // drop the stash so a later launch can't replay it. Fire-and-forget: the
      // helper is a silent no-op when the native bridge is absent, and the
      // freshness window in parsePendingOpenUrl covers us if this never lands.
      removeWidgetSharedItem(PENDING_OPEN_URL_KEY).catch(() => {});
      navigationRef.navigate("Main", {
        screen: "Jobs",
        params: { screen: "JobDetail", params: { jobId: link.jobId, autoAction: "onmyway" } },
      });
      return;
    }
    navigationRef.navigate("Main", {
      screen: "Jobs",
      params: { screen: "JobDetail", params: { jobId: link.jobId } },
    });
  }, []);

  // Cold-launch companion to the url event. The Siri on-my-way intent posts the
  // link into RN's linking stack, but on a cold start that fires before the
  // listener above exists, so the intent also stashes it in the App Group
  // container. Read-then-immediately-remove (same discipline as the pending
  // widget-action queue), then let parsePendingOpenUrl decide whether it is
  // fresh enough to act on. Never throws; a null bridge (Expo Go, Android)
  // makes the whole thing a silent no-op.
  // Both flush points can fire within a render of each other, and the read is an
  // async bridge round-trip — without this latch they can both read the stash
  // before either removal lands and navigate twice, which would open the SMS
  // composer twice. Skipping the second call is safe: whichever drain is in
  // flight either navigates itself (navigation is ready by then) or parks the
  // link in pendingDeepLinkRef, which onReady and the session effect replay.
  const drainingRef = React.useRef(false);
  const drainPendingOpenUrl = React.useCallback(async () => {
    if (drainingRef.current) return;
    drainingRef.current = true;
    try {
      const raw = await getWidgetSharedItem(PENDING_OPEN_URL_KEY);
      if (!raw) return;
      await removeWidgetSharedItem(PENDING_OPEN_URL_KEY);
      const url = parsePendingOpenUrl(raw, Date.now());
      if (url) consumeDeepLink(url);
    } finally {
      drainingRef.current = false;
    }
  }, [consumeDeepLink]);

  useEffect(() => {
    Linking.getInitialURL().then(consumeDeepLink).catch(() => {});
    const sub = Linking.addEventListener("url", (e) => consumeDeepLink(e.url));
    return () => sub.remove();
  }, [consumeDeepLink]);

  useEffect(() => {
    if (session && pendingDeepLinkRef.current) consumeDeepLink(pendingDeepLinkRef.current);
    if (session) drainPendingOpenUrl().catch(() => {});
  }, [session, consumeDeepLink, drainPendingOpenUrl]);

  const isLoading = rootGateLoading({
    initializing,
    hasSession: !!session,
    onboardingDone,
    startChoiceDone,
    subLoading,
  });

  if (isLoading) {
    return (
      <View style={{ flex: 1, justifyContent: "center", alignItems: "center", backgroundColor: colors.background }}>
        <ActivityIndicator color={colors.accent} size="large" />
      </View>
    );
  }

  const navTheme = {
    dark: isDark,
    colors: {
      primary:      colors.accent,
      background:   colors.background,
      card:         colors.surface,
      text:         colors.textPrimary,
      border:       colors.border,
      notification: colors.accent,
    },
  };

  return (
    <NavigationContainer
      ref={navigationRef}
      theme={navTheme}
      onReady={() => {
        consumeDeepLink(pendingDeepLinkRef.current);
        drainPendingOpenUrl().catch(() => {});
      }}
    >
      {/* Must live INSIDE the container — see ScreenTracker. */}
      {POSTHOG_ENABLED && <ScreenTracker />}
      <RootStack.Navigator screenOptions={{ headerShown: false }}>
        {!session ? (
          <RootStack.Screen name="Auth" component={AuthScreen} />
        ) : !onboardingDone ? (
          <RootStack.Screen name="Onboarding">
            {() => (
              <OnboardingScreen
                onComplete={() => {
                  // The wizard just stamped stage "personalized": onboarding is
                  // done but the starting-point choice (post-paywall) is now owed.
                  setOnboardingDone(true);
                  setStartChoiceDone(false);
                }}
              />
            )}
          </RootStack.Screen>
        ) : !isSubscribed ? (
          <RootStack.Screen name="Paywall" component={PaywallScreen} />
        ) : !startChoiceDone ? (
          <RootStack.Screen name="StartingPoint">
            {() => <StartingPointScreen onComplete={() => setStartChoiceDone(true)} />}
          </RootStack.Screen>
        ) : (
          <>
            <RootStack.Screen name="Main" component={MainTabs} />
            <RootStack.Screen
              name="PaywallModal"
              component={PaywallScreen}
              options={{ presentation: "modal", headerShown: false }}
            />
          </>
        )}
      </RootStack.Navigator>
    </NavigationContainer>
  );
}

let Updates: any = null;
// eslint-disable-next-line @typescript-eslint/no-require-imports -- expo-updates is absent in Expo Go; lazy require prevents a crash on dev builds
try { Updates = require("expo-updates"); } catch {}

interface ErrorBoundaryState { hasError: boolean; }

class ErrorBoundary extends React.Component<{ children: React.ReactNode }, ErrorBoundaryState> {
  state: ErrorBoundaryState = { hasError: false };

  static getDerivedStateFromError(): ErrorBoundaryState {
    return { hasError: true };
  }

  componentDidCatch(error: Error, errorInfo: React.ErrorInfo) {
    Sentry.captureException(error, { extra: { componentStack: errorInfo.componentStack } });
    if (__DEV__) {
      // Sentry.init passes enabled: !__DEV__, so in development the line above is a
      // no-op and this boundary would otherwise swallow the error entirely — leaving
      // only the "Something went wrong" screen with no way to find out what broke.
      // eslint-disable-next-line no-console -- the only channel that surfaces a caught render error in dev
      console.error("ErrorBoundary caught:", error, errorInfo.componentStack);
    }
  }

  render() {
    if (!this.state.hasError) return this.props.children;

    const handleRestart = () => {
      if (Updates?.reloadAsync) {
        Updates.reloadAsync();
      } else {
        Alert.alert("Restart required", "Please close and reopen TradeReady to continue.");
      }
    };

    return (
      <View style={{ flex: 1, backgroundColor: staticColors.background, alignItems: "center", justifyContent: "center", padding: 32 }}>
        <Text style={{ fontSize: 28, fontWeight: "800", color: staticColors.accent, marginBottom: 16 }}>TradeReady</Text>
        <Text style={{ fontSize: 16, color: staticColors.textPrimary, textAlign: "center", marginBottom: 32 }}>
          Something went wrong. Please restart the app.
        </Text>
        <TouchableOpacity
          onPress={handleRestart}
          style={{ backgroundColor: staticColors.accent, borderRadius: 12, paddingVertical: 14, paddingHorizontal: 32 }}
          activeOpacity={0.85}
          accessibilityRole="button"
          accessibilityLabel="Restart"
        >
          <Text style={{ color: "#fff", fontSize: 16, fontWeight: "700" }}>Restart</Text>
        </TouchableOpacity>
      </View>
    );
  }
}

if (!__DEV__) {
  // eslint-disable-next-line no-console
  console.log = () => {};
}

// RN repaints text when iOS changes the system text size under a running
// app, but existing layout is never re-measured — headers chop and siblings
// keep the old scale (device-verified 2026-07-14; a relaunch renders
// correctly). Offer that relaunch when we detect the change.
function FontScaleWatcher() {
  const baselineRef = React.useRef(Dimensions.get("window").fontScale);
  const promptingRef = React.useRef(false);

  React.useEffect(() => {
    const sub = Dimensions.addEventListener("change", ({ window }) => {
      const next = window.fontScale;
      if (promptingRef.current || !fontScaleChanged(baselineRef.current, next)) return;
      promptingRef.current = true;
      Alert.alert(
        "Text size changed",
        "TradeReady needs a quick restart to fit the new text size.",
        [
          {
            text: "Later",
            style: "cancel",
            // New baseline so we only re-prompt on a further change.
            onPress: () => { baselineRef.current = next; promptingRef.current = false; },
          },
          {
            text: "Restart now",
            onPress: () => {
              if (Updates?.reloadAsync) {
                Updates.reloadAsync();
              } else {
                promptingRef.current = false;
                baselineRef.current = next;
                Alert.alert("Restart required", "Please close and reopen TradeReady to continue.");
              }
            },
          },
        ]
      );
    });
    return () => sub.remove();
  }, []);

  return null;
}

function PostHogBridge() {
  const posthog = usePostHog();
  React.useEffect(() => {
    posthogRef.current = posthog;
    return () => { posthogRef.current = null; };
  }, [posthog]);
  return null;
}

// PostHog's screen autocapture calls useNavigationState/useNavigation, so it only
// works inside a NavigationContainer. PostHogProvider renders that hook itself, but
// the provider has to stay at the root (it owns the client and the app-lifecycle
// events, and remounting it inside the root gate would recreate both) — from there
// the hooks can't see a navigation object and every launch logged
//   ERROR useNavigationState error [Error: Couldn't find a navigation object...]
//   ERROR useNavigation error     [Error: Couldn't find a navigation object...]
// and then bailed out, so no screen was ever captured. Fix: turn the provider's own
// tracker off with autocapture.captureScreens and call the exported hook from in
// here, rendered inside the container.
function ScreenTracker() {
  useNavigationTracker();
  return null;
}

// Gates first paint on the custom typeface set loading. Sits inside
// ThemeProvider (not above it) so the loading spinner itself can use the
// live background/accent tokens instead of a hardcoded fallback.
function FontGate({ children }: { children: React.ReactNode }) {
  const { colors } = useThemeContext();
  const [fontsLoaded, fontError] = useFonts({
    "ChakraPetch-Bold":   require("./assets/fonts/ChakraPetch-Bold.ttf"),
    "PublicSans-Regular": require("./assets/fonts/PublicSans-Regular.ttf"),
    "PublicSans-Medium":  require("./assets/fonts/PublicSans-Medium.ttf"),
    "PublicSans-SemiBold": require("./assets/fonts/PublicSans-SemiBold.ttf"),
    "PublicSans-Bold":    require("./assets/fonts/PublicSans-Bold.ttf"),
    "PlexMono-Medium":    require("./assets/fonts/IBMPlexMono-Medium.ttf"),
  });

  useEffect(() => {
    if (fontError) reportError(fontError, { context: "fontGateLoad" });
  }, [fontError]);

  // A font load failure shouldn't hard-lock the app on the spinner forever —
  // fall through to system fonts (styles that set fontFamily just silently
  // miss and render the platform default) rather than blocking startup.
  if (!fontsLoaded && !fontError) {
    return (
      <View style={{ flex: 1, justifyContent: "center", alignItems: "center", backgroundColor: colors.background }}>
        <ActivityIndicator color={colors.accent} size="large" />
      </View>
    );
  }
  return <>{children}</>;
}

function AppRoot() {
  const content = (
    <SafeAreaProvider>
      <ErrorBoundary>
        <ThemeProvider>
          <FontGate>
            <SyncStatusProvider>
              <UndoProvider>
                <AuthProvider>
                  <SubscriptionProvider>
                    <RootNavigator />
                  </SubscriptionProvider>
                </AuthProvider>
              </UndoProvider>
              <SyncBanner />
              <FontScaleWatcher />
            </SyncStatusProvider>
          </FontGate>
        </ThemeProvider>
      </ErrorBoundary>
    </SafeAreaProvider>
  );

  if (POSTHOG_ENABLED) {
    return (
      <PostHogProvider
        apiKey={POSTHOG_API_KEY}
        options={{ host: "https://us.i.posthog.com" }}
        // captureScreens defaults to true and renders a tracker here, outside the
        // NavigationContainer, where its hooks throw. ScreenTracker does it inside.
        autocapture={{ captureScreens: false }}
      >
        <PostHogBridge />
        {content}
      </PostHogProvider>
    );
  }

  return content;
}

export default Sentry.wrap(AppRoot);
