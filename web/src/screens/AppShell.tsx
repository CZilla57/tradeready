import { NavLink, Outlet } from 'react-router-dom';
import { useAuth } from '../lib/AuthContext';
import { useData } from '../lib/DataContext';
import { Icon, type IconName } from '../ui/Icon';
import logo from '../assets/logo.png';

type NavItem = { to: string; label: string; ico: IconName; end: boolean };

const NAV: NavItem[] = [
  { to: '/', label: 'Today', ico: 'home', end: true },
  { to: '/calendar', label: 'Calendar', ico: 'calendar', end: false },
  { to: '/jobs', label: 'Jobs', ico: 'hammer', end: false },
  { to: '/estimates', label: 'Estimates', ico: 'document-text', end: false },
  { to: '/invoices', label: 'Invoices', ico: 'receipt', end: false },
  { to: '/customers', label: 'Customers', ico: 'people', end: false },
  { to: '/money', label: 'Money', ico: 'cash', end: false },
];

const NAV_MORE: NavItem[] = [
  { to: '/recurring', label: 'Recurring', ico: 'repeat', end: false },
  { to: '/pricebook', label: 'Pricebook', ico: 'pricetags', end: false },
  { to: '/settings', label: 'Settings', ico: 'settings', end: false },
];

export default function AppShell() {
  const { session, signOut } = useAuth();
  const { settings } = useData();
  const business = settings?.businessName?.trim();

  return (
    <div className="app-shell">
      <aside className="sidebar">
        <div className="brand">
          <img className="dot" src={logo} alt="TradeReady logo" />
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
            <span className="ico">
              <Icon name={n.ico} size={18} />
            </span>
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
            <span className="ico">
              <Icon name={n.ico} size={18} />
            </span>
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
