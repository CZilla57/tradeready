import { Navigate, Route, Routes } from 'react-router-dom';
import { useAuth } from './lib/AuthContext';
import { DataProvider } from './lib/DataContext';
import AppShell from './screens/AppShell';
import LoginScreen from './screens/LoginScreen';
import ResetPasswordScreen from './screens/ResetPasswordScreen';
import TodayScreen from './screens/TodayScreen';
import JobsScreen from './screens/JobsScreen';
import JobDetailScreen from './screens/JobDetailScreen';
import InvoicesScreen from './screens/InvoicesScreen';
import InvoiceDetailScreen from './screens/InvoiceDetailScreen';
import CustomersScreen from './screens/CustomersScreen';
import CustomerDetailScreen from './screens/CustomerDetailScreen';
import MoneyScreen from './screens/MoneyScreen';
import CalendarScreen from './screens/CalendarScreen';
import EstimatesScreen from './screens/EstimatesScreen';
import EstimateDetailScreen from './screens/EstimateDetailScreen';
import RecurringScreen from './screens/RecurringScreen';
import PricebookScreen from './screens/PricebookScreen';
import PricebookDetailScreen from './screens/PricebookDetailScreen';
import SettingsScreen from './screens/SettingsScreen';
import NotFoundScreen from './screens/NotFoundScreen';

export default function App() {
  const { session, initializing, recovery } = useAuth();

  if (initializing) {
    return <div className="empty">Loading…</div>;
  }

  // Password recovery takes precedence over the ordinary authenticated redirect:
  // a recovery session must land on the password-update screen and cannot fall
  // through into the portal until the user sets a new password (or signs out).
  if (recovery) {
    return (
      <Routes>
        <Route path="/reset-password" element={<ResetPasswordScreen />} />
        <Route path="*" element={<Navigate to="/reset-password" replace />} />
      </Routes>
    );
  }

  if (!session) {
    return (
      <Routes>
        {/* Reachable while signed out so expired/invalid recovery links (which
            create no session) still render a clear path back to requesting a
            new reset email. */}
        <Route path="/reset-password" element={<ResetPasswordScreen />} />
        <Route path="/login" element={<LoginScreen />} />
        <Route path="*" element={<Navigate to="/login" replace />} />
      </Routes>
    );
  }

  return (
    <DataProvider>
      <Routes>
        <Route element={<AppShell />}>
          <Route path="/" element={<TodayScreen />} />
          <Route path="/calendar" element={<CalendarScreen />} />
          <Route path="/jobs" element={<JobsScreen />} />
          <Route path="/jobs/:id" element={<JobDetailScreen />} />
          <Route path="/estimates" element={<EstimatesScreen />} />
          <Route path="/estimates/:id" element={<EstimateDetailScreen />} />
          <Route path="/invoices" element={<InvoicesScreen />} />
          <Route path="/invoices/:id" element={<InvoiceDetailScreen />} />
          <Route path="/customers" element={<CustomersScreen />} />
          <Route path="/customers/:id" element={<CustomerDetailScreen />} />
          <Route path="/money" element={<MoneyScreen />} />
          <Route path="/recurring" element={<RecurringScreen />} />
          <Route path="/pricebook" element={<PricebookScreen />} />
          <Route path="/pricebook/:id" element={<PricebookDetailScreen />} />
          <Route path="/settings" element={<SettingsScreen />} />
          {/* Unknown paths keep the app shell (nav stays visible) and show a
              real not-found view rather than silently redirecting home. */}
          <Route path="*" element={<NotFoundScreen />} />
        </Route>
      </Routes>
    </DataProvider>
  );
}
