# TradeReady — App Architecture

## Vision
A mobile-first business operating system for solo blue collar workers and 
small trade businesses (plumbers, electricians, HVAC, landscapers, cleaners,
painters, handymen). Helps them price jobs, schedule work, navigate their day,
collect payments, and grow — without needing a business degree.

---

## The Five Pillars

1. **Get the job** — Estimates & proposals
2. **Do the job** — Scheduling & route planning  
3. **Charge for the job** — Invoicing & payments (already built)
4. **Run the business** — Finances, expenses, taxes
5. **Grow the business** — AI coach, insights, reviews

---

## Screen Map

### Tab 1 — Today
The home screen. Shows what matters right now.
- Today's job schedule in time order
- Map of today's route (optimized)
- Quick actions: Start job, Mark complete, Call customer
- Weather alert if conditions affect outdoor work
- Earnings summary for today

### Tab 2 — Jobs
Full job lifecycle from lead to paid.

**Sub-screens:**
- Job list (filterable: Active, Estimates, Completed)
- Job detail
  - Customer info
  - Job description and photos
  - Status timeline (Estimate → Approved → Scheduled → In Progress → Complete → Paid)
  - Linked invoice
  - Notes and materials used
- New job / edit job form
- Estimate builder (see Pricing section)
- Proposal PDF preview and send

### Tab 3 — Schedule
Calendar and time management.

**Sub-screens:**
- Week view calendar (tap a day to see jobs)
- Day view with time blocks
- Add appointment
- Route view for any day (opens Maps)
- Recurring job setup (e.g. weekly lawn care)
- Buffer time settings (travel time between jobs)

### Tab 4 — Money
Everything financial in one place.

**Sub-screens:**
- Dashboard: outstanding, collected, expenses, profit this month
- Invoices (what we already built — moved here)
- Expenses
  - Log expense (camera → receipt scan)
  - Expense categories (fuel, materials, tools, insurance, etc.)
  - Monthly expense summary
- Tax center
  - Estimated quarterly taxes owed
  - Deduction tracker
  - Mileage log (auto-tracked with GPS)
- Reports
  - Revenue by month (chart)
  - Most profitable job types
  - Best customers by revenue

### Tab 5 — Customers
What we already built, expanded.

**Sub-screens:**
- Customer list with search
- Customer detail
  - Contact info
  - Full job history
  - Total revenue
  - Notes ("prefers morning appointments", "dog in backyard")
  - One-tap call / text / email
- Add / edit customer

### Tab 6 — Coach (AI)
The business advisor in their pocket.

**Sub-screens:**
- Chat interface — ask anything about running the business
- Suggested questions (contextual to their situation)
- Quick tools:
  - "Help me price this job"
  - "Draft a response to this difficult customer"
  - "Is this contract clause normal?"
  - "What should I charge for mileage?"
  - "How do I hire my first employee?"
- Insights feed — proactive tips based on their data
  ("You haven't followed up on 3 estimates this week")

---

## Data Models

### Customer
- id
- name
- email
- phone
- address (for routing)
- notes
- createdAt

### Job
- id
- customerId
- title
- description
- status: lead | estimate_sent | approved | scheduled | in_progress | complete | invoiced | paid
- jobType: (plumbing | electrical | HVAC | landscaping | cleaning | painting | other)
- estimatedHours
- actualHours
- scheduledDate
- scheduledStartTime
- scheduledEndTime
- completedAt
- address
- photos: []
- notes
- materials: [{ name, quantity, unitCost }]
- laborRate
- estimatedTotal
- actualTotal
- invoiceId (links to invoice when created)
- createdAt

### Invoice (already built)
- id
- customerId
- jobId
- number
- amount
- due
- paid
- paidAt
- paymentLinkUrl

### Appointment (scheduling block)
- id
- jobId (optional — could be a personal block)
- customerId
- title
- date
- startTime
- endTime
- address
- travelTimeMinutes
- isRecurring
- recurrenceRule

### Expense
- id
- date
- amount
- category: fuel | materials | tools | insurance | marketing | subcontractor | office | other
- description
- receiptPhoto
- jobId (optional — job-specific expense)
- isTaxDeductible
- mileage (if category is fuel)

### Settings / Business Profile
- businessName
- ownerName
- trade (type of work)
- phone, email, address
- logoPhoto
- laborRate (default hourly rate)
- materialMarkup (default %)
- overtimeRate
- travelFee
- minimumJobFee
- taxRate (for estimates)
- paymentProcessor + key
- notificationRules

---

## The Pricing / Estimate Engine

This is the core feature that doesn't exist well anywhere for this market.

**Inputs:**
- Job type
- Estimated hours
- Materials (name, quantity, cost)
- Travel distance
- Any special conditions (emergency/after-hours, permits needed, etc.)

**Calculation:**
```
Labor cost     = hours × laborRate
Materials cost = sum of materials × (1 + markupPercent)
Travel fee     = flat fee OR per-mile rate × distance
Overhead       = (labor + materials) × overheadPercent  [default ~15%]
Subtotal       = labor + materials + travel + overhead
Profit margin  = subtotal × marginPercent               [default ~20%]
Total          = subtotal + profit
Tax            = total × taxRate (if applicable)
```

**AI layer on top:**
User describes the job in plain English → Claude extracts the inputs → 
calculator runs → Claude explains the price in plain English and flags 
anything that seems off (e.g. "that's below your break-even rate")

**Output:**
- Price range (not just one number — gives confidence)
- Itemized breakdown
- One-tap "Turn into estimate" → formatted PDF proposal

---

## Route Planning

**How it works:**
1. Pull all jobs scheduled for a given day
2. Get their addresses + the user's starting location (home or current)
3. Call Google Maps Directions API with all waypoints
4. Get back optimized order + estimated drive times
5. Display on map with turn-by-turn option (opens Apple Maps)
6. Show timeline: "Leave home at 7:45am → Job 1 8:00-10:00am → 22 min drive → Job 2 10:22am..."

**Key library:** `react-native-maps` + Google Maps Directions API
**Cost:** Google Maps API is free up to $200/month of usage, which covers 
roughly 10,000 route calculations. A solo operator won't come close to that.

---

## AI Coach — What Claude Powers

| Feature | What the user does | What Claude does |
|---|---|---|
| Job pricing | Describes a job in plain English | Extracts hours/materials, suggests price, explains reasoning |
| Estimate writing | Reviews calculated price | Writes professional proposal text |
| Collection messages | Picks an invoice | Writes email/SMS with payment link (already built) |
| Difficult customers | Describes situation | Drafts a professional response |
| Business questions | Asks anything | Answers based on their trade and business data |
| Contract review | Photographs a contract | Flags unusual clauses in plain English |
| Proactive insights | (automatic) | Analyzes their data and surfaces actionable tips |
| Receipt scanning | Photographs a receipt | Extracts amount, vendor, category |

---

## Tech Stack

### Mobile app
- **Expo** (React Native) — already chosen
- **React Navigation** — already chosen
- **AsyncStorage** — for local data (works for solo users)
- **react-native-maps** — schedule/route map views
- **expo-camera** — receipt and job photo capture
- **expo-location** — GPS for routing and mileage tracking
- **expo-notifications** — payment reminders, appointment alerts
- **expo-document-picker** — import existing customer lists
- **react-native-calendars** — scheduling UI

### Backend (Vercel serverless — already chosen)
- Payment link generation (already built)
- Anthropic API calls (move here from client for security)
- Google Maps Directions API calls (keeps API key server-side)
- PDF generation for proposals and invoices
- Push notification scheduling (for overdue invoice alerts)

### Future (when you outgrow local storage)
- **Supabase** — Postgres database + auth, easy to add later
  - Enables: multi-device sync, web dashboard, team members
- **Stripe Connect** — if you ever want to take a % of payments processed

---

## Build Order (Recommended)

Build in this sequence so you always have something shippable:

**Phase 1 — MVP (what we have + pricing)**
✅ Invoice tracking
✅ Collection messages with payment links
✅ Customer history
⬜ Basic job tracking (status pipeline)
⬜ Pricing calculator
⬜ Simple estimate → PDF

**Phase 2 — Daily operations**
⬜ Scheduling / calendar
⬜ Today screen (jobs for today)
⬜ Route planning
⬜ Job photos

**Phase 3 — Money**
⬜ Expense tracking + receipt scanning
⬜ Mileage tracking
⬜ Basic tax estimates
⬜ Revenue reports

**Phase 4 — Growth**
⬜ AI Coach chat
⬜ Proactive insights
⬜ Customer review requests
⬜ Recurring jobs

**Phase 5 — Scale**
⬜ Cloud sync (Supabase)
⬜ Web dashboard
⬜ Team / subcontractor support
⬜ Customer self-booking portal

---

## What Makes This Different from Competitors

| Feature | TradeReady | Jobber | Housecall Pro | QuickBooks |
|---|---|---|---|---|
| Price | $15-20/mo target | $49+/mo | $65+/mo | $30+/mo |
| Designed for beginners | ✅ | ❌ | ❌ | ❌ |
| AI pricing help | ✅ | ❌ | ❌ | ❌ |
| AI business coach | ✅ | ❌ | ❌ | ❌ |
| Route optimization | ✅ | ✅ | ✅ | ❌ |
| Works offline | ✅ | Partial | Partial | ❌ |
| Setup time | < 5 min | Hours | Hours | Days |

The core differentiation is that this app *teaches* people how to run a 
business as they use it, not just tracks data. That's the AI layer.
