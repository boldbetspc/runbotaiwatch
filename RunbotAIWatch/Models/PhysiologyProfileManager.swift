import Foundation
import HealthKit
import Combine

/// Display-only physiology snapshot (VO₂ max + threshold HR + time above LT) on watch.
/// Does not feed AI coaching.
struct PhysiologyRunSummary: Codable, Equatable {
    let runId: String
    let vo2Max: Double?
    let thresholdHR: Int?
    let percentAboveThreshold: Double
    let hrSourceLabel: String
    let capturedAt: Date
}

@MainActor
final class PhysiologyProfileManager: ObservableObject {
    static let shared = PhysiologyProfileManager()

    @Published private(set) var vo2Max: Double?
    @Published private(set) var thresholdHR: Int?
    @Published private(set) var percentAboveThreshold: Double = 0
    @Published private(set) var hrSourceLabel: String = "—"
    @Published private(set) var isTracking = false

    private let healthStore = HKHealthStore()
    private let storageKey = "run_physiology_v1"
    private var aboveThresholdSamples = 0
    private var totalHRSamples = 0

    private init() {}

    func beginRun(hrSourceLabel: String = "Health · HR via Watch") {
        aboveThresholdSamples = 0
        totalHRSamples = 0
        percentAboveThreshold = 0
        isTracking = true
        self.hrSourceLabel = hrSourceLabel
        Task { await refreshProfile() }
    }

    func recordHeartRate(_ bpm: Double) {
        guard isTracking, bpm.isFinite, bpm >= 30, bpm <= 220 else { return }
        totalHRSamples += 1
        if let lt = thresholdHR, Int(bpm.rounded()) >= lt {
            aboveThresholdSamples += 1
        }
        if totalHRSamples > 0 {
            percentAboveThreshold = (Double(aboveThresholdSamples) / Double(totalHRSamples)) * 100.0
        }
    }

    @discardableResult
    func endRun(runId: String?) -> PhysiologyRunSummary? {
        isTracking = false
        guard let runId, !runId.isEmpty else { return nil }
        let summary = PhysiologyRunSummary(
            runId: runId,
            vo2Max: vo2Max,
            thresholdHR: thresholdHR,
            percentAboveThreshold: percentAboveThreshold,
            hrSourceLabel: hrSourceLabel,
            capturedAt: Date()
        )
        saveSummary(summary)
        return summary
    }

    func summary(forRunId runId: String) -> PhysiologyRunSummary? {
        loadAllSummaries()[runId]
    }

    func refreshProfile() async {
        let userId: String? = {
            if let data = UserDefaults.standard.data(forKey: "currentUser"),
               let user = try? JSONDecoder().decode(User.self, from: data) {
                return user.id
            }
            return nil
        }()

        if let userId {
            let manager = SupabaseManager()
            manager.initializeSession(for: userId)
            let config = await manager.loadHRConfig()
            if let age = config?.age, let resting = config?.restingHeartRate {
                thresholdHR = HeartZoneCalculator.thresholdHeartRate(age: age, restingHeartRate: resting)
            } else {
                thresholdHR = nil
            }
        } else {
            thresholdHR = nil
        }
        vo2Max = await fetchLatestVO2Max()
    }

    private func fetchLatestVO2Max() async -> Double? {
        guard HKHealthStore.isHealthDataAvailable(),
              let vo2Type = HKQuantityType.quantityType(forIdentifier: .vo2Max) else {
            return nil
        }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            healthStore.requestAuthorization(toShare: [], read: [vo2Type]) { _, _ in
                cont.resume()
            }
        }

        return await withCheckedContinuation { cont in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
            let query = HKSampleQuery(
                sampleType: vo2Type,
                predicate: nil,
                limit: 1,
                sortDescriptors: [sort]
            ) { _, samples, _ in
                guard let sample = samples?.first as? HKQuantitySample else {
                    cont.resume(returning: nil)
                    return
                }
                let value = sample.quantity.doubleValue(for: HKUnit(from: "ml/kg*min"))
                cont.resume(returning: value > 0 ? value : nil)
            }
            healthStore.execute(query)
        }
    }

    private func saveSummary(_ summary: PhysiologyRunSummary) {
        var all = loadAllSummaries()
        all[summary.runId] = summary
        if let data = try? JSONEncoder().encode(all) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private func loadAllSummaries() -> [String: PhysiologyRunSummary] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([String: PhysiologyRunSummary].self, from: data) else {
            return [:]
        }
        return decoded
    }
}
