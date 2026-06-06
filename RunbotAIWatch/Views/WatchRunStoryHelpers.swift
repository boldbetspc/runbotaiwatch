import Foundation
import SwiftUI

/// Run Story math aligned with Runbot iOS (`MainView` arc + ETA helpers), kept minimal for watch.
enum WatchRunStoryHelpers {

    struct ArcEntry {
        let kmValue: Double
        let paceValue: Double
        let aheadSec: Int?
    }

    struct ETAScenarioRow: Identifiable {
        var id: String { title }
        let title: String
        let paceMinPerKm: Double
        let paceLabel: String
        let etaLabel: String
        let seconds: Double
        let color: Color
        let isTargetAnchor: Bool
    }

    static func formatPace(_ paceMinutesPerKm: Double) -> String {
        if paceMinutesPerKm <= 0 || !paceMinutesPerKm.isFinite { return "--:--" }
        let mins = Int(paceMinutesPerKm)
        let secs = Int((paceMinutesPerKm - Double(mins)) * 60)
        return String(format: "%d:%02d", mins, secs)
    }

    static func parseRunArc(_ raw: [String]) -> [ArcEntry] {
        raw.compactMap { entry in
            let s = entry.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            let parts = s.components(separatedBy: ",")
            guard let first = parts.first else { return nil }
            let kmPaceParts = first.components(separatedBy: "km:")
            guard kmPaceParts.count == 2 else { return nil }
            let kmNum = kmPaceParts[0]
            let kmValue = Double(kmNum.trimmingCharacters(in: .whitespaces)) ?? 0
            let paceStr = kmPaceParts[1]
            let paceComponents = paceStr.components(separatedBy: ":")
            let paceValue: Double = {
                if paceComponents.count == 2,
                   let m = Double(paceComponents[0]),
                   let sec = Double(paceComponents[1]) {
                    return m + sec / 60.0
                }
                return 5.5
            }()
            var aheadSec: Int?
            for part in parts.dropFirst() {
                let trimmed = part.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("ahead") {
                    let n = trimmed.replacingOccurrences(of: "ahead", with: "")
                        .replacingOccurrences(of: "s", with: "")
                        .replacingOccurrences(of: "+", with: "")
                    aheadSec = Int(String(n.filter { $0.isNumber }))
                } else if trimmed.hasPrefix("behind") {
                    let n = trimmed.replacingOccurrences(of: "behind", with: "")
                        .replacingOccurrences(of: "s", with: "")
                    if let v = Int(String(n.filter { $0.isNumber })) { aheadSec = -v }
                }
            }
            return ArcEntry(kmValue: kmValue, paceValue: paceValue, aheadSec: aheadSec)
        }
    }

    static func cumulativeDeltaSeconds(from entries: [ArcEntry]) -> Int {
        entries.reduce(0) { $0 + ($1.aheadSec ?? 0) }
    }

    static func cumulativeSeries(from entries: [ArcEntry]) -> [Double] {
        var cumulative: [Double] = [0]
        var sum = 0.0
        for e in entries {
            sum += Double(e.aheadSec ?? 0)
            cumulative.append(sum)
        }
        return cumulative
    }

    static func displacementNormalizedY(from cumulative: [Double]) -> [CGFloat] {
        guard !cumulative.isEmpty else { return [] }
        let maxAbs = max(cumulative.map { abs($0) }.max() ?? 0, 8)
        return cumulative.map { v in
            let t = 0.5 + (v / (2 * maxAbs))
            return CGFloat(min(1, max(0, t)))
        }
    }

    static func deltaMeters(cumulativeSeconds: Int, targetPaceMinPerKm: Double) -> Int? {
        guard targetPaceMinPerKm.isFinite, !targetPaceMinPerKm.isNaN, targetPaceMinPerKm > 0 else { return nil }
        let metersPerSecond = 1000.0 / (targetPaceMinPerKm * 60.0)
        let meters = Double(cumulativeSeconds) * metersPerSecond
        return Int(meters.rounded())
    }

    /// Tier 0 = low, 1 = medium, 2 = high (matches iOS `runStoryFatigueBucket`).
    static func fatigueBucket(_ raw: String) -> (Int, String) {
        let s = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty || s == "—" || s == "baseline" { return (0, "LOW") }
        if s.contains("critical") || s == "high" { return (2, "HIGH") }
        if s.contains("moderate") { return (1, "MEDIUM") }
        if s.contains("fresh") { return (0, "LOW") }
        if s.contains("fatigue") {
            if s.contains("high") || s.contains("significant") { return (2, "HIGH") }
            if s.contains("moderate") { return (1, "MEDIUM") }
        }
        return (0, "LOW")
    }

    static func injuryBucket(_ raw: String) -> (Int, String) {
        let s = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty || s == "—" { return (-1, "—") }
        if s.contains("high") || s.contains("severe") { return (2, "HIGH") }
        if s.contains("moderate") { return (1, "MEDIUM") }
        return (0, "LOW")
    }

    static func compactRemainLabel(seconds: TimeInterval) -> String {
        let sec = max(0, seconds)
        if sec <= 0 { return "0m" }
        if sec < 60 { return "<1m" }
        let totalMinutes = Int(ceil(sec / 60.0))
        let h = totalMinutes / 60
        let m = totalMinutes % 60
        if h > 0 { return String(format: "%dh%02dm", h, m) }
        return String(format: "%dm", totalMinutes)
    }

    static func etaProjectionRows(
        targetDistanceKm: Double,
        coveredKm: Double,
        currentPace: Double,
        averagePace: Double,
        targetPace: Double
    ) -> [ETAScenarioRow] {
        let remainingKm = max(0, targetDistanceKm - coveredKm)
        func buildRow(title: String, pace: Double, color: Color, isTargetAnchor: Bool = false) -> ETAScenarioRow? {
            guard pace.isFinite, pace > 0 else { return nil }
            let sec = remainingKm <= 0 ? 0 : (remainingKm * pace * 60.0)
            return ETAScenarioRow(
                title: title,
                paceMinPerKm: pace,
                paceLabel: formatPace(pace),
                etaLabel: remainingKm <= 0 ? "Done" : compactRemainLabel(seconds: sec),
                seconds: sec,
                color: color,
                isTargetAnchor: isTargetAnchor
            )
        }
        let basePace = targetPace > 0 ? targetPace : averagePace
        let trendPace: Double = {
            if currentPace > 0, currentPace < 20 { return currentPace }
            if averagePace > 0 { return averagePace }
            return basePace
        }()
        let pushPace = max(2.5, min(trendPace * 0.93, trendPace - 0.04))
        let easyPace = max(trendPace * 1.07, basePace * 1.10)

        var rows: [ETAScenarioRow] = []
        if let avg = buildRow(title: "Avg", pace: averagePace, color: Color(red: 0.57, green: 0.67, blue: 1.0)) { rows.append(avg) }
        if let target = buildRow(title: "Tgt", pace: basePace, color: Color(red: 0.38, green: 0.98, blue: 0.72), isTargetAnchor: true) { rows.append(target) }
        if let easy = buildRow(title: "Easy", pace: easyPace, color: Color(red: 1.0, green: 0.74, blue: 0.34)) { rows.append(easy) }
        if let cur = buildRow(title: "Now", pace: currentPace, color: Color(red: 0.24, green: 0.92, blue: 1.0)) { rows.append(cur) }
        if let push = buildRow(title: "Push", pace: pushPace, color: Color(red: 1.0, green: 0.5, blue: 0.56)) { rows.append(push) }
        return rows
    }

    static func etaSmartScenarioIndex(
        rows: [ETAScenarioRow],
        fatigueRaw: String,
        injuryRaw: String,
        currentZone: Int?,
        coveredKm: Double = 0,
        currentPace: Double = 0,
        averagePace: Double = 0,
        targetPace: Double = 0
    ) -> Int? {
        guard !rows.isEmpty else { return nil }
        let fatigue = fatigueBucket(fatigueRaw).0
        let injury = injuryBucket(injuryRaw).0
        if fatigue >= 2 || injury >= 2 {
            return rows.firstIndex { $0.title == "Easy" } ?? rows.indices.last
        }
        if let z = currentZone, z >= 5 {
            return rows.firstIndex { $0.title == "Avg" } ?? rows.firstIndex { $0.isTargetAnchor }
        }

        let livePace: Double = {
            if coveredKm < 0.8 { return averagePace }
            if currentPace > 0, currentPace < 20 { return currentPace }
            return averagePace
        }()
        if targetPace > 0, livePace > 0 {
            let paceRatio = livePace / targetPace
            if paceRatio < 0.88 {
                return rows.firstIndex { $0.title == "Now" } ?? rows.firstIndex { $0.title == "Avg" }
            }
            if paceRatio > 1.12 {
                return rows.firstIndex { $0.title == "Easy" } ?? rows.firstIndex { $0.isTargetAnchor }
            }
        }

        return rows.firstIndex { $0.isTargetAnchor } ?? rows.firstIndex { $0.title == "Avg" }
    }

    static func liveTargetContext(
        runArc: [String],
        coveredKm: Double,
        elapsedMin: Double,
        userTargetPace: Double
    ) -> (
        entries: [ArcEntry],
        waveY: [CGFloat],
        cumulativeSeconds: Int,
        badgeMeters: Int?,
        badgeAhead: Bool
    ) {
        let entries = parseRunArc(runArc)
        let cumSeries = cumulativeSeries(from: entries)
        let waveY = displacementNormalizedY(from: cumSeries)
        let cumulativeSeconds = cumulativeDeltaSeconds(from: entries)
        let fallbackPace = entries.isEmpty ? 0.0 : entries.map(\.paceValue).reduce(0, +) / Double(entries.count)
        let effectiveTargetPace = userTargetPace > 0 ? userTargetPace : fallbackPace
        let deltaKmVsTarget: Double? = (effectiveTargetPace > 0 && elapsedMin > 0)
            ? (coveredKm - elapsedMin / effectiveTargetPace)
            : nil
        let badgeMeters: Int? = {
            if let dk = deltaKmVsTarget { return Int(round(dk * 1000.0)) }
            guard effectiveTargetPace > 0 else { return nil }
            return deltaMeters(cumulativeSeconds: cumulativeSeconds, targetPaceMinPerKm: effectiveTargetPace)
        }()
        let badgeAhead: Bool = {
            if let dk = deltaKmVsTarget { return dk >= 0 }
            return cumulativeSeconds >= 0
        }()
        return (entries, waveY, cumulativeSeconds, badgeMeters, badgeAhead)
    }

    struct GoalConfidence {
        let percent: Int
        let statusLine: String
    }

    /// Predictive % chance of finishing at or under target-pace goal time for the full race.
    static func goalMeetConfidence(
        targetDistanceKm: Double,
        coveredKm: Double,
        elapsedSeconds: TimeInterval,
        targetPaceMinPerKm: Double,
        averagePace: Double,
        currentPace: Double,
        fatigueTier: Int,
        injuryTier: Int,
        hrZone: Int?,
        deltaKmVsTarget: Double?
    ) -> GoalConfidence {
        guard targetDistanceKm > 0.1, targetPaceMinPerKm > 0 else {
            return GoalConfidence(percent: 0, statusLine: "Set goal")
        }
        let remainingKm = max(0, targetDistanceKm - coveredKm)
        let elapsedSec = max(0, elapsedSeconds)
        let progress = min(1.0, max(0, coveredKm / targetDistanceKm))
        let targetFinishSec = targetPaceMinPerKm * targetDistanceKm * 60.0

        if remainingKm <= 0.05 {
            let met = elapsedSec <= targetFinishSec * 1.01
            return GoalConfidence(percent: met ? 100 : 1, statusLine: met ? "Goal met" : "Over goal")
        }

        let predictivePace: Double = {
            if coveredKm < 0.5 { return averagePace > 0 ? averagePace : targetPaceMinPerKm }
            let cur = (currentPace > 0 && currentPace < 20) ? currentPace : averagePace
            let avg = averagePace > 0 ? averagePace : cur
            let avgWeight = 0.35 + 0.45 * progress
            return avg * avgWeight + cur * (1.0 - avgWeight)
        }()

        let projectedFinishSec = elapsedSec + remainingKm * predictivePace * 60.0
        let slackSec = targetFinishSec - projectedFinishSec
        var probability = 1.0 / (1.0 + exp(-slackSec / 90.0))
        if let dk = deltaKmVsTarget {
            probability += min(0.22, max(-0.22, dk * 0.12))
        }
        var penalty = 0.0
        if fatigueTier >= 2 { penalty += 0.18 }
        else if fatigueTier >= 1 { penalty += 0.08 }
        if injuryTier >= 2 { penalty += 0.12 }
        else if injuryTier >= 1 { penalty += 0.05 }
        if let z = hrZone {
            if z >= 5 { penalty += 0.10 }
            else if z >= 4 { penalty += 0.04 }
        }
        probability = max(0.02, min(0.98, probability - penalty))
        let certainty = min(1.0, 0.28 + 0.72 * progress)
        probability = 0.5 + (probability - 0.5) * certainty
        if slackSec > 180 { probability = max(probability, 0.90) }
        if slackSec < -180 { probability = min(probability, 0.18) }

        let percent = max(1, min(99, Int((probability * 100).rounded())))
        let statusLine: String
        if percent >= 75 { statusLine = "On goal" }
        else if percent >= 50 { statusLine = "Hold steady" }
        else if percent >= 30 { statusLine = "At risk" }
        else { statusLine = "Unlikely" }
        return GoalConfidence(percent: percent, statusLine: statusLine)
    }
}
