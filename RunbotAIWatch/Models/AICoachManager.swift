import Foundation
import Combine

// MARK: - Coaching Trigger Type
enum CoachingTrigger {
    case runStart
    case interval
    case runEnd
}

class AICoachManager: NSObject, ObservableObject {
    @Published var isCoaching = false
    @Published var currentFeedback = ""
    @Published var coachingTimeRemaining: Double = 0.0
    /// iOS-compatible run arc lines for cumulative vs-target curve (watch carousel).
    @Published var runArcForUI: [String] = []
    /// Latest RAG running-quality line (fatigue); mirrors iOS Run Story energy page input.
    @Published var lastFatigueLevel: String = "—"
    /// Latest injury-risk signals joined; "—" when none.
    @Published var lastInjuryRiskFlag: String = "—"
    
    private var coachingTimer: Timer?
    private var feedbackTimer: Timer?
    private let openAIKey: String
    private let supabaseURL: String
    private let supabaseAnonKey: String
    private let maxCoachingDuration: TimeInterval = 60.0
    private var runnerName: String = "Runner"
    private var currentTrigger: CoachingTrigger = .interval
    private var lastDeliveredFeedback: String?
    
    private let ragAnalyzer = RAGPerformanceAnalyzer()
    
    // MARK: - Run Arc (race shape — per-km summary)
    private var runArc: [String] = []
    
    // MARK: - Response Delta tracking
    private var lastCoachingStats: (pace: Double, hr: Double?, distance: Double, time: Date)?
    private var lastCoachingMessage: String?
    private var cuesFollowed: Int = 0
    private var cuesTotal: Int = 0
    
    // MARK: - Coaching DNA + Coach Notes + Race Brief (fetched at run start)
    private var coachingDNA: [String] = []
    private var coachNotes: [String] = []
    private var raceIntelligenceBrief: String = ""
    private var startStrategyName: String = ""
    private var strategiesUsed: [String] = []
    
    override init() {
        if let config = ConfigLoader.loadConfig() {
            self.openAIKey = (config["OPENAI_API_KEY"] as? String) ?? ""
            self.supabaseURL = (config["SUPABASE_URL"] as? String) ?? ""
            self.supabaseAnonKey = (config["SUPABASE_ANON_KEY"] as? String) ?? ""
        } else {
            self.openAIKey = ""
            self.supabaseURL = ""
            self.supabaseAnonKey = ""
        }
        super.init()
        print("🤖 [AICoach] Initialized — using Supabase openai-proxy (same as iOS)")
    }
    
    // MARK: - Run Arc Builder
    
    private func updateRunArc(intervals: [RunInterval], targetPace: Double) {
        runArc = intervals.map { interval in
            let km = interval.index + 1
            let paceStr = formatPace(interval.paceMinPerKm)
            guard targetPace > 0, interval.paceMinPerKm > 0 else {
                return "[\(km)km: \(paceStr), ahead +0s]"
            }
            let targetSec = targetPace * 60.0
            let actualSec = interval.paceMinPerKm * 60.0
            let aheadSec = Int(round(targetSec - actualSec))
            if abs(aheadSec) < 2 {
                return "[\(km)km: \(paceStr), ahead +0s]"
            }
            if aheadSec > 0 {
                return "[\(km)km: \(paceStr), ahead +\(aheadSec)s]"
            }
            return "[\(km)km: \(paceStr), behind \(abs(aheadSec))s]"
        }
        DispatchQueue.main.async { [weak self] in
            self?.runArcForUI = self?.runArc ?? []
        }
    }

    private func applyRunStorySignalsFromRAG(_ analysis: RAGPerformanceAnalyzer.RAGAnalysisResult) {
        let injury = analysis.injuryRiskSignals.isEmpty
            ? "—"
            : analysis.injuryRiskSignals.joined(separator: "; ")
        DispatchQueue.main.async { [weak self] in
            self?.lastFatigueLevel = analysis.runningQualityAssessment.isEmpty ? "—" : analysis.runningQualityAssessment
            self?.lastInjuryRiskFlag = injury
        }
    }
    
    // MARK: - Response Delta
    
    private func computeResponseDelta(currentStats: RunningStatsUpdate, currentHR: Double?) -> String? {
        guard let last = lastCoachingStats, let lastMsg = lastCoachingMessage else { return nil }
        
        let paceDelta = currentStats.pace - last.pace
        let distanceSince = (currentStats.distance - last.distance) / 1000.0
        let paceDirection = paceDelta > 0.05 ? "slower" : paceDelta < -0.05 ? "faster" : "unchanged"
        let paceChangeStr = String(format: "%.0f", abs(paceDelta * 60)) + " s/km " + paceDirection
        
        var hrChange = ""
        if let currentHR = currentHR, let lastHR = last.hr, lastHR > 0 {
            let hrDelta = currentHR - lastHR
            let hrPct = abs(hrDelta / lastHR * 100)
            hrChange = ", HR \(hrDelta > 0 ? "+" : "")\(Int(hrDelta)) bpm (\(String(format: "%.0f", hrPct))%)"
        }
        
        let coachSaid = String(lastMsg.prefix(60))
        let followed = paceDelta < 0.05
        if followed { cuesFollowed += 1 }
        cuesTotal += 1
        
        return "Last cue: \"\(coachSaid)…\" Since then: pace \(paceChangeStr)\(hrChange) over \(String(format: "%.1f", distanceSince))km."
    }
    
    private func snapshotStatsForDelta(stats: RunningStatsUpdate, hr: Double?, feedback: String) {
        lastCoachingStats = (pace: stats.effectivePace, hr: hr, distance: stats.distance, time: Date())
        lastCoachingMessage = feedback
    }
    
    // MARK: - Target Gap Trend + Projected Finish
    
    private func computeTargetGapTrend(stats: RunningStatsUpdate, preferences: UserPreferences.Settings, elapsedSeconds: Double) -> String {
        let targetPace = preferences.targetPaceMinPerKm
        let targetDistanceM = preferences.targetDistanceMeters
        guard targetPace > 0, targetDistanceM > 0, elapsedSeconds > 0 else { return "" }
        
        let expectedDistanceM = (elapsedSeconds / 60.0) / targetPace * 1000.0
        let gapM = stats.distance - expectedDistanceM
        let gapDir = gapM >= 0 ? "ahead" : "behind"
        let gapStr = String(format: "%.0fm %@", abs(gapM), gapDir)
        
        let projectedFinishSec: Double
        if stats.distance > 100 {
            let currentPaceSec = stats.effectivePace * 60.0
            let remainingM = targetDistanceM - stats.distance
            projectedFinishSec = elapsedSeconds + (remainingM / 1000.0) * currentPaceSec
        } else {
            projectedFinishSec = targetDistanceM / 1000.0 * targetPace * 60.0
        }
        let targetFinishSec = targetDistanceM / 1000.0 * targetPace * 60.0
        
        return "Gap: \(gapStr). Projected finish: \(formatDuration(projectedFinishSec)) vs target \(formatDuration(targetFinishSec))."
    }
    
    // MARK: - Coaching DNA fetch
    
    private func fetchCoachingDNA(userId: String, raceType: String) async {
        let dnaResults = await Mem0Manager.shared.search(
            userId: userId,
            query: "coaching DNA, what worked, pacing tendency, response to cues, \(raceType)",
            limit: 5
        )
        coachingDNA = dnaResults
        print("🧬 [AICoach] Coaching DNA loaded: \(dnaResults.count) entries")
    }
    
    private func dnaWatchForPhase(_ phase: String) -> String {
        let phaseKeywords: [String]
        switch phase {
        case "early": phaseKeywords = ["start", "early", "opening", "first", "begin", "warmup"]
        case "middle": phaseKeywords = ["middle", "mid", "steady", "maintain", "cruise"]
        default: phaseKeywords = ["closing", "finish", "final", "end", "last", "kick", "push"]
        }
        
        for dna in coachingDNA {
            let lower = dna.lowercased()
            if phaseKeywords.contains(where: { lower.contains($0) }) && lower.contains("watch") {
                return dna
            }
        }
        
        for dna in coachingDNA {
            let lower = dna.lowercased()
            if phaseKeywords.contains(where: { lower.contains($0) }) {
                return dna
            }
        }
        return coachingDNA.first ?? ""
    }
    
    // MARK: - Coach Notes fetch
    
    private func fetchCoachNotes(userId: String) async {
        let notes = await Mem0Manager.shared.search(
            userId: userId,
            query: "COACH_NOTES, profile, patterns, predictive thresholds, what to watch next",
            limit: 5
        )
        coachNotes = notes
        print("📋 [AICoach] Coach Notes loaded: \(notes.count) entries")
    }
    
    // MARK: - Race Intelligence Brief
    
    private func buildRaceIntelligenceBrief(aggregates: SupabaseManager.RunAggregates?, lastRun: SupabaseManager.LastRunStats?) -> String {
        var parts: [String] = []
        
        if let agg = aggregates, agg.totalRuns > 0 {
            parts.append("Over \(agg.totalRuns) runs: avg pace \(formatPace(agg.avgPaceMinPerKm)), best \(formatPace(agg.bestPaceMinPerKm)).")
        }
        
        if let last = lastRun {
            parts.append("Last run: \(String(format: "%.1f", last.distanceKm))km at \(formatPace(last.paceMinPerKm)).")
            if let agg = aggregates, agg.avgPaceMinPerKm > 0 {
                let trend = last.paceMinPerKm < agg.avgPaceMinPerKm ? "improving" : "slower than average"
                parts.append("Trend: \(trend).")
            }
        }
        
        let brief = parts.isEmpty ? "" : parts.joined(separator: " ")
        print("📊 [AICoach] Race Intelligence Brief: \(brief.count) chars")
        return brief
    }
    
    // MARK: - Reset run state
    
    private func resetRunState() {
        runArc = []
        DispatchQueue.main.async { [weak self] in
            self?.runArcForUI = []
            self?.lastFatigueLevel = "—"
            self?.lastInjuryRiskFlag = "—"
        }
        lastCoachingStats = nil
        lastCoachingMessage = nil
        cuesFollowed = 0
        cuesTotal = 0
        coachingDNA = []
        coachNotes = []
        raceIntelligenceBrief = ""
        startStrategyName = ""
        strategiesUsed = []
    }
    
    // MARK: - Coaching Control
    
    /// Start-of-run coaching with personalization
    /// Fetches Coaching DNA, Coach Notes, builds Race Intelligence Brief
    /// Strategy-first prompt, 100 words max
    func startOfRunCoaching(
        for stats: RunningStatsUpdate,
        with preferences: UserPreferences.Settings,
        voiceManager: VoiceManager,
        runSessionId: String?,
        runnerName: String = "Runner",
        healthManager: HealthManager? = nil,
        runStartTime: Date? = nil
    ) {
        guard !isCoaching else { return }
        currentTrigger = .runStart
        resetRunState()
        print("🏁 [AICoach] Start-of-run coaching — next-gen flow (RAG + Strategy)")
        
        Task {
            let userId = currentUserIdFromDefaults() ?? "watch_user"
            
            // All fetches in parallel
            async let insightsFetch = fetchMem0InsightsWithName(for: userId)
            async let aggregatesFetch = SupabaseManager().fetchRunAggregates(userId: userId)
            async let lastRunFetch = SupabaseManager().fetchLastRun(userId: userId)
            async let dnaFetch: () = fetchCoachingDNA(userId: userId, raceType: preferences.targetDistance.displayName)
            async let notesFetch: () = fetchCoachNotes(userId: userId)
            
            let (insights, name) = await insightsFetch
            let aggregates = await aggregatesFetch
            let lastRun = await lastRunFetch
            _ = await dnaFetch
            _ = await notesFetch
            
            self.runnerName = name
            
            ragAnalyzer.initializeForRun(preferences: preferences, runnerName: name, userId: userId)
            raceIntelligenceBrief = buildRaceIntelligenceBrief(aggregates: aggregates, lastRun: lastRun)
            
            // RAG Performance Analysis at start (lightweight — no intervals yet)
            let startTime = runStartTime ?? Date()
            let ragAnalysis = await ragAnalyzer.analyzePerformance(
                stats: stats, preferences: preferences, healthManager: healthManager,
                intervals: [], runStartTime: startTime, userId: userId
            )
            
            // Coach Strategy RAG for race strategy (ragAnalysis is non-optional from analyzePerformance)
            var coachStrategy: CoachStrategyRAGManager.StrategyResponse.Strategy? = nil
            let elapsedTime = Date().timeIntervalSince(startTime)
            let perfAnalysis = CoachStrategyRAGManager.shared.createPerformanceAnalysis(
                from: ragAnalysis, stats: stats, preferences: preferences,
                healthManager: healthManager, intervals: [], elapsedTime: elapsedTime
            )
            coachStrategy = await CoachStrategyRAGManager.shared.getStrategy(
                performanceAnalysis: perfAnalysis,
                personality: preferences.coachPersonality.rawValue.lowercased(),
                energyLevel: preferences.coachEnergy.rawValue.lowercased(),
                userId: userId, runId: runSessionId, goal: "race_strategy"
            )
            if let strategy = coachStrategy {
                startStrategyName = strategy.strategy_name
                strategiesUsed.append(strategy.strategy_name)
                print("📚 [AICoach] Start strategy: \(strategy.strategy_name)")
            }
            
            let feedback = await generateCoachingFeedback(
                stats: stats, preferences: preferences, mem0Insights: insights,
                aggregates: aggregates, lastRun: lastRun, trigger: .runStart,
                runnerName: name, ragAnalysisContext: ragAnalysis.llmContext,
                ragAnalysis: ragAnalysis, coachStrategy: coachStrategy
            )
            
            await deliverFeedback(feedback, voiceManager: voiceManager, preferences: preferences)
            snapshotStatsForDelta(stats: stats, hr: healthManager?.currentHeartRate, feedback: feedback)
            await persistFeedback(userId: userId, runSessionId: runSessionId, feedback: feedback, stats: stats, preferences: preferences)
            
            let strategyLog = "Start strategy: \(startStrategyName). \(feedback.prefix(80)). Target \(formatPace(preferences.targetPaceMinPerKm))."
            Mem0Manager.shared.add(userId: userId, text: strategyLog, category: "ai_coaching_feedback", metadata: ["type": "start_strategy"])
        }
        
        startCoachingTimer()
    }
    
    /// Interval coaching — action-first, 100 words max
    /// Includes Run Arc, Response Delta, Target Gap, DNA watch-for, Coach Notes
    func startScheduledCoaching(
        for stats: RunningStatsUpdate,
        with preferences: UserPreferences.Settings,
        voiceManager: VoiceManager,
        runSessionId: String?,
        isTrainMode: Bool = false,
        shadowData: ShadowRunData? = nil,
        healthManager: HealthManager? = nil,
        intervals: [RunInterval] = [],
        runStartTime: Date? = nil
    ) {
        guard !isCoaching else { return }
        currentTrigger = .interval
        print("🎯 [AICoach] Interval coaching triggered — next-gen flow")
        
        Task {
            let userId = currentUserIdFromDefaults() ?? "watch_user"
            let (insights, name) = await fetchMem0InsightsWithName(for: userId)
            self.runnerName = name
            let aggregates = await SupabaseManager().fetchRunAggregates(userId: userId)
            
            // Update Run Arc with latest intervals
            updateRunArc(intervals: intervals, targetPace: preferences.targetPaceMinPerKm)
            
            // Compute Response Delta (how runner responded to last cue)
            let responseDelta = computeResponseDelta(currentStats: stats, currentHR: healthManager?.currentHeartRate)
            
            // Target Gap Trend + Projected Finish
            let elapsedSeconds = runStartTime != nil ? Date().timeIntervalSince(runStartTime!) : 0
            let targetGapTrend = computeTargetGapTrend(stats: stats, preferences: preferences, elapsedSeconds: elapsedSeconds)
            
            // Determine run phase for DNA watch-for
            let targetDistanceKm = preferences.targetDistanceMeters / 1000.0
            let distanceKm = stats.distance / 1000.0
            let progress = targetDistanceKm > 0 ? distanceKm / targetDistanceKm : 0
            let phase = progress < 0.33 ? "early" : progress < 0.67 ? "middle" : "closing"
            let dnaWatchFor = dnaWatchForPhase(phase)
            
            // RAG Performance Analysis
            var ragAnalysis: RAGPerformanceAnalyzer.RAGAnalysisResult? = nil
            if let startTime = runStartTime {
                ragAnalysis = await ragAnalyzer.analyzePerformance(
                    stats: stats, preferences: preferences, healthManager: healthManager,
                    intervals: intervals, runStartTime: startTime, userId: userId
                )
                if let rag = ragAnalysis {
                    applyRunStorySignalsFromRAG(rag)
                }
            }
            
            // Coach Strategy RAG (tactical)
            var coachStrategy: CoachStrategyRAGManager.StrategyResponse.Strategy? = nil
            if let analysis = ragAnalysis, let startTime = runStartTime {
                let elapsedTime = Date().timeIntervalSince(startTime)
                let perfAnalysis = CoachStrategyRAGManager.shared.createPerformanceAnalysis(
                    from: analysis, stats: stats, preferences: preferences,
                    healthManager: healthManager, intervals: intervals, elapsedTime: elapsedTime
                )
                coachStrategy = await CoachStrategyRAGManager.shared.getStrategy(
                    performanceAnalysis: perfAnalysis,
                    personality: preferences.coachPersonality.rawValue.lowercased(),
                    energyLevel: preferences.coachEnergy.rawValue.lowercased(),
                    userId: userId, runId: runSessionId, goal: "tactical"
                )
                if let strategy = coachStrategy {
                    if !strategiesUsed.contains(strategy.strategy_name) {
                        strategiesUsed.append(strategy.strategy_name)
                    }
                }
            }
            
            let feedback = await generateCoachingFeedback(
                stats: stats, preferences: preferences, mem0Insights: insights,
                aggregates: aggregates, lastRun: nil, trigger: .interval,
                runnerName: name, isTrainMode: isTrainMode, shadowData: shadowData,
                ragAnalysisContext: ragAnalysis?.llmContext, ragAnalysis: ragAnalysis,
                coachStrategy: coachStrategy,
                responseDelta: responseDelta, targetGapTrend: targetGapTrend,
                dnaWatchFor: dnaWatchFor
            )
            
            await deliverFeedback(feedback, voiceManager: voiceManager, preferences: preferences)
            snapshotStatsForDelta(stats: stats, hr: healthManager?.currentHeartRate, feedback: feedback)
            await persistFeedback(userId: userId, runSessionId: runSessionId, feedback: feedback, stats: stats, preferences: preferences)
        }
        
        startCoachingTimer()
    }
    
    /// End-of-run coaching — story-style debrief, up to 150 words
    /// Waits for any active coaching to finish (up to 120s) before starting — never skips the debrief.
    func endOfRunCoaching(
        for stats: RunningStatsUpdate,
        session: RunSession,
        with preferences: UserPreferences.Settings,
        voiceManager: VoiceManager,
        healthManager: HealthManager? = nil
    ) {
        currentTrigger = .runEnd
        print("🏁 [AICoach] End-of-run coaching — next-gen debrief")
        
        Task {
            // Wait for any active coaching/TTS to finish (up to 120s) — mirrors iOS pipeline
            var waitTicks = 0
            while isCoaching && waitTicks < 480 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                waitTicks += 1
            }
            if waitTicks > 0 {
                print("🏁 [AICoach] Waited \(Double(waitTicks) * 0.25)s for prior coaching to finish")
            }
            
            let userId = currentUserIdFromDefaults() ?? "watch_user"
            let (insights, name) = await fetchMem0InsightsWithName(for: userId)
            self.runnerName = name
            
            // Final Run Arc update
            updateRunArc(intervals: session.intervals, targetPace: preferences.targetPaceMinPerKm)
            
            // Performance Analyzer only — no Coach Strategy RAG for end
            let ragEndOfRunAnalysis = await ragAnalyzer.analyzeEndOfRun(
                session: session, stats: stats, preferences: preferences,
                healthManager: healthManager, userId: userId
            )
            
            // Coaching response summary
            let responseSummary = cuesTotal > 0 ? "\(cuesFollowed)/\(cuesTotal) cues followed positively" : "No interval cues tracked"
            
            let feedback = await generateEndOfRunFeedback(
                session: session, stats: stats, preferences: preferences,
                mem0Insights: insights, ragAnalysis: ragEndOfRunAnalysis, runnerName: name
            )
            
            await deliverFeedback(feedback, voiceManager: voiceManager, preferences: preferences)
            await persistFeedback(userId: userId, runSessionId: session.id, feedback: feedback, stats: stats, preferences: preferences)
            
            // Store end-of-run analysis
            let detailedSummary = """
            Run completed: \(String(format: "%.2f", stats.distance / 1000.0))km in \(formatDuration(session.duration)), pace \(formatPace(session.pace)).
            Target: \(preferences.targetDistance.displayName) at \(formatPace(preferences.targetPaceMinPerKm)).
            Result: \(ragEndOfRunAnalysis.targetAchievement). \(responseSummary).
            Race shape: \(runArc.joined(separator: ", ")).
            Feedback: \(feedback)
            """
            saveMem0Memory(userId: userId, text: detailedSummary, category: "running_performance", metadata: [
                "type": "end_of_run_analysis",
                "distance_km": String(format: "%.2f", stats.distance / 1000.0),
                "pace": formatPace(session.pace),
                "target_met": ragEndOfRunAnalysis.targetMet ? "yes" : "no"
            ])
            
            // Post-run deep learning: generate Coach Notes + Coaching DNA
            await generatePostRunCoachNotes(
                userId: userId, session: session, stats: stats,
                preferences: preferences, ragAnalysis: ragEndOfRunAnalysis,
                responseSummary: responseSummary
            )
            
            ragAnalyzer.clearRunContext()
            resetRunState()
            print("🧹 [AICoach] Run state cleared after end-of-run")
        }
        
        startCoachingTimer()
    }
    
    /// Generate end-of-run feedback — Performance Analyzer only, story-style, 120 words
    private func generateEndOfRunFeedback(
        session: RunSession,
        stats: RunningStatsUpdate,
        preferences: UserPreferences.Settings,
        mem0Insights: String,
        ragAnalysis: RAGPerformanceAnalyzer.EndOfRunAnalysis,
        runnerName: String
    ) async -> String {
        let prompt = buildEndOfRunPrompt(
            session: session, stats: stats, preferences: preferences,
            mem0Insights: mem0Insights, ragAnalysis: ragAnalysis, runnerName: runnerName
        )
        return await requestAICoachingFeedback(prompt, energy: preferences.coachEnergy, personality: preferences.coachPersonality, language: preferences.language, trigger: .runEnd)
    }
    
    /// Build end-of-run prompt — story-style debrief with Run Arc, response summary
    private func buildEndOfRunPrompt(
        session: RunSession,
        stats: RunningStatsUpdate,
        preferences: UserPreferences.Settings,
        mem0Insights: String,
        ragAnalysis: RAGPerformanceAnalyzer.EndOfRunAnalysis,
        runnerName: String
    ) -> String {
        let raceShapeStr = runArc.isEmpty ? "No per-km data" : runArc.joined(separator: ", ")
        let responseSummary = cuesTotal > 0 ? "\(cuesFollowed)/\(cuesTotal) coaching cues followed positively" : "No interval cues tracked"
        let strategiesStr = strategiesUsed.isEmpty ? "None recorded" : strategiesUsed.joined(separator: " → ")
        
        return """
        This is END OF RUN — post-race debrief. Write as a short story, no bullet lists.
        
        IMPORTANT: Lower pace in min/km means faster running (e.g., 5:30 is faster than 7:00).
        
        USER PREFERENCES:
        - Language: \(preferences.language.displayName)
        - Coach Personality: \(preferences.coachPersonality.rawValue.uppercased())
        - Coach Energy: \(preferences.coachEnergy.rawValue.uppercased())
        
        RACE SHAPE (Run Arc): \(raceShapeStr)
        OPENING PLAN: \(startStrategyName.isEmpty ? "No start strategy recorded" : startStrategyName)
        STRATEGIES USED THIS RUN: \(strategiesStr)
        COACHING RESPONSE: \(responseSummary)
        
        \(ragAnalysis.llmContext)
        
        MEM0 PERSONALIZED INSIGHTS:
        \(mem0Insights.isEmpty ? "First tracked run!" : mem0Insights)
        
        DEBRIEF TASK (weave into a cohesive story, up to ~150 words):
        1. Result vs target — ahead, on, or behind?
        2. Race shape — how the run unfolded (negative split, fade, steady?)
        3. HR story — efficiency, drift, zones
        4. Interval variation — consistency or breakdown?
        5. Was the opening plan followed?
        6. One lesson that explains the performance
        7. One specific next step for improvement
        
        RULES:
        - Story format, no bullet lists
        - Be honest, critical, and constructive
        - Use numbers to explain meaning, not to list data
        - Reference the runner's name "\(runnerName)" naturally
        - Match personality and energy settings
        - Up to ~150 words
        
        NOW GENERATE THE END-OF-RUN DEBRIEF:
        """
    }
    
    // MARK: - Post-Run Deep Learning (Coach Notes + Coaching DNA)
    
    private func generatePostRunCoachNotes(
        userId: String,
        session: RunSession,
        stats: RunningStatsUpdate,
        preferences: UserPreferences.Settings,
        ragAnalysis: RAGPerformanceAnalyzer.EndOfRunAnalysis,
        responseSummary: String
    ) async {
        let raceShapeStr = runArc.joined(separator: ", ")
        let prompt = """
        Generate private COACH NOTES for this runner's file. These notes are for the AI coach's internal use in future runs — not spoken to the runner.
        
        RUN DATA:
        - Distance: \(String(format: "%.2f", stats.distance / 1000.0))km, Duration: \(formatDuration(session.duration)), Pace: \(formatPace(session.pace))
        - Target: \(preferences.targetDistance.displayName) at \(formatPace(preferences.targetPaceMinPerKm))
        - Result: \(ragAnalysis.targetAchievement)
        - Race shape: \(raceShapeStr)
        - Coaching response: \(responseSummary)
        - Intervals: \(session.intervals.map { formatPace($0.paceMinPerKm) }.joined(separator: ", "))
        
        Generate exactly 4 lines:
        1. PROFILE: One-sentence runner profile update (ability level, tendencies)
        2. PATTERN: Key pattern from this run (pacing, fatigue, HR behavior)
        3. WATCH_FOR: What to watch for in the next run (phase-specific, e.g. "early: tends to start 15s/km fast")
        4. THRESHOLD: A predictive threshold (e.g. "if pace drops >10s/km after km 3, likely to fade")
        
        Be concise and data-driven. No fluff.
        """
        
        let notes = await requestAICoachingFeedback(prompt, energy: .medium, personality: .strategist, language: .english, trigger: .runEnd)
        
        if !notes.isEmpty && notes != "Stay strong and keep your pace!" {
            Mem0Manager.shared.add(userId: userId, text: notes, category: "COACH_NOTES", metadata: [
                "type": "coach_notes",
                "distance_km": String(format: "%.2f", stats.distance / 1000.0),
                "pace": formatPace(session.pace),
                "platform": "watchOS"
            ])
            print("📋 [AICoach] Coach Notes stored for deep learning")
            
            // Store Coaching DNA entry
            let dnaEntry = "DNA \(preferences.targetDistance.displayName): Race shape [\(raceShapeStr)]. \(responseSummary). Pace \(formatPace(session.pace)) vs target \(formatPace(preferences.targetPaceMinPerKm)). \(ragAnalysis.targetMet ? "Target met." : "Target missed.")"
            Mem0Manager.shared.add(userId: userId, text: dnaEntry, category: "coaching_dna", metadata: [
                "type": "coaching_dna",
                "race_type": preferences.targetDistance.displayName,
                "platform": "watchOS"
            ])
            print("🧬 [AICoach] Coaching DNA stored for deep learning")
        }
    }
    
    // MARK: - Periodic Scheduling (time-based intervals)
    func beginPeriodicFeedback(
        getStats: @escaping () -> RunningStatsUpdate?,
        preferencesProvider: @escaping () -> UserPreferences.Settings,
        voiceManager: VoiceManager,
        runSessionIdProvider: @escaping () -> String?
    ) {
        feedbackTimer?.invalidate()
        let intervalMinutes = Double(preferencesProvider().feedbackFrequency)
        let intervalSeconds = intervalMinutes * 60.0
        
        feedbackTimer = Timer.scheduledTimer(withTimeInterval: intervalSeconds, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            guard !self.isCoaching else { return }
            
            guard let stats = getStats() else { return }
            let prefs = preferencesProvider()
            
            self.startScheduledCoaching(
                for: stats,
                with: prefs,
                voiceManager: voiceManager,
                runSessionId: runSessionIdProvider()
            )
        }
        
        print("⏱️ [AICoach] Periodic feedback started (every \(intervalMinutes) min)")
    }
    
    func stopPeriodicFeedback() {
        feedbackTimer?.invalidate()
        feedbackTimer = nil
        print("⏹️ [AICoach] Periodic feedback stopped")
    }
    
    private func startCoachingTimer() {
        isCoaching = true
        coachingTimeRemaining = maxCoachingDuration
        coachingTimer?.invalidate()
        var elapsed: TimeInterval = 0
        
        coachingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            
            elapsed += 0.1
            self.coachingTimeRemaining = max(0, self.maxCoachingDuration - elapsed)
            
            if elapsed >= self.maxCoachingDuration {
                timer.invalidate()
                // Guardrail: auto cut-off — notify so view can stop TTS; then clear coaching state
                NotificationCenter.default.post(name: .coachingTimeLimitReached, object: nil)
                self.stopCoaching()
            }
        }
    }
    
    func stopCoaching() {
        print("⏹️ [AICoach] Stopping coaching (auto-terminate or manual)")
        isCoaching = false
        coachingTimer?.invalidate()
        coachingTimer = nil
        // Keep currentFeedback visible for at least 3 mins; only replace when next feedback is delivered in deliverFeedback()
        coachingTimeRemaining = 0.0
        lastDeliveredFeedback = nil
    }
    
    // MARK: - AI Feedback Generation
    
    private func generateCoachingFeedback(
        stats: RunningStatsUpdate,
        preferences: UserPreferences.Settings,
        mem0Insights: String,
        aggregates: SupabaseManager.RunAggregates?,
        lastRun: SupabaseManager.LastRunStats? = nil,
        trigger: CoachingTrigger,
        runnerName: String,
        isTrainMode: Bool = false,
        shadowData: ShadowRunData? = nil,
        ragAnalysisContext: String? = nil,
        ragAnalysis: RAGPerformanceAnalyzer.RAGAnalysisResult? = nil,
        coachStrategy: CoachStrategyRAGManager.StrategyResponse.Strategy? = nil,
        responseDelta: String? = nil,
        targetGapTrend: String? = nil,
        dnaWatchFor: String? = nil
    ) async -> String {
        let prompt = buildCoachingPrompt(
            stats: stats, personality: preferences.coachPersonality,
            energy: preferences.coachEnergy, mem0Insights: mem0Insights,
            aggregates: aggregates, lastRun: lastRun, trigger: trigger,
            runnerName: runnerName, targetPace: preferences.targetPaceMinPerKm,
            targetDistance: preferences.targetDistance, isTrainMode: isTrainMode,
            shadowData: shadowData, ragAnalysisContext: ragAnalysisContext,
            ragAnalysis: ragAnalysis, coachStrategy: coachStrategy,
            responseDelta: responseDelta, targetGapTrend: targetGapTrend,
            dnaWatchFor: dnaWatchFor
        )
        return await requestAICoachingFeedback(prompt, energy: preferences.coachEnergy, personality: preferences.coachPersonality, language: preferences.language, trigger: trigger)
    }
    
    private func generateRunSummary(
        session: RunSession,
        stats: RunningStatsUpdate,
        preferences: UserPreferences.Settings,
        mem0Insights: String,
        aggregates: SupabaseManager.RunAggregates?,
        runnerName: String
    ) async -> String {
        let prompt = buildRunSummaryPrompt(
            session: session,
            stats: stats,
            personality: preferences.coachPersonality,
            energy: preferences.coachEnergy,
            mem0Insights: mem0Insights,
            aggregates: aggregates,
            runnerName: runnerName,
            targetPace: preferences.targetPaceMinPerKm
        )
        return await requestAICoachingFeedback(prompt, energy: preferences.coachEnergy, personality: preferences.coachPersonality, language: preferences.language, trigger: .runEnd)
    }
    
    private func buildCoachingPrompt(
        stats: RunningStatsUpdate,
        personality: CoachPersonality,
        energy: CoachEnergy,
        mem0Insights: String,
        aggregates: SupabaseManager.RunAggregates?,
        lastRun: SupabaseManager.LastRunStats? = nil,
        trigger: CoachingTrigger,
        runnerName: String,
        targetPace: Double,
        targetDistance: TargetDistance? = nil,
        isTrainMode: Bool = false,
        shadowData: ShadowRunData? = nil,
        ragAnalysisContext: String? = nil,
        ragAnalysis: RAGPerformanceAnalyzer.RAGAnalysisResult? = nil,
        coachStrategy: CoachStrategyRAGManager.StrategyResponse.Strategy? = nil,
        responseDelta: String? = nil,
        targetGapTrend: String? = nil,
        dnaWatchFor: String? = nil
    ) -> String {
        let distanceKm = stats.distance / 1000.0
        let currentPaceStr = formatPace(stats.effectivePace)
        let targetPaceStr = formatPace(targetPace)
        let paceDeviation = stats.effectivePace > 0 ? ((stats.effectivePace - targetPace) / targetPace * 100) : 0
        
        // Personality-specific focus
        let personalityInstructions: String
        switch personality {
        case .strategist:
            personalityInstructions = """
            STRATEGIST MODE: You are a race strategist. Focus on:
            - Energy management and pacing strategy
            - When to conserve vs. push based on remaining distance
            - Run-walk strategies if pace is struggling
            - Segment planning (e.g., "next 500m steady, then assess")
            - Smart decision-making: "Hold back now, surge at 5k" type advice
            - Tactical adjustments based on fatigue signs
            NO generic motivation. Give strategic game plans.
            """
            
        case .pacer:
            personalityInstructions = """
            PACER MODE: You are a tactical running coach. Focus on:
            - Breathing patterns (inhale 2, exhale 2 for rhythm)
            - Cadence cues (180 steps/min, quick light steps)
            - Stride efficiency (avoid overstriding, land under hips)
            - Form checks (shoulders down, core engaged, arms 90°)
            - Pace adjustments ("drop 10 sec/km" or "ease 5%")
            - Biomechanics: foot strike, posture, arm swing
            NO vague "keep going" phrases. Give biomechanical cues.
            """
            
        case .finisher:
            personalityInstructions = """
            FINISHER MODE: You are a motivational powerhouse. Focus on:
            - Mental strength and pushing through fatigue
            - Milestone celebrations and progress recognition
            - Confidence-building statements
            - "Dig deep" and "finish strong" messaging
            - Visualization of crossing the finish line
            - Empowering the runner to break through limits
            BUT: Still tie motivation to actionable cues (e.g., "You're strong! Lift those knees!")
            """
        }
        
        // Energy-specific tone
        let energyInstructions: String
        switch energy {
        case .low:
            energyInstructions = "Tone: Calm, steady, almost meditative. Short sentences. Minimal words. Supportive but not loud."
        case .medium:
            energyInstructions = "Tone: Balanced, positive, clear. Conversational but focused. Professional coach vibe."
        case .high:
            energyInstructions = "Tone: HIGH-ENERGY, motivating, punchy! Short bursts of power. Make them FEEL the energy!"
        }
        
        // Trigger-specific context with TRAIN MODE adaptation
        let triggerContext: String
        if isTrainMode, let shadow = shadowData {
            let currentKm = Int(distanceKm)
            let shadowInterval = shadow.intervals.first(where: { $0.kilometer == currentKm })
            let shadowPace = shadowInterval?.pacePerKm ?? shadow.prModel.averagePaceMinPerKm
            let shadowPaceStr = formatPace(shadowPace)
            let paceDiff = stats.effectivePace - shadowPace
            let status = paceDiff > 0.1 ? "BEHIND" : (paceDiff < -0.1 ? "AHEAD" : "ON PACE")
            
            triggerContext = """
            🏃‍♂️ TRAIN MODE - RACING AGAINST SHADOW PR: \(shadow.prModel.name)
            
            Current km: \(currentKm)
            Your pace: \(currentPaceStr) | Shadow pace: \(shadowPaceStr)
            Status: \(status) (\(String(format: "%.1f", abs(paceDiff))) min/km difference)
            
            THIS IS A RACE AGAINST YOUR OWN PR! The runner is competing against themselves.
            
            KEY COACHING POINTS:
            - If BEHIND: Push them to close the gap. "Pick up the pace, you're \(String(format: "%.1f", abs(paceDiff))) min/km slower than your PR!"
            - If AHEAD: Encourage maintaining lead. "You're beating your PR! Hold this pace, don't let up!"
            - If ON PACE: Motivate to surge. "You're matching your PR, now's the time to break it!"
            
            Focus on:
            1. Competitive mindset (you vs past you)
            2. Specific pace adjustments needed
            3. Mental toughness to beat your own record
            
            NO GENERIC PRAISE. This is a race - be tactical and competitive!
            """
        } else {
            switch trigger {
            case .runStart:
                // New start-of-run prompt format with RAG analysis + Coach Strategy Graph RAG
                let raceType = targetDistance?.displayName ?? "run"
                let targetPaceDisplay = targetPaceStr.isEmpty ? "Not set" : targetPaceStr
                
                // Truncate Mem0 insights to 400 chars
                let mem0Context = mem0Insights.isEmpty ? "No historical context available." : String(mem0Insights.prefix(400))
                
                // Extract RAG analysis data for connecting to previous races and highlighting key lessons
                let similarRuns = ragAnalysis?.similarRunsContext ?? "No similar runs found."
                let historicalOutcomes = ragAnalysis?.overallRecommendation ?? "No historical outcomes available."
                let performancePatterns = ragAnalysis?.performanceAnalysis ?? "No performance patterns available."
                let adaptiveStrategy = ragAnalysis?.adaptiveMicrostrategy ?? "No adaptive strategy available."
                
                // Check if we have meaningful historical data from RAG (not just default "No..." messages)
                let hasRAGData = (similarRuns != "No similar runs found." && !similarRuns.isEmpty) ||
                                 (historicalOutcomes != "No historical outcomes available." && !historicalOutcomes.isEmpty) ||
                                 (performancePatterns != "No performance patterns available." && !performancePatterns.isEmpty) ||
                                 (adaptiveStrategy != "No adaptive strategy available." && !adaptiveStrategy.isEmpty)
                
                // Log RAG data lengths for debugging
                print("📊 [AICoach] Start-of-run RAG data lengths:")
                print("   - similarRuns: \(similarRuns.count) chars")
                print("   - historicalOutcomes: \(historicalOutcomes.count) chars")
                print("   - performancePatterns: \(performancePatterns.count) chars")
                print("   - adaptiveStrategy: \(adaptiveStrategy.count) chars")
                print("   - mem0Context: \(mem0Context.count) chars")
                print("   - hasRAGData: \(hasRAGData)")
                
                // Coach Strategy RAG section
                var raceStrategySection = ""
                if let strategy = coachStrategy {
                    // Note: Graph RAG entities/relations not currently in response structure
                    // This can be enhanced when edge function provides graph RAG metadata
                    raceStrategySection = """
                    
                    RACE STRATEGY: \(strategy.strategy_text)
                    [Graph RAG: matched entities: [strategy-based]; relations: [coaching-strategy-graph]]
                    Strategy Name: \(strategy.strategy_name)
                    Situation: \(strategy.situation_summary)
                    Selection Reason: \(strategy.selection_reason)
                    Expected Outcome: \(strategy.expected_outcome)
                    """
                } else {
                    raceStrategySection = "\nRACE STRATEGY: No strategy available from knowledge base."
                }
                
                // Coaching DNA section
                let dnaSection = coachingDNA.isEmpty ? "" : """
                
                COACHING DNA (learned from past runs):
                \(coachingDNA.prefix(3).joined(separator: "\n"))
                """
                
                // Coach Notes section
                let notesSection = coachNotes.isEmpty ? "" : """
                
                COACH NOTES (private AI observations from past runs):
                \(coachNotes.prefix(3).joined(separator: "\n"))
                """
                
                // Race Intelligence Brief
                let briefSection = raceIntelligenceBrief.isEmpty ? "" : """
                
                RACE INTELLIGENCE BRIEF: \(raceIntelligenceBrief)
                """
                
                triggerContext = """
                You're coaching \(runnerName) at the START of a \(raceType) run. Strategy-first.
                
                Target pace: \(targetPaceDisplay)/km
                \(briefSection)
                \(dnaSection)
                \(notesSection)
                
                HISTORICAL CONTEXT:
                - Previous race: \(lastRun != nil ? "\(String(format: "%.2f", lastRun!.distanceKm))km at \(formatPace(lastRun!.paceMinPerKm)), \(formatDuration(lastRun!.durationSeconds))" : "No previous run data")
                - Similar runs: \(similarRuns)
                - Performance patterns: \(performancePatterns)
                
                \(raceStrategySection)
                
                Runner history: \(mem0Context)
                
                IMPORTANT: Lower pace in min/km means faster (5:30 is faster than 7:00).
                
                TASK: Lead with the chosen strategy. One clear opening instruction. Connect to this runner's history and what the DNA/notes say about their tendencies. Strategy-first, then tie to history.
                
                Max 100 words. No generic advice. Be critical and honest.
                """
            case .interval:
                // New interval prompt structure with RAG analysis + Coach Strategy Graph RAG
                if let analysis = ragAnalysis {
                    let raceType = targetDistance?.displayName ?? "run"
                    let targetDistanceMeters = targetDistance?.distanceMeters ?? 5000.0
                    let targetDistanceKm = targetDistanceMeters / 1000.0
                    
                    // Calculate run phase
                    let progress = distanceKm / targetDistanceKm
                    let runPhase: String
                    let phaseDescription: String
                    if progress < 0.33 {
                        runPhase = "early"
                        phaseDescription = "first third"
                    } else if progress < 0.67 {
                        runPhase = "middle"
                        phaseDescription = "middle section"
                    } else {
                        runPhase = "closing"
                        phaseDescription = "final stretch"
                    }
                    
                    // Calculate approximate duration from distance and pace (in seconds)
                    let estimatedDurationSeconds = distanceKm * stats.effectivePace * 60.0
                    let durationStr = formatDuration(estimatedDurationSeconds)
                    
                    // Extract HR data from heart zone / HR variation analysis (if available)
                    let hrText = analysis.heartZoneAnalysis.contains("bpm") || analysis.heartZoneAnalysis.contains("HR") || analysis.hrVariationAnalysis.contains("bpm") || analysis.hrVariationAnalysis.contains("HR") ? "Available in analysis below" : "No heart rate data available for this run."
                    
                    // Extract data from RAG analysis sections
                    let statusLabel = analysis.targetStatus.description
                    let paceVsTarget = String(format: "%.1f", paceDeviation > 0 ? paceDeviation : abs(paceDeviation)) + "% " + (paceDeviation > 0 ? "slower" : paceDeviation < 0 ? "faster" : "on target")
                    let distanceProgressVsTarget = String(format: "%.1f", progress * 100) + "%"
                    let distanceCoveredVsExpected = String(format: "%.2f", distanceKm) + "km / " + String(format: "%.2f", targetDistanceKm) + "km"
                    let paceTrend = analysis.intervalTrends.isEmpty ? "Stable" : analysis.intervalTrends
                    let hrAndCurrentZone = analysis.heartZoneAnalysis.isEmpty ? "N/A" : analysis.heartZoneAnalysis
                    let hrTrendAndDrift = analysis.hrVariationAnalysis.isEmpty ? "N/A" : analysis.hrVariationAnalysis
                    let heartZoneDistribution = analysis.heartZoneAnalysis.isEmpty ? "N/A" : analysis.heartZoneAnalysis
                    let consistency = analysis.runningQualityAssessment.isEmpty ? "N/A" : analysis.runningQualityAssessment
                    
                    // Extract from performance analysis and running quality (RAGAnalysisResult uses these)
                    let coachContext = analysis.performanceAnalysis + " " + analysis.adaptiveMicrostrategy
                    let effortCostSignal = coachContext.contains("effort") ? coachContext : "See Coach Perspective below"
                    let hiddenFatigueFlag = coachContext.contains("fatigue") || coachContext.contains("drift") ? "Detected" : "None detected"
                    let fatigueLevel = analysis.runningQualityAssessment.contains("fatigue") ? analysis.runningQualityAssessment : "Moderate"
                    let sustainabilityStatus = coachContext.contains("sustainable") ? coachContext : "See Coach Perspective below"
                    
                    // Coach perspective fields (derived from performance + adaptive strategy)
                    let runPhaseDesc = runPhase
                    let effortTiming = analysis.performanceAnalysis
                    let finishImpact = coachContext.contains("finish") ? coachContext : "See Coach Perspective below"
                    let overallJudgment = analysis.adaptiveMicrostrategy
                    
                    // Historical context
                    let similarRunContext = analysis.similarRunsContext.isEmpty ? "No similar runs found" : analysis.similarRunsContext
                    let typicalHistoricalOutcomes = analysis.overallRecommendation.isEmpty ? "N/A" : analysis.overallRecommendation
                    let runningQualityScore = analysis.runningQualityAssessment.isEmpty ? "N/A" : analysis.runningQualityAssessment
                    let injuryRiskFlag = analysis.injuryRiskSignals.isEmpty ? "None" : analysis.injuryRiskSignals.joined(separator: "; ")
                    let nextAction500m1km = analysis.adaptiveMicrostrategy.isEmpty ? "See adaptive strategy below" : analysis.adaptiveMicrostrategy
                    let conciseRecommendation = analysis.overallRecommendation.isEmpty ? "See recommendation below" : analysis.overallRecommendation
                    
                    // Mem0 context (truncated)
                    let mem0Context = mem0Insights.isEmpty ? "" : String(mem0Insights.prefix(400))
                    
                    // Coach Strategy RAG section
                    var raceStrategySection = ""
                    if let strategy = coachStrategy {
                        raceStrategySection = """
                        
                        RACE STRATEGY: \(strategy.strategy_text)
                        [Graph RAG: matched entities: [strategy-based]; relations: [coaching-strategy-graph]]
                        Strategy Name: \(strategy.strategy_name)
                        Situation: \(strategy.situation_summary)
                        Selection Reason: \(strategy.selection_reason)
                        Expected Outcome: \(strategy.expected_outcome)
                        """
                    } else {
                        raceStrategySection = "\nRACE STRATEGY: No adaptive strategy available from knowledge base."
                    }
                    
                    // New context: Run Arc, Response Delta, Target Gap, DNA, Coach Notes
                    let runArcStr = runArc.isEmpty ? "No per-km data yet" : runArc.joined(separator: ", ")
                    let responseDeltaStr = responseDelta ?? ""
                    let targetGapStr = targetGapTrend ?? ""
                    let dnaWatchForStr = dnaWatchFor ?? ""
                    let coachNotesStr = coachNotes.prefix(2).joined(separator: " ")
                    
                    triggerContext = """
                    INTERVAL feedback — lead with ACTION, not explanation. Direct, short, mid-race tone.
                    
                    IMPORTANT: Lower pace in min/km means faster (5:30 is faster than 7:00).
                    
                    RACE SHAPE (Run Arc): \(runArcStr)
                    \(responseDeltaStr.isEmpty ? "" : "RESPONSE DELTA: \(responseDeltaStr)")
                    \(targetGapStr.isEmpty ? "" : "TARGET GAP: \(targetGapStr)")
                    \(dnaWatchForStr.isEmpty ? "" : "DNA WATCH-FOR (\(runPhase) phase): \(dnaWatchForStr)")
                    \(coachNotesStr.isEmpty ? "" : "COACH NOTES: \(coachNotesStr)")
                    
                    Current: \(String(format: "%.2f", distanceKm))km, pace \(currentPaceStr)/km (target \(targetPaceStr)), \(durationStr), phase: \(runPhase)
                    HR: \(hrText)
                    
                    PERFORMANCE ANALYSIS:
                    - Status: \(statusLabel) (\(paceVsTarget))
                    - Distance: \(distanceCoveredVsExpected)
                    - Pace trend: \(paceTrend)
                    - HR: \(hrAndCurrentZone), drift: \(hrTrendAndDrift)
                    - Fatigue: \(fatigueLevel)
                    - Consistency: \(consistency)
                    - Injury risk: \(injuryRiskFlag)
                    - Next action: \(nextAction500m1km)
                    
                    \(raceStrategySection)
                    
                    Generate **100 words** max. Lead with action. Concise, actionable, target-aware — not generic encouragement.
                    """
                } else {
                    triggerContext = """
                    THIS IS MID-RUN COACHING. Runner is at \(String(format: "%.2f", distanceKm)) km.
                    Check their pace vs target. Current: \(currentPaceStr), Target: \(targetPaceStr).
                    Pace deviation: \(String(format: "%.1f", paceDeviation))% (\(paceDeviation > 0 ? "slower" : "faster")).
                    Give actionable advice NOW to adjust or maintain.
                    """
                }
            case .runEnd:
                triggerContext = "THIS IS END-OF-RUN (handled separately, should not reach here)"
            }
        }
        
        let insightsSection = mem0Insights.isEmpty ? "No historical data yet. Fresh start!" : "Historical insights:\n\(mem0Insights)"
        
        var aggregatesSection = "No recent runs to compare."
        if let a = aggregates, a.totalRuns > 0 {
            aggregatesSection = """
            Recent performance (\(a.totalRuns) runs):
            - Avg distance: \(String(format: "%.2f", a.avgDistanceKm)) km
            - Avg pace: \(formatPace(a.avgPaceMinPerKm))
            - Best pace: \(formatPace(a.bestPaceMinPerKm))
            """
        }
        
        // For start-of-run, exclude personality/energy instructions, current stats, and examples
        let personalitySection = trigger == .runStart ? "" : """
        \(personalityInstructions)
        
        \(energyInstructions)
        
        """
        
        let currentStatsSection = trigger == .runStart ? "" : """
        CURRENT RUN STATS:
        - Distance: \(String(format: "%.2f", distanceKm)) km
        - Current pace: \(currentPaceStr) min/km (Target: \(targetPaceStr))
        - Pace status: \(paceDeviation > 10 ? "TOO SLOW" : paceDeviation < -10 ? "TOO FAST" : "ON TARGET")
        - Calories: \(String(format: "%.0f", stats.calories))
        
        """
        
        let examplesSection = trigger == .runStart ? "" : """
        GOOD EXAMPLES (INSIGHT SYNTHESIS using Coach Perspective + Trade-offs):
        - "\(runnerName), 8% behind target but HR stable Zone 3. Coach Perspective: 'effort rising faster than distance' - drift 6.2% means hidden fatigue. Trade-off: 'future impact negative'. Ease to 6:20 next km to prevent bigger slowdown. You have headroom but cost is rising."
        - "Pace declining last 3km (5:20→5:25). Coach Perspective: 'paying for pace too early' - started too fast. Trade-off: 'Zone 4 cost too high early, future impact negative'. Runner's Wisdom: 'form breaking down'. Ease to Zone 2 for 500m, then reassess."
        - "Zone 5 for 15% already. Coach Perspective: 'would struggle 5km later' + Trade-off: 'unsustainable for remaining 5km'. Drift at 8% means if you maintain this, you'll fade hard. Ease to Zone 3 now - smart recovery preserves finish."
        
        BAD EXAMPLES (avoid):
        - "Pace is 6:45, target is 6:30. HR is 165. Zone 3." (no synthesis, no why, no insight)
        - "You're behind target. Pick up pace." (no root cause, no pattern connection)
        - "Great job, keep going!" (no action, ignores data)
        - "You're almost there!" (not actionable)
        - "Stay strong and push through." (vague, no specific guidance)
        
        """
        
        let criticalRulesSection = trigger == .runStart ? "" : """
        CRITICAL RULES - INSIGHT SYNTHESIS REQUIRED:
        1. SYNTHESIZE PATTERNS: Connect data across sections to find root causes and implications.
        2. EXPLAIN WHY, not just WHAT: "Pace declining because HR drift rising - physiological cost increasing" not just "pace is slow".
        3. PREDICTIVE INSIGHTS: Connect current patterns to future outcomes ("if drift continues, you'll struggle at km 8").
        4. ROOT CAUSE FOCUS: Identify WHY things are happening, not just that they're happening.
        5. Use runner's name "\(runnerName)" if it feels natural.
        6. NO preamble. Just the coaching message with synthesized insights.
        
        """
        
        // For start-of-run, reorder sections: insights and aggregates come before main context
        if trigger == .runStart {
            return """
            \(insightsSection)
            
            \(aggregatesSection)
            
            \(triggerContext)
            
            NOW GENERATE THE COACHING MESSAGE:
            """
        } else {
            return """
            \(personalitySection)\(triggerContext)
            
            \(insightsSection)
            
            \(aggregatesSection)
            
            \(currentStatsSection)\(criticalRulesSection)\(examplesSection)NOW GENERATE THE COACHING MESSAGE:
            """
        }
    }
    
    private func buildRunSummaryPrompt(
        session: RunSession,
        stats: RunningStatsUpdate,
        personality: CoachPersonality,
        energy: CoachEnergy,
        mem0Insights: String,
        aggregates: SupabaseManager.RunAggregates?,
        runnerName: String,
        targetPace: Double
    ) -> String {
        let distanceKm = stats.distance / 1000.0
        let duration = session.duration
        let avgPaceStr = formatPace(session.pace)
        let targetPaceStr = formatPace(targetPace)
        let paceDeviation = session.pace > 0 ? ((session.pace - targetPace) / targetPace * 100) : 0
        
        let performanceAssessment: String
        if abs(paceDeviation) <= 5 {
            performanceAssessment = "EXCELLENT - Hit target pace"
        } else if paceDeviation < -10 {
            performanceAssessment = "STRONG - Faster than target"
        } else if paceDeviation > 10 {
            performanceAssessment = "CHALLENGING - Slower than target"
        } else {
            performanceAssessment = "GOOD - Close to target"
        }
        
        let improvement: String
        if let agg = aggregates {
            if session.pace < agg.avgPaceMinPerKm {
                improvement = "FASTER than your recent average!"
            } else if session.pace > agg.avgPaceMinPerKm {
                improvement = "Slower than recent avg. Room to build."
            } else {
                improvement = "Consistent with your recent pace."
            }
        } else {
            improvement = "First tracked run - great baseline!"
        }
        
        return """
        Personality: \(personality.rawValue.uppercased())
        Energy: \(energy.rawValue.uppercased())
        
        RUN COMPLETE:
        - Distance: \(String(format: "%.2f", distanceKm)) km
        - Duration: \(formatDuration(duration))
        - Average pace: \(avgPaceStr) min/km (Target: \(targetPaceStr))
        - Performance: \(performanceAssessment)
        - Trend: \(improvement)
        
        TASK: Give a 2-sentence summary (max 30 words):
        1. First sentence: Acknowledge the accomplishment with a specific stat.
        2. Second sentence: ONE specific thing to improve or focus on next time.
        
        RULES:
        - Use \(runnerName)'s name.
        - Be SPECIFIC (use actual numbers/stats).
        - NO generic praise. Tie feedback to data.
        - Match personality: Strategist = tactical next steps, Pacer = form/technique, Finisher = celebrate + challenge.
        
        GOOD EXAMPLES:
        - "\(runnerName), solid \(String(format: "%.1f", distanceKm))k at \(avgPaceStr) pace! Next time, focus on holding sub-\(targetPaceStr) in the final 2k."
        - "Nice work, \(runnerName)! \(String(format: "%.1f", distanceKm))k done. Work on cadence drills to shave 10 seconds off your pace."
        
        NOW GENERATE THE RUN SUMMARY:
        """
    }
    
    // MARK: - Mem0 Integration (Enhanced)
    /// Fetches Mem0 insights via Supabase edge function (shared with iOS app)
    /// Edge function uses MEM0_API_KEY from Supabase secrets
    private func fetchMem0InsightsWithName(for userId: String) async -> (insights: String, runnerName: String) {
        var runnerName = "Runner"
        var allInsights: [String] = []
        
        // Fetch runner profile (name) via Mem0Manager (uses mem0-proxy edge function)
        let profile = await Mem0Manager.shared.search(userId: userId, query: "runner name, user name, profile", limit: 5)
        if let nameMatch = profile.first(where: { $0.lowercased().contains("name") }) {
            // Extract name from text like "Runner's name is John" or "User name: Sarah"
            let components = nameMatch.components(separatedBy: CharacterSet.alphanumerics.inverted)
            if let extractedName = components.first(where: { $0.count > 2 && $0.count < 20 && !["name", "user", "runner", "is"].contains($0.lowercased()) }) {
                runnerName = extractedName
            }
        }
        
        // Fetch performance insights via Mem0Manager (uses mem0-proxy edge function)
        let perfInsights = await Mem0Manager.shared.search(userId: userId, query: "pace, performance, speed, endurance, fatigue, strengths, weaknesses", limit: 5)
        allInsights.append(contentsOf: perfInsights.prefix(3))
        
        // Fetch recent run summaries via Mem0Manager (uses mem0-proxy edge function)
        let runSummaries = await Mem0Manager.shared.search(userId: userId, query: "recent run, last run, run summary, completed", limit: 5)
        allInsights.append(contentsOf: runSummaries.prefix(2))
        
        let insightsText = allInsights.isEmpty ? "" : allInsights.joined(separator: "\n- ")
        return (insightsText, runnerName)
    }
    
    private func saveMem0Memory(userId: String, text: String, category: String = "ai_coaching_feedback", metadata: [String: String] = [:]) {
        // Use Mem0Manager for efficient batching and caching
        var enrichedMetadata = metadata
        enrichedMetadata["category"] = category
        Mem0Manager.shared.add(userId: userId, text: text, category: category, metadata: enrichedMetadata)
    }
    
    // MARK: - System Prompt Builder
    
    /// Builds the common system prompt for all coaching feedback (start, intervals, end)
    private func buildSystemPrompt(personality: CoachPersonality, language: SupportedLanguage) -> String {
        // Personality hint
        let personalityHint: String
        switch personality {
        case .strategist:
            personalityHint = "You are a race strategist focused on energy management, pacing strategy, and tactical decision-making."
        case .pacer:
            personalityHint = "You are a tactical running coach focused on biomechanics, form cues, cadence, and pace adjustments."
        case .finisher:
            personalityHint = "You are a motivational powerhouse focused on mental strength, pushing through fatigue, and finishing strong."
        }
        
        // Language instruction
        let languageInstruction: String
        if language != .english {
            languageInstruction = " Generate all feedback in \(language.displayName)."
        } else {
            languageInstruction = ""
        }
        
        let wordLimit: String
        switch currentTrigger {
        case .runStart, .interval: wordLimit = "~100 words"
        case .runEnd: wordLimit = "up to ~150 words"
        }
        
        return """
        You are an expert running coach with mastery of race strategy, biomechanics, physiology, and training adaptation. \(personalityHint)\(languageInstruction)
        
        Your expertise includes pacing dynamics, cardiovascular efficiency, fatigue control, biomechanical economy, mental resilience, and race execution. You synthesize multiple data streams and analyze past performances to spot trends, improvement, and recurring issues. Adapt guidance based on runner's performance data and evolving ability.
        
        Generate natural, conversational feedback: mid-run \(wordLimit); end-of-run debrief \(wordLimit). Be authentic, critical, insightful, and actionable. No emojis.
        """
    }
    
    // MARK: - OpenAI API
    private func requestAICoachingFeedback(_ prompt: String, energy: CoachEnergy, personality: CoachPersonality, language: SupportedLanguage, trigger: CoachingTrigger = .interval) async -> String {
        let proxyURL = "\(supabaseURL)/functions/v1/openai-proxy"
        guard !supabaseURL.isEmpty, !supabaseAnonKey.isEmpty else {
            // Fall back to direct OpenAI if proxy not configured
            if !openAIKey.isEmpty {
                return await requestAICoachingFeedbackDirect(prompt, energy: energy, personality: personality, language: language, trigger: trigger)
            }
            return "Great job, keep it up!"
        }
        
        do {
            let url = URL(string: proxyURL)!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(supabaseAnonKey)", forHTTPHeaderField: "Authorization")
            
            let maxTokens: Int
            let timeout: TimeInterval
            switch trigger {
            case .runStart, .interval:
                maxTokens = 150
                timeout = 12.0
            case .runEnd:
                maxTokens = 520
                timeout = 55.0
            }
            
            let systemPrompt = buildSystemPrompt(personality: personality, language: language)
            let body: [String: Any] = [
                "model": "gpt-4o-mini",
                "messages": [
                    ["role": "system", "content": systemPrompt],
                    ["role": "user", "content": prompt]
                ],
                "temperature": 0.8,
                "max_tokens": maxTokens,
                "presence_penalty": 0.3,
                "frequency_penalty": 0.3
            ]
            
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.timeoutInterval = timeout
            
            print("📤 [AICoach] Sending to Supabase proxy (prompt: \(prompt.count) chars, max_tokens: \(maxTokens), timeout: \(timeout)s)")
            let (data, response) = try await URLSession.shared.data(for: request)
            
            if let httpResponse = response as? HTTPURLResponse {
                print("📊 [AICoach] HTTP Status: \(httpResponse.statusCode)")
                if httpResponse.statusCode == 200 {
                    if let jsonResponse = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let choices = jsonResponse["choices"] as? [[String: Any]],
                       let firstChoice = choices.first,
                       let message = firstChoice["message"] as? [String: Any],
                       let content = message["content"] as? String {
                        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                        print("📝 [AICoach] Feedback: \(trimmed.count) chars, \(trimmed.split(separator: " ").count) words")
                        if trimmed.count < 50 {
                            print("⚠️ [AICoach] WARNING: Feedback seems truncated")
                        }
                        return trimmed
                    }
                } else {
                    if let errorData = String(data: data, encoding: .utf8) {
                        print("❌ [AICoach] Proxy error \(httpResponse.statusCode): \(errorData.prefix(500))")
                    }
                }
            }
        } catch {
            print("❌ [AICoach] Proxy API error: \(error.localizedDescription)")
        }
        
        // Retry via direct OpenAI if proxy fails
        if !openAIKey.isEmpty {
            print("🔄 [AICoach] Retrying via direct OpenAI…")
            return await requestAICoachingFeedbackDirect(prompt, energy: energy, personality: personality, language: language, trigger: trigger)
        }
        return "Stay strong and keep your pace!"
    }
    
    /// Fallback: direct OpenAI (used if Supabase proxy is down)
    private func requestAICoachingFeedbackDirect(_ prompt: String, energy: CoachEnergy, personality: CoachPersonality, language: SupportedLanguage, trigger: CoachingTrigger) async -> String {
        guard !openAIKey.isEmpty else { return "Keep going!" }
        do {
            let url = URL(string: "https://api.openai.com/v1/chat/completions")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(openAIKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            
            let maxTokens = trigger == .runEnd ? 520 : 150
            let systemPrompt = buildSystemPrompt(personality: personality, language: language)
            let body: [String: Any] = [
                "model": "gpt-4o-mini",
                "messages": [
                    ["role": "system", "content": systemPrompt],
                    ["role": "user", "content": prompt]
                ],
                "temperature": 0.8,
                "max_tokens": maxTokens,
                "presence_penalty": 0.3,
                "frequency_penalty": 0.3
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.timeoutInterval = trigger == .runEnd ? 55.0 : 12.0
            
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 200,
               let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let choices = json["choices"] as? [[String: Any]],
               let msg = choices.first?["message"] as? [String: Any],
               let content = msg["content"] as? String {
                return content.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch {
            print("❌ [AICoach] Direct OpenAI error: \(error.localizedDescription)")
        }
        return "Stay strong and keep your pace!"
    }
    
    // MARK: - Helpers
    private func deliverFeedback(_ feedback: String, voiceManager: VoiceManager, preferences: UserPreferences.Settings) async {
        let trimmed = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // CRITICAL: Map voiceAIModel to voiceOption for TTS
        // This ensures the user's selection in settings is used for scheduled coaching
        let voiceOption: VoiceOption = {
            switch preferences.voiceAIModel {
            case .openai:
                print("🎤 [AICoach] User selected OpenAI GPT-4 Mini - using GPT-4 TTS")
                return .gpt4 // Use OpenAI GPT-4 TTS
            case .apple:
                print("🎤 [AICoach] User selected Apple Samantha - using Apple TTS")
                return .samantha // Use Apple Samantha TTS
            }
        }()
        
        print("🎤 [AICoach] Voice mapping: voiceAIModel=\(preferences.voiceAIModel.rawValue) -> voiceOption=\(voiceOption.rawValue)")
        
        await MainActor.run {
            if let last = self.lastDeliveredFeedback,
               last.caseInsensitiveCompare(trimmed) == .orderedSame {
                self.currentFeedback = trimmed
                self.isCoaching = true
                if !voiceManager.isSpeaking {
                    print("🎤 [AICoach] Speaking duplicate feedback using \(voiceOption.rawValue)")
                    voiceManager.speak(trimmed, using: voiceOption, rate: 0.48)
                }
                return
            }
            
            self.lastDeliveredFeedback = trimmed
            self.currentFeedback = trimmed
            self.isCoaching = true
            print("🎤 [AICoach] Delivering NEW feedback using \(preferences.voiceAIModel.displayName) (mapped to \(voiceOption.rawValue))")
            print("📝 [AICoach] Feedback length: \(trimmed.count) characters, words: ~\(trimmed.split(separator: " ").count)")
            print("📝 [AICoach] Full feedback text: \(trimmed)")
            voiceManager.speak(trimmed, using: voiceOption, rate: 0.48)
        }
    }
    
    private func persistFeedback(userId: String, runSessionId: String?, feedback: String, stats: RunningStatsUpdate, preferences: UserPreferences.Settings) async {
        async let saveSupabase: Void = SupabaseManager().saveCoachingSession(
            userId: userId,
            runSessionId: runSessionId,
            text: feedback,
            personality: preferences.coachPersonality.rawValue,
            energy: preferences.coachEnergy.rawValue,
            stats: stats,
            durationSeconds: maxCoachingDuration
        )
        saveMem0Memory(userId: userId, text: feedback, category: "ai_coaching_feedback", metadata: ["source": "watch"])
        _ = await saveSupabase
    }
    
    private func currentUserIdFromDefaults() -> String? {
        if let data = UserDefaults.standard.data(forKey: "currentUser"),
           let user = try? JSONDecoder().decode(User.self, from: data) {
            return user.id
        }
        return nil
    }
    
    private func formatPace(_ paceMinutesPerKm: Double) -> String {
        let minutes = Int(paceMinutesPerKm)
        let seconds = Int((paceMinutesPerKm - Double(minutes)) * 60)
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    private func formatDuration(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

// MARK: - Voice AI timing guardrail notification
extension Notification.Name {
    /// Posted when the 60s coaching timer expires so the view can stop TTS (auto cut-off).
    static let coachingTimeLimitReached = Notification.Name("CoachingTimeLimitReached")
}
