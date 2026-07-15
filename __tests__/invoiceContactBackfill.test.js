// __tests__/invoiceContactBackfill.test.js
// Pure customer→invoice contact backfill: fills a blank invoice email/phone from
// the linked customer, never clobbering a non-blank invoice value.
import { backfillInvoiceContacts } from "../utils/storage";

const cust = (over = {}) => ({ id: "c1", name: "Jane Smith", email: "jane@x.com", phone: "555-1234", address: "", notes: "", ...over });
const inv = (over = {}) => ({ id: "i1", customerId: "c1", customer: "Jane Smith", number: "INV-1", amount: 100, due: "2026-06-01", paid: false, email: "", phone: "", desc: "", ...over });

describe("backfillInvoiceContacts", () => {
  test("fills blank email/phone from the customer matched by customerId", () => {
    const { invoices, changed } = backfillInvoiceContacts([inv()], [cust()]);
    expect(changed).toBe(true);
    expect(invoices[0].email).toBe("jane@x.com");
    expect(invoices[0].phone).toBe("555-1234");
  });

  test("matches by normalized name when the invoice has no customerId", () => {
    const { invoices, changed } = backfillInvoiceContacts(
      [inv({ customerId: undefined, customer: "  jane smith " })],
      [cust()]
    );
    expect(changed).toBe(true);
    expect(invoices[0].email).toBe("jane@x.com");
  });

  test("never clobbers a non-blank invoice value; fills the blank one", () => {
    const { invoices, changed } = backfillInvoiceContacts([inv({ email: "custom@x.com" })], [cust()]);
    expect(changed).toBe(true);
    expect(invoices[0].email).toBe("custom@x.com"); // preserved
    expect(invoices[0].phone).toBe("555-1234");     // filled
  });

  test("leaves an invoice with no matching customer unchanged", () => {
    const { invoices, changed } = backfillInvoiceContacts([inv({ customerId: "cX", customer: "Ghost" })], [cust()]);
    expect(changed).toBe(false);
    expect(invoices[0].email).toBe("");
  });

  test("does nothing when the customer's field is also blank", () => {
    const { changed } = backfillInvoiceContacts([inv()], [cust({ email: "", phone: "" })]);
    expect(changed).toBe(false);
  });

  test("returns changed:false when nothing is fillable (idempotence guard)", () => {
    const { changed } = backfillInvoiceContacts([inv({ email: "jane@x.com", phone: "555-1234" })], [cust()]);
    expect(changed).toBe(false);
  });
});
