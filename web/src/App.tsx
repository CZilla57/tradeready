import { Navigate, Route, Routes } from 'react-router-dom';
import { useAuth } from './lib/AuthContext';
import { DataProvider } from './lib/DataContext';
import AppShell from './screens/AppShell';
import LoginScreen from './screens/LoginScreen';
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

export default function App() {
  const { session, initializing } = useAuth();

  if (initializing) {
    return <div className="empty">Loading…</div>;
  }

  if (!session) {
    return (
      <Routes>
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
        </Route>
        <Route path="*" element={<Navigate to="/" replace />} />
      </Routes>
    </DataProvider>
  );
}
