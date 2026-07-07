// __tests__/customerIdentity.test.js
// Roadmap #5 (step 5.1): the customer-registry primitive + the one-time,
// idempotent backfill that unifies the dual customer-identity model.

import AsyncStorage from "@react-native-async-storage/async-storage";
import {
  upsertCustomerInList,
  getOrCreateCustomer,
  updateCustomerNotes,
  migrateCustomerIdentity,
  loadCustomers,
  loadInvoices,
  loadJobs,
} from "../utils/storage";

// Isolate storage from sync / notification side-effects.
jest.mock("../utils/sync", () => ({
  enqueue: jest.fn(),
  enqueueCollectionChanges: jest.fn(),
  trySync: jest.fn(),
}));
jest.mock("../utils/notifications", () => ({ syncNotifications: jest.fn() }));

// Back AsyncStorage with a real in-memory store so load/save round-trip.
let store;
beforeEach(() => {
  jest.clearAllMocks();
  store = {};
  AsyncStorage.getItem.mockImplementation((k) =>
    Promise.resolve(k in store ? store[k] : null)
  );
  AsyncStorage.setItem.mockImplementation((k, v) => {
    store[k] = v;
    return Promise.resolve();
  });
});

const seed = (obj) => {
  for (const [k, v] of Object.entries(obj)) store[k] = JSON.stringify(v);
};

// ── upsertCustomerInList (pure core) ──────────────────────────────────────────

describe("upsertCustomerInList", () => {
  test("creates a fresh record with a c-id when the name is new", () => {
    const { customer, customers, changed } = upsertCustomerInList([], {
      name: "  Jane Smith ",
      email: "jane@x.com",
    });
    expect(changed).toBe(true);
    expect(customers).toHaveLength(1);
    expect(customer.id).toMatch(/^c\d+_\d+$/);
    expect(customer.name).toBe("Jane Smith"); // trimmed
    expect(customer.email).toBe("jane@x.com");
    expect(customer.notes).toBe("");
  });

  test("matches an existing record by normalized name (case/space-insensitive)", () => {
    const existing = [{ id: "c1", name: "Jane Smith", email: "jane@x.com", phone: "", address: "", notes: "" }];
    const { customer, changed } = upsertCustomerInList(existing, { name: "jane smith" });
    expect(customer.id).toBe("c1");
    expect(changed).toBe(false);
  });

  test("backfills only blank contact fields, never clobbering existing data", () => {
    const existing = [{ id: "c1", name: "Jane", email: "old@x.com", phone: "", address: "", notes: "" }];
    const { customer, changed } = upsertCustomerInList(existing, {
      name: "Jane",
      email: "new@x.com", // ignored — email already set
      phone: "555-1234",  // filled — phone was blank
    });
    expect(changed).toBe(true);
    expect(customer.email).toBe("old@x.com");
    expect(customer.phone).toBe("555-1234");
  });

  test("a blank name yields no customer and no change", () => {
    const { customer, changed } = upsertCustomerInList([], { name: "   " });
    expect(customer).toBeNull();
    expect(changed).toBe(false);
  });
});

// ── getOrCreateCustomer (async wrapper) ───────────────────────────────────────

describe("getOrCreateCustomer", () => {
  test("creates + persists a new record", async () => {
    seed({ customers: [] });
    const c = await getOrCreateCustomer({ name: "Bob Lee", phone: "555" });
    expect(c.name).toBe("Bob Lee");
    const saved = await loadCustomers();
    expect(saved).toHaveLength(1);
    expect(saved[0].id).toBe(c.id);
  });

  test("returns the existing record without duplicating it", async () => {
    seed({ customers: [{ id: "c1", name: "Bob Lee", email: "", phone: "555", address: "", notes: "" }] });
    const c = await getOrCreateCustomer({ name: "bob lee" });
    expect(c.id).toBe("c1");
    expect(await loadCustomers()).toHaveLength(1);
  });
});

// ── updateCustomerNotes (record.notes is the single home since #5) ────────────

describe("updateCustomerNotes", () => {
  test("updates the notes on an existing record (matched by id)", async () => {
    seed({ customers: [{ id: "c1", name: "Jane", email: "", phone: "", address: "", notes: "old" }] });
    const id = await updateCustomerNotes({ id: "c1", name: "Jane" }, "new note");
    expect(id).toBe("c1");
    const [saved] = await loadCustomers();
    expect(saved.notes).toBe("new note");
  });

  test("promotes an invoice-derived customer (name-key id, no record) then sets notes", async () => {
    seed({ customers: [] });
    // CustomerDetail passes a customer whose id is the name-key with no record.
    const id = await updateCustomerNotes(
      { id: "jane smith", name: "Jane Smith", email: "jane@x.com" },
      "prefers mornings"
    );
    const customers = await loadCustomers();
    expect(customers).toHaveLength(1);
    expect(customers[0].id).toBe(id);
    expect(customers[0].id).not.toBe("jane smith"); // promoted to a real c-id
    expect(customers[0].notes).toBe("prefers mornings");
  });
});

// ── migrateCustomerIdentity (backfill) ────────────────────────────────────────

describe("migrateCustomerIdentity", () => {
  test("stamps customerId on invoices/orphan-jobs and merges notes", async () => {
    seed({
      invoices: [{ id: "i1", customer: "Jane Smith", email: "jane@x.com", amount: 100, paid: true }],
      jobs: [{ id: "j1", customerId: "", customerName: "Bob Lee" }],
      customers: [],
      customerNotes: { "jane smith": "VIP client" },
    });

    const result = await migrateCustomerIdentity();
    expect(result).toEqual({ customersChanged: true, invoicesChanged: true, jobsChanged: true });

    const customers = await loadCustomers();
    const jane = customers.find((c) => c.name === "Jane Smith");
    const bob = customers.find((c) => c.name === "Bob Lee");
    expect(jane).toBeDefined();
    expect(jane.email).toBe("jane@x.com");
    expect(jane.notes).toBe("VIP client"); // merged from the notes map
    expect(bob).toBeDefined();

    const [inv] = await loadInvoices();
    const [job] = await loadJobs();
    expect(inv.customerId).toBe(jane.id);
    expect(job.customerId).toBe(bob.id);
  });

  test("is idempotent — a second run changes nothing", async () => {
    seed({
      invoices: [{ id: "i1", customer: "Jane Smith", email: "jane@x.com", amount: 100, paid: true }],
      jobs: [{ id: "j1", customerId: "", customerName: "Bob Lee" }],
      customers: [],
      customerNotes: {},
    });

    await migrateCustomerIdentity();
    const afterFirst = await loadCustomers();

    const second = await migrateCustomerIdentity();
    expect(second).toEqual({ customersChanged: false, invoicesChanged: false, jobsChanged: false });
    expect(await loadCustomers()).toHaveLength(afterFirst.length);
  });

  test("reuses one record when an invoice and a job share a name", async () => {
    seed({
      invoices: [{ id: "i1", customer: "Sam Park", amount: 50, paid: false }],
      jobs: [{ id: "j1", customerId: "", customerName: "sam park" }],
      customers: [],
      customerNotes: {},
    });

    await migrateCustomerIdentity();
    const customers = await loadCustomers();
    expect(customers.filter((c) => c.name.toLowerCase() === "sam park")).toHaveLength(1);

    const [inv] = await loadInvoices();
    const [job] = await loadJobs();
    expect(inv.customerId).toBe(job.customerId);
  });
});
