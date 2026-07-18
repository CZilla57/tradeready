// utils/storage/collections.ts
// The four synced domain collections — invoices, jobs, customers, expenses.
// Every load falls back to seed data (or []) on a cold cache; every save writes
// AsyncStorage, diffs old→new into the sync queue, and kicks a background sync.
// Saving invoices also re-derives due-date reminders (syncNotifications).

import AsyncStorage from "@react-native-async-storage/async-storage";
import { enqueueCollectionChanges, trySync } from "../sync";
import { syncNotifications } from "../notifications";
import { KEYS } from "./keys";
import { defaultInvoices, defaultJobs, defaultCustomers } from "./defaults";
import type { Invoice, Job, Customer, Expense } from "../../types/models";

// --- Invoices ---

export async function loadInvoices(): Promise<Invoice[]> {
  try {
    const raw = await AsyncStorage.getItem(KEYS.invoices);
    return raw ? JSON.parse(raw) : defaultInvoices();
  } catch {
    return defaultInvoices();
  }
}

export async function saveInvoices(invoices: Invoice[]): Promise<void> {
  const oldRaw = await AsyncStorage.getItem(KEYS.invoices);
  const old: Invoice[] = oldRaw ? JSON.parse(oldRaw) : [];
  await AsyncStorage.setItem(KEYS.invoices, JSON.stringify(invoices));
  await enqueueCollectionChanges("invoices", old, invoices);
  trySync();
  syncNotifications();
}

// --- Jobs ---

export async function loadJobs(): Promise<Job[]> {
  try {
    const raw = await AsyncStorage.getItem(KEYS.jobs);
    return raw ? JSON.parse(raw) : defaultJobs();
  } catch {
    return defaultJobs();
  }
}

export async function saveJobs(jobs: Job[]): Promise<void> {
  const oldRaw = await AsyncStorage.getItem(KEYS.jobs);
  const old: Job[] = oldRaw ? JSON.parse(oldRaw) : [];
  await AsyncStorage.setItem(KEYS.jobs, JSON.stringify(jobs));
  await enqueueCollectionChanges("jobs", old, jobs);
  trySync();
  syncNotifications();
}

// --- Customers ---

export async function loadCustomers(): Promise<Customer[]> {
  try {
    const raw = await AsyncStorage.getItem(KEYS.customers);
    return raw ? JSON.parse(raw) : defaultCustomers();
  } catch {
    return defaultCustomers();
  }
}

export async function saveCustomers(customers: Customer[]): Promise<void> {
  const oldRaw = await AsyncStorage.getItem(KEYS.customers);
  const old: Customer[] = oldRaw ? JSON.parse(oldRaw) : [];
  await AsyncStorage.setItem(KEYS.customers, JSON.stringify(customers));
  await enqueueCollectionChanges("customers", old, customers);
  trySync();
  syncNotifications();
}

// --- Expenses ---

export async function loadExpenses(): Promise<Expense[]> {
  try {
    const raw = await AsyncStorage.getItem(KEYS.expenses);
    return raw ? JSON.parse(raw) : [];
  } catch {
    return [];
  }
}

export async function saveExpenses(expenses: Expense[]): Promise<void> {
  const oldRaw = await AsyncStorage.getItem(KEYS.expenses);
  const old: Expense[] = oldRaw ? JSON.parse(oldRaw) : [];
  await AsyncStorage.setItem(KEYS.expenses, JSON.stringify(expenses));
  await enqueueCollectionChanges("expenses", old, expenses);
  trySync();
}
