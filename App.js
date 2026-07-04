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
import { Text, View, ActivityIndicator } from "react-native";
import { AuthProvider, useAuth } from "./context/AuthContext";
import AuthScreen from "./screens/AuthScreen";
import OnboardingScreen from "./screens/OnboardingScreen";
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
 
import { colors, fontSize } from "./utils/theme";
import { loadSettings } from "./utils/storage";
import { getTradeNickname } from "./utils/pricingEngine";
 
const TodayStack    = createNativeStackNavigator();
const Tab           = createBottomTabNavigator();
const JobStack      = createNativeStackNavigator();
const InvoiceStack  = createNativeStackNavigator();
const CustomerStack = createNativeStackNavigator();
const MoneyStack    = createNativeStackNavigator();
const ChatStack     = createNativeStackNavigator();
 
// Shared header styling across all stacks
const NAV_OPTS = {
  headerStyle:           { backgroundColor: colors.surface },
  headerTintColor:       colors.accent,
  headerTitleStyle:      { color: colors.textPrimary, fontWeight: "600" },
  headerBackTitleVisible: false,
};
 
// ── Tab stacks ────────────────────────────────────────────────────────────────
 
function TodayTab() {
  return (
    <TodayStack.Navigator screenOptions={NAV_OPTS}>
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
  return (
    <JobStack.Navigator screenOptions={NAV_OPTS}>
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
  return (
    <InvoiceStack.Navigator screenOptions={NAV_OPTS}>
      <InvoiceStack.Screen name="InvoiceList" component={InvoicesScreen}   options={{ title: "Invoices" }} />
      <InvoiceStack.Screen name="AddInvoice"  component={AddInvoiceScreen} options={{ presentation: "modal" }} />
      <InvoiceStack.Screen name="Outreach"    component={OutreachScreen}   options={{ title: "Outreach" }} />
    </InvoiceStack.Navigator>
  );
}
 
function CustomersTab() {
  return (
    <CustomerStack.Navigator screenOptions={NAV_OPTS}>
      <CustomerStack.Screen name="CustomerList"   component={CustomersScreen}       options={{ title: "Customers" }} />
      <CustomerStack.Screen name="CustomerDetail" component={CustomerDetailScreen}  options={{ title: "Customer" }} />
      <CustomerStack.Screen name="AddCustomer"    component={AddCustomerScreen}     options={{ presentation: "modal" }} />
      {/* AddInvoice is here so CustomerDetail can navigate to it within the same tab */}
      <CustomerStack.Screen name="AddInvoice"     component={AddInvoiceScreen}      options={{ presentation: "modal" }} />
      <CustomerStack.Screen name="Outreach"       component={OutreachScreen}        options={{ title: "Outreach" }} />
    </CustomerStack.Navigator>
  );
}

function MoneyTab() {
  return (
    <MoneyStack.Navigator screenOptions={NAV_OPTS}>
      <MoneyStack.Screen name="MoneyHome" component={MoneyScreen} options={{ title: "Money" }} />
    </MoneyStack.Navigator>
  );
}

function ChatTab() {
  return (
    <ChatStack.Navigator screenOptions={NAV_OPTS}>
      <ChatStack.Screen name="ChatHome" component={ChatScreen} options={{ title: "AI Assistant" }} />
    </ChatStack.Navigator>
  );
}
 
// ── Tab icons ─────────────────────────────────────────────────────────────────
 
const TAB_ICONS = {
  Today:     { active: "📅", inactive: "📅" },
  Jobs:      { active: "🔨", inactive: "🔨" },
  Invoices:  { active: "💰", inactive: "💰" },
  Customers: { active: "👤", inactive: "👤" },
  Money:     { active: "💵", inactive: "💵" },
  AI:        { active: "🤖", inactive: "🤖" },
  Settings:  { active: "⚙️", inactive: "⚙️" },
};
 
// ── Root ──────────────────────────────────────────────────────────────────────

function MainTabs() {
  const [nickname, setNickname] = useState("Tradie");

  useEffect(() => {
    loadSettings().then(s => setNickname(getTradeNickname(s?.trade)));
  }, []);

  return (
    <Tab.Navigator
      screenOptions={({ route }) => ({
        headerShown: false,
        tabBarIcon: ({ focused }) => (
          <Text style={{ fontSize: 20 }}>
            {focused
              ? TAB_ICONS[route.name]?.active
              : TAB_ICONS[route.name]?.inactive}
          </Text>
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
  const { session, initializing } = useAuth();
  const [onboardingDone, setOnboardingDone] = useState(null);

  useEffect(() => {
    if (!session) { setOnboardingDone(null); return; }
    isOnboardingComplete().then(setOnboardingDone);
  }, [session]);

  if (initializing || (session && onboardingDone === null)) {
    return (
      <View style={{ flex: 1, justifyContent: "center", alignItems: "center", backgroundColor: colors.background }}>
        <ActivityIndicator color={colors.accent} size="large" />
      </View>
    );
  }

  if (!session) return <AuthScreen />;

  return (
    <NavigationContainer>
      {onboardingDone
        ? <MainTabs />
        : <OnboardingScreen onComplete={() => setOnboardingDone(true)} />
      }
    </NavigationContainer>
  );
}

export default function App() {
  return (
    <SafeAreaProvider>
      <AuthProvider>
        <RootNavigator />
      </AuthProvider>
    </SafeAreaProvider>
  );
}
