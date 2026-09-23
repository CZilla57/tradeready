import Foundation

// MARK: - Job-based money reports (task 9.01, requirements M2)
//
// Ports computeAvgJobValue, computeConversionFunnel, computeRevenueByType,
// computeRevenueForecast, and computeProfitabilityHistory. Pure over canonical
// arrays; reuses `NativeChangeOrders.billableTotal` (jobBillableTotal) and the
// shared `JobProfitabilityEngine` rather than re-deriving those rules.

extension NativeMoneyReports {
    // MARK: avgJobValue

    /// `computeAvgJobValue` — done jobs with a positive billable total. A job
    /// with no `createdAt` is INCLUDED in a windowed average.
    static func computeAvgJobValue(
        _ jobs: [Canonical.Job],
        start: Date? = nil,
        end: Date? = nil
    ) -> NativeAvgJobValue {
        var totalValue = Decimal.zero
        var count = 0
        for job in jobs {
            guard doneStatuses.contains(job.status) else { continue }
            let billable = NativeChangeOrders.billableTotal(for: job)
            if billable <= 0 { continue }
            if let start, let end, !job.createdAt.isEmpty,
               !NativeCashBasis.isInRange(job.createdAt, start: start, end: end) {
                continue
            }
            totalValue += billable
            count += 1
        }
        return NativeAvgJobValue(
            avgValue: count > 0 ? totalValue / Decimal(count) : 0,
            count: count,
            totalValue: totalValue
        )
    }

    // MARK: conversionFunnel

    static let funnelStages = [
        "lead", "estimate_sent", "approved", "scheduled", "in_progress", "complete",
    ]

    static let statusOrdinal: [String: Int] = [
        "lead": 0, "estimate_sent": 1, "approved": 2, "scheduled": 3,
        "in_progress": 4, "complete": 5, "invoiced": 6, "paid": 7,
        // A declined job reached "estimate sent" but not "approved".
        "declined": 1,
    ]

    static let statusLabels: [String: String] = [
        "lead": "Lead", "estimate_sent": "Estimate sent", "approved": "Approved",
        "scheduled": "Scheduled", "in_progress": "In Progress", "complete": "Complete",
    ]

    static func computeConversionFunnel(_ jobs: [Canonical.Job]) -> NativeConversionFunnel {
        var reached: [String: Int] = [:]
        for stage in funnelStages { reached[stage] = 0 }
        for job in jobs {
            let ordinal = statusOrdinal[job.status] ?? -1
            for stage in funnelStages where ordinal >= (statusOrdinal[stage] ?? 0) {
                reached[stage, default: 0] += 1
            }
        }
        let stages: [NativeFunnelStage] = funnelStages.enumerated().map { index, status in
            let count = reached[status] ?? 0
            let previous = index > 0 ? (reached[funnelStages[index - 1]] ?? 0) : nil
            return NativeFunnelStage(
                status: status,
                label: statusLabels[status] ?? status,
                count: count,
                rate: (previous != nil && previous! > 0) ? Decimal(count) / Decimal(previous!) : nil
            )
        }
        let estimateSent = reached["estimate_sent"] ?? 0
        let approved = reached["approved"] ?? 0
        return NativeConversionFunnel(
            stages: stages,
            totalJobs: jobs.count,
            winRate: estimateSent > 0 ? Decimal(approved) / Decimal(estimateSent) : nil
        )
    }

    // MARK: revenueByType

    /// `computeEstimateBreakdown` reduced to the pieces `computeRevenueByType`
    /// reads: raw (unrounded) labor/material plus the residual overhead line with
    /// customer-visible direct cost lines subtracted. `estimateTotal` is the
    /// billable total, exactly like the RN caller's `{ ...job, estimateTotal }`.
    static func estimateBreakdownParts(
        _ job: Canonical.Job,
        estimateTotal: Decimal
    ) -> (labor: Decimal, material: Decimal, overhead: Decimal) {
        let labor = job.laborHours * job.laborRate
        let materialBase = job.materials.reduce(Decimal.zero) { $0 + $1.quantity * $1.unitCost }
        let material = materialBase * (1 + job.materialMarkup / 100)
        var visibleDirect = Decimal.zero
        for cost in job.jobCosts ?? [] where cost.customerVisible {
            let policy = cost.markupPolicy.isEmpty
                ? (cost.category == "permit" ? "passthrough" : "in_margin_base")
                : cost.markupPolicy
            let base = cost.quantity * cost.unitCost
            let amount = policy == "in_margin_base" ? base * (1 + cost.markupPercent / 100) : base
            visibleDirect += jsCents(amount)
        }
        return (labor, material, estimateTotal - labor - material - visibleDirect)
    }

    static func computeRevenueByType(_ jobs: [Canonical.Job]) -> NativeRevenueByType {
        var laborTotal = Decimal.zero
        var materialTotal = Decimal.zero
        var overheadTotal = Decimal.zero
        var jobCount = 0

        for job in jobs {
            guard doneStatuses.contains(job.status) else { continue }
            let billable = NativeChangeOrders.billableTotal(for: job)
            if billable <= 0 { continue }
            jobCount += 1
            let parts = estimateBreakdownParts(job, estimateTotal: billable)
            laborTotal += parts.labor
            materialTotal += parts.material
            overheadTotal += FinancialDecimal.maximum(0, parts.overhead)
        }

        let totalRevenue = laborTotal + materialTotal + overheadTotal
        var components: [NativeRevenueComponent] = []
        if totalRevenue > 0 {
            if laborTotal > 0 {
                components.append(NativeRevenueComponent(
                    label: "Labor", total: laborTotal,
                    pct: jsRound(laborTotal / totalRevenue * 100), color: "accent"
                ))
            }
            if materialTotal > 0 {
                components.append(NativeRevenueComponent(
                    label: "Materials", total: materialTotal,
                    pct: jsRound(materialTotal / totalRevenue * 100), color: "success"
                ))
            }
            if overheadTotal > 0 {
                components.append(NativeRevenueComponent(
                    label: "Overhead & Profit", total: overheadTotal,
                    pct: jsRound(overheadTotal / totalRevenue * 100), color: "warning"
                ))
            }
        }
        return NativeRevenueByType(totalRevenue: totalRevenue, jobCount: jobCount, components: components)
    }

    // MARK: revenueForecast

    static func computeRevenueForecast(_ jobs: [Canonical.Job]) -> NativeRevenueForecast {
        let winRate = computeConversionFunnel(jobs).winRate
        var certainValue = Decimal.zero
        var certainCount = 0
        var speculativeValue = Decimal.zero
        var speculativeCount = 0

        for job in jobs {
            let billable = NativeChangeOrders.billableTotal(for: job)
            if billable <= 0 { continue }
            if ["approved", "scheduled", "in_progress"].contains(job.status) {
                certainValue += billable
                certainCount += 1
            } else if ["lead", "estimate_sent"].contains(job.status) {
                speculativeValue += billable
                speculativeCount += 1
            }
        }

        // winRate === null propagates: no projected value at all.
        let projectedValue = winRate.map { speculativeValue * $0 } ?? 0
        return NativeRevenueForecast(
            certainValue: certainValue,
            certainCount: certainCount,
            speculativeValue: speculativeValue,
            speculativeCount: speculativeCount,
            winRate: winRate,
            projectedValue: projectedValue,
            totalForecast: certainValue + projectedValue
        )
    }

    // MARK: profitabilityAggregate

    static func median(_ values: [Decimal]) -> Decimal? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }

    /// `computeProfitabilityHistory` — medians of completed jobs WITH an estimate
    /// that are not archived. Reuses the shared `JobProfitabilityEngine` per job.
    static func computeProfitabilityHistory(
        jobs: [Canonical.Job],
        invoices: [Canonical.Invoice],
        expenses: [Canonical.Expense],
        laborCostRate: Decimal?
    ) -> NativeProfitabilityHistory {
        let done = jobs.filter { job in
            doneStatuses.contains(job.status)
                && !(job.archivedAt.map { !$0.isEmpty } ?? false)
                && job.estimateTotal > 0
        }

        var jobsWithData = 0
        var hourly: [Decimal] = []
        var laborOverruns: [Decimal] = []
        var materialsRatios: [Decimal] = []
        var materialsVariances: [Decimal] = []

        for job in done {
            let result = NativeJobProfitability.calculate(
                job: job, invoices: invoices, expenses: expenses, laborCostRate: laborCostRate
            )
            if result.actualLaborHours != nil || result.actualMaterialExpense != nil { jobsWithData += 1 }
            if let value = result.effectiveHourlyActual { hourly.append(value) }
            if let variance = result.laborHoursVariance { laborOverruns.append(variance) }
            if let variance = result.materialsVariance {
                materialsVariances.append(variance)
                if let actual = result.actualMaterialExpense, result.estimatedMaterialCost > 0 {
                    materialsRatios.append(actual / result.estimatedMaterialCost)
                }
            }
        }

        return NativeProfitabilityHistory(
            doneJobs: done.count,
            jobsWithData: jobsWithData,
            hourlyCount: hourly.count,
            medianEffectiveHourly: median(hourly).map { FinancialDecimal.cents($0) },
            laborCount: laborOverruns.count,
            medianLaborOverrunHours: median(laborOverruns).map { jsCents($0) },
            materialsCount: materialsVariances.count,
            medianMaterialsOverrunRatio: median(materialsRatios),
            medianMaterialsVariance: median(materialsVariances).map { FinancialDecimal.cents($0) }
        )
    }
}
