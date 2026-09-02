import type { CSSProperties, ReactNode } from 'react';
import type { BadgeColor } from './status';
import { Icon, type IconName } from './Icon';

export function Card({
  children,
  pad = false,
  className = '',
  style,
}: {
  children: ReactNode;
  pad?: boolean;
  className?: string;
  style?: CSSProperties;
}) {
  return (
    <div
      className={`card ${pad ? 'card-pad' : ''} ${className}`.trim()}
      style={style}
    >
      {children}
    </div>
  );
}

export function Badge({
  color,
  children,
}: {
  color: BadgeColor;
  children: ReactNode;
}) {
  return <span className={`badge ${color}`}>{children}</span>;
}

export function Stat({
  label,
  value,
  hint,
  tone,
  icon,
}: {
  label: string;
  value: string;
  hint?: string;
  tone?: 'pos' | 'neg';
  icon?: IconName;
}) {
  return (
    <Card className={`stat ${tone ? `stat-${tone}` : ''}`.trim()}>
      <span className="stat-rule" aria-hidden="true" />
      <div className="stat-topline">
        <div className="label">{label}</div>
        {icon && (
          <span className="stat-icon" aria-hidden="true">
            <Icon name={icon} size={18} />
          </span>
        )}
      </div>
      <div className={`value ${tone ?? ''}`.trim()}>{value}</div>
      {hint && <div className="hint">{hint}</div>}
    </Card>
  );
}

export function PageHead({
  title,
  sub,
  right,
}: {
  title: string;
  sub?: string;
  right?: ReactNode;
}) {
  return (
    <header className="page-head">
      <div className="page-head-copy">
        <h1>{title}</h1>
        {sub && <div className="sub">{sub}</div>}
      </div>
      {right}
    </header>
  );
}

export function Empty({ children }: { children: ReactNode }) {
  const loading = typeof children === 'string' && children.startsWith('Loading');
  return <div className={`empty${loading ? ' loading-state' : ''}`}>{children}</div>;
}

/**
 * A scoped load failure with a retry action. Shown in place of a screen's body
 * when the resources it needs failed and there is no prior data to fall back
 * on — an unrelated collection failing never reaches here.
 */
export function ErrorState({
  message,
  onRetry,
}: {
  message: string;
  onRetry: () => void;
}) {
  return (
    <div className="error-state" role="alert" aria-live="polite">
      <div className="error-state-msg">{message}</div>
      <button type="button" className="retry-btn" onClick={onRetry}>
        Retry
      </button>
    </div>
  );
}

export function KV({ k, v }: { k: string; v: ReactNode }) {
  return (
    <div className="kv">
      <span className="k">{k}</span>
      <span className="v">{v}</span>
    </div>
  );
}
