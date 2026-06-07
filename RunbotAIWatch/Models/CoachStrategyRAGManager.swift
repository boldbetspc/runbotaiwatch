import Foundation

/// Coach Strategy RAG Manager
/// Calls the coach-rag-strategy edge function to get adaptive coaching strategies from KB
/// Uses Graph RAG for enhanced strategy retrieval via graph-based embeddings in coaching_strategies_kb
/// Different goals for different coaching moments:
/// - Start: Race strategy (overall plan)
/// - Intervals: Tactical/adaptive microstrategy + monitoring
/// - End: Learning/takeaways
class CoachStrategyRAGManager {
    static let shared = CoachStrategyRAGManager()
    
    private let supabaseURL: String
    private let supabaseKey: String
    
    private init() {
        if let config = ConfigLoader.loadConfig() {
            self.supabaseURL = (config["SUPABASE_URL"] as? String) ?? ""
            self.supabaseKey = (config["SUPABASE_ANON_KEY"] as? String) ?? ""
        } else {
            self.supabaseURL = ""
            self.supabaseKey = ""
        }
    }
    
    // MARK: - Strategy Request Models
    
    struct PerformanceAnalysis: Codable {
        let current_pace: Double
        let target_pace: Double
        let current_distance: Double
        let target_distance: Double
        let elapsed_time: Double
        let current_hr: Double?
        let average_hr: Double?
        let max_hr: Double?
        let current_zone: Int?
        let zone_percentages: [String: Double] // Zone number as string key
        let pace_trend: String
        let hr_trend: String
        let fatigue_level: String
        let target_status: String
        let performance_summary: String
        let heart_zone_analysis: String
        let interval_trends: String
        let hr_variation_analysis: String
        let injury_risk_signals: [String]
        let adaptive_microstrategy: String
        let pace_deviation: Double
        let completed_intervals: Int
        let interval_paces: [Double]
    }
    
    struct StrategyRequest: Codable {
        let performance_analysis: PerformanceAnalysis
        let personality: String // 'strategist' | 'pacer' | 'finisher'
        let energy_level: String // 'low' | 'medium' | 'high'
        let user_id: String
        let run_id: String?
        // Coach Logic routing (optional, omitted when nil): the edge function pre-filters the
        // KB by cluster + phase and uses intent_label as selector context.
        let cluster: String?       // strategy cluster routed by the on-watch diagnosis engine
        let phase: String?         // start | early | mid | late | finish
        let intent_label: String?  // short human-readable coaching intent
        let feedback_type: String? // start | interval | end
        let recent_strategies: [String]?
        let runner_strategy_fx: String?
        let previous_strategy: String?
    }
    
    struct StrategyResponse: Codable {
        let success: Bool
        let strategy: Strategy?
        let error: String?
        
        struct Strategy: Codable {
            let strategy_text: String
            let strategy_name: String
            let situation_summary: String
            let selection_reason: String
            let confidence_score: Double
            let expected_outcome: String
            let strategy_id: String
        }
    }
    
    // MARK: - Get Strategy from KB
    
    /// Get coaching strategy from KB based on performance analysis
    /// - Parameters:
    ///   - performanceAnalysis: Current performance metrics
    ///   - personality: Coach personality (strategist/pacer/finisher)
    ///   - energyLevel: Coach energy (low/medium/high)
    ///   - userId: User ID
    ///   - runId: Optional run ID
    ///   - goal: Strategy goal - 'race_strategy' (start), 'tactical' (intervals), 'learning' (end)
    /// - Returns: Selected strategy from KB or nil if failed
    func getStrategy(
        performanceAnalysis: PerformanceAnalysis,
        personality: String,
        energyLevel: String,
        userId: String,
        runId: String? = nil,
        goal: String,
        feedbackType: String = "interval",
        recentStrategies: [String] = [],
        runnerStrategyFx: String? = nil,
        previousStrategy: String? = nil
    ) async -> StrategyResponse.Strategy? {
        guard !supabaseURL.isEmpty else {
            print("❌ [CoachStrategyRAG] Supabase URL not configured")
            return nil
        }
        
        let edgeFunctionURL = "\(supabaseURL)/functions/v1/coach-rag-strategy"
        guard let url = URL(string: edgeFunctionURL) else {
            print("❌ [CoachStrategyRAG] Invalid edge function URL")
            return nil
        }
        
        print("📚 [CoachStrategyRAG] ========== REQUESTING COACH STRATEGY (Graph RAG) ==========")
        print("📚 [CoachStrategyRAG] Goal: \(goal)")
        print("📚 [CoachStrategyRAG] Personality: \(personality)")
        print("📚 [CoachStrategyRAG] Energy: \(energyLevel)")
        print("📚 [CoachStrategyRAG] URL: \(url)")
        
        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(supabaseKey, forHTTPHeaderField: "apikey")
            request.setValue(getAuthToken(), forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 15
            
            // Note: Edge function uses Graph RAG to retrieve strategies from coaching_strategies_kb
            // It selects strategies based on distance category, runner level, and situation automatically
            // Graph RAG leverages graph-based embeddings for enhanced strategy matching
            // We pass goal for logging purposes
            // Coach Logic routing: derive a structured diagnosis (cluster + intent + phase)
            // from the performance analysis and route the KB query. Additive — falls back to
            // the edge function's standard selection if these are nil.
            let diag = WatchDiagnosisEngine.diagnose(pa: performanceAnalysis, goal: goal)
            let routedCluster = (goal == "tactical")
                ? WatchDiagnosisEngine.confirmedCluster(runId: runId, raw: diag.cluster, urgency: diag.urgency, confidence: diag.confidence)
                : diag.cluster
            print("📚 [CoachStrategyRAG] Diagnosis → cluster=\(routedCluster), phase=\(diag.phase), intent=\(diag.intent)")

            let strategyRequest = StrategyRequest(
                performance_analysis: performanceAnalysis,
                personality: personality,
                energy_level: energyLevel,
                user_id: userId,
                run_id: runId,
                cluster: routedCluster,
                phase: diag.phase,
                intent_label: diag.intent,
                feedback_type: feedbackType,
                recent_strategies: recentStrategies.isEmpty ? nil : recentStrategies,
                runner_strategy_fx: runnerStrategyFx,
                previous_strategy: previousStrategy
            )
            
            request.httpBody = try JSONEncoder().encode(strategyRequest)
            
            print("📚 [CoachStrategyRAG] Sending request to edge function...")
            let startTime = Date()
            let (data, response) = try await URLSession.shared.data(for: request)
            let duration = Date().timeIntervalSince(startTime)
            
            print("📚 [CoachStrategyRAG] Response received in \(String(format: "%.2f", duration)) seconds")
            
            if let httpResponse = response as? HTTPURLResponse {
                print("📚 [CoachStrategyRAG] HTTP Status Code: \(httpResponse.statusCode)")
                
                if httpResponse.statusCode == 200 {
                    let decoder = JSONDecoder()
                    let strategyResponse = try decoder.decode(StrategyResponse.self, from: data)
                    
                    if strategyResponse.success, let strategy = strategyResponse.strategy {
                        print("📚 [CoachStrategyRAG] ✅✅✅ Strategy selected from KB ✅✅✅")
                        print("📚 [CoachStrategyRAG] Strategy: \(strategy.strategy_name)")
                        print("📚 [CoachStrategyRAG] Text: \(strategy.strategy_text)")
                        print("📚 [CoachStrategyRAG] Confidence: \(String(format: "%.0f", strategy.confidence_score * 100))%")
                        return strategy
                    } else {
                        print("❌ [CoachStrategyRAG] Strategy response indicates failure")
                        if let error = strategyResponse.error {
                            print("❌ [CoachStrategyRAG] Error: \(error)")
                        }
                    }
                } else {
                    let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
                    print("❌ [CoachStrategyRAG] Edge function error - Status: \(httpResponse.statusCode)")
                    print("❌ [CoachStrategyRAG] Error response: \(errorBody)")
                }
            }
        } catch {
            print("❌ [CoachStrategyRAG] Request error: \(error.localizedDescription)")
        }
        
        return nil
    }
    
    // MARK: - Helper: Convert RAG Analysis to Performance Analysis
    
    /// Convert RAGPerformanceAnalyzer result to PerformanceAnalysis for edge function
    func createPerformanceAnalysis(
        from ragAnalysis: RAGPerformanceAnalyzer.RAGAnalysisResult,
        stats: RunningStatsUpdate,
        preferences: UserPreferences.Settings,
        healthManager: HealthManager?,
        intervals: [RunInterval],
        elapsedTime: Double
    ) -> PerformanceAnalysis {
        // Convert zone percentages to string keys
        var zonePercentages: [String: Double] = [:]
        if let hm = healthManager {
            for (zone, pct) in hm.zonePercentages {
                zonePercentages[String(zone)] = pct
            }
        }
        
        // Get interval paces
        let intervalPaces = intervals.map { $0.paceMinPerKm }
        
        // Extract pace trend from interval trends text
        let paceTrend: String
        let intervalTrendsLower = ragAnalysis.intervalTrends.lowercased()
        if intervalTrendsLower.contains("declining") || intervalTrendsLower.contains("slowing") {
            paceTrend = "declining"
        } else if intervalTrendsLower.contains("improving") || intervalTrendsLower.contains("faster") {
            paceTrend = "improving"
        } else if intervalTrendsLower.contains("erratic") || intervalTrendsLower.contains("inconsistent") {
            paceTrend = "erratic"
        } else {
            paceTrend = "stable"
        }
        
        // Extract HR trend from HR variation analysis
        let hrTrend: String
        let hrAnalysisLower = ragAnalysis.hrVariationAnalysis.lowercased()
        if hrAnalysisLower.contains("rising") || hrAnalysisLower.contains("drift") {
            hrTrend = "rising"
        } else if hrAnalysisLower.contains("spiking") || hrAnalysisLower.contains("spike") {
            hrTrend = "spiking"
        } else if hrAnalysisLower.contains("recovering") || hrAnalysisLower.contains("recover") {
            hrTrend = "recovering"
        } else {
            hrTrend = "stable"
        }
        
        // Extract fatigue level from running quality assessment
        let fatigueLevel: String
        let qualityLower = ragAnalysis.runningQualityAssessment.lowercased()
        if qualityLower.contains("critical") || qualityLower.contains("high fatigue") {
            fatigueLevel = "critical"
        } else if qualityLower.contains("high") && qualityLower.contains("fatigue") {
            fatigueLevel = "high"
        } else if qualityLower.contains("moderate") || qualityLower.contains("moderate fatigue") {
            fatigueLevel = "moderate"
        } else {
            fatigueLevel = "fresh"
        }
        
        return PerformanceAnalysis(
            current_pace: stats.effectivePace,
            target_pace: preferences.targetPaceMinPerKm,
            current_distance: stats.distance,
            target_distance: preferences.targetDistanceMeters,
            elapsed_time: elapsedTime,
            current_hr: healthManager?.currentHeartRate,
            average_hr: healthManager?.averageHeartRate,
            max_hr: healthManager?.maxHeartRate,
            current_zone: healthManager?.currentZone,
            zone_percentages: zonePercentages,
            pace_trend: paceTrend,
            hr_trend: hrTrend,
            fatigue_level: fatigueLevel,
            target_status: ragAnalysis.targetStatus.description,
            performance_summary: ragAnalysis.performanceAnalysis,
            heart_zone_analysis: ragAnalysis.heartZoneAnalysis,
            interval_trends: ragAnalysis.intervalTrends,
            hr_variation_analysis: ragAnalysis.hrVariationAnalysis,
            injury_risk_signals: ragAnalysis.injuryRiskSignals,
            adaptive_microstrategy: ragAnalysis.adaptiveMicrostrategy,
            pace_deviation: abs(stats.effectivePace - preferences.targetPaceMinPerKm) / preferences.targetPaceMinPerKm * 100,
            completed_intervals: intervals.count,
            interval_paces: intervalPaces
        )
    }
    
    // MARK: - Helper: Get Auth Token
    
    private func getAuthToken() -> String {
        if let token = UserDefaults.standard.string(forKey: "sessionToken") {
            return "Bearer \(token)"
        }
        return "Bearer \(supabaseKey)"
    }
}

// MARK: - Watch Run Diagnosis Engine
//
// Mirrors the iOS RunDiagnosisEngine: turns the performance analysis into one typed
// diagnosis (cluster + intent + phase) with evidence-weighted confidence and a forward
// projection. Internal routing only — no prompt or response-schema changes.
//
// The watch has no per-km HR, so the HR dimension uses the coarse hr_trend label while
// pace rate-of-change (slope) and variability come from interval_paces.

struct WatchRunDiagnosis {
    let cluster: String
    let intent: String
    let phase: String
    let urgency: Int        // 0 none … 5 critical
    let confidence: Double  // 0–1
}

enum WatchDiagnosisEngine {

    private static let stateKeyPrefix = "watch_coachlogic_state_"

    // MARK: Numeric helpers

    static func slope(_ y: [Double]) -> Double {
        let n = y.count
        guard n >= 2 else { return 0 }
        let xs = (0..<n).map { Double($0) }
        let mx = xs.reduce(0, +) / Double(n)
        let my = y.reduce(0, +) / Double(n)
        var num = 0.0, den = 0.0
        for i in 0..<n {
            num += (xs[i] - mx) * (y[i] - my)
            den += (xs[i] - mx) * (xs[i] - mx)
        }
        return den == 0 ? 0 : num / den
    }

    static func cv(_ y: [Double]) -> Double {
        let n = y.count
        guard n >= 2 else { return 0 }
        let mean = y.reduce(0, +) / Double(n)
        guard mean != 0 else { return 0 }
        let varc = y.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(n)
        return sqrt(varc) / abs(mean)
    }

    static func trendConfidence(_ n: Int) -> Double { min(1.0, max(0.0, Double(n - 1) / 3.0)) }

    // MARK: Phase

    static func derivePhase(pa: CoachStrategyRAGManager.PerformanceAnalysis, goal: String) -> String {
        if goal == "race_strategy" { return "start" }
        if goal == "learning" { return "finish" }
        if pa.target_distance > 0 {
            let frac = pa.current_distance / pa.target_distance
            if frac >= 0.9 { return "finish" }
            if frac >= 0.6 { return "late" }
            if frac >= 0.25 { return "mid" }
            return "early"
        }
        return "mid"
    }

    // MARK: Diagnose

    static func diagnose(pa: CoachStrategyRAGManager.PerformanceAnalysis, goal: String) -> WatchRunDiagnosis {
        let phase = derivePhase(pa: pa, goal: goal)

        // Start: open with a pacing intent based on direction vs target.
        if phase == "start" {
            let status = pa.target_status.lowercased()
            let intent: String
            if status.contains("ahead") { intent = "Settle a hot start — pull back to plan pace" }
            else if status.contains("behind") { intent = "Lift gently to plan pace — conservative start" }
            else { intent = "Execute the race plan — lock target effort" }
            return WatchRunDiagnosis(cluster: "pace_control", intent: intent, phase: phase, urgency: 1, confidence: 0.7)
        }

        // Signed pace gap (+ slower, − faster) from target_status direction + magnitude.
        let status = pa.target_status.lowercased()
        let mag = abs(pa.pace_deviation)
        let paceGapPct: Double = status.contains("behind") ? mag : (status.contains("ahead") ? -mag : 0)

        let paceSlopeSecPerKm = slope(pa.interval_paces.filter { $0 > 0 }) * 60.0
        let paceCV = cv(pa.interval_paces.filter { $0 > 0 })
        let n = pa.completed_intervals
        let tconf = trendConfidence(n)

        let fat = pa.fatigue_level.lowercased()
        let zone = pa.current_zone ?? 0
        let effort = zone >= 4 ? "high" : (zone == 3 ? "moderate" : "low")
        let unsustainable = fat.contains("critical") || zone >= 5
        let hr = pa.hr_trend.lowercased()
        let hrRising = hr.contains("ris") || hr.contains("drift") || hr.contains("spik")
        let hrFalling = hr.contains("recover") || hr.contains("fall") || hr.contains("drop")
        let slowing = paceSlopeSecPerKm > 4.0
        let isLate = (phase == "late" || phase == "finish")

        struct Cand { let cluster: String; let intent: String; let urgency: Int; let confidence: Double
            var score: Double { Double(urgency) + min(confidence, 1.0) * 0.99 } }
        var cands: [Cand] = []

        // A. Wall (critical)
        if isLate && unsustainable {
            cands.append(Cand(cluster: "wall_management", intent: "Manage the wall — protect form, target the finish", urgency: 5, confidence: fat.contains("critical") ? 0.9 : max(0.6, tconf)))
        }
        // B. Bonk — HR falling + pace falling (critical)
        if hrFalling && slowing {
            cands.append(Cand(cluster: "fatigue_management", intent: "Fuel and ease — bonk pattern (HR falling with pace)", urgency: 5, confidence: max(0.5, tconf)))
        }
        // C. Fatigue — HR rising + pace falling (high)
        if hrRising && slowing {
            cands.append(Cand(cluster: "fatigue_management", intent: "Reduce effort — fatigue (HR up, pace down)", urgency: 4, confidence: max(0.5, tconf)))
        }
        // D. HR drift — HR rising while holding/faster (high)
        if hrRising && !slowing {
            cands.append(Cand(cluster: "hr_management", intent: "Manage HR drift — protect aerobic ceiling", urgency: 4, confidence: 0.55))
        }
        // G. Way behind + high cost (high)
        if paceGapPct > 10 && (effort == "high" || unsustainable) {
            cands.append(Cand(cluster: "goal_management", intent: "Pivot to a realistic goal", urgency: 4, confidence: 0.7))
        }
        // E. Forward-looking positive-split risk (medium)
        if !isLate && slowing && paceGapPct > 2 {
            cands.append(Cand(cluster: "pace_control", intent: "Arrest the drift now — heading for a positive split", urgency: 3, confidence: max(0.45, tconf)))
        }
        // F. Volatile pacing (medium)
        if paceCV > 0.06 {
            cands.append(Cand(cluster: "pace_control", intent: "Stabilise pace — hold consistent effort", urgency: 3, confidence: min(0.85, 0.4 + paceCV * 4 + tconf * 0.2)))
        }
        // H. Recoverable deficit (medium)
        if paceGapPct > 2 && paceGapPct <= 10 && (effort == "low" || effort == "moderate") && !hrRising {
            cands.append(Cand(cluster: "goal_management", intent: "Recover the deficit within HR headroom", urgency: 3, confidence: 0.6))
        }
        // I. Exploit surplus (opportunity)
        if paceGapPct < -2 && (fat.contains("fresh") || fat.contains("moderate")) && effort != "high" && !hrRising {
            cands.append(Cand(cluster: "pacing_architecture", intent: "Exploit surplus — controlled acceleration within HR ceiling", urgency: 2, confidence: max(0.45, tconf)))
        }
        // J. Finish kick (high)
        if phase == "finish" && !fat.contains("critical") && paceGapPct <= 5 && !slowing {
            cands.append(Cand(cluster: "finish", intent: "Commit the finish kick", urgency: 4, confidence: 0.7))
        }

        guard let best = cands.max(by: { $0.score < $1.score }) else {
            return WatchRunDiagnosis(cluster: "pace_control", intent: "Hold the race plan — stay disciplined", phase: phase, urgency: 0, confidence: 0.5)
        }
        return WatchRunDiagnosis(cluster: best.cluster, intent: best.intent, phase: phase, urgency: best.urgency, confidence: min(0.95, max(0.3, best.confidence)))
    }

    // MARK: Confirmation guard (per-run, persisted)

    private struct State: Codable { var pendingCluster: String; var pendingCount: Int; var activeCluster: String }

    private static func additionalConfirm(cluster: String, urgency: Int, confidence: Double) -> Int {
        if cluster == "wall_management" || cluster == "finish" { return 0 }
        if urgency >= 5 || confidence >= 0.8 { return 0 }
        return 1
    }

    static func confirmedCluster(runId: String?, raw: String, urgency: Int, confidence: Double) -> String {
        let key = stateKeyPrefix + (runId ?? "default")
        var state: State
        if let data = UserDefaults.standard.data(forKey: key), let s = try? JSONDecoder().decode(State.self, from: data) {
            state = s
        } else {
            state = State(pendingCluster: "", pendingCount: 0, activeCluster: "")
        }

        let result: String
        if raw == "pace_control" || raw == state.activeCluster {
            state.activeCluster = raw; state.pendingCluster = raw; state.pendingCount = 1
            result = raw
        } else {
            if state.pendingCluster == raw { state.pendingCount += 1 }
            else { state.pendingCluster = raw; state.pendingCount = 1 }
            if state.pendingCount > additionalConfirm(cluster: raw, urgency: urgency, confidence: confidence) {
                state.activeCluster = raw; result = raw
            } else {
                result = state.activeCluster.isEmpty ? "pace_control" : state.activeCluster
            }
        }

        if let data = try? JSONEncoder().encode(state) { UserDefaults.standard.set(data, forKey: key) }
        return result
    }
}

