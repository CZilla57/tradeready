import { NavLink, Outlet } from 'react-router-dom';
import { useAuth } from '../lib/AuthContext';
import { useData } from '../lib/DataContext';

const NAV = [
  { to: '/', label: 'Today', ico: '🏠', end: true },
  { to: '/calendar', label: 'Calendar', ico: '📅', end: false },
  { to: '/jobs', label: 'Jobs', ico: '🧰', end: false },
  { to: '/estimates', label: 'Estimates', ico: '📝', end: false },
  { to: '/invoices', label: 'Invoices', ico: '🧾', end: false },
  { to: '/customers', label: 'Customers', ico: '👥', end: false },
  { to: '/money', label: 'Money', ico: '💰', end: false },
];

const NAV_MORE = [
  { to: '/recurring', label: 'Recurring', ico: '🔁', end: false },
  { to: '/pricebook', label: 'Pricebook', ico: '📗', end: false },
  { to: '/settings', label: 'Settings', ico: '⚙️', end: false },
];

export default function AppShell() {
  const { session, signOut } = useAuth();
  const { settings } = useData();
  const business = settings?.businessName?.trim();

  return (
    <div className="app-shell">
      <aside className="sidebar">
        <div className="brand">
          <span className="dot">🔧</span>
          <span>TradeReady</span>
        </div>
        {NAV.map((n) => (
          <NavLink
            key={n.to}
            to={n.to}
            end={n.end}
            className={({ isActive }) =>
              `nav-link ${isActive ? 'active' : ''}`.trim()
            }
          >
            <span className="ico">{n.ico}</span>
            <span>{n.label}</span>
          </NavLink>
        ))}
        <div className="nav-sep" />
        {NAV_MORE.map((n) => (
          <NavLink
            key={n.to}
            to={n.to}
            end={n.end}
            className={({ isActive }) =>
              `nav-link ${isActive ? 'active' : ''}`.trim()
            }
          >
            <span className="ico">{n.ico}</span>
            <span>{n.label}</span>
          </NavLink>
        ))}
        <div className="spacer" />
        <div className="userline">
          {business ? `${business} · ` : ''}
          {session?.user?.email}
        </div>
        <button className="signout" onClick={() => void signOut()}>
          Sign out
        </button>
      </aside>
      <main className="main">
        <div className="page">
          <Outlet />
        </div>
      </main>
    </div>
  );
}
