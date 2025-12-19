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
    
    private var coachingTimer: Timer?
    private var feedbackTimer: Timer?
    private var feedbackClearTimer: Timer? // Timer to clear feedback text 2 minutes after TTS completes
    private let openAIKey: String
    private let maxCoachingDuration: TimeInterval = 40.0 // 40 seconds auto-terminate for voice TTS
    private let feedbackRetentionDuration: TimeInterval = 120.0 // 2 minutes - keep feedback text visible after TTS
    private var runnerName: String = "Runner"
    private var currentTrigger: CoachingTrigger = .interval
    private var lastDeliveredFeedback: String?
    
    // RAG Performance Analyzer for enhanced interval coaching
    private let ragAnalyzer = RAGPerformanceAnalyzer()
    
    override init() {
        if let config = ConfigLoader.loadConfig() {
            self.openAIKey = (config["OPENAI_API_KEY"] as? String) ?? ""
        } else {
            self.openAIKey = ""
        }
        super.init()
        print("🤖 [AICoach] Initialized - Mem0 uses Supabase edge function (mem0-proxy)")
    }
    
    // MARK: - Coaching Control
    
    /// Start-of-run coaching with personalization (uses cache)
    /// Also initializes RAG analyzer cache for preferences, language, Mem0 insights
    /// NOW INCLUDES RAG PERFORMANCE ANALYSIS + ADAPTIVE COACH RAG
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
        print("🏁 [AICoach] Start-of-run coaching triggered - RAG Analysis: ENABLED")
        
        Task {
            let userId = currentUserIdFromDefaults() ?? "watch_user"
            let (insights, name) = await fetchMem0InsightsWithName(for: userId)
            self.runnerName = name
            
            // Initialize RAG analyzer cache with preferences, language, Mem0 (never change during run)
            ragAnalyzer.initializeForRun(
                preferences: preferences,
                runnerName: name,
                userId: userId
            )
            print("📦 [AICoach] RAG cache initialized - Language: \(preferences.language.displayName), Target: \(preferences.targetDistance.displayName)")
            
            let aggregates = await SupabaseManager().fetchRunAggregates(userId: userId)
            let lastRun = await SupabaseManager().fetchLastRun(userId: userId)
            
            // SEQUENCE: Mem0 → Performance RAG (historic/big picture) → Coach Strategy RAG (race strategy)
            // Goal: Overall race strategy for 5K/10K/half/full/casual, not tactical microstrategy
            
            // Step 1: RAG-DRIVEN PERFORMANCE ANALYSIS (historic context)
            var ragContext: String? = nil
            var ragAnalysis: RAGPerformanceAnalyzer.RAGAnalysisResult? = nil
            let startTime = runStartTime ?? Date()
                print("📊 [AICoach] Step 1: Running RAG performance analysis for start-of-run (historic context)...")
                ragAnalysis = await ragAnalyzer.analyzePerformance(
                    stats: stats,
                    preferences: preferences,
                    healthManager: healthManager,
                    intervals: [], // Empty at start, but RAG can still analyze initial state
                    runStartTime: startTime,
                    userId: userId
                )
                ragContext = ragAnalysis!.llmContext
                print("📊 [AICoach] Performance RAG complete - Target Status: \(ragAnalysis!.targetStatus)")
            
            // Step 2: COACH STRATEGY RAG (race strategy from KB)
            var coachStrategy: CoachStrategyRAGManager.StrategyResponse.Strategy? = nil
            if let analysis = ragAnalysis {
                print("📚 [AICoach] Step 2: Calling Coach Strategy RAG for race strategy...")
                let elapsedTime = Date().timeIntervalSince(runStartTime ?? Date())
                let perfAnalysis = CoachStrategyRAGManager.shared.createPerformanceAnalysis(
                    from: analysis,
                    stats: stats,
                    preferences: preferences,
                    healthManager: healthManager,
                    intervals: [],
                    elapsedTime: elapsedTime
                )
                
                coachStrategy = await CoachStrategyRAGManager.shared.getStrategy(
                    performanceAnalysis: perfAnalysis,
                    personality: preferences.coachPersonality.rawValue.lowercased(),
                    energyLevel: preferences.coachEnergy.rawValue.lowercased(),
                    userId: userId,
                    runId: runSessionId,
                    goal: "race_strategy" // Goal: Overall race strategy, not tactical
                )
                
                if let strategy = coachStrategy {
                    print("📚 [AICoach] Coach Strategy RAG complete - Strategy: \(strategy.strategy_name)")
                } else {
                    print("⚠️ [AICoach] Coach Strategy RAG failed - continuing without KB strategy")
                }
            }
            
            let feedback = await generateCoachingFeedback(
                stats: stats,
                preferences: preferences,
                mem0Insights: insights,
                aggregates: aggregates,
                lastRun: lastRun,
                trigger: .runStart,
                runnerName: name,
                ragAnalysisContext: ragContext,
                ragAnalysis: ragAnalysis, // Pass full RAG analysis object
                coachStrategy: coachStrategy // Include Coach Strategy RAG
            )
            
            await deliverFeedback(feedback, voiceManager: voiceManager, preferences: preferences)
            await persistFeedback(userId: userId, runSessionId: runSessionId, feedback: feedback, stats: stats, preferences: preferences)
            
            // Start-of-run: Save initial strategy to Mem0
            let strategyLog = "Start strategy: \(feedback.prefix(50)). Target \(formatPace(preferences.targetPaceMinPerKm))."
            Mem0Manager.shared.add(userId: userId, text: strategyLog, category: "ai_coaching_feedback", metadata: ["type": "start_strategy"])
        }
        
        startCoachingTimer()
    }
    
    /// Interval coaching (every N km/minutes) - uses RAG-driven closed-loop performance analysis
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
        print("🎯 [AICoach] Interval coaching triggered - Train Mode: \(isTrainMode), RAG Analysis: ENABLED")
        
        Task {
            let userId = currentUserIdFromDefaults() ?? "watch_user"
            let (insights, name) = await fetchMem0InsightsWithName(for: userId)
            self.runnerName = name
            let aggregates = await SupabaseManager().fetchRunAggregates(userId: userId)
            
            // SEQUENCE: Performance RAG → Mem0 → Coach Strategy RAG (tactical/monitoring)
            // Goal: Tactical/adaptive microstrategy + monitor if user is following strategy
            
            // Step 1: RAG-DRIVEN PERFORMANCE ANALYSIS
            var ragContext: String? = nil
            var ragAnalysis: RAGPerformanceAnalyzer.RAGAnalysisResult? = nil
            if let startTime = runStartTime {
                print("📊 [AICoach] Step 1: Running RAG performance analysis...")
                ragAnalysis = await ragAnalyzer.analyzePerformance(
                    stats: stats,
                    preferences: preferences,
                    healthManager: healthManager,
                    intervals: intervals,
                    runStartTime: startTime,
                    userId: userId
                )
                ragContext = ragAnalysis!.llmContext
                print("📊 [AICoach] Performance RAG complete - Target Status: \(ragAnalysis!.targetStatus)")
            }
            
            // Step 2: COACH STRATEGY RAG (tactical/adaptive microstrategy + monitoring)
            var coachStrategy: CoachStrategyRAGManager.StrategyResponse.Strategy? = nil
            if let analysis = ragAnalysis, let startTime = runStartTime {
                print("📚 [AICoach] Step 2: Calling Coach Strategy RAG for tactical microstrategy...")
                let elapsedTime = Date().timeIntervalSince(startTime)
                let perfAnalysis = CoachStrategyRAGManager.shared.createPerformanceAnalysis(
                    from: analysis,
                    stats: stats,
                    preferences: preferences,
                    healthManager: healthManager,
                    intervals: intervals,
                    elapsedTime: elapsedTime
                )
                
                coachStrategy = await CoachStrategyRAGManager.shared.getStrategy(
                    performanceAnalysis: perfAnalysis,
                    personality: preferences.coachPersonality.rawValue.lowercased(),
                    energyLevel: preferences.coachEnergy.rawValue.lowercased(),
                    userId: userId,
                    runId: runSessionId,
                    goal: "tactical" // Goal: Tactical/adaptive microstrategy + monitoring
                )
                
                if let strategy = coachStrategy {
                    print("📚 [AICoach] Coach Strategy RAG complete - Strategy: \(strategy.strategy_name)")
                } else {
                    print("⚠️ [AICoach] Coach Strategy RAG failed - continuing without KB strategy")
                }
            }
            
            let feedback = await generateCoachingFeedback(
                stats: stats,
                preferences: preferences,
                mem0Insights: insights,
                aggregates: aggregates,
                lastRun: nil, // Not needed for intervals
                trigger: .interval,
                runnerName: name,
                isTrainMode: isTrainMode,
                shadowData: shadowData,
                ragAnalysisContext: ragContext,
                ragAnalysis: ragAnalysis, // Pass full RAG analysis object
                coachStrategy: coachStrategy // Include Coach Strategy RAG
            )
            
            await deliverFeedback(feedback, voiceManager: voiceManager, preferences: preferences)
            await persistFeedback(userId: userId, runSessionId: runSessionId, feedback: feedback, stats: stats, preferences: preferences)
        }
        
        startCoachingTimer()
    }
    
    /// End-of-run summary coaching - RAG-powered comprehensive analysis
    /// Uses full AI analysis: HealthKit, Supabase, RAG vectors, Mem0 insights
    /// Clears RAG analyzer cache after analysis
    func endOfRunCoaching(
        for stats: RunningStatsUpdate,
        session: RunSession,
        with preferences: UserPreferences.Settings,
        voiceManager: VoiceManager,
        healthManager: HealthManager? = nil
    ) {
        guard !isCoaching else { return }
        currentTrigger = .runEnd
        print("🏁 [AICoach] End-of-run RAG analysis triggered")
        
        Task {
            let userId = currentUserIdFromDefaults() ?? "watch_user"
            let (insights, name) = await fetchMem0InsightsWithName(for: userId)
            self.runnerName = name
            
            // SEQUENCE: Mem0 → Performance RAG → Coach Strategy RAG (learning/takeaways)
            // Goal: Learning/takeaways - how well runner followed coaching, lessons for next runs
            
            // Step 1: Generate RAG-powered end-of-run analysis
            let ragEndOfRunAnalysis = await ragAnalyzer.analyzeEndOfRun(
                session: session,
                stats: stats,
                preferences: preferences,
                healthManager: healthManager,
                userId: userId
            )
            
            // Step 2: COACH STRATEGY RAG (learning/takeaways)
            // Create a performance analysis from end-of-run data for strategy selection
            print("📚 [AICoach] Step 2: Calling Coach Strategy RAG for learning/takeaways...")
            var coachStrategy: CoachStrategyRAGManager.StrategyResponse.Strategy? = nil
            
            // Build performance analysis from end-of-run data
            var zonePercentages: [String: Double] = [:]
            if let hm = healthManager {
                for (zone, pct) in hm.zonePercentages {
                    zonePercentages[String(zone)] = pct
                }
            }
            
            let intervalPaces = session.intervals.map { $0.paceMinPerKm }
            let perfAnalysis = CoachStrategyRAGManager.PerformanceAnalysis(
                current_pace: session.pace,
                target_pace: preferences.targetPaceMinPerKm,
                current_distance: stats.distance,
                target_distance: preferences.targetDistanceMeters,
                elapsed_time: session.duration,
                current_hr: healthManager?.currentHeartRate,
                average_hr: healthManager?.averageHeartRate,
                max_hr: healthManager?.maxHeartRate,
                current_zone: healthManager?.currentZone,
                zone_percentages: zonePercentages,
                pace_trend: ragEndOfRunAnalysis.paceVariation.contains("positive") ? "declining" : 
                           ragEndOfRunAnalysis.paceVariation.contains("negative") ? "improving" : "stable",
                hr_trend: "stable",
                fatigue_level: "moderate",
                target_status: ragEndOfRunAnalysis.targetMet ? "on track" : "behind",
                performance_summary: ragEndOfRunAnalysis.intervalAnalysis,
                heart_zone_analysis: ragEndOfRunAnalysis.zoneDistribution,
                interval_trends: ragEndOfRunAnalysis.paceVariation,
                hr_variation_analysis: ragEndOfRunAnalysis.zonePaceCorrelation,
                injury_risk_signals: [],
                adaptive_microstrategy: ragEndOfRunAnalysis.overallRating,
                pace_deviation: abs(session.pace - preferences.targetPaceMinPerKm) / preferences.targetPaceMinPerKm * 100,
                completed_intervals: session.intervals.count,
                interval_paces: intervalPaces
            )
            
            coachStrategy = await CoachStrategyRAGManager.shared.getStrategy(
                performanceAnalysis: perfAnalysis,
                personality: preferences.coachPersonality.rawValue.lowercased(),
                energyLevel: preferences.coachEnergy.rawValue.lowercased(),
                userId: userId,
                runId: session.id,
                goal: "learning" // Goal: Learning/takeaways - how well followed coaching
            )
            
            if let strategy = coachStrategy {
                print("📚 [AICoach] Coach Strategy RAG complete - Strategy: \(strategy.strategy_name)")
            } else {
                print("⚠️ [AICoach] Coach Strategy RAG failed - continuing without KB strategy")
            }
            
            // Generate final AI coaching feedback using RAG analysis + Coach Strategy RAG
            let feedback = await generateEndOfRunFeedback(
                session: session,
                stats: stats,
                preferences: preferences,
                mem0Insights: insights,
                ragAnalysis: ragEndOfRunAnalysis,
                runnerName: name,
                coachStrategy: coachStrategy // Include Coach Strategy RAG
            )
            
            await deliverFeedback(feedback, voiceManager: voiceManager, preferences: preferences)
            await persistFeedback(userId: userId, runSessionId: session.id, feedback: feedback, stats: stats, preferences: preferences)
            
            // Store comprehensive end-of-run feedback to Mem0 for future runs
            let detailedSummary = """
            Run completed: \(String(format: "%.2f", stats.distance / 1000.0))km in \(formatDuration(session.duration)), pace \(formatPace(session.pace)).
            Target: \(preferences.targetDistance.displayName) at \(formatPace(preferences.targetPaceMinPerKm)).
            Result: \(ragEndOfRunAnalysis.targetAchievement).
            Feedback: \(feedback)
            """
            saveMem0Memory(userId: userId, text: detailedSummary, category: "running_performance", metadata: [
                "type": "end_of_run_analysis",
                "distance_km": String(format: "%.2f", stats.distance / 1000.0),
                "pace": formatPace(session.pace),
                "target_met": ragEndOfRunAnalysis.targetMet ? "yes" : "no"
            ])
            
            // Clear RAG analyzer cache (run is complete)
            ragAnalyzer.clearRunContext()
            print("🧹 [AICoach] RAG cache cleared after end-of-run analysis")
        }
        
        startCoachingTimer()
    }
    
    /// Generate end-of-run feedback using RAG analysis + Coach Strategy RAG
    private func generateEndOfRunFeedback(
        session: RunSession,
        stats: RunningStatsUpdate,
        preferences: UserPreferences.Settings,
        mem0Insights: String,
        ragAnalysis: RAGPerformanceAnalyzer.EndOfRunAnalysis,
        runnerName: String,
        coachStrategy: CoachStrategyRAGManager.StrategyResponse.Strategy? = nil
    ) async -> String {
        let prompt = buildEndOfRunPrompt(
            session: session,
            stats: stats,
            preferences: preferences,
            mem0Insights: mem0Insights,
            ragAnalysis: ragAnalysis,
            runnerName: runnerName,
            coachStrategy: coachStrategy
        )
        return await requestAICoachingFeedback(prompt, energy: preferences.coachEnergy, personality: preferences.coachPersonality, language: preferences.language, trigger: .runEnd)
    }
    
    /// Build comprehensive end-of-run LLM prompt with RAG analysis + Coach Strategy RAG (learning/takeaways)
    private func buildEndOfRunPrompt(
        session: RunSession,
        stats: RunningStatsUpdate,
        preferences: UserPreferences.Settings,
        mem0Insights: String,
        ragAnalysis: RAGPerformanceAnalyzer.EndOfRunAnalysis,
        runnerName: String,
        coachStrategy: CoachStrategyRAGManager.StrategyResponse.Strategy? = nil
    ) -> String {
        var coachStrategySection = ""
        if let strategy = coachStrategy {
            coachStrategySection = """
            
            📚 COACH STRATEGY FROM KNOWLEDGE BASE (Learning/Takeaways):
            Strategy: \(strategy.strategy_name)
            \(strategy.strategy_text)
            Situation: \(strategy.situation_summary)
            Reason: \(strategy.selection_reason)
            Expected Outcome: \(strategy.expected_outcome)
            
            IMPORTANT: This is a LEARNING/TAKEAWAYS strategy from the knowledge base.
            Focus: How well did the runner follow the coaching? What are the lessons learned for next runs?
            This is NOT tactical advice - it's reflection and improvement insights.
            """
        }
        
        return """
        This is END OF RUN feedback. Ignore closing HR or pace—what matters is outcome and historical meaning. Use the Performance Analyzer RAG embedding as the primary lens; it already synthesizes target completion, distance-vs-expected gaps, pacing shape, fatigue signals, and recurring historical patterns.
        
        IMPORTANT: Lower pace in min/km means faster running (e.g., 5:30 min/km is faster than 7:00 min/km). Synthesize this correctly when comparing paces.
        
        Your analytical task:
        
        Judge the result: ahead/on target/slightly behind/behind/way behind based on target completion
        
        Define the pacing narrative (negative/positive/consistent/fade) and what it implies
        
        If HR exists, interpret efficiency through zone distribution and drift
        
        Compare against history: repeat breakdown or meaningful improvement, referencing Mem0 where relevant
        
        Assess adherence to coaching strategy (did they follow prescribed pacing or execution?)
        
        Surface one specific win and one critical fix—data-backed, not a list
        
        Extract one key lesson that explains performance and give one next developmental priority (not punitive)
        
        ============================================================================
        USER PREFERENCES:
        - Language: \(preferences.language.displayName)
        - Coach Personality: \(preferences.coachPersonality.rawValue.uppercased())
        - Coach Energy: \(preferences.coachEnergy.rawValue.uppercased())
        ============================================================================
        
        \(ragAnalysis.llmContext)
        \(coachStrategySection)
        
        MEM0 PERSONALIZED INSIGHTS:
        \(mem0Insights.isEmpty ? "First tracked run!" : mem0Insights)
        
        Generate a CRITICAL, PERSONAL end-of-run analysis (max 70 words) following the analytical task and rules below.
        
        RULES - INSIGHT SYNTHESIS REQUIRED:
        
        Connect data across sections to explain why the outcome happened—not just what happened
        
        Identify one root cause pattern (pace errors, HR overshoot, form breakdown, execution discipline)
        
        Turn the pattern into a forward prediction ("If you start 5 sec/km fast, you'll fade again")
        
        Be honest but constructive, use numbers only to explain meaning
        
        Check adherence to coaching strategy from the KB
        
        Match personality, energy, and language settings
        
        Max 70 words, no scores or ratings
        
        NOW GENERATE THE END-OF-RUN FEEDBACK:
        """
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
                self.stopCoaching()
            }
        }
    }
    
    func stopCoaching() {
        print("⏹️ [AICoach] Stopping coaching (auto-terminate or manual)")
        isCoaching = false
        coachingTimer?.invalidate()
        coachingTimer = nil
        // Don't clear currentFeedback here - let it persist for 2 minutes after TTS completes
        // The feedbackClearTimer will handle clearing it
        coachingTimeRemaining = 0.0
        // Don't clear lastDeliveredFeedback - needed for duplicate detection
    }
    
    /// Schedule clearing of feedback text 2 minutes after TTS completes
    private func scheduleFeedbackClear() {
        // Cancel any existing clear timer
        feedbackClearTimer?.invalidate()
        
        // Schedule new timer to clear feedback after 2 minutes
        feedbackClearTimer = Timer.scheduledTimer(withTimeInterval: feedbackRetentionDuration, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            print("📝 [AICoach] Clearing feedback text after 2 minute retention period")
            self.currentFeedback = ""
        }
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
        coachStrategy: CoachStrategyRAGManager.StrategyResponse.Strategy? = nil
    ) async -> String {
        let prompt = buildCoachingPrompt(
            stats: stats,
            personality: preferences.coachPersonality,
            energy: preferences.coachEnergy,
            mem0Insights: mem0Insights,
            aggregates: aggregates,
            lastRun: lastRun,
            trigger: trigger,
            runnerName: runnerName,
            targetPace: preferences.targetPaceMinPerKm,
            targetDistance: preferences.targetDistance,
            isTrainMode: isTrainMode,
            shadowData: shadowData,
            ragAnalysisContext: ragAnalysisContext,
            ragAnalysis: ragAnalysis,
            coachStrategy: coachStrategy
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
        coachStrategy: CoachStrategyRAGManager.StrategyResponse.Strategy? = nil
    ) -> String {
        let distanceKm = stats.distance / 1000.0
        let currentPaceStr = formatPace(stats.pace)
        let targetPaceStr = formatPace(targetPace)
        let paceDeviation = stats.pace > 0 ? ((stats.pace - targetPace) / targetPace * 100) : 0
        
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
            let paceDiff = stats.pace - shadowPace
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
                
                triggerContext = """
                You're coaching \(runnerName) during a \(raceType) run.
                
                Run setup:
                - Phase: early
                - Target pace: \(targetPaceDisplay)/km
                
                [SKIPPED: Real-time observation - not included for start]
                [SKIPPED: Heart rate insight - not included for start]
                
                PERFORMANCE ANALYSIS - Historical performance patterns from Performance Analyzer RAG:
                
                HISTORICAL CONTEXT:
                - Previous race (most recent): \(lastRun != nil ? "\(String(format: "%.2f", lastRun!.distanceKm))km at \(formatPace(lastRun!.paceMinPerKm)) pace, duration \(formatDuration(lastRun!.durationSeconds))" : (hasRAGData ? "Historical data available from RAG analysis below" : "No previous run data available"))
                - Similar runs: \(similarRuns)
                - Historical outcomes: \(historicalOutcomes)
                - Performance patterns from previous runs: \(performancePatterns)
                - Adaptive strategy insights: \(adaptiveStrategy)
                
                \(raceStrategySection)
                
                Runner's historical context: \(mem0Context)
                
                This is the START of the run. You are not assessing current performance yet — focus on history and strategy.
                
                IMPORTANT: Lower pace in min/km means faster running (e.g., 5:30 min/km is faster than 7:00 min/km). Synthesize this correctly when comparing paces.
                
                Your task: Open with a connection to the runner's previous race and highlight one key lesson that matters today. Then shape race strategy around what history suggests: early-phase control, pacing risk, fatigue prevention, and mental setup for the opening kilometers.
                
                Provide a cohesive message that uses historic insights and strategy—not generic advice. Be critical and honest.
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
                    let estimatedDurationSeconds = distanceKm * stats.pace * 60.0
                    let durationStr = formatDuration(estimatedDurationSeconds)
                    
                    // Extract HR data from physiology analysis (if available)
                    let hrText = analysis.physiologyAnalysis.contains("bpm") || analysis.physiologyAnalysis.contains("HR") ? "Available in analysis below" : "No heart rate data available for this run."
                    
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
                    
                    // Extract from coach perspective and quality sections
                    let effortCostSignal = analysis.coachPerspective.contains("effort") ? analysis.coachPerspective : "See Coach Perspective below"
                    let hiddenFatigueFlag = analysis.coachPerspective.contains("fatigue") || analysis.coachPerspective.contains("drift") ? "Detected" : "None detected"
                    let fatigueLevel = analysis.qualityAndRisks.contains("fatigue") ? analysis.qualityAndRisks : "Moderate"
                    let sustainabilityStatus = analysis.coachPerspective.contains("sustainable") ? analysis.coachPerspective : "See Coach Perspective below"
                    
                    // Coach perspective fields
                    let runPhaseDesc = runPhase
                    let effortTiming = analysis.coachPerspective
                    let finishImpact = analysis.coachPerspective.contains("finish") ? analysis.coachPerspective : "See Coach Perspective below"
                    let overallJudgment = analysis.coachPerspective
                    
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
                    
                    triggerContext = """
                    This is INTERVAL feedback during mid of the run. Lead with TARGET AWARE judgment using distance-vs-expected to classify ahead/on/behind and set urgency. Interpret what's working, what's slipping, and what needs immediate correction. Check whether the runner is following the assigned strategy or drifting off-plan, and adjust accordingly.
                    
                    IMPORTANT: Lower pace in min/km means faster running (e.g., 5:30 min/km is faster than 7:00 min/km). Synthesize this correctly when comparing paces.
                    
                    Help the runner think like an expert by prompting internal questions:
                    - "Am I on target or borrowing from later?"
                    - "Is HR rising faster than pace justifies?"
                    - "Do I protect the finish or push now?"
                    - "Does history say I fade here?"
                    
                    Current run status:
                    - Distance: \(String(format: "%.2f", distanceKm))km (target: \(targetPaceStr)/km)
                    - Current pace: \(currentPaceStr)/km
                    - Duration: \(durationStr)
                    - Heart rate: \(hrText)
                    - Phase: \(runPhase) (\(phaseDescription))
                    
                    PERFORMANCE ANALYSIS - Synthesize these insights intelligently:
                    
                    CURRENT STATE:
                    - Status: \(statusLabel) (pace vs target: \(paceVsTarget))
                    - Distance: \(distanceProgressVsTarget) of target, \(distanceCoveredVsExpected) vs expected
                    - Pace trend: \(paceTrend)
                    - Heart rate: \(hrAndCurrentZone), trend/drift: \(hrTrendAndDrift)
                    - Zone distribution: \(heartZoneDistribution)
                    - Consistency: \(consistency)
                    
                    EFFORT & SUSTAINABILITY:
                    - Effort cost signal: \(effortCostSignal)
                    - Hidden fatigue: \(hiddenFatigueFlag)
                    - Fatigue level: \(fatigueLevel)
                    - Sustainability status: \(sustainabilityStatus)
                    
                    HISTORICAL CONTEXT (Previous intervals in THIS run):
                    - Interval trends: \(paceTrend) (comparing to earlier intervals in this run)
                    - Similar runs (for reference): \(similarRunContext)
                    - Historical outcomes (from past runs): \(typicalHistoricalOutcomes)
                    - Running quality: \(runningQualityScore)
                    - Injury risk: \(injuryRiskFlag)
                    - Next action (500m-1km): \(nextAction500m1km)
                    - Recommendation: \(conciseRecommendation)
                    
                    \(raceStrategySection)
                    
                    \(hrText.contains("Available") ? "Additional HR insight: \(hrAndCurrentZone). Consider this alongside the HR analysis in the performance data. " : "")
                    Generate **70 words** of concise, actionable interpretation using performance analysis, target-aware judgment, and embedding-retrieved strategy — not generic encouragement.
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
        
        // Examples section removed for interval feedback - cleaner prompt
        let examplesSection = ""
        
        let criticalRulesSection = trigger == .runStart ? "" : """
        CRITICAL RULES - INSIGHT SYNTHESIS REQUIRED:
        1. SYNTHESIZE PATTERNS: Connect data across sections to find root causes and implications.
        2. EXPLAIN WHY, not just WHAT: "Pace declining because HR drift rising - physiological cost increasing" not just "pace is slow".
        3. PREDICTIVE INSIGHTS: Connect current patterns to future outcomes ("if drift continues, you'll struggle at km 8").
        4. ROOT CAUSE FOCUS: Identify WHY things are happening, not just that they're happening.
        5. RECOGNIZE STRONG OUTPERFORMANCE: If the runner is ahead in distance vs expected (positive net distance at elapsed time) AND current pace is faster than target pace (e.g., 4:00 min/km vs 7:00 min/km target) AND heart rate zones are sustainable (appropriate, not excessive) AND there is no significant heart rate drift, acknowledge they're performing well. Allow them to continue this strong pace, but keep them aware to monitor and watch out for signs of fatigue or unsustainable effort. Don't unnecessarily suggest slowing down when performance is strong and sustainable.
        6. RECOGNIZE TARGET DISTANCE ACHIEVED: If the runner has already covered the total target distance and continues running further, recognize this as outperformance. Acknowledge they've exceeded their target and are continuing strong. Provide encouragement for the extra distance while monitoring for sustainable effort.
        7. Use runner's name "\(runnerName)" if it feels natural.
        8. NO preamble. Just the coaching message with synthesized insights.
        
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
        
        return """
        You are an expert running coach with mastery of race strategy, biomechanics, physiology, and training adaptation. \(personalityHint)\(languageInstruction)
        
        Your expertise includes pacing dynamics, cardiovascular efficiency, fatigue control, biomechanical economy, mental resilience, and race execution. You synthesize multiple data streams and analyze past performances to spot trends, improvement, and recurring issues. Adapt guidance based on runner's performance data and evolving ability.
        
        Generate natural, conversational feedback (70 words max), authentic, critical & insightful, and actionable. No emojis.
        """
    }
    
    // MARK: - OpenAI API
    private func requestAICoachingFeedback(_ prompt: String, energy: CoachEnergy, personality: CoachPersonality, language: SupportedLanguage, trigger: CoachingTrigger = .interval) async -> String {
        guard !openAIKey.isEmpty else {
            return "Great job, keep it up!"
        }
        
        do {
            let url = URL(string: "https://api.openai.com/v1/chat/completions")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(openAIKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            
            let temperature: Double = energy == .high ? 0.9 : energy == .medium ? 0.7 : 0.5
            let maxTokens = 140 // 140 tokens (~70 words) for all coaching feedback
            let systemPrompt = buildSystemPrompt(personality: personality, language: language)
            let body: [String: Any] = [
                "model": "gpt-4o-mini",
                "messages": [
                    [
                        "role": "system",
                        "content": systemPrompt
                    ],
                    [
                        "role": "user",
                        "content": prompt
                    ]
                ],
                "temperature": temperature,
                "max_tokens": maxTokens
            ]
            
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.timeoutInterval = 30.0 // 30 second timeout for older devices
            
            print("📤 [AICoach] Sending request to OpenAI (prompt length: \(prompt.count) chars, max_tokens: \(maxTokens))")
            let (data, response) = try await URLSession.shared.data(for: request)
            print("📥 [AICoach] Received response (data size: \(data.count) bytes)")
            
            if let httpResponse = response as? HTTPURLResponse {
                print("📊 [AICoach] HTTP Status: \(httpResponse.statusCode)")
                if httpResponse.statusCode == 200 {
                    if let jsonResponse = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let choices = jsonResponse["choices"] as? [[String: Any]],
                       let firstChoice = choices.first,
                       let message = firstChoice["message"] as? [String: Any],
                       let content = message["content"] as? String {
                        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                        print("📝 [AICoach] Full feedback received: \(trimmed.count) characters, \(trimmed.split(separator: " ").count) words")
                        print("📝 [AICoach] Complete feedback: \"\(trimmed)\"")
                        if trimmed.count < 50 {
                            print("⚠️ [AICoach] WARNING: Feedback seems truncated (only \(trimmed.count) chars)")
                        }
                        return trimmed
                    } else {
                        print("❌ [AICoach] Failed to parse response JSON")
                        if let jsonString = String(data: data, encoding: .utf8) {
                            print("📄 [AICoach] Raw response: \(jsonString.prefix(500))")
                        }
                    }
                } else {
                    print("❌ [AICoach] HTTP Error: \(httpResponse.statusCode)")
                    if let errorData = String(data: data, encoding: .utf8) {
                        print("📄 [AICoach] Error response: \(errorData.prefix(500))")
                    }
                }
            }
        } catch {
            print("❌ [AICoach] OpenAI API error: \(error)")
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
            // Cancel any existing feedback clear timer (new feedback is arriving)
            self.feedbackClearTimer?.invalidate()
            self.feedbackClearTimer = nil
            
            // Set up callback to schedule feedback clear 2 minutes after TTS completes
            voiceManager.onSpeechFinished = { [weak self] in
                guard let self = self else { return }
                print("📝 [AICoach] TTS completed - scheduling feedback text to clear in 2 minutes")
                self.scheduleFeedbackClear()
            }
            
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


