// utils/storage/defaults.ts
// Seed / sample data returned when a collection has never been written. Kept in
// one place so the shapes here stay the reference implementation of the types in
// types/models.ts. Only defaultSettings is part of the public storage API (the
// onboarding flow reads it); the collection seeds are internal to storage.

import type { Invoice, Job, Customer, Settings, TradeId } from "../../types/models";
import { freshSampleSuffix } from "../sampleData";

// Per-install namespace for sample ids. Fixed ids (c1, j1, "1"...) collided
// across accounts on the per-user cloud tables and RLS rejected every later
// account's pushes (wedged "changes pending" banner — TestFlight finding
// 2026-07-14). Module-level so one app launch seeds all collections with
// consistent cross-links (jobs reference customers by these ids).
let SEED = freshSampleSuffix();

// Sign-out wipes local storage, and the next collection read re-seeds. Without
// a new suffix that re-seed reuses this launch's ids — and if the previous
// account already pushed them, the next account's upserts hit rows owned by
// someone else and RLS rejects them forever (demo-account sync wedge,
// 2026-07-16). clearAllUserData calls this so each account seeds fresh ids.
export function resetSampleSeed(): void {
  SEED = freshSampleSuffix();
}

export function defaultCustomers(): Customer[] {
  return [
    {
      id: `c1-${SEED}`,
      name: "Riverside Bakery",
      email: "owner@riversidebakery.com",
      phone: "(555) 301-2200",
      address: "142 Mill St, Austin TX 78701",
      notes: "Side entrance is easiest. Ask for Maria.",
    },
    {
      id: `c2-${SEED}`,
      name: "Tom Nguyen",
      email: "tom.nguyen@gmail.com",
      phone: "(555) 874-9900",
      address: "88 Oak Lane, Austin TX 78745",
      notes: "Dog in backyard — keep gate closed.",
    },
    {
      id: `c3-${SEED}`,
      name: "Patel Family Dental",
      email: "admin@pateldental.com",
      phone: "(555) 440-1133",
      address: "310 Congress Ave, Austin TX 78701",
      notes: "Call ahead — building requires visitor badge.",
    },
  ];
}

export function defaultJobs(): Job[] {
  return [
    {
      id: `j1-${SEED}`,
      customerId: `c2-${SEED}`,
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
      id: `j2-${SEED}`,
      customerId: `c1-${SEED}`,
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
      id: `j3-${SEED}`,
      customerId: `c3-${SEED}`,
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

const SAMPLE_INVOICE_DESCS: Record<TradeId, string[]> = {
  plumbing: ["Kitchen faucet replacement", "Emergency pipe repair", "Water heater flush", "Bathroom remodel — rough-in"],
  electrical: ["Panel upgrade — 200A", "Recessed lighting install", "Outlet and switch replacement", "EV charger installation"],
  hvac: ["AC unit service call", "Furnace replacement", "Ductwork repair", "Thermostat installation"],
  carpenter: ["Custom shelving build", "Deck repair and staining", "Door frame replacement", "Cabinet installation"],
  bricklayer: ["Garden wall construction", "Chimney repointing", "Patio brickwork", "Foundation repair"],
  plasterer: ["Living room skim coat", "Ceiling repair", "Full room replaster", "Decorative cornice work"],
  landscaping: ["Spring cleanup and mulching", "Patio paver installation", "Weekly mowing contract — Q2", "Tree trimming and removal"],
  cleaning: ["Deep clean — 3BR house", "Post-construction cleanup", "Office weekly service", "Move-out clean"],
  painting: ["Interior 2-room repaint", "Exterior house painting", "Cabinet refinishing", "Deck staining"],
  handyman: ["Fence repair", "Drywall patch and paint", "Ceiling fan installation", "Gutter cleaning"],
  other: ["Service call", "Project estimate", "Maintenance visit", "Repair work"],
};

export function defaultInvoices(trade?: TradeId): Invoice[] {
  const descs = SAMPLE_INVOICE_DESCS[trade || "other"];
  return [
    {
      id: `1-${SEED}`,
      customer: "Riverside Bakery",
      number: "INV-0038",
      amount: 2400,
      due: "2026-05-10",
      email: "owner@riversidebakery.com",
      phone: "(555) 301-2200",
      desc: descs[0],
      paid: false,
    },
    {
      id: `2-${SEED}`,
      customer: "Green Thumb Landscaping",
      number: "INV-0041",
      amount: 875,
      due: "2026-06-01",
      email: "billing@greenthumbla.com",
      phone: "(555) 874-9900",
      desc: descs[1],
      paid: false,
    },
    {
      id: `3-${SEED}`,
      customer: "Patel Family Dental",
      number: "INV-0043",
      amount: 5100,
      due: "2026-06-15",
      email: "admin@pateldental.com",
      phone: "(555) 440-1133",
      desc: descs[2],
      paid: false,
    },
    {
      id: `4-${SEED}`,
      customer: "Blue Ridge Coffee Co.",
      number: "INV-0039",
      amount: 650,
      due: "2026-05-20",
      email: "mgr@blueridgecoffee.com",
      phone: "(555) 920-5544",
      desc: descs[3],
      paid: true,
    },
  ];
}

export function defaultSettings(): Settings {
  return {
    // Business info
    businessName: "Your Business Name",
    contactName: "Your Name",
    phone: "",
    email: "",
    address: "",
    region: "",
    logoPhoto: "",
    trade: "plumbing", // plumbing | electrical | hvac | landscaping | cleaning | painting | handyman | other

    // Pricing defaults — worker sets these once, used in every estimate
    laborRate: 85,          // $ per hour
    materialMarkup: 20,     // % markup on materials (covers cost of sourcing, carrying)
    overheadPercent: 15,    // % for business overhead (insurance, truck, tools)
    marginPercent: 20,      // % profit margin on top
    minimumJobFee: 75,      // minimum charge even for tiny jobs
    travelFeePerMile: 0,    // 0 = no travel fee, otherwise $ per mile
    emergencyMultiplier: 1.5, // after-hours/emergency rate multiplier
    mileageRate: 0.70,      // $ per mile — IRS standard mileage rate; user sets per tax year

    // Payment
    paymentNotes: "Payment due upon completion. We accept check, card, or bank transfer.",
    provider: "stripe",
    providerKey: "",
    providerKeys: {},

    // Notifications — days after due date to send a reminder
    rules: [{ days: 1 }, { days: 7 }],
    autoOutreachEnabled: false, // opt-in; see docs/superpowers/specs/2026-07-14-overdue-auto-outreach-design.md
    autoSendEmailEnabled: false, // opt-in; Phase 2 server email auto-send

    // AI
    anthropicKey: "",
    groqKey: "",

    // Review requests
    reviewRequestEnabled: false,
    reviewRequestTemplate:
      "Hi {customerName}, thanks for choosing {businessName}! If you were happy with the work, we'd really appreciate a Google review:\n\n{googleReviewLink}\n\nThank you!",
    googleReviewLink: "",
    reviewRequestDelayHours: 1,
  };
}
