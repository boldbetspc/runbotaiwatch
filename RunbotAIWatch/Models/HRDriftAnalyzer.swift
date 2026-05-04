import Foundation
import Combine

/// Heart Rate Drift Analyzer - Detects gradual HR rise despite steady pace
/// Conforms to `ObservableObject` so `MainRunbotView` can hold it with `@StateObject`.
final class HRDriftAnalyzer: ObservableObject {

    enum DriftLevel: String, Codable {
        case normal, rising, high, critical

        var description: String {
            switch self {
            case .normal: return "Normal"
            case .rising: return "Early fatigue"
            case .high: return "Unsustainable"
            case .critical: return "Blow-up risk"
            }
        }
    }

    struct HRDriftSnapshot: Codable {
        let timestamp: Date
        let distance: Double
        let hrNow: Int
        let paceNow: Double
        let driftPercent: Double
        let driftLevel: DriftLevel
        let paceStable: Bool
    }

    private struct Baseline {
        let hrBase: Double
        let paceBase: Double
    }

    private var baseline: Baseline?
    private var lastSnapshot: HRDriftSnapshot?
    private var driftHistory: [HRDriftSnapshot] = []
    private var runStartTime = Date()
    private var lastEvalTime: Date?
    private var windowData: [(time: Date, hr: Int, pace: Double)] = []

    private let baselineStart = 3.0 * 60.0
    private let baselineEnd = 10.0 * 60.0
    private let windowSize = 2.5 * 60.0
    private let evalInterval = 75.0
    private let paceTolerance = 0.05

    func processDataPoint(timestamp: Date, distance: Double, heartRate: Int?, pace: Double) -> HRDriftSnapshot? {
        guard let hr = heartRate, hr > 40, hr < 220 else { return nil }

        let duration = timestamp.timeIntervalSince(runStartTime)

        if baseline == nil {
            if duration >= baselineStart && duration <= baselineEnd {
                windowData.append((timestamp, hr, pace))
                if windowData.count >= 3 {
                    let avgHR = windowData.map { Double($0.hr) }.reduce(0, +) / Double(windowData.count)
                    let avgPace = windowData.map { $0.pace }.reduce(0, +) / Double(windowData.count)
                    baseline = Baseline(hrBase: avgHR, paceBase: avgPace)
                    print("📊 [HRDrift] Baseline: HR=\(String(format: "%.0f", avgHR)) bpm, Pace=\(String(format: "%.2f", avgPace)) min/km")
                }
            }
            return nil
        }

        if let lastEval = lastEvalTime, timestamp.timeIntervalSince(lastEval) < evalInterval {
            return nil
        }

        windowData.append((timestamp, hr, pace))
        let cutoff = timestamp.addingTimeInterval(-3 * 60)
        windowData = windowData.filter { $0.time >= cutoff }

        guard windowData.count >= 2 else { return nil }

        let windowStart = timestamp.addingTimeInterval(-windowSize)
        let recent = windowData.filter { $0.time >= windowStart }
        guard recent.count >= 2 else { return nil }

        let avgHR = recent.map { Double($0.hr) }.reduce(0, +) / Double(recent.count)
        let avgPace = recent.map { $0.pace }.reduce(0, +) / Double(recent.count)

        let paceChange = abs(avgPace - baseline!.paceBase) / baseline!.paceBase
        guard paceChange < paceTolerance else { return nil }

        let drift = max(0, ((avgHR - baseline!.hrBase) / baseline!.hrBase) * 100.0)
        let level: DriftLevel = drift < 5 ? .normal : drift < 8 ? .rising : drift < 10 ? .high : .critical

        let snapshot = HRDriftSnapshot(
            timestamp: timestamp,
            distance: distance,
            hrNow: Int(avgHR),
            paceNow: avgPace,
            driftPercent: drift,
            driftLevel: level,
            paceStable: true
        )

        if isPersistent(snapshot) {
            lastEvalTime = timestamp
            lastSnapshot = snapshot
            driftHistory.append(snapshot)
            return snapshot
        }

        return nil
    }

    func getCurrentDrift() -> HRDriftSnapshot? { lastSnapshot }

    func reset() {
        baseline = nil
        lastSnapshot = nil
        driftHistory = []
        lastEvalTime = nil
        windowData = []
        runStartTime = Date()
    }

    private func isPersistent(_ snapshot: HRDriftSnapshot) -> Bool {
        guard snapshot.driftPercent >= 5.0 else { return true }

        if let last = lastSnapshot, snapshot.timestamp.timeIntervalSince(last.timestamp) < 3 * 60, last.driftPercent >= 5.0 {
            return true
        }

        let fiveMinAgo = snapshot.timestamp.addingTimeInterval(-5 * 60)
        let recent = driftHistory.filter { $0.timestamp >= fiveMinAgo }
        if recent.count >= 3 {
            let hrs = recent.map { Double($0.hrNow) }
            let increasing = (1..<hrs.count).filter { hrs[$0] > hrs[$0 - 1] }.count
            if increasing >= (hrs.count - 1) * 2 / 3 { return true }
        }

        return false
    }
}
