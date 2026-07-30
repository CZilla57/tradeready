// __tests__/pdfBizHeader.test.js
// The business address used to be joined onto the contact line
// (`contact · phone · email · address`), which made that line long enough to
// wrap mid-address on both documents. The address now renders on its own line
// in a `.biz-addr` div. Both templates share one helper, so these tests run the
// same assertions against each to keep them from drifting apart.

import { invoiceHtml, estimateHtml } from "../utils/pdfTemplates";

const BIZ = {
  businessName: "Acme Plumbing",
  contactName: "Chad",
  phone: "(512) 555-0142",
  email: "chad@acmeplumbing.com",
  address: "123 Main St, Austin TX 78701",
};

const INVOICE = {
  id: "inv1700000000000",
  number: "INV-0001",
  customer: "Dana Reyes",
  email: "dana@example.com",
  phone: "(512) 555-0199",
  desc: "Water heater replacement",
  amount: 850,
  due: "2026-08-15",
  paid: false,
  lineItems: [],
};

const JOB = {
  title: "Water heater replacement",
  customerName: "Dana Reyes",
  laborHours: 4,
  laborRate: 95,
  materials: [{ name: "Water heater", quantity: 1, unitCost: 220 }],
  estimateTotal: 850,
};

const CUSTOMER = { name: "Dana Reyes", email: "dana@example.com", phone: "(512) 555-0199" };

// Pulls the text of a given class's div out of the generated HTML.
function divText(html, className) {
  const match = html.match(new RegExp(`<div class="${className}">([^<]*)</div>`));
  return match ? match[1] : null;
}

const CASES = [
  ["invoiceHtml", (biz) => invoiceHtml({ ...INVOICE }, biz)],
  ["estimateHtml", (biz) => estimateHtml({ ...JOB }, CUSTOMER, biz)],
];

describe.each(CASES)("%s business header", (_name, render) => {
  test("the address is on its own line, not appended to the contact line", () => {
    const html = render(BIZ);
    expect(divText(html, "biz-sub")).toBe("Chad · (512) 555-0142 · chad@acmeplumbing.com");
    expect(divText(html, "biz-addr")).toBe("123 Main St, Austin TX 78701");
  });

  test("the contact line does not contain the address", () => {
    const contactLine = divText(render(BIZ), "biz-sub");
    expect(contactLine).not.toContain("123 Main St");
    expect(contactLine).not.toContain("Austin");
  });

  test("no address emits no address div at all", () => {
    const html = render({ ...BIZ, address: "" });
    expect(html).not.toContain('class="biz-addr"');
    expect(divText(html, "biz-sub")).toBe("Chad · (512) 555-0142 · chad@acmeplumbing.com");
  });

  test("an address with no contact details still renders on its own line", () => {
    const html = render({ businessName: "Acme Plumbing", address: "123 Main St, Austin TX 78701" });
    expect(html).not.toContain('class="biz-sub"');
    expect(divText(html, "biz-addr")).toBe("123 Main St, Austin TX 78701");
  });

  test("an address with no contact details or business name still renders", () => {
    expect(divText(render({ address: "123 Main St, Austin TX 78701" }), "biz-addr")).toBe(
      "123 Main St, Austin TX 78701"
    );
  });

  test("the address is HTML-escaped", () => {
    const html = render({ ...BIZ, address: 'Unit <5> & "rear"' });
    expect(html).toContain('class="biz-addr"');
    expect(html).not.toContain("Unit <5>");
    expect(html).toContain("&lt;5&gt;");
    expect(html).toContain("&amp;");
  });

  test("a business with no address and no contact details emits neither line", () => {
    const html = render({ businessName: "Acme Plumbing" });
    expect(html).not.toContain('class="biz-sub"');
    expect(html).not.toContain('class="biz-addr"');
  });
});
