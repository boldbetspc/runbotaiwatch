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
    private let openAIKey: String
    private let mem0APIKey: String
    private let mem0BaseURL: String
    private let maxCoachingDuration: TimeInterval = 60.0 // 60 seconds auto-terminate for voice TTS
    private var runnerName: String = "Runner"
    private var currentTrigger: CoachingTrigger = .interval
    private var lastDeliveredFeedback: String?
    
    // RAG Performance Analyzer for enhanced interval coaching
    private let ragAnalyzer = RAGPerformanceAnalyzer()
    
    override init() {
        if let config = ConfigLoader.loadConfig() {
            self.openAIKey = (config["OPENAI_API_KEY"] as? String) ?? ""
            self.mem0APIKey = (config["MEM0_API_KEY"] as? String) ?? ""
            self.mem0BaseURL = (config["MEM0_BASE_URL"] as? String)
                ?? (config["MEM0_PROXY_URL"] as? String)
                ?? "https://api.mem0.ai/v1"
        } else {
            self.openAIKey = ""
            self.mem0APIKey = ""
            self.mem0BaseURL = "https://api.mem0.ai/v1"
        }
        super.init()
    }
    
    // MARK: - Coaching Control
    
    /// Start-of-run coaching with personalization (uses cache)
    /// Also initializes RAG analyzer cache for preferences, language, Mem0 insights
    func startOfRunCoaching(
        for stats: RunningStatsUpdate,
        with preferences: UserPreferences.Settings,
        voiceManager: VoiceManager,
        runSessionId: String?,
        runnerName: String = "Runner"
    ) {
        guard !isCoaching else { return }
        currentTrigger = .runStart
        print("🏁 [AICoach] Start-of-run coaching triggered")
        
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
            
            let feedback = await generateCoachingFeedback(
                stats: stats,
                preferences: preferences,
                mem0Insights: insights,
                aggregates: aggregates,
                trigger: .runStart,
                runnerName: name
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
            
            // RAG-DRIVEN PERFORMANCE ANALYSIS
            var ragContext: String? = nil
            if let startTime = runStartTime {
                print("📊 [AICoach] Running RAG performance analysis...")
                let ragAnalysis = await ragAnalyzer.analyzePerformance(
                    stats: stats,
                    preferences: preferences,
                    healthManager: healthManager,
                    intervals: intervals,
                    runStartTime: startTime,
                    userId: userId
                )
                ragContext = ragAnalysis.llmContext
                print("📊 [AICoach] RAG analysis complete - Target Status: \(ragAnalysis.targetStatus)")
            }
            
            let feedback = await generateCoachingFeedback(
                stats: stats,
                preferences: preferences,
                mem0Insights: insights,
                aggregates: aggregates,
                trigger: .interval,
                runnerName: name,
                isTrainMode: isTrainMode,
                shadowData: shadowData,
                ragAnalysisContext: ragContext
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
            
            // Generate RAG-powered end-of-run analysis
            let ragEndOfRunAnalysis = await ragAnalyzer.analyzeEndOfRun(
                session: session,
                stats: stats,
                preferences: preferences,
                healthManager: healthManager,
                userId: userId
            )
            
            // Generate final AI coaching feedback using RAG analysis
            let feedback = await generateEndOfRunFeedback(
                session: session,
                stats: stats,
                preferences: preferences,
                mem0Insights: insights,
                ragAnalysis: ragEndOfRunAnalysis,
                runnerName: name
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
    
    /// Generate end-of-run feedback using RAG analysis
    private func generateEndOfRunFeedback(
        session: RunSession,
        stats: RunningStatsUpdate,
        preferences: UserPreferences.Settings,
        mem0Insights: String,
        ragAnalysis: RAGPerformanceAnalyzer.EndOfRunAnalysis,
        runnerName: String
    ) async -> String {
        let prompt = buildEndOfRunPrompt(
            session: session,
            stats: stats,
            preferences: preferences,
            mem0Insights: mem0Insights,
            ragAnalysis: ragAnalysis,
            runnerName: runnerName
        )
        return await requestAICoachingFeedback(prompt, energy: preferences.coachEnergy)
    }
    
    /// Build comprehensive end-of-run LLM prompt with RAG analysis
    private func buildEndOfRunPrompt(
        session: RunSession,
        stats: RunningStatsUpdate,
        preferences: UserPreferences.Settings,
        mem0Insights: String,
        ragAnalysis: RAGPerformanceAnalyzer.EndOfRunAnalysis,
        runnerName: String
    ) -> String {
        return """
        You are an ELITE RUNNING COACH giving \(runnerName) their END-OF-RUN ANALYSIS.
        
        ============================================================================
        USER PREFERENCES:
        - Language: \(preferences.language.displayName)
        - Coach Personality: \(preferences.coachPersonality.rawValue.uppercased())
        - Coach Energy: \(preferences.coachEnergy.rawValue.uppercased())
        ============================================================================
        
        \(ragAnalysis.llmContext)
        
        MEM0 PERSONALIZED INSIGHTS:
        \(mem0Insights.isEmpty ? "First tracked run!" : mem0Insights)
        
        ============================================================================
        COACHING TASK
        ============================================================================
        
        Generate a CRITICAL, PERSONAL end-of-run analysis (max 60 words):
        
        1. TARGET ASSESSMENT: Did they hit \(preferences.targetDistance.displayName) target? Be specific.
        2. WHAT WENT WELL: One specific thing with data (e.g., "Zone 2 efficiency at 65% was excellent")
        3. WHAT NEEDS WORK: One critical improvement area with facts (e.g., "Pace dropped 45s in final km")
        4. PERSONAL TOUCH: Reference their history from Mem0 if available
        
        RULES:
        - Be CRITICAL but constructive - real coaches don't sugarcoat
        - Use SPECIFIC NUMBERS from the analysis (pace, zones, intervals)
        - Match personality: \(preferences.coachPersonality.rawValue)
        - Match energy: \(preferences.coachEnergy.rawValue)
        \(preferences.language != .english ? "- Generate in \(preferences.language.displayName) language" : "")
        - Maximum 60 words
        - DO NOT mention any scores or ratings (no "Score: 75" or "Rating: Good")
        
        EXAMPLE (good):
        "\(runnerName), \(preferences.targetDistance.displayName) done in \(formatDuration(session.duration)) - \(ragAnalysis.targetMet ? "target hit" : "missed by " + ragAnalysis.targetDeviation)! Your Zone 3 efficiency was solid at 48%. But those final 2km? Pace dropped 35 seconds - that's where you lost time. Next run: focus on even splits. Strong effort overall."
        
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
        currentFeedback = ""
        coachingTimeRemaining = 0.0
        lastDeliveredFeedback = nil
    }
    
    // MARK: - AI Feedback Generation
    
    private func generateCoachingFeedback(
        stats: RunningStatsUpdate,
        preferences: UserPreferences.Settings,
        mem0Insights: String,
        aggregates: SupabaseManager.RunAggregates?,
        trigger: CoachingTrigger,
        runnerName: String,
        isTrainMode: Bool = false,
        shadowData: ShadowRunData? = nil,
        ragAnalysisContext: String? = nil
    ) async -> String {
        let prompt = buildCoachingPrompt(
            stats: stats,
            personality: preferences.coachPersonality,
            energy: preferences.coachEnergy,
            mem0Insights: mem0Insights,
            aggregates: aggregates,
            trigger: trigger,
            runnerName: runnerName,
            targetPace: preferences.targetPaceMinPerKm,
            isTrainMode: isTrainMode,
            shadowData: shadowData,
            ragAnalysisContext: ragAnalysisContext
        )
        return await requestAICoachingFeedback(prompt, energy: preferences.coachEnergy)
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
        return await requestAICoachingFeedback(prompt, energy: preferences.coachEnergy)
    }
    
    private func buildCoachingPrompt(
        stats: RunningStatsUpdate,
        personality: CoachPersonality,
        energy: CoachEnergy,
        mem0Insights: String,
        aggregates: SupabaseManager.RunAggregates?,
        trigger: CoachingTrigger,
        runnerName: String,
        targetPace: Double,
        isTrainMode: Bool = false,
        shadowData: ShadowRunData? = nil,
        ragAnalysisContext: String? = nil
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
                // Enhanced start-of-run: Personalized with name, last run stats, target awareness, heart zone advice, detailed strategy
                let lastRunInfo: String
                if let agg = aggregates, agg.totalRuns > 0 {
                    lastRunInfo = """
                    Last run stats:
                    - Distance: \(String(format: "%.2f", agg.avgDistanceKm)) km (avg)
                    - Pace: \(formatPace(agg.avgPaceMinPerKm)) (avg), Best: \(formatPace(agg.bestPaceMinPerKm))
                    """
                } else {
                    lastRunInfo = "This is your first tracked run - let's set a great baseline!"
                }
                
                triggerContext = """
                THIS IS THE START OF THE RUN. Give personalized, motivating, strategic feedback.
                
                PERSONALIZATION REQUIREMENTS:
                1. Use runner's name "\(runnerName)" naturally
                2. Reference last run performance: \(lastRunInfo)
                3. Acknowledge what they did well in previous runs (from Mem0 insights)
                4. Be target-aware: Target pace is \(targetPaceStr) min/km
                5. Give heart zone advice: "Start in Zone 2-3, build gradually"
                6. Provide detailed race strategy: "First km easy, then settle into target pace"
                7. Motivate: "You've been improving, let's build on that momentum!"
                
                STRUCTURE (max 60 words):
                - Greeting with name
                - Brief reference to last run/what they did well
                - Target pace reminder
                - Heart zone guidance
                - Race strategy (pacing plan)
                - Motivation to finish strong
                
                Example: "Hey \(runnerName)! Your last run was solid at \(formatPace(aggregates?.avgPaceMinPerKm ?? targetPace)) pace. Today, target \(targetPaceStr). Start in Zone 2, build to Zone 3 by km 2. First km easy, then lock in. You've got this!"
                """
            case .interval:
                // Enhanced interval coaching with RAG analysis if available
                if let ragContext = ragAnalysisContext {
                    triggerContext = """
                    THIS IS MID-RUN COACHING with RAG-DRIVEN PERFORMANCE ANALYSIS.
                    
                    \(ragContext)
                    
                    COACHING PRIORITY:
                    1. Use the RAG analysis above to understand the runner's EXACT situation
                    2. Reference specific data points (zones, trends, target status)
                    3. Give coaching based on the ADAPTIVE MICROSTRATEGY recommendation
                    4. If injury risk signals exist, prioritize safety
                    5. Be specific about pace adjustments needed (e.g., "drop 10 sec/km")
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
        
        return """
        You are an ELITE RUNNING COACH speaking to \(runnerName) during their run.
        
        \(personalityInstructions)
        
        \(energyInstructions)
        
        \(triggerContext)
        
        \(insightsSection)
        
        \(aggregatesSection)
        
        CURRENT RUN STATS:
        - Distance: \(String(format: "%.2f", distanceKm)) km
        - Current pace: \(currentPaceStr) min/km (Target: \(targetPaceStr))
        - Pace status: \(paceDeviation > 10 ? "TOO SLOW" : paceDeviation < -10 ? "TOO FAST" : "ON TARGET")
        - Calories: \(String(format: "%.0f", stats.calories))
        
        CRITICAL RULES:
        1. Maximum 60 words - be concise but insightful.
        2. Be SPECIFIC and ACTIONABLE. Reference actual data from analysis.
        3. Use runner's name "\(runnerName)" if it feels natural.
        4. Match the personality mode precisely.
        5. NO preamble. Just the coaching message.
        6. If RAG analysis is provided, use its insights (target status, zone guidance, injury risks).
        
        GOOD EXAMPLES (RAG-enhanced):
        - "\(runnerName), you're 8% behind target but HR is stable in Zone 3. Pick up cadence to 180 - you have headroom. Next km: push to Zone 4 briefly."
        - "Your interval trend shows declining pace. Zone 2 efficiency is dropping. Quick form check: shoulders down, arms 90°. Shorter, quicker steps."
        - "Zone 5 for 15% of run - that's high strain. Ease to Zone 3 for next 500m. You're building fatigue - smart recovery now means strong finish."
        
        BAD EXAMPLES (avoid these):
        - "Great job, keep going!" (no action, ignores data)
        - "You're almost there!" (not actionable)
        - "Stay strong and push through." (vague, no specific guidance)
        
        NOW GENERATE THE COACHING MESSAGE:
        """
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
        You are an ELITE RUNNING COACH giving \(runnerName) their END-OF-RUN SUMMARY.
        
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
    private func fetchMem0InsightsWithName(for userId: String) async -> (insights: String, runnerName: String) {
        guard !mem0APIKey.isEmpty else { return ("", "Runner") }
        
        var runnerName = "Runner"
        var allInsights: [String] = []
        
        // Fetch runner profile (name)
        if let profile = await fetchMem0Search(userId: userId, query: "runner name, user name, profile") {
            if let nameMatch = profile.first(where: { $0.lowercased().contains("name") }) {
                // Extract name from text like "Runner's name is John" or "User name: Sarah"
                let components = nameMatch.components(separatedBy: CharacterSet.alphanumerics.inverted)
                if let extractedName = components.first(where: { $0.count > 2 && $0.count < 20 && !["name", "user", "runner", "is"].contains($0.lowercased()) }) {
                    runnerName = extractedName
                }
            }
        }
        
        // Fetch performance insights
        if let perfInsights = await fetchMem0Search(userId: userId, query: "pace, performance, speed, endurance, fatigue, strengths, weaknesses") {
            allInsights.append(contentsOf: perfInsights.prefix(3))
        }
        
        // Fetch recent run summaries
        if let runSummaries = await fetchMem0Search(userId: userId, query: "recent run, last run, run summary, completed") {
            allInsights.append(contentsOf: runSummaries.prefix(2))
        }
        
        let insightsText = allInsights.isEmpty ? "" : allInsights.joined(separator: "\n- ")
        return (insightsText, runnerName)
    }
    
    private func fetchMem0Search(userId: String, query: String) async -> [String]? {
        do {
            let url = URL(string: "\(mem0BaseURL)/memories/search")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(mem0APIKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let body: [String: Any] = ["query": query, "user_id": userId, "limit": 5]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 200,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let results = json["results"] as? [[String: Any]] {
                    return results.compactMap { $0["memory"] as? String }
                }
            }
        } catch {
            print("❌ [AICoach] Mem0 search failed: \(error)")
        }
        return nil
    }
    
    private func saveMem0Memory(userId: String, text: String, category: String = "ai_coaching_feedback", metadata: [String: String] = [:]) {
        // Use Mem0Manager for efficient batching and caching
        var enrichedMetadata = metadata
        enrichedMetadata["category"] = category
        Mem0Manager.shared.add(userId: userId, text: text, category: category, metadata: enrichedMetadata)
    }
    
    // MARK: - OpenAI API
    private func requestAICoachingFeedback(_ prompt: String, energy: CoachEnergy) async -> String {
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
            let body: [String: Any] = [
                "model": "gpt-4o-mini",
                "messages": [
                    [
                        "role": "system",
                        "content": "You are an elite running coach. Give SHORT, actionable coaching. NO fluff. Maximum 60 words."
                    ],
                    [
                        "role": "user",
                        "content": prompt
                    ]
                ],
                "temperature": temperature,
                "max_tokens": 120 // ~60 words
            ]
            
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)
            
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
               let jsonResponse = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let choices = jsonResponse["choices"] as? [[String: Any]],
               let firstChoice = choices.first,
               let message = firstChoice["message"] as? [String: Any],
               let content = message["content"] as? String {
                return content.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch {
            print("❌ [AICoach] OpenAI API error: \(error)")
        }
        
        return "Stay strong and keep your pace!"
    }
    
    // MARK: - Helpers
    private func deliverFeedback(_ feedback: String, voiceManager: VoiceManager, preferences: UserPreferences.Settings) async {
        let trimmed = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        await MainActor.run {
            if let last = self.lastDeliveredFeedback,
               last.caseInsensitiveCompare(trimmed) == .orderedSame {
                self.currentFeedback = trimmed
                self.isCoaching = true
                if !voiceManager.isSpeaking {
                    voiceManager.speak(trimmed, using: preferences.voiceOption, rate: 0.48)
                }
                return
            }
            
            self.lastDeliveredFeedback = trimmed
            self.currentFeedback = trimmed
            self.isCoaching = true
            voiceManager.speak(trimmed, using: preferences.voiceOption, rate: 0.48)
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


