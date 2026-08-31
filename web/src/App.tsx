import { lazy, Suspense } from 'react';
import { Navigate, Route, Routes } from 'react-router-dom';
import { useAuth } from './lib/AuthContext';
import { DataProvider } from './lib/DataContext';

// Route-level code splitting: each screen is its own async chunk, so the
// initial bundle carries only the shell + auth path and a viewer downloads a
// screen's code the first time they visit it. AppShell stays eager — it's the
// layout every authenticated route mounts inside, so splitting it would only
// add a redundant chunk boundary.
import AppShell from './screens/AppShell';

const LoginScreen = lazy(() => import('./screens/LoginScreen'));
const ResetPasswordScreen = lazy(() => import('./screens/ResetPasswordScreen'));
const TodayScreen = lazy(() => import('./screens/TodayScreen'));
const JobsScreen = lazy(() => import('./screens/JobsScreen'));
const JobDetailScreen = lazy(() => import('./screens/JobDetailScreen'));
const InvoicesScreen = lazy(() => import('./screens/InvoicesScreen'));
const InvoiceDetailScreen = lazy(() => import('./screens/InvoiceDetailScreen'));
const CustomersScreen = lazy(() => import('./screens/CustomersScreen'));
const CustomerDetailScreen = lazy(() => import('./screens/CustomerDetailScreen'));
const MoneyScreen = lazy(() => import('./screens/MoneyScreen'));
const CalendarScreen = lazy(() => import('./screens/CalendarScreen'));
const EstimatesScreen = lazy(() => import('./screens/EstimatesScreen'));
const EstimateDetailScreen = lazy(() => import('./screens/EstimateDetailScreen'));
const RecurringScreen = lazy(() => import('./screens/RecurringScreen'));
const PricebookScreen = lazy(() => import('./screens/PricebookScreen'));
const PricebookDetailScreen = lazy(() => import('./screens/PricebookDetailScreen'));
const SettingsScreen = lazy(() => import('./screens/SettingsScreen'));
const NotFoundScreen = lazy(() => import('./screens/NotFoundScreen'));

function Fallback() {
  return <div className="empty">Loading…</div>;
}

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
      <Suspense fallback={<Fallback />}>
        <Routes>
          <Route path="/reset-password" element={<ResetPasswordScreen />} />
          <Route path="*" element={<Navigate to="/reset-password" replace />} />
        </Routes>
      </Suspense>
    );
  }

  if (!session) {
    return (
      <Suspense fallback={<Fallback />}>
        <Routes>
          {/* Reachable while signed out so expired/invalid recovery links (which
              create no session) still render a clear path back to requesting a
              new reset email. */}
          <Route path="/reset-password" element={<ResetPasswordScreen />} />
          <Route path="/login" element={<LoginScreen />} />
          <Route path="*" element={<Navigate to="/login" replace />} />
        </Routes>
      </Suspense>
    );
  }

  return (
    <DataProvider>
      <Suspense fallback={<Fallback />}>
        <Routes>
          {/* Auth-only paths a signed-out visitor was parked on (the signed-out
              catch-all sends everything to /login). Once the session exists we
              bounce them home instead of falling through to the not-found view. */}
          <Route path="/login" element={<Navigate to="/" replace />} />
          <Route path="/reset-password" element={<Navigate to="/" replace />} />
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
      </Suspense>
    </DataProvider>
  );
}
