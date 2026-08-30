import type { CSSProperties, ReactNode } from 'react';
import type { BadgeColor } from './status';

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
}: {
  label: string;
  value: string;
  hint?: string;
  tone?: 'pos' | 'neg';
}) {
  return (
    <Card className="stat">
      <div className="label">{label}</div>
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
    <div className="page-head">
      <div>
        <h1>{title}</h1>
        {sub && <div className="sub">{sub}</div>}
      </div>
      {right}
    </div>
  );
}

export function Empty({ children }: { children: ReactNode }) {
  return <div className="empty">{children}</div>;
}

export function KV({ k, v }: { k: string; v: ReactNode }) {
  return (
    <div className="kv">
      <span className="k">{k}</span>
      <span className="v">{v}</span>
    </div>
  );
}
