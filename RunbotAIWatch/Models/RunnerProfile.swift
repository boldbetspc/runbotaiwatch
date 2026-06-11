import Foundation

// MARK: - Last-run insights (shared key with iOS — local zero-lag cache on this device)

struct LastRunMem0Insights: Codable {
    let coachNotes: String?
    let endDebrief: String?
    let dna: String?
    let raceType: String
    let distanceKm: Double
    let savedAt: TimeInterval
    var inferredTags: InferredRunnerTags?

    static let persistenceKey = "last_run_mem0_insights_for_start"

    static func load() -> LastRunMem0Insights? {
        guard let data = UserDefaults.standard.data(forKey: persistenceKey),
              let insights = try? JSONDecoder().decode(LastRunMem0Insights.self, from: data) else {
            return nil
        }
        guard Date().timeIntervalSince1970 - insights.savedAt < 14 * 24 * 3600 else { return nil }
        return insights
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.persistenceKey)
        }
    }

    func contextSnippet(typeMatches: Bool) -> String {
        var parts: [String] = []
        if typeMatches {
            parts.append("Last run (\(String(format: "%.1f", distanceKm)) km \(raceType))")
        }
        if let dna = dna, !dna.isEmpty { parts.append("COACHING DNA from last run: \(dna)") }
        if let debrief = endDebrief, !debrief.isEmpty { parts.append("Last run close: \(debrief)") }
        if let notes = coachNotes, !notes.isEmpty { parts.append("COACH NOTES from last run: \(notes)") }
        if let tags = inferredTags, let block = tags.structuredBlock, !block.isEmpty {
            parts.append(block)
        }
        return parts.isEmpty ? "" : parts.joined(separator: ". ") + ". "
    }
}

struct InferredRunnerTags: Codable, Equatable {
    var primaryWeakness: String?
    var problemPatterns: [String]
    var splitArchitecture: String?
    var openingStyle: String?
    var nextRunFocus: String?
    var targetAssessment: String?

    init(
        primaryWeakness: String? = nil,
        problemPatterns: [String] = [],
        splitArchitecture: String? = nil,
        openingStyle: String? = nil,
        nextRunFocus: String? = nil,
        targetAssessment: String? = nil
    ) {
        self.primaryWeakness = primaryWeakness
        self.problemPatterns = problemPatterns
        self.splitArchitecture = splitArchitecture
        self.openingStyle = openingStyle
        self.nextRunFocus = nextRunFocus
        self.targetAssessment = targetAssessment
    }

    var structuredBlock: String? {
        var parts: [String] = []
        if let w = primaryWeakness, !w.isEmpty { parts.append("primary_weakness=\(w)") }
        if !problemPatterns.isEmpty { parts.append("problem_patterns=[\(problemPatterns.joined(separator: ","))]") }
        if let s = splitArchitecture { parts.append("split_architecture=\(s)") }
        if let o = openingStyle { parts.append("opening_style=\(o)") }
        if let f = nextRunFocus, !f.isEmpty { parts.append("next_run_focus=\"\(f)\"") }
        if let t = targetAssessment { parts.append("target_assessment=\(t)") }
        return parts.isEmpty ? nil : "STRUCTURED PROFILE: " + parts.joined(separator: ", ")
    }

    static func infer(
        lastRun: LastRunMem0Insights?,
        dnaMemories: [String],
        coachNotes: [String],
        raceBrief: String,
        strategyEffectiveness: String,
        targetPace: Double?,
        raceType: String,
        aggregates: SupabaseManager.RunAggregates?,
        lastRunStats: SupabaseManager.LastRunStats?
    ) -> InferredRunnerTags {
        let corpus = [
            lastRun?.dna, lastRun?.endDebrief, lastRun?.coachNotes,
            dnaMemories.joined(separator: " "), coachNotes.joined(separator: " "),
            raceBrief, strategyEffectiveness
        ].compactMap { $0 }.joined(separator: " ").lowercased()

        var patterns = Set<String>()
        var weakness: String?
        var split: String?
        var opening: String?

        if corpus.contains("fade") || corpus.contains("faded late") { patterns.insert("fades_late"); weakness = weakness ?? "fades_late" }
        if corpus.contains("hot start") || corpus.contains("starts-fast") { patterns.insert("starts_too_hot"); weakness = weakness ?? "starts_too_hot" }
        if corpus.contains("negative split") { patterns.insert("negative_split_capable"); split = "negative" }
        if corpus.contains("even") || corpus.contains("plateau") { split = split ?? "even" }
        if corpus.contains("chasing") { patterns.insert("erratic_pacing") }

        if weakness == "starts_too_hot" || patterns.contains("fades_late") { opening = "protect_opening" }
        else if patterns.contains("erratic_pacing") { opening = "build_into_pace" }
        else if split == "negative" { opening = "commit_immediately" }
        else { opening = "build_into_pace" }

        let nextFocus = extractNextRunFocus(debrief: lastRun?.endDebrief, notes: coachNotes.first ?? lastRun?.coachNotes)
        let targetAssessment = assessTarget(targetPace: targetPace, raceBrief: raceBrief, aggregates: aggregates)

        return InferredRunnerTags(
            primaryWeakness: weakness ?? (patterns.isEmpty ? "none_yet" : patterns.sorted().first),
            problemPatterns: Array(patterns).sorted(),
            splitArchitecture: split ?? "even",
            openingStyle: opening,
            nextRunFocus: nextFocus,
            targetAssessment: targetAssessment
        )
    }

    private static func extractNextRunFocus(debrief: String?, notes: String?) -> String? {
        let sources = [debrief, notes].compactMap { $0 }.joined(separator: ". ")
        guard !sources.isEmpty else { return nil }
        for sentence in sources.replacingOccurrences(of: "\n", with: ". ").components(separatedBy: ". ") {
            let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count > 12 else { continue }
            if ["next run", "next time", "watch for", "focus on"].contains(where: { trimmed.lowercased().contains($0) }) {
                return String(trimmed.prefix(140))
            }
        }
        return nil
    }

    private static func assessTarget(targetPace: Double?, raceBrief: String, aggregates: SupabaseManager.RunAggregates?) -> String? {
        if raceBrief.contains("ambitious") || raceBrief.contains("FASTER") { return "ambitious" }
        if raceBrief.contains("conservative") || raceBrief.contains("slower") { return "conservative" }
        if raceBrief.contains("near avg") { return "realistic" }
        guard let tp = targetPace, tp > 0, let avg = aggregates?.avgPaceMinPerKm, avg > 0 else { return nil }
        let gapSec = (tp - avg) * 60
        if gapSec < -10 { return "ambitious" }
        if gapSec > 10 { return "conservative" }
        return "realistic"
    }
}

struct CoachedRunnerProfile {
    let raceType: String
    let targetPace: Double?
    let lastRunInsights: LastRunMem0Insights?
    let semanticMemories: [String]
    let dnaMemories: [String]
    let coachNotesMemories: [String]
    let runnerBrain: String?
    let raceIntelligenceBrief: String
    let compactRaceHistory: String
    let coachMemoryCallbacks: String
    let strategyEffectiveness: String
    let inferred: InferredRunnerTags

    func startFeedbackContext(prefsLine: String) -> String {
        var context = ""
        if let insights = lastRunInsights {
            let snippet = insights.contextSnippet(typeMatches: insights.raceType == raceType)
            if !snippet.isEmpty { context += snippet }
        }
        if !prefsLine.isEmpty { context += prefsLine }
        if !semanticMemories.isEmpty { context += "Context: \(semanticMemories.joined(separator: " | ")). " }
        if !dnaMemories.isEmpty { context += "\nCOACHING DNA (learned from past runs): \(dnaMemories.joined(separator: " | ")). " }
        if !coachNotesMemories.isEmpty { context += "\nCOACH NOTES (your private analysis): \(coachNotesMemories.joined(separator: " | ")). " }
        if !raceIntelligenceBrief.isEmpty { context += raceIntelligenceBrief }
        if !coachMemoryCallbacks.isEmpty { context += coachMemoryCallbacks }
        if let tags = inferred.structuredBlock { context += "\n\(tags) " }
        if let focus = inferred.nextRunFocus, !focus.isEmpty {
            context += "\nCOMMITMENT FROM LAST RUN: \"\(focus)\" — honor this in today's opening plan if relevant. "
        }
        return context
    }

    func runnerPatternsForStrategy() -> String {
        var parts: [String] = []
        if let insights = lastRunInsights {
            let fresh = insights.contextSnippet(typeMatches: true).trimmingCharacters(in: .whitespacesAndNewlines)
            if !fresh.isEmpty { parts.append("FRESH FROM LAST RUN (highest priority): \(fresh)") }
        }
        if let brain = runnerBrain { parts.append("RUNNER_BRAIN: \(brain)") }
        if !dnaMemories.isEmpty { parts.append("Coaching DNA: \(dnaMemories.joined(separator: " | "))") }
        if !coachNotesMemories.isEmpty { parts.append("Coach notes: \(coachNotesMemories.joined(separator: " | "))") }
        if let tags = inferred.structuredBlock { parts.append(tags) }
        if let focus = inferred.nextRunFocus { parts.append("Next run focus: \(focus)") }
        if !strategyEffectiveness.isEmpty { parts.append("Strategy FX: \(strategyEffectiveness)") }
        return parts.joined(separator: " | ")
    }
}

enum CoachedRunnerProfileAssembler {
    static func extractRollupSection(_ text: String, tag: String) -> String? {
        let marker = "\(tag):"
        guard let range = text.range(of: marker) else { return nil }
        let after = text[range.upperBound...]
        if let end = after.range(of: " | ") { return String(after[..<end.lowerBound]).trimmingCharacters(in: .whitespaces) }
        return after.trimmingCharacters(in: .whitespaces)
    }

    static func assemble(
        raceType: String,
        targetPace: Double?,
        combinedMemories: [String],
        rollups: [String],
        lastRunInsights: LastRunMem0Insights?,
        strategyEffectiveness: String,
        aggregates: SupabaseManager.RunAggregates?,
        lastRun: SupabaseManager.LastRunStats?
    ) -> CoachedRunnerProfile {
        let brainRollups = rollups.filter { $0.contains("RUNNER_BRAIN") || $0.contains("RUN ROLLUP") }
        let dnaMemories = brainRollups.compactMap { extractRollupSection($0, tag: "DNA") }
        let coachNotes = brainRollups.compactMap { extractRollupSection($0, tag: "COACH_NOTES") ?? extractRollupSection($0, tag: "COACH") }
        let runnerBrain = brainRollups.first(where: { $0.contains("RUNNER_BRAIN") })

        var briefParts = ["\nRACE INTELLIGENCE BRIEF:"]
        if let agg = aggregates, agg.totalRuns > 0 {
            briefParts.append("\(agg.totalRuns) runs, avg \(WatchPaceFormat.format(agg.avgPaceMinPerKm)), best \(WatchPaceFormat.format(agg.bestPaceMinPerKm)).")
        }
        if let lr = lastRun {
            briefParts.append("Last: \(String(format: "%.1f", lr.distanceKm))km @\(WatchPaceFormat.format(lr.paceMinPerKm)).")
        }
        if let tp = targetPace, tp > 0, let avg = aggregates?.avgPaceMinPerKm, avg > 0 {
            let gap = (tp - avg) * 60
            briefParts.append(gap < -10 ? "Target ambitious vs avg." : gap > 10 ? "Target conservative vs avg." : "Target near avg.")
        }
        let brief = briefParts.joined(separator: " ")

        var historyParts: [String] = []
        if let insights = lastRunInsights {
            let days = Int((Date().timeIntervalSince1970 - insights.savedAt) / 86400)
            var line = "Most recent (\(days == 0 ? "today" : "\(days)d ago")) \(String(format: "%.1f", insights.distanceKm))km"
            if let d = insights.dna { line += " — \(String(d.prefix(80)))" }
            if let db = insights.endDebrief { line += " — close: \"\(db)\"" }
            historyParts.append(line)
        }
        if let lr = lastRun { historyParts.append("Last session @\(WatchPaceFormat.format(lr.paceMinPerKm))") }
        let compactHistory = historyParts.joined(separator: "; ")

        var callbacks: [String] = []
        if let db = lastRunInsights?.endDebrief, !db.isEmpty { callbacks.append("Last close: \"\(db)\"") }
        if let lr = lastRun { callbacks.append("Last \(raceType): \(String(format: "%.1f", lr.distanceKm))km") }
        if let dna = dnaMemories.first { callbacks.append("Pattern: \(String(dna.prefix(100)))") }
        let callbackBlock = callbacks.isEmpty ? "" : "\nCOACH MEMORY: \(callbacks.joined(separator: " | ")) "

        let inferred = InferredRunnerTags.infer(
            lastRun: lastRunInsights, dnaMemories: dnaMemories, coachNotes: coachNotes,
            raceBrief: brief, strategyEffectiveness: strategyEffectiveness,
            targetPace: targetPace, raceType: raceType, aggregates: aggregates, lastRunStats: lastRun
        )

        return CoachedRunnerProfile(
            raceType: raceType, targetPace: targetPace, lastRunInsights: lastRunInsights,
            semanticMemories: combinedMemories, dnaMemories: dnaMemories, coachNotesMemories: coachNotes,
            runnerBrain: runnerBrain, raceIntelligenceBrief: brief, compactRaceHistory: compactHistory,
            coachMemoryCallbacks: callbackBlock, strategyEffectiveness: strategyEffectiveness, inferred: inferred
        )
    }
}

enum WatchPaceFormat {
    static func format(_ pace: Double) -> String {
        guard pace.isFinite, pace > 0 else { return "—" }
        return String(format: "%d:%02d", Int(pace), Int((pace - Double(Int(pace))) * 60))
    }
}
