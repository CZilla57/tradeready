// utils/customerList.ts
// Derives the unified customer list from invoices + manually added customer
// records (roadmap #5), extracted from CustomersScreen so the join/rollup — the
// de-facto customer identity — is unit-tested. Keyed on the real customer.id:
// invoices join by their customerId, fall back to matching a record by
// normalized name, and finally derive a name-keyed entry so an un-migrated
// invoice-only customer still appears. Sorted by lifetime spend.

import { parseNumberInput } from "./numberInput";
import type { Invoice, Customer } from "../types/models";

export interface CustomerListEntry {
  id: string;
  name: string;
  email: string;
  phone: string;
  /** Only carried on real records (manual seed); absent on invoice-derived entries. */
  notes?: string;
  invoices: Invoice[];
  totalSpent: number;
  totalOwed: number;
  isManual: boolean;
}

const nameKeyOf = (s: string | null | undefined): string => (s || "").trim().toLowerCase();

export function buildCustomerList(
  invoices: Invoice[],
  manualCustomers: Customer[],
): CustomerListEntry[] {
  const byId: Record<string, CustomerListEntry> = {};
  const idByName: Record<string, string> = {};

  // Seed from real customer records — post-#5 every customer has one.
  manualCustomers.forEach((mc) => {
    if (!mc.id) return;
    byId[mc.id] = {
      id: mc.id,
      name: mc.name?.trim() || "",
      email: mc.email || "",
      phone: mc.phone || "",
      notes: mc.notes || "",
      invoices: [],
      totalSpent: 0,
      totalOwed: 0,
      isManual: true,
    };
    const key = nameKeyOf(mc.name);
    if (key) idByName[key] = mc.id;
  });

  // Aggregate invoices onto their customer, by id → name → derived name-key.
  invoices.forEach((inv) => {
    const nameKey = nameKeyOf(inv.customer);
    let id = inv.customerId || (nameKey ? idByName[nameKey] : "");
    if (!id) {
      if (!nameKey) return;
      id = nameKey; // invoice-only customer, not yet migrated
      idByName[nameKey] = id;
    }

    if (!byId[id]) {
      byId[id] = {
        id,
        name: inv.customer?.trim() || "",
        email: inv.email || "",
        phone: inv.phone || "",
        invoices: [],
        totalSpent: 0,
        totalOwed: 0,
        isManual: false,
      };
    }

    const entry = byId[id];
    entry.invoices.push(inv);
    entry.totalSpent += inv.paid ? parseNumberInput(inv.amount, 0) : 0;
    entry.totalOwed += !inv.paid ? parseNumberInput(inv.amount, 0) : 0;
    if (inv.email) entry.email = inv.email;
    if (inv.phone) entry.phone = inv.phone;
  });

  return Object.values(byId).sort((a, b) => b.totalSpent - a.totalSpent);
}
