import Foundation
#if !GLOBAL_SEARCH_PURE_TESTS
import SwiftUI
#endif

struct NativeSearchSection<Item> {
    let items: [Item]
    let total: Int
}

struct NativeGlobalSearchResults {
    let jobs: NativeSearchSection<Job>
    let customers: NativeSearchSection<Customer>
    let invoices: NativeSearchSection<Invoice>
    let actions: NativeSearchSection<NativeGlobalSearchAction>
    let total: Int
}

enum NativeGlobalSearchDestination: Equatable {
    case job(String)
    case customer(String)
    case invoice(String)
}

enum NativeGlobalSearchActionID: String, Identifiable {
    case newJob
    case newCustomer
    case newInvoice

    var id: String { rawValue }
}

struct NativeGlobalSearchAction: Identifiable, Equatable {
    let id: NativeGlobalSearchActionID
    let title: String
    let detail: String
    let symbol: String
    let keywords: String
}

/// Pure Phase 5 search contract ported from `utils/globalSearch.ts`. Matching,
/// ordering, archived-record exclusion, section caps, and true totals remain
/// independent of SwiftUI navigation so host tests can pin the wire behavior.
enum NativeGlobalSearch {
    static let sectionLimit = 8

    static let availableActions: [NativeGlobalSearchAction] = [
        .init(
            id: .newJob,
            title: "New job",
            detail: "Create a lead or scheduled job",
            symbol: "hammer",
            keywords: "new add create job work lead estimate schedule"
        ),
        .init(
            id: .newCustomer,
            title: "New customer",
            detail: "Add a customer or contact",
            symbol: "person.crop.circle.badge.plus",
            keywords: "new add create customer client contact"
        ),
        .init(
            id: .newInvoice,
            title: "New invoice",
            detail: "Create a customer invoice",
            symbol: "doc.badge.plus",
            keywords: "new add create invoice bill billing payment"
        ),
    ]

    static func search(
        jobs: [Job],
        customers: [Customer],
        invoices: [Invoice],
        query: String,
        limit: Int = sectionLimit
    ) -> NativeGlobalSearchResults {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return empty }
        let cap = max(0, limit)

        let matchingJobs = jobs
            .filter { !isArchived($0.archivedAt) && jobMatches($0, normalized) }
            .sorted { $0.createdAt > $1.createdAt }
        let matchingCustomers = customers
            .filter { !isArchived($0.archivedAt) && customerMatches($0, normalized) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let matchingInvoices = invoices
            .filter { invoiceMatches($0, normalized) }
            .sorted { $0.due > $1.due }
        let matchingActions = availableActions.filter {
            contains($0.title, normalized) || contains($0.keywords, normalized)
        }

        return .init(
            jobs: section(matchingJobs, cap: cap),
            customers: section(matchingCustomers, cap: cap),
            invoices: section(matchingInvoices, cap: cap),
            actions: section(matchingActions, cap: cap),
            total: matchingJobs.count + matchingCustomers.count + matchingInvoices.count + matchingActions.count
        )
    }

    static func jobMatches(_ job: Job, _ query: String) -> Bool {
        [job.title, job.customerName, job.address, job.description, job.notes]
            .contains { contains($0, query) }
    }

    static func customerMatches(_ customer: Customer, _ query: String) -> Bool {
        [customer.name, customer.phone, customer.email, customer.address, customer.notes]
            .contains { contains($0, query) }
    }

    static func invoiceMatches(_ invoice: Invoice, _ query: String) -> Bool {
        [invoice.number, invoice.customer, invoice.description]
            .contains { contains($0, query) }
    }

    private static var empty: NativeGlobalSearchResults {
        .init(
            jobs: .init(items: [], total: 0),
            customers: .init(items: [], total: 0),
            invoices: .init(items: [], total: 0),
            actions: .init(items: [], total: 0),
            total: 0
        )
    }

    private static func contains(_ value: String, _ query: String) -> Bool {
        value.lowercased().contains(query)
    }

    private static func isArchived(_ value: String?) -> Bool {
        !(value ?? "").isEmpty
    }

    private static func section<Item>(_ values: [Item], cap: Int) -> NativeSearchSection<Item> {
        .init(items: Array(values.prefix(cap)), total: values.count)
    }
}

#if !GLOBAL_SEARCH_PURE_TESTS
struct NativeGlobalSearchView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var action: NativeGlobalSearchActionID?

    private var results: NativeGlobalSearchResults {
        NativeGlobalSearch.search(
            jobs: store.jobs,
            customers: store.customers,
            invoices: store.invoices,
            query: query
        )
    }

    private var hasQuery: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            List {
                if !hasQuery {
                    ContentUnavailableView(
                        "Search TradeReady",
                        systemImage: "magnifyingglass",
                        description: Text("Find active jobs, customers, invoices, or an action.")
                    )
                    .listRowBackground(Color.clear)
                } else if results.total == 0 {
                    NativeContentStateView(
                        state: .noMatches(query: query.trimmingCharacters(in: .whitespacesAndNewlines)),
                        emptyTitle: "Search TradeReady",
                        emptyMessage: "Find active jobs, customers, invoices, or an action.",
                        symbol: "magnifyingglass",
                        resetAction: { query = "" }
                    )
                    .listRowBackground(Color.clear)
                } else {
                    jobSection
                    customerSection
                    invoiceSection
                    actionSection
                }
            }
            .tradeReadyListStyle()
            .refreshable { await store.performPullToRefresh() }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Jobs, customers, invoices, actions"
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $action) { selected in
                switch selected {
                case .newJob:
                    JobEditor(job: Job(laborRate: store.settings.laborRate), isNewRecord: true)
                case .newCustomer:
                    CustomerEditor(customer: Customer(), mode: .create)
                case .newInvoice:
                    InvoiceEditor(invoice: Invoice(
                        number: store.nextInvoiceNumber(),
                        due: Calendar.current.date(byAdding: .day, value: 30, to: .now) ?? .now
                    ))
                }
            }
        }
        .nativeAnalyticsScreen(.search)
    }

    @ViewBuilder
    private var jobSection: some View {
        if results.jobs.total > 0 {
            Section("Jobs") {
                ForEach(results.jobs.items) { job in
                    Button {
                        route(.job(job.id))
                    } label: {
                        JobRow(job: job)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Job: \(job.title), \(job.customerName)")
                }
                moreHint(total: results.jobs.total, shown: results.jobs.items.count, destination: "Jobs")
            }
        }
    }

    @ViewBuilder
    private var customerSection: some View {
        if results.customers.total > 0 {
            Section("Customers") {
                ForEach(results.customers.items) { customer in
                    Button {
                        route(.customer(customer.id))
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "person")
                                .foregroundStyle(Color.tradeReady)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(customer.name).font(.headline)
                                let contact = customer.phone.isEmpty ? customer.email : customer.phone
                                if !contact.isEmpty {
                                    Text(contact).font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Customer: \(customer.name)")
                }
                moreHint(total: results.customers.total, shown: results.customers.items.count, destination: "Customers")
            }
        }
    }

    @ViewBuilder
    private var invoiceSection: some View {
        if results.invoices.total > 0 {
            Section("Invoices") {
                ForEach(results.invoices.items) { invoice in
                    Button {
                        route(.invoice(invoice.id))
                    } label: {
                        InvoiceRow(invoice: invoice)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Invoice \(invoice.number), \(invoice.customer)")
                }
                moreHint(total: results.invoices.total, shown: results.invoices.items.count, destination: "Invoices")
            }
        }
    }

    @ViewBuilder
    private var actionSection: some View {
        if results.actions.total > 0 {
            Section("Actions") {
                ForEach(results.actions.items) { item in
                    Button {
                        action = item.id
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title).font(.headline)
                                Text(item.detail).font(.subheadline).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: item.symbol)
                                .foregroundStyle(Color.tradeReady)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private func moreHint(total: Int, shown: Int, destination: String) -> some View {
        if total > shown {
            Text("+\(total - shown) more in \(destination)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func route(_ destination: NativeGlobalSearchDestination) {
        store.routeToGlobalSearchResult(destination)
        dismiss()
    }
}
#endif
