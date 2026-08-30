import { Link } from 'react-router-dom';

export default function NotFoundScreen() {
  return (
    <div className="empty">
      <div style={{ fontSize: 21, fontWeight: 700, color: 'var(--text)' }}>
        Page not found
      </div>
      <div style={{ marginTop: 8 }}>
        That page doesn’t exist in your portal.
      </div>
      <Link to="/" className="back-link" style={{ marginTop: 16 }}>
        ‹ Back to Today
      </Link>
    </div>
  );
}
