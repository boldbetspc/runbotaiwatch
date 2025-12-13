import Foundation

/// Coach Strategy RAG Manager
/// Calls the coach-rag-strategy edge function to get adaptive coaching strategies from KB
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
        // Note: 'goal' parameter is for logging/future use - edge function doesn't use it yet
        // Edge function selects strategies based on distance category, runner level, and situation
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
        goal: String
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
        
        print("📚 [CoachStrategyRAG] ========== REQUESTING COACH STRATEGY ==========")
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
            
            // Note: Edge function doesn't use 'goal' parameter yet
            // It selects strategies based on distance category, runner level, and situation automatically
            // We pass goal for logging purposes
            let strategyRequest = StrategyRequest(
                performance_analysis: performanceAnalysis,
                personality: personality,
                energy_level: energyLevel,
                user_id: userId,
                run_id: runId
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
                    
                    // Provide helpful error messages for common issues
                    if httpResponse.statusCode == 500 && errorBody.contains("OPENAI_API_KEY") {
                        print("⚠️ [CoachStrategyRAG] ========== SECRET CONFIGURATION ISSUE ==========")
                        print("⚠️ [CoachStrategyRAG] The edge function cannot access OPENAI_API_KEY.")
                        print("⚠️ [CoachStrategyRAG]")
                        print("⚠️ [CoachStrategyRAG] CRITICAL: Check Supabase Dashboard → Edge Functions → coach-rag-strategy → Logs")
                        print("⚠️ [CoachStrategyRAG] Look for 'Environment check' log which shows:")
                        print("⚠️ [CoachStrategyRAG]   - hasOpenAIKey: true/false")
                        print("⚠️ [CoachStrategyRAG]   - envKeys: [list of available env vars]")
                        print("⚠️ [CoachStrategyRAG]")
                        print("⚠️ [CoachStrategyRAG] To fix:")
                        print("⚠️ [CoachStrategyRAG] 1. Supabase Dashboard → Edge Functions → coach-rag-strategy → Settings → Secrets")
                        print("⚠️ [CoachStrategyRAG] 2. Click 'Add Secret' and add:")
                        print("⚠️ [CoachStrategyRAG]    Name: OPENAI_API_KEY (exact case, no spaces)")
                        print("⚠️ [CoachStrategyRAG]    Value: <your-openai-api-key>")
                        print("⚠️ [CoachStrategyRAG] 3. Redeploy: supabase functions deploy coach-rag-strategy")
                        print("⚠️ [CoachStrategyRAG] 4. Note: Function-specific secrets may be required even if project-wide exists")
                        print("⚠️ [CoachStrategyRAG] ==========================================")
                    } else if httpResponse.statusCode == 404 {
                        print("⚠️ [CoachStrategyRAG] Edge function not found. Ensure 'coach-rag-strategy' is deployed.")
                    } else if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                        print("⚠️ [CoachStrategyRAG] Authentication error. Check Supabase credentials.")
                    }
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
            current_pace: stats.pace,
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
            pace_deviation: abs(stats.pace - preferences.targetPaceMinPerKm) / preferences.targetPaceMinPerKm * 100,
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

