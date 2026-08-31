import { describe, it, expect } from 'vitest';
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join, relative } from 'node:path';

// Read-only architecture guard.
//
// The web portal is a read-first business-data portal: it reads Supabase but
// never writes TradeReady business records. The *only* legitimate mutations are
// authentication/account operations, which go through the `supabase.auth.*` API
// (login, signup, OAuth, password reset/update, logout) — never through a
// business-data table.
//
// This static/source-graph check fails if any web source file adds a Supabase
// business-data mutation — `supabase.from(<table>).insert|update|upsert|delete`
// — so the read-only contract can't regress silently (e.g. a reintroduced
// generic `upsertRecord`). It is a guardrail against accidental drift, NOT a
// security boundary: ownership is enforced by Supabase RLS (auth.uid() =
// user_id), and no client-side check substitutes for that.

const here = dirname(fileURLToPath(import.meta.url));
const srcRoot = join(here, '..'); // web/src

function collectSourceFiles(dir: string): string[] {
  const out: string[] = [];
  for (const entry of readdirSync(dir)) {
    const full = join(dir, entry);
    if (statSync(full).isDirectory()) {
      out.push(...collectSourceFiles(full));
      continue;
    }
    // Only real source files; skip tests (which mock/reference these APIs).
    if (!/\.(ts|tsx)$/.test(entry)) continue;
    if (/\.test\.(ts|tsx)$/.test(entry)) continue;
    out.push(full);
  }
  return out;
}

// Match a Supabase table mutation, tolerating line breaks between the
// `.from(...)` call and the mutating method.
const MUTATION_RE =
  /\.from\s*\([^)]*\)\s*\.\s*(insert|update|upsert|delete)\s*\(/;

describe('read-only architecture', () => {
  const files = collectSourceFiles(srcRoot);

  it('finds source files to scan', () => {
    expect(files.length).toBeGreaterThan(0);
  });

  it('no web source performs a Supabase business-data mutation', () => {
    const offenders: string[] = [];
    for (const file of files) {
      // Collapse whitespace so a `.from(...)` chain split across lines is still
      // matched as one call.
      const source = readFileSync(file, 'utf8').replace(/\s+/g, ' ');
      if (MUTATION_RE.test(source)) {
        offenders.push(relative(srcRoot, file));
      }
    }
    expect(
      offenders,
      `read-only portal: business-data mutations (.from(...).insert|update|upsert|delete) ` +
        `must not exist in web source. Writes belong in a separate, typed write ` +
        `module (see web/README.md). Offending files: ${offenders.join(', ')}`,
    ).toEqual([]);
  });

  it('the repository module exposes readers only', () => {
    const repo = readFileSync(join(srcRoot, 'lib', 'repository.ts'), 'utf8');
    expect(repo).not.toMatch(/\bexport\s+(async\s+)?function\s+upsertRecord\b/);
    expect(repo.replace(/\s+/g, ' ')).not.toMatch(MUTATION_RE);
  });
});
