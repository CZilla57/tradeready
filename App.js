// App.js
// Entry point. Sets up navigation — bottom tab bar with stack navigators
// inside each tab so you can go forward/back within a tab independently.
//
// Route inventory (keep this updated when adding screens):
//
// JobsTab:
//   JobList              → JobsScreen
//   JobDetail            → JobDetailScreen
//   AddJob               → AddJobScreen          (modal)
//   AddCustomer          → AddCustomerScreen     (modal, for "Add new customer" from AddJob)
//   PricingCalculator    → PricingCalculatorScreen
//   CreateInvoiceFromJob → CreateInvoiceFromJobScreen
//   SendEstimate         → SendEstimateScreen
//   Outreach             → OutreachScreen
//
// InvoicesTab:
//   InvoiceList          → InvoicesScreen
//   AddInvoice           → AddInvoiceScreen      (modal)
//   Outreach             → OutreachScreen
//
// CustomersTab:
//   CustomerList         → CustomersScreen
//   CustomerDetail       → CustomerDetailScreen
//   AddCustomer          → AddCustomerScreen     (modal)
//   AddInvoice           → AddInvoiceScreen      (modal, for "New Invoice" from CustomerDetail)
//   Outreach             → OutreachScreen
//
// TodayTab:
//   TodayHome  → TodayScreen
//   Route      → RouteScreen
//
// Settings (top-level tab, no nested stack needed):
//   SettingsScreen
//
// MoneyTab:
//   MoneyHome  → MoneyScreen
//   LogExpense → LogExpenseScreen
//
// AITab:
//   ChatHome   → ChatScreen

import React, { useState, useEffect } from "react";
import { NavigationContainer } from "@react-navigation/native";
import { createBottomTabNavigator } from "@react-navigation/bottom-tabs";
import { createNativeStackNavigator } from "@react-navigation/native-stack";
import { SafeAreaProvider } from "react-native-safe-area-context";
import { Text, View, ActivityIndicator, TouchableOpacity, Alert } from "react-native";
import { Ionicons } from "@expo/vector-icons";
import { AuthProvider, useAuth } from "./context/AuthContext";
import { SubscriptionProvider, useSubscription } from "./context/SubscriptionContext";
import { ThemeProvider, useThemeContext } from "./context/ThemeContext";
import AuthScreen from "./screens/AuthScreen";
import OnboardingScreen from "./screens/OnboardingScreen";
import PaywallScreen from "./screens/PaywallScreen";
import { isOnboardingComplete } from "./utils/storage";

// Screens
import InvoicesScreen              from "./screens/InvoicesScreen";
import AddInvoiceScreen            from "./screens/AddInvoiceScreen";
import OutreachScreen              from "./screens/OutreachScreen";
import JobsScreen                  from "./screens/JobsScreen";
import JobDetailScreen             from "./screens/JobDetailScreen";
import AddJobScreen                from "./screens/AddJobScreen";
import PricingCalculatorScreen     from "./screens/PricingCalculatorScreen";
import CreateInvoiceFromJobScreen  from "./screens/CreateInvoiceFromJobScreen";
import SendEstimateScreen          from "./screens/SendEstimateScreen";
import CustomersScreen             from "./screens/CustomersScreen";
import CustomerDetailScreen        from "./screens/CustomerDetailScreen";
import AddCustomerScreen           from "./screens/AddCustomerScreen";
import SettingsScreen              from "./screens/SettingsScreen";
import TodayScreen                 from "./screens/TodayScreen";
import MoneyScreen                 from "./screens/MoneyScreen";
import ChatScreen                  from "./screens/ChatScreen";
import RouteScreen                 from "./screens/RouteScreen";

import { colors as staticColors, fontSize } from "./utils/theme";
import { loadSettings, migrateCustomerIdentity } from "./utils/storage";
import { getTradeNickname } from "./utils/pricingEngine";

const RootStack     = createNativeStackNavigator();
const TodayStack    = createNativeStackNavigator();
const Tab           = createBottomTabNavigator();
const JobStack      = createNativeStackNavigator();
const InvoiceStack  = createNativeStackNavigator();
const CustomerStack = createNativeStackNavigator();
const MoneyStack    = createNativeStackNavigator();
const ChatStack     = createNativeStackNavigator();

// ── Tab stacks ────────────────────────────────────────────────────────────────

function TodayTab() {
  const { colors } = useThemeContext();
  const navOpts = {
    headerStyle:           { backgroundColor: colors.surface },
    headerTintColor:       colors.accent,
    headerTitleStyle:      { color: colors.textPrimary, fontWeight: "600" },
    headerBackTitleVisible: false,
  };
  return (
    <TodayStack.Navigator screenOptions={navOpts}>
      <TodayStack.Screen
        name="TodayHome"
        component={TodayScreen}
        options={{ headerShown: false }}
      />
      <TodayStack.Screen
        name="Route"
        component={RouteScreen}
        options={{ title: "Today's Route" }}
      />
    </TodayStack.Navigator>
  );
}

function JobsTab() {
  const { colors } = useThemeContext();
  const navOpts = {
    headerStyle:           { backgroundColor: colors.surface },
    headerTintColor:       colors.accent,
    headerTitleStyle:      { color: colors.textPrimary, fontWeight: "600" },
    headerBackTitleVisible: false,
  };
  return (
    <JobStack.Navigator screenOptions={navOpts}>
      <JobStack.Screen name="JobList"             component={JobsScreen}                 options={{ title: "Jobs" }} />
      <JobStack.Screen name="JobDetail"           component={JobDetailScreen}            options={{ title: "Job" }} />
      <JobStack.Screen name="AddJob"              component={AddJobScreen}               options={{ presentation: "modal" }} />
      <JobStack.Screen name="PricingCalculator"   component={PricingCalculatorScreen}    options={{ title: "Price this job" }} />
      <JobStack.Screen name="CreateInvoiceFromJob" component={CreateInvoiceFromJobScreen} options={{ title: "Create Invoice" }} />
      <JobStack.Screen name="SendEstimate"         component={SendEstimateScreen}         options={{ title: "Send Estimate" }} />
      <JobStack.Screen name="AddCustomer"         component={AddCustomerScreen}          options={{ presentation: "modal" }} />
      <JobStack.Screen name="Outreach"            component={OutreachScreen}             options={{ title: "Outreach" }} />
    </JobStack.Navigator>
  );
}

function InvoicesTab() {
  const { colors } = useThemeContext();
  const navOpts = {
    headerStyle:           { backgroundColor: colors.surface },
    headerTintColor:       colors.accent,
    headerTitleStyle:      { color: colors.textPrimary, fontWeight: "600" },
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
    headerTitleStyle:      { color: colors.textPrimary, fontWeight: "600" },
    headerBackTitleVisible: false,
  };
  return (
    <CustomerStack.Navigator screenOptions={navOpts}>
      <CustomerStack.Screen name="CustomerList"   component={CustomersScreen}       options={{ title: "Customers" }} />
      <CustomerStack.Screen name="CustomerDetail" component={CustomerDetailScreen}  options={{ title: "Customer" }} />
      <CustomerStack.Screen name="AddCustomer"    component={AddCustomerScreen}     options={{ presentation: "modal" }} />
      <CustomerStack.Screen name="AddInvoice"     component={AddInvoiceScreen}      options={{ presentation: "modal" }} />
      <CustomerStack.Screen name="Outreach"       component={OutreachScreen}        options={{ title: "Outreach" }} />
    </CustomerStack.Navigator>
  );
}

function MoneyTab() {
  const { colors } = useThemeContext();
  const navOpts = {
    headerStyle:           { backgroundColor: colors.surface },
    headerTintColor:       colors.accent,
    headerTitleStyle:      { color: colors.textPrimary, fontWeight: "600" },
    headerBackTitleVisible: false,
  };
  return (
    <MoneyStack.Navigator screenOptions={navOpts}>
      <MoneyStack.Screen name="MoneyHome" component={MoneyScreen} options={{ title: "Money" }} />
    </MoneyStack.Navigator>
  );
}

function ChatTab() {
  const { colors } = useThemeContext();
  const navOpts = {
    headerStyle:           { backgroundColor: colors.surface },
    headerTintColor:       colors.accent,
    headerTitleStyle:      { color: colors.textPrimary, fontWeight: "600" },
    headerBackTitleVisible: false,
  };
  return (
    <ChatStack.Navigator screenOptions={navOpts}>
      <ChatStack.Screen name="ChatHome" component={ChatScreen} options={{ title: "AI Assistant" }} />
    </ChatStack.Navigator>
  );
}

// ── Tab icons ─────────────────────────────────────────────────────────────────

const TAB_ICONS = {
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
            name={focused ? TAB_ICONS[route.name]?.active : TAB_ICONS[route.name]?.inactive}
            size={22}
            color={color}
          />
        ),
        tabBarActiveTintColor:   colors.accent,
        tabBarInactiveTintColor: colors.textMuted,
        tabBarStyle: { backgroundColor: colors.surface, borderTopColor: colors.border },
        tabBarLabelStyle: { fontSize: fontSize.xs, fontWeight: "500" },
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
          headerTitleStyle: { color: colors.textPrimary, fontWeight: "600" },
        }}
      />
    </Tab.Navigator>
  );
}

function RootNavigator() {
  const { session, initializing }                = useAuth();
  const { isSubscribed, isLoading: subLoading }  = useSubscription();
  const { colors, isDark }                       = useThemeContext();
  const [onboardingDone, setOnboardingDone]      = useState(null);

  useEffect(() => {
    if (!session) { setOnboardingDone(null); return; }
    isOnboardingComplete().then(setOnboardingDone);
    migrateCustomerIdentity().catch(() => {});
  }, [session]);

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
    <NavigationContainer theme={navTheme}>
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
              name="Paywall"
              component={PaywallScreen}
              options={{ presentation: "modal", headerShown: false }}
            />
          </>
        )}
      </RootStack.Navigator>
    </NavigationContainer>
  );
}

// expo-updates may not be installed; degrade gracefully if absent
let Updates;
try { Updates = require('expo-updates'); } catch (_) {}

class ErrorBoundary extends React.Component {
  state = { hasError: false };

  static getDerivedStateFromError() {
    return { hasError: true };
  }

  render() {
    if (!this.state.hasError) return this.props.children;

    const handleRestart = () => {
      if (Updates?.reloadAsync) {
        Updates.reloadAsync();
      } else {
        Alert.alert('Restart required', 'Please close and reopen TradeReady to continue.');
      }
    };

    return (
      <View style={{ flex: 1, backgroundColor: staticColors.background, alignItems: 'center', justifyContent: 'center', padding: 32 }}>
        <Text style={{ fontSize: 28, fontWeight: '800', color: staticColors.accent, marginBottom: 16 }}>TradeReady</Text>
        <Text style={{ fontSize: 16, color: staticColors.textPrimary, textAlign: 'center', marginBottom: 32 }}>
          Something went wrong. Please restart the app.
        </Text>
        <TouchableOpacity
          onPress={handleRestart}
          style={{ backgroundColor: staticColors.accent, borderRadius: 12, paddingVertical: 14, paddingHorizontal: 32 }}
          activeOpacity={0.85}
        >
          <Text style={{ color: '#fff', fontSize: 16, fontWeight: '700' }}>Restart</Text>
        </TouchableOpacity>
      </View>
    );
  }
}

// Suppress console.log in production builds. console.error and console.warn
// are kept so crash-reporting integrations can capture them.
if (!__DEV__) {
  // eslint-disable-next-line no-console
  console.log = () => {};
}

export default function App() {
  return (
    <SafeAreaProvider>
      <ErrorBoundary>
        <ThemeProvider>
          <AuthProvider>
            <SubscriptionProvider>
              <RootNavigator />
            </SubscriptionProvider>
          </AuthProvider>
        </ThemeProvider>
      </ErrorBoundary>
    </SafeAreaProvider>
  );
}
