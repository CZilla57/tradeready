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
  const accountLabel = business || session?.user?.email || 'TradeReady account';
  const accountInitial = accountLabel.charAt(0).toUpperCase();

  return (
    <div className="app-shell">
      <a className="skip-link" href="#main-content">
        Skip to main content
      </a>
      <aside className="sidebar">
        <NavLink className="brand" to="/" aria-label="TradeReady home">
          <img className="dot" src={logo} alt="" width="40" height="40" />
          <span className="brand-copy">
            <strong>TradeReady</strong>
            <small>Owner workspace</small>
          </span>
        </NavLink>
        <nav className="portal-nav" aria-label="Portal navigation">
          <div className="nav-group">
            <div className="nav-group-label">Work</div>
            {NAV.map((n) => (
              <NavLink
                key={n.to}
                to={n.to}
                end={n.end}
                className={({ isActive }) =>
                  `nav-link ${isActive ? 'active' : ''}`.trim()
                }
              >
                <span className="ico" aria-hidden="true">
                  <Icon name={n.ico} size={19} />
                </span>
                <span>{n.label}</span>
              </NavLink>
            ))}
          </div>
          <div className="nav-group">
            <div className="nav-group-label">Business</div>
            {NAV_MORE.map((n) => (
              <NavLink
                key={n.to}
                to={n.to}
                end={n.end}
                className={({ isActive }) =>
                  `nav-link ${isActive ? 'active' : ''}`.trim()
                }
              >
                <span className="ico" aria-hidden="true">
                  <Icon name={n.ico} size={19} />
                </span>
                <span>{n.label}</span>
              </NavLink>
            ))}
          </div>
        </nav>
        <div className="spacer" />
        <div className="account-card">
          <span className="account-avatar" aria-hidden="true">
            {accountInitial}
          </span>
          <span className="account-copy">
            <strong>{business || 'Your business'}</strong>
            <small>{session?.user?.email}</small>
          </span>
          <button
            type="button"
            className="signout"
            onClick={() => void signOut()}
          >
            Sign out
          </button>
        </div>
      </aside>
      <main className="main" id="main-content" tabIndex={-1}>
        <div className="page">
          <Outlet />
        </div>
      </main>
    </div>
  );
}
