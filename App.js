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
//   PricingCalculator    → PricingCalculatorScreen
//   CreateInvoiceFromJob → CreateInvoiceFromJobScreen
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
// Settings (top-level tab, no nested stack needed):
//   SettingsScreen
//
// MoneyTab:
//   MoneyHome  → MoneyScreen
//   LogExpense → LogExpenseScreen
 
import React from "react";
import { NavigationContainer } from "@react-navigation/native";
import { createBottomTabNavigator } from "@react-navigation/bottom-tabs";
import { createNativeStackNavigator } from "@react-navigation/native-stack";
import { SafeAreaProvider } from "react-native-safe-area-context";
import { Text } from "react-native";
 
// Screens
import InvoicesScreen              from "./screens/InvoicesScreen";
import AddInvoiceScreen            from "./screens/AddInvoiceScreen";
import OutreachScreen              from "./screens/OutreachScreen";
import JobsScreen                  from "./screens/JobsScreen";
import JobDetailScreen             from "./screens/JobDetailScreen";
import AddJobScreen                from "./screens/AddJobScreen";
import PricingCalculatorScreen     from "./screens/PricingCalculatorScreen";
import CreateInvoiceFromJobScreen  from "./screens/CreateInvoiceFromJobScreen";
import CustomersScreen             from "./screens/CustomersScreen";
import CustomerDetailScreen        from "./screens/CustomerDetailScreen";
import AddCustomerScreen           from "./screens/AddCustomerScreen";
import SettingsScreen              from "./screens/SettingsScreen";
import TodayScreen                 from "./screens/TodayScreen";
import MoneyScreen                 from "./screens/MoneyScreen";
 
import { colors, fontSize } from "./utils/theme";
 
const TodayStack    = createNativeStackNavigator();
const Tab           = createBottomTabNavigator();
const JobStack      = createNativeStackNavigator();
const InvoiceStack  = createNativeStackNavigator();
const CustomerStack = createNativeStackNavigator();
const MoneyStack    = createNativeStackNavigator();
 
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
 
// ── Tab icons ─────────────────────────────────────────────────────────────────
 
const TAB_ICONS = {
  Today:     { active: "📅", inactive: "📅" },
  Jobs:      { active: "🔨", inactive: "🔨" },
  Invoices:  { active: "💰", inactive: "💰" },
  Customers: { active: "👤", inactive: "👤" },
  Money:     { active: "💵", inactive: "💵" },
  Settings:  { active: "⚙️", inactive: "⚙️" },
};
 
// ── Root ──────────────────────────────────────────────────────────────────────
 
export default function App() {
  return (
    <SafeAreaProvider>
      <NavigationContainer>
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
            tabBarActiveTintColor:  colors.accent,
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
      </NavigationContainer>
    </SafeAreaProvider>
  );
}
