import React, { useState, useEffect } from "react";
import { NavigationContainer, createNavigationContainerRef } from "@react-navigation/native";
import { createBottomTabNavigator } from "@react-navigation/bottom-tabs";
import { createNativeStackNavigator } from "@react-navigation/native-stack";
import { SafeAreaProvider } from "react-native-safe-area-context";
import { Text, View, ActivityIndicator, TouchableOpacity, Alert } from "react-native";
import { Ionicons } from "@expo/vector-icons";
import { AuthProvider, useAuth } from "./context/AuthContext";
import { SubscriptionProvider, useSubscription } from "./context/SubscriptionContext";
import { ThemeProvider, useThemeContext } from "./context/ThemeContext";
import { SyncStatusProvider } from "./context/SyncStatusContext";
import { SyncBanner } from "./components/SyncBanner";
import AuthScreen from "./screens/AuthScreen";
import OnboardingScreen from "./screens/OnboardingScreen";
import PaywallScreen from "./screens/PaywallScreen";
import { isOnboardingComplete } from "./utils/storage";
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

import InvoicesScreen             from "./screens/InvoicesScreen";
import AddInvoiceScreen           from "./screens/AddInvoiceScreen";
import OutreachScreen             from "./screens/OutreachScreen";
import JobsScreen                 from "./screens/JobsScreen";
import JobDetailScreen            from "./screens/JobDetailScreen";
import AddJobScreen               from "./screens/AddJobScreen";
import PricingCalculatorScreen    from "./screens/PricingCalculatorScreen";
import CreateInvoiceFromJobScreen from "./screens/CreateInvoiceFromJobScreen";
import SendEstimateScreen         from "./screens/SendEstimateScreen";
import CustomersScreen            from "./screens/CustomersScreen";
import CustomerDetailScreen       from "./screens/CustomerDetailScreen";
import AddCustomerScreen          from "./screens/AddCustomerScreen";
import SettingsScreen             from "./screens/SettingsScreen";
import TodayScreen                from "./screens/TodayScreen";
import MoneyScreen                from "./screens/MoneyScreen";
import ChatScreen                 from "./screens/ChatScreen";
import RouteScreen                from "./screens/RouteScreen";
import RecurringJobsScreen        from "./screens/RecurringJobsScreen";
import MileageLogScreen           from "./screens/MileageLogScreen";
import AddTripScreen              from "./screens/AddTripScreen";
import ReviewRequestScreen        from "./screens/ReviewRequestScreen";
import PricebookScreen            from "./screens/PricebookScreen";
import PricebookEntryScreen       from "./screens/PricebookEntryScreen";

import * as Notifications from "expo-notifications";

import { colors as staticColors, fontSize } from "./utils/theme";
import { loadSettings, migrateCustomerIdentity, migrateSampleDataIds } from "./utils/storage";
import { getTradeNickname } from "./utils/pricingEngine";

import * as Sentry from "@sentry/react-native";
import { PostHogProvider, usePostHog } from "posthog-react-native";
import Constants from "expo-constants";
import { posthogRef } from "./utils/analytics";

const SENTRY_DSN = Constants.expoConfig?.extra?.sentryDsn ?? "";
const POSTHOG_API_KEY = Constants.expoConfig?.extra?.posthogApiKey ?? "";

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
      <InvoiceStack.Screen name="InvoiceList" component={InvoicesScreen}   options={{ title: "Invoices" }} />
      <InvoiceStack.Screen name="AddInvoice"  component={AddInvoiceScreen} options={{ presentation: "modal" }} />
      <InvoiceStack.Screen name="Outreach"    component={OutreachScreen}   options={{ title: "Outreach" }} />
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
      <MoneyStack.Screen name="MoneyHome"   component={MoneyScreen}       options={{ title: "Money" }} />
      <MoneyStack.Screen name="MileageLog"  component={MileageLogScreen}  options={{ title: "Mileage" }} />
      <MoneyStack.Screen name="AddTrip"     component={AddTripScreen}     options={{ presentation: "modal" }} />
      <MoneyStack.Screen name="Pricebook"      component={PricebookScreen}      options={{ title: "Pricebook" }} />
      <MoneyStack.Screen name="PricebookEntry" component={PricebookEntryScreen} options={{ title: "Service" }} />
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

const TAB_ICONS: Record<string, { active: string; inactive: string }> = {
  Today:     { active: "calendar",             inactive: "calendar-outline" },
  Jobs:      { active: "hammer",               inactive: "hammer-outline" },
  Invoices:  { active: "receipt",              inactive: "receipt-outline" },
  Customers: { active: "people",               inactive: "people-outline" },
  Money:     { active: "cash",                 inactive: "cash-outline" },
  AI:        { active: "chatbubble-ellipses",  inactive: "chatbubble-ellipses-outline" },
  Settings:  { active: "settings",             inactive: "settings-outline" },
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
      <Tab.Screen
        name="Settings"
        component={SettingsScreen}
        options={{
          headerShown:      true,
          title:            "Settings",
          headerStyle:      { backgroundColor: colors.surface },
          headerTitleStyle: { color: colors.textPrimary, fontWeight: "600" as const },
        }}
      />
    </Tab.Navigator>
  );
}

function RootNavigator() {
  const { session, initializing }               = useAuth();
  const { isSubscribed, isLoading: subLoading } = useSubscription();
  const { colors, isDark }                      = useThemeContext();
  const [onboardingDone, setOnboardingDone]     = useState<boolean | null>(null);
  // Mirrors `session` for the notification listener, which registers once and
  // would otherwise close over the value from the first render.
  const sessionRef = React.useRef(session);

  useEffect(() => {
    sessionRef.current = session;
    if (!session) { setOnboardingDone(null); return; }
    isOnboardingComplete().then(setOnboardingDone);
    // Identity first (may backfill invoice.customerId with a legacy sample
    // id), then the sample-id migration remaps those to namespaced ids.
    migrateCustomerIdentity()
      .catch(() => {})
      .then(() => migrateSampleDataIds())
      .catch(() => {});
  }, [session]);

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
          params: { screen: "ReviewRequest", params: { jobId: String(data.jobId) } },
        });
      }
    });
    return () => sub.remove();
  }, []);

  const isLoading =
    initializing ||
    (session && onboardingDone === null) ||
    (session && onboardingDone && subLoading);

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
    <NavigationContainer ref={navigationRef} theme={navTheme}>
      <RootStack.Navigator screenOptions={{ headerShown: false }}>
        {!session ? (
          <RootStack.Screen name="Auth" component={AuthScreen} />
        ) : !onboardingDone ? (
          <RootStack.Screen name="Onboarding">
            {() => <OnboardingScreen onComplete={() => setOnboardingDone(true)} />}
          </RootStack.Screen>
        ) : !isSubscribed ? (
          <RootStack.Screen name="Paywall" component={PaywallScreen} />
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

function PostHogBridge() {
  const posthog = usePostHog();
  React.useEffect(() => {
    posthogRef.current = posthog;
    return () => { posthogRef.current = null; };
  }, [posthog]);
  return null;
}

function AppRoot() {
  const content = (
    <SafeAreaProvider>
      <ErrorBoundary>
        <ThemeProvider>
          <SyncStatusProvider>
            <AuthProvider>
              <SubscriptionProvider>
                <RootNavigator />
              </SubscriptionProvider>
            </AuthProvider>
            <SyncBanner />
          </SyncStatusProvider>
        </ThemeProvider>
      </ErrorBoundary>
    </SafeAreaProvider>
  );

  if (POSTHOG_API_KEY && !POSTHOG_API_KEY.startsWith("PLACEHOLDER")) {
    return (
      <PostHogProvider
        apiKey={POSTHOG_API_KEY}
        options={{ host: "https://us.i.posthog.com" }}
      >
        <PostHogBridge />
        {content}
      </PostHogProvider>
    );
  }

  return content;
}

export default Sentry.wrap(AppRoot);
