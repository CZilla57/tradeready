// utils/storage.js
// Wraps AsyncStorage so the rest of the app doesn't have to deal with
// JSON serialization or storage keys directly.
// AsyncStorage is like a mini database that lives on the user's phone.
// Sensitive keys (API keys, payment tokens) go through SecureStore instead.

import AsyncStorage from "@react-native-async-storage/async-storage";
import * as SecureStore from "expo-secure-store";
import { enqueue, enqueueCollectionChanges, trySync } from "./sync";
import { syncNotifications } from "./notifications";

// Fields that must live in the iOS Keychain / Android Keystore rather than
// plain AsyncStorage. Both load/saveSettings strip these out before hitting
// AsyncStorage and delegate to SecureStore.
const SECURE_FIELDS = ["providerKey", "anthropicKey", "geminiKey"];

async function loadSecureFields() {
  const result = {};
  for (const field of SECURE_FIELDS) {
    try {
      result[field] = (await SecureStore.getItemAsync(field)) || "";
    } catch {
      result[field] = "";
    }
  }
  return result;
}

async function saveSecureFields(settings) {
  for (const field of SECURE_FIELDS) {
    try {
      await SecureStore.setItemAsync(field, settings[field] || "");
    } catch {
      // SecureStore unavailable in some simulators — silently degrade
    }
  }
}

const KEYS = {
  invoices: "invoices",
  jobs: "jobs",
  customers: "customers",
  settings: "settings",
  expenses: "expenses",
  customerNotes: "customerNotes",
};

// --- Invoices ---

export async function loadInvoices() {
  try {
    const raw = await AsyncStorage.getItem(KEYS.invoices);
    return raw ? JSON.parse(raw) : defaultInvoices();
  } catch {
    return defaultInvoices();
  }
}

export async function saveInvoices(invoices) {
  const oldRaw = await AsyncStorage.getItem(KEYS.invoices);
  const old = oldRaw ? JSON.parse(oldRaw) : [];
  await AsyncStorage.setItem(KEYS.invoices, JSON.stringify(invoices));
  await enqueueCollectionChanges('invoices', old, invoices);
  trySync();
  syncNotifications();
}

// --- Settings ---

export async function loadSettings() {
  try {
    const [raw, secureFields] = await Promise.all([
      AsyncStorage.getItem(KEYS.settings),
      loadSecureFields(),
    ]);
    const base = raw ? JSON.parse(raw) : defaultSettings();
    return { ...base, ...secureFields };
  } catch {
    return defaultSettings();
  }
}

export async function saveSettings(settings) {
  const publicSettings = { ...settings };
  for (const field of SECURE_FIELDS) {
    delete publicSettings[field];
  }
  await Promise.all([
    AsyncStorage.setItem(KEYS.settings, JSON.stringify(publicSettings)),
    saveSecureFields(settings),
  ]);
  await enqueue('settings', 'upsert', 'settings', publicSettings);
  trySync();
  syncNotifications();
}

// --- Jobs ---

export async function loadJobs() {
  try {
    const raw = await AsyncStorage.getItem(KEYS.jobs);
    return raw ? JSON.parse(raw) : defaultJobs();
  } catch {
    return defaultJobs();
  }
}

export async function saveJobs(jobs) {
  const oldRaw = await AsyncStorage.getItem(KEYS.jobs);
  const old = oldRaw ? JSON.parse(oldRaw) : [];
  await AsyncStorage.setItem(KEYS.jobs, JSON.stringify(jobs));
  await enqueueCollectionChanges('jobs', old, jobs);
  trySync();
}

// --- Customers ---

export async function loadCustomers() {
  try {
    const raw = await AsyncStorage.getItem(KEYS.customers);
    return raw ? JSON.parse(raw) : defaultCustomers();
  } catch {
    return defaultCustomers();
  }
}

export async function saveCustomers(customers) {
  const oldRaw = await AsyncStorage.getItem(KEYS.customers);
  const old = oldRaw ? JSON.parse(oldRaw) : [];
  await AsyncStorage.setItem(KEYS.customers, JSON.stringify(customers));
  await enqueueCollectionChanges('customers', old, customers);
  trySync();
}

// --- Expenses ---

export async function loadExpenses() {
  try {
    const raw = await AsyncStorage.getItem(KEYS.expenses);
    return raw ? JSON.parse(raw) : [];
  } catch {
    return [];
  }
}

export async function saveExpenses(expenses) {
  const oldRaw = await AsyncStorage.getItem(KEYS.expenses);
  const old = oldRaw ? JSON.parse(oldRaw) : [];
  await AsyncStorage.setItem(KEYS.expenses, JSON.stringify(expenses));
  await enqueueCollectionChanges('expenses', old, expenses);
  trySync();
}

// --- Customer Notes ---
// Stored as a flat map of { [normalizedName]: noteString } so a single
// read/write covers all customers rather than one key per customer.

export async function loadCustomerNotes() {
  try {
    const raw = await AsyncStorage.getItem(KEYS.customerNotes);
    return raw ? JSON.parse(raw) : {};
  } catch {
    return {};
  }
}

export async function saveCustomerNotes(notesMap) {
  await AsyncStorage.setItem(KEYS.customerNotes, JSON.stringify(notesMap));
}

// Convenience helpers used by CustomerDetailScreen
export async function loadNoteForCustomer(customerName) {
  const notes = await loadCustomerNotes();
  return notes[customerName.trim().toLowerCase()] || '';
}

export async function saveNoteForCustomer(customerName, note) {
  const notes = await loadCustomerNotes();
  const key = customerName.trim().toLowerCase();
  notes[key] = note;
  await saveCustomerNotes(notes);
  await enqueue('customer_notes', 'upsert', key, note);
  trySync();
}

// --- Defaults ---

function defaultCustomers() {
  return [
    {
      id: "c1",
      name: "Riverside Bakery",
      email: "owner@riversidebakery.com",
      phone: "(555) 301-2200",
      address: "142 Mill St, Austin TX 78701",
      notes: "Side entrance is easiest. Ask for Maria.",
    },
    {
      id: "c2",
      name: "Tom Nguyen",
      email: "tom.nguyen@gmail.com",
      phone: "(555) 874-9900",
      address: "88 Oak Lane, Austin TX 78745",
      notes: "Dog in backyard — keep gate closed.",
    },
    {
      id: "c3",
      name: "Patel Family Dental",
      email: "admin@pateldental.com",
      phone: "(555) 440-1133",
      address: "310 Congress Ave, Austin TX 78701",
      notes: "Call ahead — building requires visitor badge.",
    },
  ];
}

function defaultJobs() {
  return [
    {
      id: "j1",
      customerId: "c2",
      customerName: "Tom Nguyen",
      title: "Replace kitchen faucet",
      description: "Customer wants Moen Arbor faucet installed, remove old unit and dispose.",
      status: "scheduled",
      scheduledDate: "2026-06-30",
      scheduledStartTime: "09:00",
      scheduledEndTime: "11:00",
      address: "88 Oak Lane, Austin TX 78745",
      estimateTotal: 285,
      laborHours: 2,
      laborRate: 85,
      materials: [
        { id: "m1", name: "Moen Arbor Faucet", quantity: 1, unitCost: 89 },
        { id: "m2", name: "Supply lines", quantity: 2, unitCost: 8 },
      ],
      materialMarkup: 20,
      overhead: 15,
      margin: 20,
      notes: "",
      invoiceId: null,
      createdAt: "2026-06-25",
    },
    {
      id: "j2",
      customerId: "c1",
      customerName: "Riverside Bakery",
      title: "Fix leaking drain pipe",
      description: "Drain under 3-compartment sink leaking at elbow joint. Replace section.",
      status: "estimate_sent",
      scheduledDate: null,
      scheduledStartTime: null,
      scheduledEndTime: null,
      address: "142 Mill St, Austin TX 78701",
      estimateTotal: 340,
      laborHours: 2.5,
      laborRate: 85,
      materials: [
        { id: "m3", name: "PVC elbow 2in", quantity: 2, unitCost: 4 },
        { id: "m4", name: "PVC pipe 2in x 10ft", quantity: 1, unitCost: 18 },
        { id: "m5", name: "PVC cement kit", quantity: 1, unitCost: 12 },
      ],
      materialMarkup: 20,
      overhead: 15,
      margin: 20,
      notes: "After business hours preferred — call before showing up.",
      invoiceId: null,
      createdAt: "2026-06-23",
    },
    {
      id: "j3",
      customerId: "c3",
      customerName: "Patel Family Dental",
      title: "Water heater replacement",
      description: "50-gal gas water heater, existing unit is 12 years old and leaking.",
      status: "lead",
      scheduledDate: null,
      scheduledStartTime: null,
      scheduledEndTime: null,
      address: "310 Congress Ave, Austin TX 78701",
      estimateTotal: 0,
      laborHours: 0,
      laborRate: 85,
      materials: [],
      materialMarkup: 20,
      overhead: 15,
      margin: 20,
      notes: "Spoke to office manager on 6/24. They want estimate ASAP.",
      invoiceId: null,
      createdAt: "2026-06-24",
    },
  ];
}

function defaultInvoices() {
  return [
    {
      id: "1",
      customer: "Riverside Bakery",
      number: "INV-0038",
      amount: 2400,
      due: "2026-05-10",
      email: "owner@riversidebakery.com",
      phone: "(555) 301-2200",
      desc: "Monthly bookkeeping — April",
      paid: false,
    },
    {
      id: "2",
      customer: "Green Thumb Landscaping",
      number: "INV-0041",
      amount: 875,
      due: "2026-06-01",
      email: "billing@greenthumbla.com",
      phone: "(555) 874-9900",
      desc: "Lawn care contract Q2",
      paid: false,
    },
    {
      id: "3",
      customer: "Patel Family Dental",
      number: "INV-0043",
      amount: 5100,
      due: "2026-06-15",
      email: "admin@pateldental.com",
      phone: "(555) 440-1133",
      desc: "Website + SEO package",
      paid: false,
    },
    {
      id: "4",
      customer: "Blue Ridge Coffee Co.",
      number: "INV-0039",
      amount: 650,
      due: "2026-05-20",
      email: "mgr@blueridgecoffee.com",
      phone: "(555) 920-5544",
      desc: "Logo refresh",
      paid: true,
    },
  ];
}

export function defaultSettings() {
  return {
    // Business info
    businessName: "Your Business Name",
    contactName: "Your Name",
    phone: "",
    email: "",
    address: "",
    trade: "plumbing", // plumbing | electrical | hvac | landscaping | cleaning | painting | handyman | other

    // Pricing defaults — worker sets these once, used in every estimate
    laborRate: 85,          // $ per hour
    materialMarkup: 20,     // % markup on materials (covers cost of sourcing, carrying)
    overheadPercent: 15,    // % for business overhead (insurance, truck, tools)
    marginPercent: 20,      // % profit margin on top
    minimumJobFee: 75,      // minimum charge even for tiny jobs
    travelFeePerMile: 0,    // 0 = no travel fee, otherwise $ per mile
    emergencyMultiplier: 1.5, // after-hours/emergency rate multiplier

    // Payment
    paymentNotes: "Payment due upon completion. We accept check, card, or bank transfer.",
    provider: "stripe",
    providerKey: "",

    // Notifications — days after due date to send a reminder
    rules: [{ days: 1 }, { days: 7 }],

    // AI
    anthropicKey: "",
    geminiKey: "",
  };
}

// --- Onboarding ---

export async function isOnboardingComplete() {
  try {
    const val = await AsyncStorage.getItem('onboardingComplete');
    if (val === 'true') return true;
    // Graceful fallback: users who set up the app before onboarding existed
    const settings = await loadSettings();
    return settings.businessName !== defaultSettings().businessName;
  } catch {
    return false;
  }
}

export async function markOnboardingComplete() {
  await AsyncStorage.setItem('onboardingComplete', 'true');
}

export async function clearSampleData() {
  await Promise.all([
    AsyncStorage.setItem(KEYS.customers, JSON.stringify([])),
    AsyncStorage.setItem(KEYS.jobs, JSON.stringify([])),
    AsyncStorage.setItem(KEYS.invoices, JSON.stringify([])),
  ]);
}

// Wipes all local user data on sign-out so the next user to sign in on this
// device cannot inherit another user's records or trigger an accidental cloud push.
export async function clearAllUserData() {
  await AsyncStorage.multiRemove([
    ...Object.values(KEYS),
    '__syncQueue',
    '__lastSyncedAt',
    'onboardingComplete',
  ]);
  for (const field of SECURE_FIELDS) {
    try { await SecureStore.deleteItemAsync(field); } catch {}
  }
}

// --- Daily Operations (Today Tab) ---

export async function loadJobsForDate(dateString) {
  try {
    const allJobs = await loadJobs();
    
    // Filter by date and sort chronologically by start time
    return allJobs
      .filter((job) => job.scheduledDate === dateString)
      .sort((a, b) => {
        // Push jobs without a start time to the end of the day
        if (!a.scheduledStartTime) return 1;
        if (!b.scheduledStartTime) return -1;
        return a.scheduledStartTime.localeCompare(b.scheduledStartTime);
      });
  } catch (error) {
    console.error("Error loading jobs for date:", error);
    return [];
  }
}

export async function getExpectedEarningsForDate(dateString) {
  try {
    const todaysJobs = await loadJobsForDate(dateString);

    // Sum the estimated totals to calculate expected daily revenue
    const total = todaysJobs.reduce((sum, job) => {
      return sum + (Number(job.estimateTotal) || 0);
    }, 0);

    return total;
  } catch (error) {
    console.error("Error calculating expected earnings:", error);
    return 0;
  }
}

export async function loadOverdueInvoices() {
  try {
    const invoices = await loadInvoices();
    const today = new Date();
    today.setHours(0, 0, 0, 0);
    return invoices
      .filter((inv) => !inv.paid && new Date(inv.due) < today)
      .sort((a, b) => new Date(a.due) - new Date(b.due));
  } catch {
    return [];
  }
}

export async function loadLeadJobs() {
  try {
    const jobs = await loadJobs();
    return jobs
      .filter((j) => j.status === "lead")
      .sort((a, b) => new Date(a.createdAt || 0) - new Date(b.createdAt || 0));
  } catch {
    return [];
  }
}