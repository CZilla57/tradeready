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
import { pruneQueueRecords } from "../sync";
import {
  LEGACY_SAMPLE_IDS,
  freshSampleSuffix,
  rewriteSampleIds,
  relinkCustomerIds,
} from "../sampleData";
import type { Customer, Job, Invoice } from "../../types/models";

async function readRaw<T>(key: string): Promise<T[] | null> {
  try {
    const raw = await AsyncStorage.getItem(key);
    return raw ? (JSON.parse(raw) as T[]) : null;
  } catch {
    return null;
  }
}

export async function migrateSampleDataIds(): Promise<void> {
  const [customers, jobs, invoices] = await Promise.all([
    readRaw<Customer>(KEYS.customers),
    readRaw<Job>(KEYS.jobs),
    readRaw<Invoice>(KEYS.invoices),
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
