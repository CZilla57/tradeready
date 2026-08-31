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
// This static/source-graph check fails if any web source file OTHER than the
// designated write module adds a Supabase business-data mutation —
// `supabase.from(<table>).insert|update|upsert|delete` — so the read-only
// contract can't regress silently (e.g. a reintroduced generic `upsertRecord`).
// It is a guardrail against accidental drift, NOT a security boundary: ownership
// is enforced by Supabase RLS (auth.uid() = user_id), and no client-side check
// substitutes for that.
//
// Editing (web/EDITING_ROADMAP.md) is introduced as a SINGLE typed write module
// so the "reads and writes live in distinct modules" invariant is machine-
// checked: exactly one file may mutate, every other file stays read-only, and
// that one file must actually be the write path (so a stale allow-list entry
// can't silently disable the guard).

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

// The sole file permitted to mutate business data, relative to web/src. Its own
// mutations are the editing surface (roadmap P0.1+); everything else stays
// read-only.
const WRITE_MODULE = join('lib', 'writeRepository.ts');

describe('read-only architecture', () => {
  const files = collectSourceFiles(srcRoot);

  it('finds source files to scan', () => {
    expect(files.length).toBeGreaterThan(0);
  });

  it('no web source outside the write module performs a Supabase business-data mutation', () => {
    const offenders: string[] = [];
    for (const file of files) {
      if (relative(srcRoot, file) === WRITE_MODULE) continue; // allow-listed
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
        `must live only in ${WRITE_MODULE} (a separate, typed write module — see ` +
        `web/README.md and web/EDITING_ROADMAP.md). Offending files: ${offenders.join(', ')}`,
    ).toEqual([]);
  });

  it('the write module is the actual mutation site (allow-list is not stale)', () => {
    // If writeRepository.ts stops containing a mutation (renamed, gutted), the
    // allow-list above would be masking nothing while a mutation could have
    // moved elsewhere undetected. Require the allow-listed file to genuinely be
    // the write path.
    const source = readFileSync(join(srcRoot, WRITE_MODULE), 'utf8').replace(
      /\s+/g,
      ' ',
    );
    expect(
      MUTATION_RE.test(source),
      `${WRITE_MODULE} is the designated write module but contains no Supabase ` +
        `mutation — move the write path back into it or update WRITE_MODULE.`,
    ).toBe(true);
  });

  it('the repository module exposes readers only', () => {
    const repo = readFileSync(join(srcRoot, 'lib', 'repository.ts'), 'utf8');
    expect(repo).not.toMatch(/\bexport\s+(async\s+)?function\s+upsertRecord\b/);
    expect(repo.replace(/\s+/g, ' ')).not.toMatch(MUTATION_RE);
  });
});
