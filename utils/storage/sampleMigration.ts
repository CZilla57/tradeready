// Heals installs whose sample data still carries the legacy fixed ids
// (c1..c3, j1..j3, "1".."4"). Those ids collide with other accounts' rows on
// the shared cloud tables, so RLS rejects every push and the sync queue
// wedges permanently (TestFlight finding 2026-07-14, proven via Sentry).
//
// Flag-free and idempotent, modeled on migrateCustomerIdentity: reads raw
// (no seed materialization), rewrites only when legacy ids are present,
// saves only collections that changed (saving re-enqueues them under the
// new ids), and prunes the un-pushable legacy-id items from the queue.

import AsyncStorage from "@react-native-async-storage/async-storage";
import { KEYS } from "./keys";
import { saveCustomers, saveJobs, saveInvoices } from "./collections";
import { saveRecurringJobs } from "./recurringJobs";
import { resolveCustomer } from "./customers";
import { pruneQueueRecords } from "../sync";
import {
  LEGACY_SAMPLE_IDS,
  freshSampleSuffix,
  isSampleId,
  rewriteSampleIds,
  relinkCustomerIds,
} from "../sampleData";
import type { Customer, Job, Invoice, RecurringJob } from "../../types/models";

async function readRaw<T>(key: string): Promise<T[] | null> {
  try {
    const raw = await AsyncStorage.getItem(key);
    return raw ? (JSON.parse(raw) as T[]) : null;
  } catch {
    return null;
  }
}

// Pure core, exported for tests. Repoints recurring rules whose customerId is
// a sample id that no longer resolves: same-run remaps come from idMap; older
// dangles (the customer was remapped in a PREVIOUS run, before rules were
// covered) fall back to the normalized-name join. Conservative on purpose —
// real (non-sample) customerIds and sample ids that still exist are untouched.
export function relinkDanglingRuleCustomers(
  rules: RecurringJob[],
  customers: Customer[],
  idMap: Record<string, string>,
): { changed: boolean; records: RecurringJob[] } {
  let changed = false;
  const liveIds = new Set(customers.map((c) => c.id));
  const records = rules.map((rule) => {
    if (!rule.customerId) return rule;
    const mapped = idMap[rule.customerId];
    if (mapped) {
      changed = true;
      return { ...rule, customerId: mapped };
    }
    if (!isSampleId(rule.customerId) || liveIds.has(rule.customerId)) return rule;
    const match = resolveCustomer(customers, { customerName: rule.customerName });
    if (!match) return rule;
    changed = true;
    return { ...rule, customerId: match.id };
  });
  return { changed, records };
}

export async function migrateSampleDataIds(): Promise<void> {
  const [customers, jobs, invoices, rules] = await Promise.all([
    readRaw<Customer>(KEYS.customers),
    readRaw<Job>(KEYS.jobs),
    readRaw<Invoice>(KEYS.invoices),
    readRaw<RecurringJob>(KEYS.recurringJobs),
  ]);

  const suffix = freshSampleSuffix();
  const idMap: Record<string, string> = {};

  const c = customers ? rewriteSampleIds(customers, suffix, idMap) : null;
  const jRewrite = jobs ? rewriteSampleIds(jobs, suffix, idMap) : null;
  const iRewrite = invoices ? rewriteSampleIds(invoices, suffix, idMap) : null;

  // Follow the customer-id remaps on records that link to them (jobs always;
  // invoices when the identity migration back-filled customerId with a
  // legacy value).
  const j = jRewrite ? relinkCustomerIds(jRewrite.records, idMap) : null;
  const i = iRewrite ? relinkCustomerIds(iRewrite.records, idMap) : null;

  // Recurring rules were not covered until 2026-07-16, so a rule can dangle
  // at an id the customers pass remapped in an earlier run — heal those even
  // when nothing else changed this run. Rules are device-local (not synced),
  // so this save has no queue side effects.
  const r = rules
    ? relinkDanglingRuleCustomers(rules, (c?.records ?? customers) || [], idMap)
    : null;
  if (r?.changed) await saveRecurringJobs(r.records);

  const anyChange =
    (c?.changed ?? false) ||
    (jRewrite?.changed ?? false) || (j?.changed ?? false) ||
    (iRewrite?.changed ?? false) || (i?.changed ?? false);
  if (!anyChange) return;

  // Legacy-id queue items can never push (they collide with another
  // account's rows); the saves below re-enqueue everything under new ids.
  await pruneQueueRecords(LEGACY_SAMPLE_IDS);

  if (c?.changed) await saveCustomers(c.records);
  if (jRewrite?.changed || j?.changed) await saveJobs((j ?? jRewrite)!.records);
  if (iRewrite?.changed || i?.changed) await saveInvoices((i ?? iRewrite)!.records);
}
