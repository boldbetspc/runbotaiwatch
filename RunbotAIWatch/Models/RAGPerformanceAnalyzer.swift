import Foundation
import Combine

/// RAG-Driven Closed-Loop Performance Analysis
///
/// This analyzer uses Retrieval-Augmented Generation (RAG) to provide truly intelligent
/// AI coaching feedback at intervals. It queries past performance data using vector
/// embeddings (pgvector in Supabase) to find similar running patterns and generate
/// context-aware, adaptive coaching insights.
///
/// **Architecture:**
/// 1. Current State → Embedding Generation → Vector Search → Similar Runs Retrieval
/// 2. Similar Runs + Current Metrics → Comprehensive Analysis → LLM Prompt Context
///
/// **Analysis Dimensions:**
/// - Target Awareness: on-track / slightly-behind / way-behind based on pace/distance/time
/// - Heart Zone Analysis: current zone, zone trends, zone time distribution
/// - Zone Guidance: adaptive recommendations based on target and current state
/// - Interval Trends: pace progression, consistency, fatigue detection
/// - HR Variations: stability, spikes, recovery patterns
/// - Running Quality: biomechanical efficiency signals
/// - Injury Detection: unusual patterns that may indicate strain or injury risk
/// - Historical Context: insights from similar past runs via RAG
///
/// **Supabase Schema (Normalized):**
/// - `run_performance` table stores ONLY: run_id, run_embedding, derived analysis fields
/// - Actual run data (distance, pace, HR, zones) comes from `run_activities` and `run_hr`
/// - Vector search RPC `match_run_performance()` joins with `run_activities` to get data
/// - This avoids data duplication - single source of truth in existing tables
///
class RAGPerformanceAnalyzer: ObservableObject {
    
    // MARK: - Cached Run Context
    // Preferences, language, runner name - cached once at run start (never change during run)
    // Mem0 insights - fetched fresh at each interval (incremental updates during run)
    private var cachedPreferences: UserPreferences.Settings?
    private var cachedRunnerName: String?
    private var cachedUserId: String?
    private var runStartTime: Date?
    private var isRunActive: Bool = false
    
    /// Call at run start to cache preferences and language (never change during run)
    /// Mem0 insights are fetched fresh at each interval for incremental updates
    func initializeForRun(
        preferences: UserPreferences.Settings,
        runnerName: String,
        userId: String
    ) {
        print("📦 [RAG] Caching run context - preferences, language, runner name")
        self.cachedPreferences = preferences
        self.cachedRunnerName = runnerName
        self.cachedUserId = userId
        self.runStartTime = Date()
        self.isRunActive = true
        
        // Note: Mem0 insights are NOT cached - fetched fresh at each interval
        // because they get incremental updates (coaching feedback stored during run)
        
        print("📦 [RAG] Cached (static): Language=\(preferences.language.displayName), Personality=\(preferences.coachPersonality.rawValue), Target=\(preferences.targetDistance.displayName)")
        print("📦 [RAG] Dynamic (per interval): Mem0 insights, similar runs, HR/pace data")
    }
    
    /// Call at run end to clear cached context
    func clearRunContext() {
        print("🧹 [RAG] Clearing cached run context")
        cachedPreferences = nil
        cachedRunnerName = nil
        cachedUserId = nil
        runStartTime = nil
        isRunActive = false
    }
    
    // MARK: - Performance Snapshot
    
    struct PerformanceSnapshot: Codable {
        // Current metrics
        let currentPace: Double // min/km
        let targetPace: Double // min/km
        let currentDistance: Double // meters
        let targetDistance: Double // meters (estimated from target time)
        let elapsedTime: Double // seconds
        let targetTime: Double // seconds (estimated)
        
        // Heart rate metrics
        let currentHR: Double?
        let averageHR: Double?
        let maxHR: Double?
        let currentZone: Int?
        let zonePercentages: [Int: Double]
        let zoneAveragePace: [Int: Double]
        
        // Interval data
        let completedIntervals: [IntervalSnapshot]
        let currentIntervalNumber: Int
        
        // Derived metrics
        let paceDeviation: Double // % deviation from target
        let estimatedFinishTime: Double // seconds
        let projectedDistance: Double // meters at current pace
        
        // Trend indicators
        let pacetrend: PaceTrend
        let hrTrend: HRTrend
        let fatigueLevel: FatigueLevel
        
        // HR Drift data
        let kmDriftData: [KmDriftData]
        let currentDrift: DriftSnapshot?
    }
    
    struct KmDriftData: Codable {
        let kilometer: Int
        let driftAtKmStart: Double
        let driftAtKmEnd: Double
    }
    
    struct DriftSnapshot: Codable {
        let driftPercent: Double
    }
    
    struct IntervalSnapshot: Codable {
        let kilometer: Int
        let pace: Double // min/km
        let duration: Double // seconds
        let avgHR: Double?
        let zone: Int?
    }
    
    enum PaceTrend: String, Codable {
        case improving = "improving"      // Getting faster
        case stable = "stable"            // Consistent
        case declining = "declining"      // Slowing down
        case erratic = "erratic"          // Inconsistent
    }
    
    enum HRTrend: String, Codable {
        case stable = "stable"            // Normal variation
        case rising = "rising"            // Cardiac drift
        case spiking = "spiking"          // Unusual spikes
        case recovering = "recovering"    // Coming down from high
    }
    
    enum FatigueLevel: String, Codable {
        case fresh = "fresh"              // Early run, no fatigue
        case moderate = "moderate"        // Normal fatigue
        case high = "high"                // Significant fatigue
        case critical = "critical"        // Warning level
    }
    
    // MARK: - RAG Analysis Result
    
    /// Helper to create empty RAGAnalysisResult for fallback cases
    private func emptyRAGAnalysisResult(targetStatus: TargetStatus) -> RAGAnalysisResult {
        return RAGAnalysisResult(
            targetStatus: targetStatus,
            performanceAnalysis: "",
            physiologyAnalysis: "",
            coachPerspective: "",
            qualityAndRisks: "",
            adaptiveMicrostrategy: "",
            similarRunsContext: "",
            overallRecommendation: "",
            intervalTrends: "",
            hrVariationAnalysis: "",
            runningQualityAssessment: "",
            heartZoneAnalysis: "",
            injuryRiskSignals: []
        )
    }
    
    struct RAGAnalysisResult {
        let targetStatus: TargetStatus
        let performanceAnalysis: String // Combined: pace, intervals, trends
        let physiologyAnalysis: String // Combined: HR zones, variation, drift
        let coachPerspective: String // Combined: runner insights + trade-offs + 5 questions
        let qualityAndRisks: String // Combined: running quality + injury signals
        let adaptiveMicrostrategy: String
        let similarRunsContext: String
        let overallRecommendation: String
        
        // Individual components for backward compatibility
        let intervalTrends: String
        let hrVariationAnalysis: String
        let runningQualityAssessment: String
        let heartZoneAnalysis: String
        let injuryRiskSignals: [String]
        
        /// Formatted context string for LLM prompt
        var llmContext: String {
            return """
            📊 RAG PERFORMANCE ANALYSIS (Real-time Closed-Loop)
            
            🎯 TARGET STATUS: \(targetStatus.description)
            
            📈 PERFORMANCE ANALYSIS:
            \(performanceAnalysis)
            
            ❤️ PHYSIOLOGY ANALYSIS (HR, Zones, Drift):
            \(physiologyAnalysis)
            
            🧠 COACH'S PERSPECTIVE:
            \(coachPerspective)
            
            🏃 QUALITY & RISKS:
            \(qualityAndRisks)
            
            🧠 ADAPTIVE MICROSTRATEGY:
            \(adaptiveMicrostrategy)
            
            📚 SIMILAR RUNS CONTEXT (RAG):
            \(similarRunsContext)
            
            💡 OVERALL RECOMMENDATION:
            \(overallRecommendation)
            """
        }
    }
    
    enum TargetStatus: CustomStringConvertible {
        case onTrack(deviation: Double)           // Within 5% of target
        case slightlyBehind(deviation: Double)    // 5-15% behind
        case wayBehind(deviation: Double)         // >15% behind
        case slightlyAhead(deviation: Double)     // 5-15% ahead
        case wayAhead(deviation: Double)          // >15% ahead
        
        var description: String {
            switch self {
            case .onTrack(let dev):
                return "ON TRACK (\(String(format: "%.1f", abs(dev)))% distance deviation)"
            case .slightlyBehind(let dev):
                return "SLIGHTLY BEHIND (\(String(format: "%.1f", dev))% behind on distance)"
            case .wayBehind(let dev):
                return "WAY BEHIND (\(String(format: "%.1f", dev))% behind on distance) ⚠️"
            case .slightlyAhead(let dev):
                return "SLIGHTLY AHEAD (\(String(format: "%.1f", dev))% ahead on distance)"
            case .wayAhead(let dev):
                return "WAY AHEAD (\(String(format: "%.1f", dev))% ahead on distance)"
            }
        }
        
        var coachingUrgency: String {
            switch self {
            case .onTrack:
                return "Maintain current effort"
            case .slightlyBehind:
                return "Minor adjustment needed"
            case .wayBehind:
                return "URGENT: Significant adjustment required"
            case .slightlyAhead:
                return "Consider banking time or easing slightly"
            case .wayAhead:
                return "Consider conserving energy for later"
            }
        }
    }
    
    // MARK: - End of Run Analysis Result
    
    struct EndOfRunAnalysis {
        // Target achievement
        let targetMet: Bool
        let targetAchievement: String // "Exceeded by 0.5km", "Missed by 2 min", etc.
        let targetDeviation: String // "12% faster", "8% behind"
        
        // Final stats
        let finalDistance: Double // km
        let finalDuration: Double // seconds
        let finalPace: Double // min/km
        let targetDistance: Double // km
        let targetPace: Double // min/km
        
        // Interval analysis
        let intervalAnalysis: String
        let paceVariation: String // "Consistent", "Positive splits", "Negative splits"
        let bestInterval: String // "Km 3: 5:45"
        let worstInterval: String // "Km 5: 7:12"
        
        // Heart zone analysis
        let zoneDistribution: String
        let dominantZone: Int
        let zoneEfficiency: String // "Excellent", "Good", "Suboptimal"
        let zonePaceCorrelation: String
        
        // Cross-analysis: Zones x Pace x Intervals
        let performanceInsights: [String]
        let whatWentWell: [String]
        let whatNeedsWork: [String]
        
        // Overall assessment
        let overallRating: String // "Excellent", "Good", "Needs work"
        let overallScore: Int // 0-100
        
        // Similar runs comparison
        let comparedToHistory: String
        
        /// LLM context for end-of-run prompt
        var llmContext: String {
            return """
            ============================================================================
            END-OF-RUN RAG ANALYSIS (Comprehensive)
            ============================================================================
            
            🎯 TARGET ACHIEVEMENT:
            - Target: \(String(format: "%.1f", targetDistance)) km at \(formatPaceStatic(targetPace)) min/km
            - Actual: \(String(format: "%.2f", finalDistance)) km at \(formatPaceStatic(finalPace)) min/km
            - Duration: \(formatDurationStatic(finalDuration))
            - Result: \(targetAchievement)
            - Status: \(targetMet ? "✅ TARGET MET" : "❌ TARGET MISSED")
            - Deviation: \(targetDeviation)
            
            📊 INTERVAL ANALYSIS:
            \(intervalAnalysis)
            - Pace pattern: \(paceVariation)
            - Best interval: \(bestInterval)
            - Worst interval: \(worstInterval)
            
            ❤️ HEART ZONE ANALYSIS:
            \(zoneDistribution)
            - Dominant zone: Zone \(dominantZone)
            - Zone efficiency: \(zoneEfficiency)
            - Zone-pace correlation: \(zonePaceCorrelation)
            
            🔬 PERFORMANCE INSIGHTS (Zones × Pace × Intervals):
            \(performanceInsights.map { "• \($0)" }.joined(separator: "\n"))
            
            ✅ WHAT WENT WELL:
            \(whatWentWell.map { "• \($0)" }.joined(separator: "\n"))
            
            ⚠️ WHAT NEEDS WORK:
            \(whatNeedsWork.map { "• \($0)" }.joined(separator: "\n"))
            
            📈 COMPARED TO HISTORY:
            \(comparedToHistory)
            
            🏆 OVERALL ASSESSMENT:
            - Performance level: \(overallRating)
            (Note: Do NOT mention scores or ratings in voice output - just give natural coaching feedback)
            ============================================================================
            """
        }
        
        private func formatPaceStatic(_ pace: Double) -> String {
            let minutes = Int(pace)
            let seconds = Int((pace - Double(minutes)) * 60)
            return String(format: "%d:%02d", minutes, seconds)
        }
        
        private func formatDurationStatic(_ seconds: Double) -> String {
            let totalSeconds = Int(seconds)
            let hours = totalSeconds / 3600
            let mins = (totalSeconds % 3600) / 60
            let secs = totalSeconds % 60
            if hours > 0 {
                return String(format: "%d:%02d:%02d", hours, mins, secs)
            }
            return String(format: "%d:%02d", mins, secs)
        }
    }
    
    // MARK: - Properties
    
    private let openAIKey: String
    private let supabaseURL: String
    private let supabaseKey: String
    private var cachedSimilarRuns: [SimilarRunResult] = []
    private var lastEmbeddingRefresh: Date?
    
    struct SimilarRunResult: Codable {
        let runId: String
        let distance: Double
        let pace: Double
        let duration: Double
        let similarity: Double
        let performanceSummary: String?
        let keyInsights: String?
    }
    
    init() {
        if let config = ConfigLoader.loadConfig() {
            self.openAIKey = (config["OPENAI_API_KEY"] as? String) ?? ""
            self.supabaseURL = (config["SUPABASE_URL"] as? String) ?? ""
            self.supabaseKey = (config["SUPABASE_ANON_KEY"] as? String) ?? ""
        } else {
            self.openAIKey = ""
            self.supabaseURL = ""
            self.supabaseKey = ""
        }
    }
    
    // MARK: - End of Run Analysis Function
    
    /// Comprehensive end-of-run RAG analysis
    /// Uses HealthKit, Supabase, RAG vectors, Mem0 for final insightful feedback
    func analyzeEndOfRun(
        session: RunSession,
        stats: RunningStatsUpdate,
        preferences: UserPreferences.Settings,
        healthManager: HealthManager?,
        userId: String
    ) async -> EndOfRunAnalysis {
        
        print("🏁 [RAG] Starting end-of-run analysis...")
        
        // 1. Calculate target achievement
        let targetDistanceKm = preferences.targetDistanceKm
        let actualDistanceKm = stats.distance / 1000.0
        let targetPace = preferences.targetPaceMinPerKm
        let actualPace = session.pace
        
        // Distance achievement
        let distanceDeviation = targetDistanceKm > 0 ? ((actualDistanceKm - targetDistanceKm) / targetDistanceKm) * 100 : 0
        let distanceMet = actualDistanceKm >= targetDistanceKm * 0.95 // Within 5%
        
        // Pace achievement
        let paceDeviation = targetPace > 0 ? ((actualPace - targetPace) / targetPace) * 100 : 0
        let paceMet = actualPace <= targetPace * 1.05 // Within 5%
        
        let targetMet = distanceMet && paceMet
        
        let targetAchievement: String
        let targetDeviationStr: String
        if targetMet {
            if actualPace < targetPace {
                targetAchievement = "Exceeded target! \(String(format: "%.0f", abs(paceDeviation)))% faster"
                targetDeviationStr = "\(String(format: "%.0f", abs(paceDeviation)))% faster"
            } else {
                targetAchievement = "Target achieved!"
                targetDeviationStr = "On target"
            }
        } else if !distanceMet {
            let shortBy = targetDistanceKm - actualDistanceKm
            targetAchievement = "Short by \(String(format: "%.1f", shortBy)) km"
            targetDeviationStr = "\(String(format: "%.1f", shortBy)) km short"
        } else {
            targetAchievement = "Pace missed by \(String(format: "%.0f", paceDeviation))%"
            targetDeviationStr = "\(String(format: "%.0f", paceDeviation))% slower"
        }
        
        // 2. Analyze intervals
        let intervals = session.intervals
        let intervalAnalysis = buildIntervalAnalysisForEndOfRun(intervals: intervals)
        let paceVariation = analyzePaceVariation(intervals: intervals)
        let (bestInterval, worstInterval) = findBestWorstIntervals(intervals: intervals)
        
        // 3. Heart zone analysis from HealthManager
        let zoneDistribution = buildZoneDistributionString(healthManager: healthManager)
        let dominantZone = findDominantZone(healthManager: healthManager)
        let zoneEfficiency = assessZoneEfficiency(healthManager: healthManager, targetPace: targetPace)
        let zonePaceCorrelation = buildZonePaceCorrelation(healthManager: healthManager)
        
        // 4. Cross-analysis: Performance insights
        let performanceInsights = generatePerformanceInsights(
            intervals: intervals,
            healthManager: healthManager,
            actualPace: actualPace,
            targetPace: targetPace
        )
        
        // 5. What went well / needs work
        let whatWentWell = identifyWhatWentWell(
            targetMet: targetMet,
            paceDeviation: paceDeviation,
            intervals: intervals,
            healthManager: healthManager
        )
        
        let whatNeedsWork = identifyWhatNeedsWork(
            targetMet: targetMet,
            paceDeviation: paceDeviation,
            intervals: intervals,
            healthManager: healthManager
        )
        
        // 6. Compare to history (Supabase + RAG)
        let comparedToHistory = await compareToRunHistory(
            actualPace: actualPace,
            actualDistance: actualDistanceKm,
            userId: userId
        )
        
        // 7. Calculate overall score
        let (overallRating, overallScore) = calculateOverallScore(
            targetMet: targetMet,
            paceDeviation: paceDeviation,
            intervals: intervals,
            healthManager: healthManager
        )
        
        print("🏁 [RAG] End-of-run analysis complete - Score: \(overallScore)/100")
        
        return EndOfRunAnalysis(
            targetMet: targetMet,
            targetAchievement: targetAchievement,
            targetDeviation: targetDeviationStr,
            finalDistance: actualDistanceKm,
            finalDuration: session.duration,
            finalPace: actualPace,
            targetDistance: targetDistanceKm,
            targetPace: targetPace,
            intervalAnalysis: intervalAnalysis,
            paceVariation: paceVariation,
            bestInterval: bestInterval,
            worstInterval: worstInterval,
            zoneDistribution: zoneDistribution,
            dominantZone: dominantZone,
            zoneEfficiency: zoneEfficiency,
            zonePaceCorrelation: zonePaceCorrelation,
            performanceInsights: performanceInsights,
            whatWentWell: whatWentWell,
            whatNeedsWork: whatNeedsWork,
            overallRating: overallRating,
            overallScore: overallScore,
            comparedToHistory: comparedToHistory
        )
    }
    
    // MARK: - End of Run Analysis Helpers
    
    private func buildIntervalAnalysisForEndOfRun(intervals: [RunInterval]) -> String {
        guard !intervals.isEmpty else { return "No interval data recorded" }
        
        var analysis = "Completed \(intervals.count) km intervals:\n"
        for interval in intervals {
            analysis += "  Km \(interval.index): \(formatPace(interval.paceMinPerKm)) min/km (\(Int(interval.durationSeconds))s)\n"
        }
        return analysis
    }
    
    private func analyzePaceVariation(intervals: [RunInterval]) -> String {
        guard intervals.count >= 2 else { return "Insufficient data" }
        
        let paces = intervals.map { $0.paceMinPerKm }
        let firstHalf = Array(paces.prefix(paces.count / 2))
        let secondHalf = Array(paces.suffix(paces.count - paces.count / 2))
        
        let firstHalfAvg = firstHalf.reduce(0, +) / Double(firstHalf.count)
        let secondHalfAvg = secondHalf.reduce(0, +) / Double(secondHalf.count)
        
        let difference = secondHalfAvg - firstHalfAvg
        
        if abs(difference) < 0.15 {
            return "Even splits (consistent pacing)"
        } else if difference > 0.3 {
            return "Positive splits (slowed down) - faded in second half"
        } else if difference > 0 {
            return "Slight positive splits (minor fade)"
        } else if difference < -0.3 {
            return "Strong negative splits (sped up) - excellent finish!"
        } else {
            return "Negative splits (strong finish)"
        }
    }
    
    private func findBestWorstIntervals(intervals: [RunInterval]) -> (String, String) {
        guard !intervals.isEmpty else { return ("N/A", "N/A") }
        
        let sorted = intervals.sorted { $0.paceMinPerKm < $1.paceMinPerKm }
        let best = sorted.first!
        let worst = sorted.last!
        
        return (
            "Km \(best.index): \(formatPace(best.paceMinPerKm))",
            "Km \(worst.index): \(formatPace(worst.paceMinPerKm))"
        )
    }
    
    private func buildZoneDistributionString(healthManager: HealthManager?) -> String {
        guard let hm = healthManager else { return "Heart rate data not available" }
        
        let zones = hm.zonePercentages
        var distribution = "Zone time distribution:\n"
        for zone in 1...5 {
            let pct = zones[zone] ?? 0
            if pct > 0 {
                distribution += "  Zone \(zone): \(String(format: "%.1f", pct))%\n"
            }
        }
        return distribution
    }
    
    private func findDominantZone(healthManager: HealthManager?) -> Int {
        guard let hm = healthManager else { return 2 }
        let zones = hm.zonePercentages
        return zones.max(by: { $0.value < $1.value })?.key ?? 2
    }
    
    private func assessZoneEfficiency(healthManager: HealthManager?, targetPace: Double) -> String {
        guard let hm = healthManager else { return "N/A" }
        
        let zones = hm.zonePercentages
        let z2z3 = (zones[2] ?? 0) + (zones[3] ?? 0)
        let z4z5 = (zones[4] ?? 0) + (zones[5] ?? 0)
        
        // For most runs, 60%+ in Zone 2-3 is efficient
        if z2z3 >= 70 {
            return "Excellent (aerobic dominant)"
        } else if z2z3 >= 50 {
            return "Good (balanced effort)"
        } else if z4z5 > 40 {
            return "High intensity (possibly overexerted)"
        } else {
            return "Suboptimal (consider zone targets)"
        }
    }
    
    private func buildZonePaceCorrelation(healthManager: HealthManager?) -> String {
        guard let hm = healthManager else { return "N/A" }
        
        let zonePace = hm.zoneAveragePace
        var correlation = ""
        for zone in 1...5 {
            if let pace = zonePace[zone], pace > 0 {
                correlation += "Z\(zone): \(formatPace(pace)) | "
            }
        }
        return correlation.isEmpty ? "No zone-pace data" : String(correlation.dropLast(3))
    }
    
    private func generatePerformanceInsights(
        intervals: [RunInterval],
        healthManager: HealthManager?,
        actualPace: Double,
        targetPace: Double
    ) -> [String] {
        var insights: [String] = []
        
        // Pace consistency insight
        if intervals.count >= 2 {
            let paces = intervals.map { $0.paceMinPerKm }
            let avgPace = paces.reduce(0, +) / Double(paces.count)
            let variance = paces.map { pow($0 - avgPace, 2) }.reduce(0, +) / Double(paces.count)
            let stdDev = sqrt(variance)
            
            if stdDev < 0.2 {
                insights.append("Excellent pace consistency (±\(String(format: "%.0f", stdDev * 60)) sec variation)")
            } else if stdDev > 0.5 {
                insights.append("High pace variability - work on even pacing")
            }
        }
        
        // Zone efficiency insight
        if let hm = healthManager {
            let z2z3 = (hm.zonePercentages[2] ?? 0) + (hm.zonePercentages[3] ?? 0)
            if z2z3 > 70 {
                insights.append("Strong aerobic base - \(String(format: "%.0f", z2z3))% in Zone 2-3")
            } else if (hm.zonePercentages[5] ?? 0) > 15 {
                insights.append("Spent \(String(format: "%.0f", hm.zonePercentages[5] ?? 0))% in Zone 5 - high strain")
            }
        }
        
        // Pace vs target insight
        let paceDeviation = ((actualPace - targetPace) / targetPace) * 100
        if abs(paceDeviation) <= 3 {
            insights.append("Pace execution was spot-on vs target")
        } else if paceDeviation > 10 {
            insights.append("Pace \(String(format: "%.0f", paceDeviation))% slower than target - fitness or conditions?")
        } else if paceDeviation < -10 {
            insights.append("Pace \(String(format: "%.0f", abs(paceDeviation)))% faster than target - great day!")
        }
        
        return insights
    }
    
    private func identifyWhatWentWell(
        targetMet: Bool,
        paceDeviation: Double,
        intervals: [RunInterval],
        healthManager: HealthManager?
    ) -> [String] {
        var wellDone: [String] = []
        
        if targetMet {
            wellDone.append("Hit your target - goal accomplished!")
        }
        
        if paceDeviation < -5 {
            wellDone.append("Faster than target pace")
        }
        
        if intervals.count >= 3 {
            let paces = intervals.map { $0.paceMinPerKm }
            let lastThird = Array(paces.suffix(intervals.count / 3))
            let firstTwoThirds = Array(paces.prefix(intervals.count - intervals.count / 3))
            
            if let lastAvg = lastThird.isEmpty ? nil : lastThird.reduce(0, +) / Double(lastThird.count),
               let firstAvg = firstTwoThirds.isEmpty ? nil : firstTwoThirds.reduce(0, +) / Double(firstTwoThirds.count) {
                if lastAvg < firstAvg - 0.1 {
                    wellDone.append("Strong finish - negative splits in final third")
                }
            }
        }
        
        if let hm = healthManager {
            let z2z3 = (hm.zonePercentages[2] ?? 0) + (hm.zonePercentages[3] ?? 0)
            if z2z3 > 60 {
                wellDone.append("Good zone discipline (\(String(format: "%.0f", z2z3))% in aerobic zones)")
            }
        }
        
        if wellDone.isEmpty {
            wellDone.append("You completed the run - that's always a win!")
        }
        
        return wellDone
    }
    
    private func identifyWhatNeedsWork(
        targetMet: Bool,
        paceDeviation: Double,
        intervals: [RunInterval],
        healthManager: HealthManager?
    ) -> [String] {
        var needsWork: [String] = []
        
        if !targetMet && paceDeviation > 10 {
            needsWork.append("Pace was \(String(format: "%.0f", paceDeviation))% off target - review training plan")
        }
        
        if intervals.count >= 3 {
            let paces = intervals.map { $0.paceMinPerKm }
            let lastThird = Array(paces.suffix(intervals.count / 3))
            let firstTwoThirds = Array(paces.prefix(intervals.count - intervals.count / 3))
            
            if let lastAvg = lastThird.isEmpty ? nil : lastThird.reduce(0, +) / Double(lastThird.count),
               let firstAvg = firstTwoThirds.isEmpty ? nil : firstTwoThirds.reduce(0, +) / Double(firstTwoThirds.count) {
                let fadeSeconds = (lastAvg - firstAvg) * 60
                if fadeSeconds > 20 {
                    needsWork.append("Faded \(String(format: "%.0f", fadeSeconds)) sec/km in final third - work on endurance")
                }
            }
        }
        
        if let hm = healthManager {
            if (hm.zonePercentages[5] ?? 0) > 20 {
                needsWork.append("Too much time in Zone 5 - consider pacing more conservatively")
            }
            if (hm.zonePercentages[1] ?? 0) > 30 {
                needsWork.append("30%+ in Zone 1 - could push harder on easy days")
            }
        }
        
        // Pace inconsistency
        if intervals.count >= 2 {
            let paces = intervals.map { $0.paceMinPerKm }
            let maxPace = paces.max() ?? 0
            let minPace = paces.min() ?? 0
            let spread = (maxPace - minPace) * 60 // in seconds
            if spread > 60 {
                needsWork.append("Pace spread was \(Int(spread)) seconds - work on consistency")
            }
        }
        
        if needsWork.isEmpty {
            needsWork.append("Solid run! Keep building on this foundation")
        }
        
        return needsWork
    }
    
    private func compareToRunHistory(actualPace: Double, actualDistance: Double, userId: String) async -> String {
        let aggregates = await SupabaseManager().fetchRunAggregates(userId: userId)
        
        guard let agg = aggregates, agg.totalRuns > 1 else {
            return "Building your run history - more data will enable better comparisons"
        }
        
        let paceVsAvg = actualPace - agg.avgPaceMinPerKm
        let distVsAvg = actualDistance - agg.avgDistanceKm
        
        var comparison = "Compared to your last \(agg.totalRuns) runs:\n"
        
        if abs(paceVsAvg) < 0.1 {
            comparison += "  Pace: Consistent with average (\(formatPace(agg.avgPaceMinPerKm)))\n"
        } else if paceVsAvg < 0 {
            comparison += "  Pace: \(String(format: "%.0f", abs(paceVsAvg) * 60)) sec/km FASTER than average\n"
        } else {
            comparison += "  Pace: \(String(format: "%.0f", paceVsAvg * 60)) sec/km slower than average\n"
        }
        
        if actualPace < agg.bestPaceMinPerKm {
            comparison += "  🏆 NEW PERSONAL BEST PACE!\n"
        }
        
        if abs(distVsAvg) < 0.5 {
            comparison += "  Distance: Typical for you"
        } else if distVsAvg > 0 {
            comparison += "  Distance: \(String(format: "%.1f", distVsAvg)) km longer than average"
        } else {
            comparison += "  Distance: \(String(format: "%.1f", abs(distVsAvg))) km shorter than average"
        }
        
        return comparison
    }
    
    private func calculateOverallScore(
        targetMet: Bool,
        paceDeviation: Double,
        intervals: [RunInterval],
        healthManager: HealthManager?
    ) -> (String, Int) {
        var score = 70 // Base score
        
        // Target achievement (+/- 15)
        if targetMet {
            score += 15
        } else if abs(paceDeviation) < 10 {
            score += 5
        } else {
            score -= 10
        }
        
        // Pace consistency (+/- 10)
        if intervals.count >= 2 {
            let paces = intervals.map { $0.paceMinPerKm }
            let maxPace = paces.max() ?? 0
            let minPace = paces.min() ?? 0
            let spread = (maxPace - minPace) * 60
            if spread < 30 {
                score += 10
            } else if spread > 60 {
                score -= 10
            }
        }
        
        // Zone efficiency (+/- 10)
        if let hm = healthManager {
            let z2z3 = (hm.zonePercentages[2] ?? 0) + (hm.zonePercentages[3] ?? 0)
            if z2z3 > 60 {
                score += 10
            } else if (hm.zonePercentages[5] ?? 0) > 25 {
                score -= 10
            }
        }
        
        // Negative splits bonus (+5)
        if intervals.count >= 3 {
            let paces = intervals.map { $0.paceMinPerKm }
            if let last = paces.last, let first = paces.first, last < first - 0.1 {
                score += 5
            }
        }
        
        score = max(0, min(100, score))
        
        let rating: String
        if score >= 90 {
            rating = "Excellent"
        } else if score >= 75 {
            rating = "Good"
        } else if score >= 60 {
            rating = "Solid"
        } else {
            rating = "Needs work"
        }
        
        return (rating, score)
    }
    
    // MARK: - Main Analysis Function (Interval)
    
    /// Perform comprehensive RAG-driven performance analysis with AI-powered insights
    /// This is the main entry point for interval coaching
    /// Uses cached preferences/language/Mem0 from run start for efficiency
    func analyzePerformance(
        stats: RunningStatsUpdate,
        preferences: UserPreferences.Settings,
        healthManager: HealthManager?,
        intervals: [RunInterval],
        runStartTime: Date,
        userId: String
    ) async -> RAGAnalysisResult {
        
        // Use cached preferences if available (set at run start), otherwise use passed-in
        let effectivePreferences = cachedPreferences ?? preferences
        let effectiveUserId = cachedUserId ?? userId
        
        // 1. Build performance snapshot
        let snapshot = buildPerformanceSnapshot(
            stats: stats,
            preferences: effectivePreferences,
            healthManager: healthManager,
            intervals: intervals,
            runStartTime: runStartTime
        )
        
        // 2. Query similar past runs via vector search (RAG) - dynamic per interval
        let similarRuns = await querySimilarRuns(snapshot: snapshot, userId: effectiveUserId)
        
        // 3. Fetch fresh Mem0 insights at each interval (incremental updates during run)
        // Note: Not cached because coaching feedback is stored to Mem0 after each interval
        print("🔄 [RAG] Fetching fresh Mem0 insights (may include recent coaching feedback)")
        let mem0Insights = await fetchMem0Insights(userId: effectiveUserId, snapshot: snapshot)
        
        // 4. Generate AI-powered comprehensive analysis
        let analysis = await generateAIPoweredAnalysis(
            snapshot: snapshot,
            similarRuns: similarRuns,
            mem0Insights: mem0Insights,
            preferences: effectivePreferences
        )
        
        return analysis
    }
    
    // MARK: - Performance Snapshot Builder
    
    private func buildPerformanceSnapshot(
        stats: RunningStatsUpdate,
        preferences: UserPreferences.Settings,
        healthManager: HealthManager?,
        intervals: [RunInterval],
        runStartTime: Date
    ) -> PerformanceSnapshot {
        
        let elapsedTime = Date().timeIntervalSince(runStartTime)
        let currentPace = stats.pace
        let targetPace = preferences.targetPaceMinPerKm
        
        // Calculate pace deviation (positive = slower, negative = faster)
        let paceDeviation = targetPace > 0 ? ((currentPace - targetPace) / targetPace) * 100 : 0
        
        // Estimate target distance based on typical run duration (30 min default)
        let estimatedRunDuration: Double = 30 * 60 // 30 minutes in seconds
        let targetDistance = (estimatedRunDuration / 60) / targetPace * 1000 // meters
        
        // Project finish time at current pace
        let estimatedFinishTime = targetDistance > 0 ? (targetDistance / 1000) * currentPace * 60 : 0
        
        // Project distance at current pace for remaining estimated time
        let remainingTime = max(0, estimatedRunDuration - elapsedTime)
        let projectedAdditionalDistance = remainingTime > 0 && currentPace > 0 ? (remainingTime / 60) / currentPace * 1000 : 0
        let projectedDistance = stats.distance + projectedAdditionalDistance
        
        // Build interval snapshots
        let intervalSnapshots: [IntervalSnapshot] = intervals.map { interval in
            IntervalSnapshot(
                kilometer: interval.index,
                pace: interval.paceMinPerKm,
                duration: interval.durationSeconds,
                avgHR: nil, // Would need HR data per interval
                zone: nil
            )
        }
        
        // Calculate pace trend
        let paceTrend = calculatePaceTrend(intervals: intervals)
        
        // Calculate HR trend
        let hrTrend = calculateHRTrend(healthManager: healthManager)
        
        // Calculate fatigue level
        let fatigueLevel = calculateFatigueLevel(
            elapsedTime: elapsedTime,
            paceTrend: paceTrend,
            hrTrend: hrTrend,
            healthManager: healthManager
        )
        
        // Calculate HR drift data
        let (kmDriftData, currentDrift) = calculateHRDriftData(
            intervals: intervals,
            healthManager: healthManager,
            elapsedTime: elapsedTime
        )
        
        return PerformanceSnapshot(
            currentPace: currentPace,
            targetPace: targetPace,
            currentDistance: stats.distance,
            targetDistance: targetDistance,
            elapsedTime: elapsedTime,
            targetTime: estimatedRunDuration,
            currentHR: healthManager?.currentHeartRate,
            averageHR: healthManager?.averageHeartRate,
            maxHR: healthManager?.maxHeartRate,
            currentZone: healthManager?.currentZone,
            zonePercentages: healthManager?.zonePercentages ?? [:],
            zoneAveragePace: healthManager?.zoneAveragePace ?? [:],
            completedIntervals: intervalSnapshots,
            currentIntervalNumber: intervals.count + 1,
            paceDeviation: paceDeviation,
            estimatedFinishTime: estimatedFinishTime,
            projectedDistance: projectedDistance,
            pacetrend: paceTrend,
            hrTrend: hrTrend,
            fatigueLevel: fatigueLevel,
            kmDriftData: kmDriftData,
            currentDrift: currentDrift
        )
    }
    
    // MARK: - Trend Calculations
    
    private func calculatePaceTrend(intervals: [RunInterval]) -> PaceTrend {
        guard intervals.count >= 2 else { return .stable }
        
        let paces = intervals.map { $0.paceMinPerKm }
        
        // Calculate pace changes between consecutive intervals
        var changes: [Double] = []
        for i in 1..<paces.count {
            changes.append(paces[i] - paces[i-1])
        }
        
        let avgChange = changes.reduce(0, +) / Double(changes.count)
        let variance = changes.map { pow($0 - avgChange, 2) }.reduce(0, +) / Double(changes.count)
        let stdDev = sqrt(variance)
        
        // High variance = erratic
        if stdDev > 0.5 { // More than 30 sec/km variation
            return .erratic
        }
        
        // Consistent negative change = improving (getting faster)
        if avgChange < -0.1 {
            return .improving
        }
        
        // Consistent positive change = declining (getting slower)
        if avgChange > 0.1 {
            return .declining
        }
        
        return .stable
    }
    
    private func calculateHRTrend(healthManager: HealthManager?) -> HRTrend {
        guard let hm = healthManager,
              let currentHR = hm.currentHeartRate,
              let avgHR = hm.averageHeartRate else {
            return .stable
        }
        
        let hrDifference = currentHR - avgHR
        
        // Current HR significantly above average = rising (cardiac drift)
        if hrDifference > 10 {
            return .rising
        }
        
        // Current HR significantly below average = recovering
        if hrDifference < -10 {
            return .recovering
        }
        
        // Check for spikes (current HR > 90% of max)
        if let maxHR = hm.maxHeartRate, currentHR > maxHR * 0.95 {
            return .spiking
        }
        
        return .stable
    }
    
    private func calculateFatigueLevel(
        elapsedTime: Double,
        paceTrend: PaceTrend,
        hrTrend: HRTrend,
        healthManager: HealthManager?
    ) -> FatigueLevel {
        
        var fatigueScore = 0
        
        // Time-based fatigue
        if elapsedTime < 600 { // < 10 min
            fatigueScore += 0
        } else if elapsedTime < 1200 { // 10-20 min
            fatigueScore += 1
        } else if elapsedTime < 1800 { // 20-30 min
            fatigueScore += 2
        } else {
            fatigueScore += 3
        }
        
        // Pace trend fatigue
        switch paceTrend {
        case .improving: fatigueScore -= 1
        case .stable: fatigueScore += 0
        case .declining: fatigueScore += 2
        case .erratic: fatigueScore += 1
        }
        
        // HR trend fatigue
        switch hrTrend {
        case .stable: fatigueScore += 0
        case .rising: fatigueScore += 2
        case .spiking: fatigueScore += 3
        case .recovering: fatigueScore -= 1
        }
        
        // Zone-based fatigue
        if let zone = healthManager?.currentZone {
            if zone >= 4 {
                fatigueScore += 2
            } else if zone == 3 {
                fatigueScore += 1
            }
        }
        
        // Map score to fatigue level
        if fatigueScore <= 1 {
            return .fresh
        } else if fatigueScore <= 3 {
            return .moderate
        } else if fatigueScore <= 5 {
            return .high
        } else {
            return .critical
        }
    }
    
    // MARK: - RAG: Vector Search for Similar Runs
    
    private func querySimilarRuns(snapshot: PerformanceSnapshot, userId: String) async -> [SimilarRunResult] {
        // First, generate embedding for current run state
        guard let embedding = await generateRunEmbedding(snapshot: snapshot) else {
            print("⚠️ [RAG] Failed to generate embedding, using cached results")
            return cachedSimilarRuns
        }
        
        // Query Supabase run_performance table using pgvector
        let similarRuns = await searchSimilarRuns(embedding: embedding, userId: userId)
        
        if !similarRuns.isEmpty {
            cachedSimilarRuns = similarRuns
            lastEmbeddingRefresh = Date()
        }
        
        return similarRuns
    }
    
    private func generateRunEmbedding(snapshot: PerformanceSnapshot) async -> [Double]? {
        guard !openAIKey.isEmpty else { return nil }
        
        // Build a text description of the current run state for embedding
        let runDescription = """
        Running at \(String(format: "%.1f", snapshot.currentPace)) min/km pace, 
        target \(String(format: "%.1f", snapshot.targetPace)) min/km. 
        Distance \(String(format: "%.1f", snapshot.currentDistance / 1000)) km, 
        elapsed \(Int(snapshot.elapsedTime / 60)) minutes. 
        Heart rate zone \(snapshot.currentZone ?? 0), 
        pace trend \(snapshot.pacetrend.rawValue), 
        fatigue level \(snapshot.fatigueLevel.rawValue).
        Zone distribution: Z1 \(String(format: "%.0f", snapshot.zonePercentages[1] ?? 0))%, 
        Z2 \(String(format: "%.0f", snapshot.zonePercentages[2] ?? 0))%, 
        Z3 \(String(format: "%.0f", snapshot.zonePercentages[3] ?? 0))%, 
        Z4 \(String(format: "%.0f", snapshot.zonePercentages[4] ?? 0))%, 
        Z5 \(String(format: "%.0f", snapshot.zonePercentages[5] ?? 0))%.
        """
        
        do {
            let url = URL(string: "https://api.openai.com/v1/embeddings")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(openAIKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            
            let body: [String: Any] = [
                "model": "text-embedding-3-small",
                "input": runDescription
            ]
            
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            
            let (data, response) = try await URLSession.shared.data(for: request)
            
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
               let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let dataArray = json["data"] as? [[String: Any]],
               let first = dataArray.first,
               let embedding = first["embedding"] as? [Double] {
                print("✅ [RAG] Generated embedding with \(embedding.count) dimensions")
                return embedding
            }
        } catch {
            print("❌ [RAG] Embedding generation failed: \(error.localizedDescription)")
        }
        
        return nil
    }
    
    private func searchSimilarRuns(embedding: [Double], userId: String) async -> [SimilarRunResult] {
        guard !supabaseURL.isEmpty, !supabaseKey.isEmpty else { return [] }
        
        // Get auth token
        let authToken = UserDefaults.standard.string(forKey: "sessionToken") ?? supabaseKey
        
        do {
            // Use Supabase's RPC function for vector similarity search
            // This assumes you have a function like: match_run_performance(query_embedding, match_threshold, match_count)
            let url = URL(string: "\(supabaseURL)/rest/v1/rpc/match_run_performance")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue(supabaseKey, forHTTPHeaderField: "apikey")
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            
            let body: [String: Any] = [
                "query_embedding": embedding,
                "match_threshold": 0.7,
                "match_count": 5,
                "filter_user_id": userId
            ]
            
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            
            let (data, response) = try await URLSession.shared.data(for: request)
            
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                let decoder = JSONDecoder()
                if let results = try? decoder.decode([SimilarRunResult].self, from: data) {
                    print("✅ [RAG] Found \(results.count) similar runs")
                    return results
                }
            } else if let httpResponse = response as? HTTPURLResponse {
                // If RPC doesn't exist, fall back to direct table query
                print("⚠️ [RAG] RPC not available (status \(httpResponse.statusCode)), falling back to direct query")
                return await fallbackSimilarRunsQuery(userId: userId)
            }
        } catch {
            print("❌ [RAG] Similar runs search failed: \(error.localizedDescription)")
        }
        
        return await fallbackSimilarRunsQuery(userId: userId)
    }
    
    /// Fallback query when pgvector RPC is not available
    private func fallbackSimilarRunsQuery(userId: String) async -> [SimilarRunResult] {
        guard !supabaseURL.isEmpty else { return [] }
        
        let authToken = UserDefaults.standard.string(forKey: "sessionToken") ?? supabaseKey
        
        do {
            // Query recent runs from run_activities as fallback
            let url = URL(string: "\(supabaseURL)/rest/v1/run_activities?user_id=eq.\(userId)&select=id,distance_meters,average_pace_minutes_per_km,duration_s&order=start_time.desc&limit=5")!
            var request = URLRequest(url: url)
            request.setValue(supabaseKey, forHTTPHeaderField: "apikey")
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
            
            let (data, response) = try await URLSession.shared.data(for: request)
            
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
               let runs = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                return runs.compactMap { run -> SimilarRunResult? in
                    guard let id = run["id"] as? String,
                          let distance = run["distance_meters"] as? Double,
                          let pace = run["average_pace_minutes_per_km"] as? Double,
                          let duration = run["duration_s"] as? Double else { return nil }
                    
                    return SimilarRunResult(
                        runId: id,
                        distance: distance,
                        pace: pace,
                        duration: duration,
                        similarity: 0.8, // Estimated similarity
                        performanceSummary: "Recent run: \(String(format: "%.1f", distance/1000))km at \(formatPace(pace))",
                        keyInsights: nil
                    )
                }
            }
        } catch {
            print("❌ [RAG] Fallback query failed: \(error.localizedDescription)")
        }
        
        return []
    }
    
    // MARK: - Mem0 Insights Integration
    
    private func fetchMem0Insights(userId: String, snapshot: PerformanceSnapshot) async -> String {
        var allInsights: [String] = []
        
        // Fetch performance-related insights
        let perfInsights = await Mem0Manager.shared.search(
            userId: userId,
            query: "running performance, pacing patterns, fatigue moments, heart rate zones, interval performance",
            category: "running_performance",
            limit: 5
        )
        allInsights.append(contentsOf: perfInsights)
        
        // Fetch coaching feedback insights
        let coachingInsights = await Mem0Manager.shared.search(
            userId: userId,
            query: "coaching feedback, what works, effective cues, breathing patterns, cadence",
            category: "ai_coaching_feedback",
            limit: 3
        )
        allInsights.append(contentsOf: coachingInsights)
        
        // Fetch injury/health insights
        let healthInsights = await Mem0Manager.shared.search(
            userId: userId,
            query: "injury, pain, discomfort, form issues, biomechanics",
            category: nil,
            limit: 2
        )
        allInsights.append(contentsOf: healthInsights)
        
        // Fetch personal preferences and patterns
        let personalInsights = await Mem0Manager.shared.search(
            userId: userId,
            query: "runner preferences, running style, strengths, weaknesses, goals",
            category: nil,
            limit: 3
        )
        allInsights.append(contentsOf: personalInsights)
        
        // Deduplicate and format
        let uniqueInsights = Array(Set(allInsights))
        return uniqueInsights.isEmpty ? "No historical insights available yet." : uniqueInsights.joined(separator: "\n- ")
    }
    
    // MARK: - AI-Powered Comprehensive Analysis Generation
    
    private func generateAIPoweredAnalysis(
        snapshot: PerformanceSnapshot,
        similarRuns: [SimilarRunResult],
        mem0Insights: String,
        preferences: UserPreferences.Settings
    ) async -> RAGAnalysisResult {
        
        // 1. Calculate target status (rule-based, fast)
        let targetStatus = calculateTargetStatus(snapshot: snapshot)
        
        // 2. Build structured data for AI analysis
        let analysisData = buildAnalysisData(
            snapshot: snapshot,
            similarRuns: similarRuns,
            mem0Insights: mem0Insights,
            targetStatus: targetStatus,
            preferences: preferences
        )
        
        // 3. Generate AI-powered insights using GPT-4o-mini
        let aiAnalysis = await generateAIAnalysis(analysisData: analysisData)
        
        // 4. Build consolidated analysis sections
        let performanceAnalysis = buildConsolidatedPerformanceAnalysis(
            snapshot: snapshot,
            aiAnalysis: aiAnalysis
        )
        
        let physiologyAnalysis = buildConsolidatedPhysiologyAnalysis(
            snapshot: snapshot,
            aiAnalysis: aiAnalysis
        )
        
        let coachPerspective = buildConsolidatedCoachPerspective(
            snapshot: snapshot,
            targetStatus: targetStatus,
            aiAnalysis: aiAnalysis
        )
        
        let qualityAndRisks = buildConsolidatedQualityAndRisks(
            snapshot: snapshot,
            aiAnalysis: aiAnalysis
        )
        
        // 5. Build individual components for backward compatibility
        let intervalTrends = buildIntervalTrendsAnalysis(snapshot: snapshot)
        let hrVariationAnalysis = buildHRVariationAnalysis(snapshot: snapshot)
        let runningQualityAssessment = buildRunningQualityAssessment(snapshot: snapshot)
        let heartZoneAnalysis = buildHeartZoneAnalysis(snapshot: snapshot)
        let injuryRiskSignals = detectInjuryRiskSignals(snapshot: snapshot)
        
        // 6. Return consolidated result
        return RAGAnalysisResult(
            targetStatus: targetStatus,
            performanceAnalysis: performanceAnalysis,
            physiologyAnalysis: physiologyAnalysis,
            coachPerspective: coachPerspective,
            qualityAndRisks: qualityAndRisks,
            adaptiveMicrostrategy: aiAnalysis.adaptiveMicrostrategy,
            similarRunsContext: aiAnalysis.similarRunsContext,
            overallRecommendation: aiAnalysis.overallRecommendation,
            intervalTrends: intervalTrends,
            hrVariationAnalysis: hrVariationAnalysis,
            runningQualityAssessment: runningQualityAssessment,
            heartZoneAnalysis: heartZoneAnalysis,
            injuryRiskSignals: injuryRiskSignals
        )
    }
    
    // MARK: - Analysis Data Builder
    
    private struct AnalysisData {
        let snapshot: PerformanceSnapshot
        let similarRuns: [SimilarRunResult]
        let mem0Insights: String
        let targetStatus: TargetStatus
        let preferences: UserPreferences.Settings
    }
    
    private func buildAnalysisData(
        snapshot: PerformanceSnapshot,
        similarRuns: [SimilarRunResult],
        mem0Insights: String,
        targetStatus: TargetStatus,
        preferences: UserPreferences.Settings
    ) -> AnalysisData {
        return AnalysisData(
            snapshot: snapshot,
            similarRuns: similarRuns,
            mem0Insights: mem0Insights,
            targetStatus: targetStatus,
            preferences: preferences
        )
    }
    
    // MARK: - AI Analysis Generation (LLM Prompt)
    
    private func generateAIAnalysis(analysisData: AnalysisData) async -> RAGAnalysisResult {
        guard !openAIKey.isEmpty else {
            // Fallback to rule-based if no API key
            return generateComprehensiveAnalysis(
                snapshot: analysisData.snapshot,
                similarRuns: analysisData.similarRuns,
                preferences: analysisData.preferences
            )
        }
        
        let prompt = buildAIAnalysisPrompt(analysisData: analysisData)
        
        do {
            let url = URL(string: "https://api.openai.com/v1/chat/completions")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(openAIKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            
            let body: [String: Any] = [
                "model": "gpt-4o-mini",
                "messages": [
                    [
                        "role": "system",
                        "content": """
                        You are an elite running performance analyst with deep expertise in:
                        - Biomechanics and running form
                        - Heart rate zone training and cardiovascular efficiency
                        - Pacing strategies and fatigue management
                        - Injury prevention and risk assessment
                        - Data-driven coaching insights
                        
                        Analyze the provided running performance data and generate comprehensive, actionable insights.
                        Be specific, data-driven, and coach-like in your analysis.
                        """
                    ],
                    [
                        "role": "user",
                        "content": prompt
                    ]
                ],
                "temperature": 0.3, // Lower temperature for more consistent, analytical output
                "max_tokens": 800 // Enough for comprehensive analysis
            ]
            
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)
            
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
               let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let choices = json["choices"] as? [[String: Any]],
               let firstChoice = choices.first,
               let message = firstChoice["message"] as? [String: Any],
               let content = message["content"] as? String {
                
                return parseAIAnalysisResponse(content: content, analysisData: analysisData)
            }
        } catch {
            print("❌ [RAG] AI analysis generation failed: \(error.localizedDescription)")
        }
        
        // Fallback to rule-based
        return generateComprehensiveAnalysis(
            snapshot: analysisData.snapshot,
            similarRuns: analysisData.similarRuns,
            preferences: analysisData.preferences
        )
    }
    
    // MARK: - LLM Prompt Builder (REVIEWABLE)
    
    private func buildAIAnalysisPrompt(analysisData: AnalysisData) -> String {
        let snapshot = analysisData.snapshot
        let similarRuns = analysisData.similarRuns
        let mem0Insights = analysisData.mem0Insights
        let targetStatus = analysisData.targetStatus
        let preferences = analysisData.preferences
        
        // Format workout HR and zone data comprehensively
        let hrDataSection: String
        if let currentHR = snapshot.currentHR,
           let avgHR = snapshot.averageHR,
           let maxHR = snapshot.maxHR,
           let currentZone = snapshot.currentZone {
            hrDataSection = """
            HEART RATE & ZONE DATA (from Apple Workout):
            - Current HR: \(Int(currentHR)) BPM (Zone \(currentZone))
            - Average HR: \(Int(avgHR)) BPM
            - Max HR: \(Int(maxHR)) BPM
            - Current at \(String(format: "%.0f", (currentHR / maxHR) * 100))% of max HR
            
            ZONE DISTRIBUTION (time spent in each zone):
            - Zone 1: \(String(format: "%.1f", snapshot.zonePercentages[1] ?? 0))%
            - Zone 2: \(String(format: "%.1f", snapshot.zonePercentages[2] ?? 0))%
            - Zone 3: \(String(format: "%.1f", snapshot.zonePercentages[3] ?? 0))%
            - Zone 4: \(String(format: "%.1f", snapshot.zonePercentages[4] ?? 0))%
            - Zone 5: \(String(format: "%.1f", snapshot.zonePercentages[5] ?? 0))%
            
            ZONE-PACE CORRELATION (average pace in each zone):
            \(buildZonePaceCorrelation(snapshot: snapshot))
            
            HR TREND: \(snapshot.hrTrend.rawValue.uppercased())
            """
        } else {
            hrDataSection = "Heart rate data not available from workout."
        }
        
        // Format interval data
        let intervalDataSection: String
        if !snapshot.completedIntervals.isEmpty {
            intervalDataSection = """
            INTERVAL DATA:
            \(snapshot.completedIntervals.map { interval in
                "Km \(interval.kilometer): \(formatPace(interval.pace)) min/km, \(Int(interval.duration))s"
            }.joined(separator: "\n"))
            
            PACE TREND: \(snapshot.pacetrend.rawValue.uppercased())
            """
        } else {
            intervalDataSection = "No completed intervals yet."
        }
        
        // Format similar runs
        let similarRunsSection: String
        if !similarRuns.isEmpty {
            similarRunsSection = """
            SIMILAR PAST RUNS (from vector search):
            \(similarRuns.enumerated().map { index, run in
                "\(index + 1). \(String(format: "%.1f", run.distance / 1000))km at \(formatPace(run.pace)) min/km (similarity: \(String(format: "%.0f", run.similarity * 100))%)"
            }.joined(separator: "\n"))
            """
        } else {
            similarRunsSection = "No similar past runs found."
        }
        
        // Calculate race progress
        let targetDistanceKm = preferences.targetDistanceKm
        let currentDistanceKm = snapshot.currentDistance / 1000
        let progressPercent = targetDistanceKm > 0 ? (currentDistanceKm / targetDistanceKm) * 100 : 0
        let remainingKm = max(0, targetDistanceKm - currentDistanceKm)
        
        // Estimate finish time at current pace
        let estimatedFinishTimeSeconds = remainingKm * snapshot.currentPace * 60
        let estimatedFinishTimeFormatted = formatDuration(estimatedFinishTimeSeconds)
        
        // Build user preferences section
        let userPreferencesSection = """
        USER PREFERENCES & COACHING STYLE:
        - Language: \(preferences.language.displayName) (\(preferences.language.localeCode))
        - Voice AI Model: \(preferences.voiceAIModel.displayName)
        - Coach Personality: \(preferences.coachPersonality.rawValue.uppercased())
        - Coach Energy Level: \(preferences.coachEnergy.rawValue.uppercased())
        - Target Pace: \(formatPace(preferences.targetPaceMinPerKm)) min/km
        - Feedback Frequency: Every \(preferences.feedbackFrequency) km
        
        RACE/TARGET DISTANCE:
        - Race Type: \(preferences.targetDistance.displayName)
        - Target Distance: \(String(format: "%.1f", targetDistanceKm)) km
        - Current Progress: \(String(format: "%.1f", currentDistanceKm)) km (\(String(format: "%.0f", progressPercent))% complete)
        - Remaining: \(String(format: "%.1f", remainingKm)) km
        - Est. Time to Finish: \(estimatedFinishTimeFormatted) (at current pace)
        
        RACE-SPECIFIC PACING STRATEGY:
        \(preferences.targetDistance.pacingStrategy)
        """
        
        // Personality-specific coaching instructions
        let personalityInstructions: String
        switch preferences.coachPersonality {
        case .strategist:
            personalityInstructions = """
            COACHING STYLE (STRATEGIST):
            - Focus on race strategy and energy management
            - Give tactical advice: "conserve now, push later"
            - Segment planning: "next 500m steady, then assess"
            - Data-driven pacing decisions
            """
        case .pacer:
            personalityInstructions = """
            COACHING STYLE (PACER):
            - Focus on form and biomechanics
            - Breathing patterns, cadence cues (180 steps/min)
            - Stride efficiency, posture checks
            - Technical coaching over motivation
            """
        case .finisher:
            personalityInstructions = """
            COACHING STYLE (FINISHER):
            - Focus on mental strength and motivation
            - "Dig deep", "You've got this!" energy
            - Celebrate milestones and progress
            - Push through fatigue with encouragement
            """
        }
        
        // Energy level instructions
        let energyInstructions: String
        switch preferences.coachEnergy {
        case .low:
            energyInstructions = "ENERGY: Calm, meditative, minimal words. Supportive but quiet."
        case .medium:
            energyInstructions = "ENERGY: Balanced, positive, professional coach vibe."
        case .high:
            energyInstructions = "ENERGY: HIGH! Punchy, motivating, short bursts of power!"
        }
        
        // Language instructions
        let languageInstructions: String
        if preferences.language != .english {
            languageInstructions = """
            
            ⚠️ CRITICAL LANGUAGE REQUIREMENT:
            Generate ALL coaching output in \(preferences.language.displayName).
            The runner prefers \(preferences.language.displayName) language.
            Adapt coaching cues and terminology to be natural in \(preferences.language.displayName).
            """
        } else {
            languageInstructions = ""
        }
        
        return """
        ============================================================================
        RUNNING PERFORMANCE ANALYSIS REQUEST
        ============================================================================
        
        \(userPreferencesSection)
        
        \(personalityInstructions)
        
        \(energyInstructions)
        \(languageInstructions)
        
        ============================================================================
        
        CURRENT RUN STATE:
        - Distance: \(String(format: "%.2f", snapshot.currentDistance / 1000)) km
        - Elapsed time: \(Int(snapshot.elapsedTime / 60)) minutes
        - Current pace: \(formatPace(snapshot.currentPace)) min/km
        - Target pace: \(formatPace(snapshot.targetPace)) min/km
        - Pace deviation: \(String(format: "%.1f", snapshot.paceDeviation))% (\(snapshot.paceDeviation > 0 ? "slower" : "faster") than target)
        - Target status: \(targetStatus.description)
        
        \(hrDataSection)
        
        \(intervalDataSection)
        
        FATIGUE LEVEL: \(snapshot.fatigueLevel.rawValue.uppercased())
        
        HR DRIFT DATA (Physiological Sustainability):
        \(buildHRDriftDataSection(snapshot: snapshot))
        
        \(similarRunsSection)
        
        MEM0 PERSONALIZED INSIGHTS:
        \(mem0Insights)
        
        ============================================================================
        ANALYSIS TASKS
        ============================================================================
        
        Generate a CONSOLIDATED performance analysis with these 4 core sections:
        
        1. PERFORMANCE ANALYSIS (Pace + Intervals + Trends):
           - Current pace vs target with specific numbers
           - Pace trend (improving/stable/declining/erratic)
           - Interval progression and consistency
           - Target status assessment (on-track/behind/ahead)
           - Split analysis (first half vs second half if applicable)
        
        2. PHYSIOLOGY ANALYSIS (HR + Zones + Drift - Combined):
           - Zone distribution and efficiency
           - HR trend and stability
           - HR drift patterns and sustainability
           - Zone-pace correlation
           - Physiological cost assessment
           - HR headroom or maxed out status
        
        3. COACH'S PERSPECTIVE (Intervals Only - Combined Insights):
           - Answer the 5 critical questions:
             * Is effort rising faster than distance?
             * Is pace being paid for too early?
             * Is this discomfort expected or premature?
             * Would this feel okay 5km later?
             * Is the runner borrowing from the finish?
           - Apply philosophy: "controlled early, honest middle, earned end"
           - Run phase assessment (early/middle/late)
           - Trade-off evaluation (cost, timing, sustainability, control, future impact)
           - Runner's wisdom checks (early comfort, cumulative fatigue, etc.)
        
        4. QUALITY & RISKS (Combined):
           - Running quality score (0-100) with key indicators
           - Injury risk signals (if any)
           - Form efficiency assessment
           - Biomechanical signals
        
        5. ADAPTIVE MICROSTRATEGY:
           - Specific tactical plan for next 500m-1km
           - Exact pace adjustments, zone targets, form cues
           - Actionable, immediate coaching cues
        
        6. SIMILAR RUNS CONTEXT:
           - Comparison to past runs
           - Historical patterns and insights
        
        7. OVERALL RECOMMENDATION:
           - Safety first, then target achievement
           - Clear, actionable next steps
        
        ============================================================================
        OUTPUT FORMAT
        ============================================================================
        
        Return your analysis as a JSON object with these exact keys:
        {
            "performanceAnalysis": "...",
            "physiologyAnalysis": "...",
            "coachPerspective": "...",
            "qualityAndRisks": "...",
            "adaptiveMicrostrategy": "...",
            "similarRunsContext": "...",
            "overallRecommendation": "..."
        }
        
        Be specific, use actual numbers, reference the data provided.
        Write like an elite coach analyzing their athlete's performance.
        """
    }
    
    private func buildZonePaceCorrelation(snapshot: PerformanceSnapshot) -> String {
        var correlations: [String] = []
        for zone in 1...5 {
            if let pace = snapshot.zoneAveragePace[zone], pace > 0 {
                correlations.append("  - Zone \(zone): \(formatPace(pace)) min/km")
            }
        }
        return correlations.isEmpty ? "  No zone-pace data yet" : correlations.joined(separator: "\n")
    }
    
    // MARK: - AI Response Parser
    
    private func parseAIAnalysisResponse(content: String, analysisData: AnalysisData) -> RAGAnalysisResult {
        // Try to parse JSON response
        if let jsonData = content.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
            
            // Try new consolidated structure first, fallback to old structure for compatibility
            let emptyResult = emptyRAGAnalysisResult(targetStatus: analysisData.targetStatus)
            let performanceAnalysis = json["performanceAnalysis"] as? String ?? buildConsolidatedPerformanceAnalysis(snapshot: analysisData.snapshot, aiAnalysis: emptyResult)
            let physiologyAnalysis = json["physiologyAnalysis"] as? String ?? buildConsolidatedPhysiologyAnalysis(snapshot: analysisData.snapshot, aiAnalysis: emptyResult)
            let coachPerspective = json["coachPerspective"] as? String ?? buildConsolidatedCoachPerspective(snapshot: analysisData.snapshot, targetStatus: analysisData.targetStatus, aiAnalysis: emptyResult)
            let qualityAndRisks = json["qualityAndRisks"] as? String ?? buildConsolidatedQualityAndRisks(snapshot: analysisData.snapshot, aiAnalysis: emptyResult)
            let adaptiveMicrostrategy = json["adaptiveMicrostrategy"] as? String ?? "Strategy unavailable"
            let similarRunsContext = json["similarRunsContext"] as? String ?? "Context unavailable"
            let overallRecommendation = json["overallRecommendation"] as? String ?? "Recommendation unavailable"
            
            // Build individual components
            let intervalTrends = buildIntervalTrendsAnalysis(snapshot: analysisData.snapshot)
            let hrVariationAnalysis = buildHRVariationAnalysis(snapshot: analysisData.snapshot)
            let runningQualityAssessment = buildRunningQualityAssessment(snapshot: analysisData.snapshot)
            let heartZoneAnalysis = buildHeartZoneAnalysis(snapshot: analysisData.snapshot)
            let injuryRiskSignals = detectInjuryRiskSignals(snapshot: analysisData.snapshot)
            
            return RAGAnalysisResult(
                targetStatus: analysisData.targetStatus,
                performanceAnalysis: performanceAnalysis,
                physiologyAnalysis: physiologyAnalysis,
                coachPerspective: coachPerspective,
                qualityAndRisks: qualityAndRisks,
                adaptiveMicrostrategy: adaptiveMicrostrategy,
                similarRunsContext: similarRunsContext,
                overallRecommendation: overallRecommendation,
                intervalTrends: intervalTrends,
                hrVariationAnalysis: hrVariationAnalysis,
                runningQualityAssessment: runningQualityAssessment,
                heartZoneAnalysis: heartZoneAnalysis,
                injuryRiskSignals: injuryRiskSignals
            )
        }
        
        // Fallback: try to extract sections from plain text
        return parsePlainTextAnalysis(content: content, analysisData: analysisData)
    }
    
    private func parsePlainTextAnalysis(content: String, analysisData: AnalysisData) -> RAGAnalysisResult {
        // Simple fallback parser for non-JSON responses
        let lines = content.components(separatedBy: .newlines)
        var sections: [String: String] = [:]
        var currentSection: String?
        var currentContent: [String] = []
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            
            // Check if this is a section header
            if trimmed.uppercased().contains("PERFORMANCE ANALYSIS") {
                if let section = currentSection {
                    sections[section] = currentContent.joined(separator: "\n")
                }
                currentSection = "performanceAnalysis"
                currentContent = []
            } else if trimmed.uppercased().contains("HEART ZONE") {
                if let section = currentSection {
                    sections[section] = currentContent.joined(separator: "\n")
                }
                currentSection = "heartZoneAnalysis"
                currentContent = []
            } else if trimmed.uppercased().contains("INTERVAL") {
                if let section = currentSection {
                    sections[section] = currentContent.joined(separator: "\n")
                }
                currentSection = "intervalTrends"
                currentContent = []
            } else if trimmed.uppercased().contains("HR VARIATION") || trimmed.uppercased().contains("HEART RATE") {
                if let section = currentSection {
                    sections[section] = currentContent.joined(separator: "\n")
                }
                currentSection = "hrVariationAnalysis"
                currentContent = []
            } else if trimmed.uppercased().contains("QUALITY") {
                if let section = currentSection {
                    sections[section] = currentContent.joined(separator: "\n")
                }
                currentSection = "runningQualityAssessment"
                currentContent = []
            } else if trimmed.uppercased().contains("INJURY") {
                if let section = currentSection {
                    sections[section] = currentContent.joined(separator: "\n")
                }
                currentSection = "injuryRiskSignals"
                currentContent = []
            } else if trimmed.uppercased().contains("MICROSTRATEGY") || trimmed.uppercased().contains("STRATEGY") {
                if let section = currentSection {
                    sections[section] = currentContent.joined(separator: "\n")
                }
                currentSection = "adaptiveMicrostrategy"
                currentContent = []
            } else if trimmed.uppercased().contains("SIMILAR RUNS") {
                if let section = currentSection {
                    sections[section] = currentContent.joined(separator: "\n")
                }
                currentSection = "similarRunsContext"
                currentContent = []
            } else if trimmed.uppercased().contains("RECOMMENDATION") || trimmed.uppercased().contains("OVERALL") {
                if let section = currentSection {
                    sections[section] = currentContent.joined(separator: "\n")
                }
                currentSection = "overallRecommendation"
                currentContent = []
            } else if let section = currentSection {
                currentContent.append(trimmed)
            }
        }
        
        // Save last section
        if let section = currentSection {
            sections[section] = currentContent.joined(separator: "\n")
        }
        
        // Build consolidated sections with fallbacks
        let emptyResult = emptyRAGAnalysisResult(targetStatus: analysisData.targetStatus)
        let injurySignals = sections["injuryRiskSignals"]?.components(separatedBy: ";").filter { !$0.isEmpty } ?? detectInjuryRiskSignals(snapshot: analysisData.snapshot)
        
        // Build individual components
        let intervalTrends = sections["intervalTrends"] ?? buildIntervalTrendsAnalysis(snapshot: analysisData.snapshot)
        let hrVariationAnalysis = sections["hrVariationAnalysis"] ?? buildHRVariationAnalysis(snapshot: analysisData.snapshot)
        let runningQualityAssessment = sections["runningQualityAssessment"] ?? buildRunningQualityAssessment(snapshot: analysisData.snapshot)
        let heartZoneAnalysis = sections["heartZoneAnalysis"] ?? buildHeartZoneAnalysis(snapshot: analysisData.snapshot)
        
        return RAGAnalysisResult(
            targetStatus: analysisData.targetStatus,
            performanceAnalysis: sections["performanceAnalysis"] ?? buildConsolidatedPerformanceAnalysis(snapshot: analysisData.snapshot, aiAnalysis: emptyResult),
            physiologyAnalysis: sections["physiologyAnalysis"] ?? buildConsolidatedPhysiologyAnalysis(snapshot: analysisData.snapshot, aiAnalysis: emptyResult),
            coachPerspective: sections["coachPerspective"] ?? buildConsolidatedCoachPerspective(snapshot: analysisData.snapshot, targetStatus: analysisData.targetStatus, aiAnalysis: emptyResult),
            qualityAndRisks: sections["qualityAndRisks"] ?? buildConsolidatedQualityAndRisks(snapshot: analysisData.snapshot, aiAnalysis: emptyResult),
            adaptiveMicrostrategy: sections["adaptiveMicrostrategy"] ?? "Strategy unavailable",
            similarRunsContext: sections["similarRunsContext"] ?? "Context unavailable",
            overallRecommendation: sections["overallRecommendation"] ?? "Recommendation unavailable",
            intervalTrends: intervalTrends,
            hrVariationAnalysis: hrVariationAnalysis,
            runningQualityAssessment: runningQualityAssessment,
            heartZoneAnalysis: heartZoneAnalysis,
            injuryRiskSignals: injurySignals
        )
    }
    
    // MARK: - Comprehensive Analysis Generation (Fallback)
    
    private func generateComprehensiveAnalysis(
        snapshot: PerformanceSnapshot,
        similarRuns: [SimilarRunResult],
        preferences: UserPreferences.Settings
    ) -> RAGAnalysisResult {
        
        // 1. Target Status
        let targetStatus = calculateTargetStatus(snapshot: snapshot)
        
        // 2-4. Build consolidated sections
        let emptyResult = emptyRAGAnalysisResult(targetStatus: targetStatus)
        let performanceAnalysis = buildConsolidatedPerformanceAnalysis(
            snapshot: snapshot,
            aiAnalysis: emptyResult
        )
        
        let physiologyAnalysis = buildConsolidatedPhysiologyAnalysis(
            snapshot: snapshot,
            aiAnalysis: emptyResult
        )
        
        let coachPerspective = buildConsolidatedCoachPerspective(
            snapshot: snapshot,
            targetStatus: targetStatus,
            aiAnalysis: emptyResult
        )
        
        let qualityAndRisks = buildConsolidatedQualityAndRisks(
            snapshot: snapshot,
            aiAnalysis: emptyResult
        )
        
        // 5. Adaptive Microstrategy
        let adaptiveMicrostrategy = generateAdaptiveMicrostrategy(
            snapshot: snapshot,
            targetStatus: targetStatus
        )
        
        // 6. Similar Runs Context (RAG)
        let similarRunsContext = buildSimilarRunsContext(similarRuns: similarRuns, snapshot: snapshot)
        
        // 7. Overall Recommendation
        let injuryRiskSignals = detectInjuryRiskSignals(snapshot: snapshot)
        let overallRecommendation = generateOverallRecommendation(
            snapshot: snapshot,
            targetStatus: targetStatus,
            injuryRiskSignals: injuryRiskSignals
        )
        
        // Build individual components for backward compatibility
        let intervalTrends = buildIntervalTrendsAnalysis(snapshot: snapshot)
        let hrVariationAnalysis = buildHRVariationAnalysis(snapshot: snapshot)
        let runningQualityAssessment = buildRunningQualityAssessment(snapshot: snapshot)
        let heartZoneAnalysis = buildHeartZoneAnalysis(snapshot: snapshot)
        
        return RAGAnalysisResult(
            targetStatus: targetStatus,
            performanceAnalysis: performanceAnalysis,
            physiologyAnalysis: physiologyAnalysis,
            coachPerspective: coachPerspective,
            qualityAndRisks: qualityAndRisks,
            adaptiveMicrostrategy: adaptiveMicrostrategy,
            similarRunsContext: similarRunsContext,
            overallRecommendation: overallRecommendation,
            intervalTrends: intervalTrends,
            hrVariationAnalysis: hrVariationAnalysis,
            runningQualityAssessment: runningQualityAssessment,
            heartZoneAnalysis: heartZoneAnalysis,
            injuryRiskSignals: injuryRiskSignals
        )
    }
    
    // MARK: - Consolidated Analysis Builders
    
    /// Build consolidated performance analysis (pace + intervals + trends)
    private func buildConsolidatedPerformanceAnalysis(
        snapshot: PerformanceSnapshot,
        aiAnalysis: RAGAnalysisResult
    ) -> String {
        let perfAnalysis = buildPerformanceAnalysis(snapshot: snapshot)
        let intervalTrends = buildIntervalTrendsAnalysis(snapshot: snapshot)
        
        // Combine into one section
        return """
        \(perfAnalysis)
        
        \(intervalTrends)
        """
    }
    
    /// Build consolidated physiology analysis (HR zones + variation + drift)
    private func buildConsolidatedPhysiologyAnalysis(
        snapshot: PerformanceSnapshot,
        aiAnalysis: RAGAnalysisResult
    ) -> String {
        let zoneAnalysis = buildHeartZoneAnalysis(snapshot: snapshot)
        let hrVariation = buildHRVariationAnalysis(snapshot: snapshot)
        let driftAnalysis = buildHRDriftAnalysis(snapshot: snapshot)
        
        // Combine into one section
        return """
        \(zoneAnalysis)
        
        \(hrVariation)
        
        \(driftAnalysis)
        """
    }
    
    /// Build consolidated coach's perspective (runner insights + trade-offs + 5 questions)
    private func buildConsolidatedCoachPerspective(
        snapshot: PerformanceSnapshot,
        targetStatus: TargetStatus,
        aiAnalysis: RAGAnalysisResult
    ) -> String {
        var perspective = ""
        
        // Add the 5 coach's perspective questions (from buildPerformanceAnalysis)
        if !snapshot.completedIntervals.isEmpty {
            let progressPercent = snapshot.targetDistance > 0 ? (snapshot.currentDistance / snapshot.targetDistance) * 100 : 0
            
            perspective += "🧠 COACH'S PERSPECTIVE EVALUATION:\n"
            perspective += "1. Effort vs Distance: \(evaluateEffortVsDistance(snapshot: snapshot))\n"
            perspective += "2. Pace Cost Timing: \(evaluatePaceCostTiming(snapshot: snapshot, progressPercent: progressPercent))\n"
            perspective += "3. Discomfort Assessment: \(evaluateDiscomfortTiming(snapshot: snapshot, progressPercent: progressPercent))\n"
            perspective += "4. Future Projection (5km): \(projectFutureFeeling(snapshot: snapshot))\n"
            perspective += "5. Borrowing Check: \(checkBorrowingFromFinish(snapshot: snapshot, progressPercent: progressPercent))\n"
            perspective += "\n📊 Run Phase: \(assessRunPhase(snapshot: snapshot, progressPercent: progressPercent))\n\n"
        }
        
        // Add runner insights
        let runnerInsights = buildRunnerInsights(snapshot: snapshot, targetStatus: targetStatus)
        perspective += "🏃‍♂️ RUNNER'S WISDOM:\n\(runnerInsights)\n\n"
        
        // Add trade-off evaluation
        let tradeOffs = buildTradeOffAnalysis(snapshot: snapshot, targetStatus: targetStatus)
        perspective += "⚖️ TRADE-OFF EVALUATION:\n\(tradeOffs)"
        
        return perspective
    }
    
    /// Build consolidated quality and risks
    private func buildConsolidatedQualityAndRisks(
        snapshot: PerformanceSnapshot,
        aiAnalysis: RAGAnalysisResult
    ) -> String {
        let quality = buildRunningQualityAssessment(snapshot: snapshot)
        let risks = detectInjuryRiskSignals(snapshot: snapshot)
        
        var combined = quality
        
        if !risks.isEmpty {
            combined += "\n\n⚠️ INJURY RISK SIGNALS:\n"
            combined += risks.map { "• \($0)" }.joined(separator: "\n")
        } else {
            combined += "\n\n✅ No injury risk signals detected"
        }
        
        return combined
    }
    
    // MARK: - Analysis Components
    
    /// Calculate target status based on:
    /// 1. Average pace (calculated from elapsed time and distance) vs target pace
    /// 2. Actual distance vs expected distance at target pace for elapsed time
    /// If average pace is faster than target AND actual distance > expected distance: AHEAD
    /// If average pace is slower than target AND actual distance < expected distance: BEHIND
    private func calculateTargetStatus(snapshot: PerformanceSnapshot) -> TargetStatus {
        let actualDistanceKm = snapshot.currentDistance / 1000.0
        let targetDistanceKm = snapshot.targetDistance / 1000.0
        let elapsedTimeMinutes = snapshot.elapsedTime / 60.0 // Convert seconds to minutes
        
        // Calculate average pace from elapsed time and distance
        // Average pace = elapsed time (minutes) / distance (km) = min/km
        let averagePace = actualDistanceKm > 0 ? elapsedTimeMinutes / actualDistanceKm : snapshot.currentPace
        
        // Calculate expected distance at target pace for elapsed time
        // Expected distance = elapsed time (minutes) / target pace (min/km) = km
        let expectedDistanceKm = snapshot.targetPace > 0 ? elapsedTimeMinutes / snapshot.targetPace : 0
        
        // If runner has already completed target distance, they're beyond target (good)
        if targetDistanceKm > 0 && actualDistanceKm >= targetDistanceKm {
            let beyondTarget = actualDistanceKm - targetDistanceKm
            let beyondPercent = (beyondTarget / targetDistanceKm) * 100
            
            if beyondPercent > 15 {
                return .wayAhead(deviation: beyondPercent)
            } else if beyondPercent > 5 {
                return .slightlyAhead(deviation: beyondPercent)
            } else {
                return .onTrack(deviation: beyondPercent)
            }
        }
        
        // Compare average pace vs target pace
        // Lower pace (min/km) = faster, so if averagePace < targetPace, runner is faster
        let paceComparison = snapshot.targetPace > 0 ? averagePace < snapshot.targetPace : false
        
        // Calculate distance deviation
        // If actualDistance > expectedDistance: runner is AHEAD (faster pace = more distance covered)
        // If actualDistance < expectedDistance: runner is BEHIND (slower pace = less distance covered)
        // Positive deviation = ahead (good), Negative deviation = behind (bad)
        let distanceDeviation = expectedDistanceKm > 0 ? ((actualDistanceKm - expectedDistanceKm) / expectedDistanceKm) * 100 : 0
        
        // Determine status based on both average pace comparison and distance deviation
        // Both should agree: faster pace + more distance = AHEAD, slower pace + less distance = BEHIND
        if abs(distanceDeviation) <= 5 {
            return .onTrack(deviation: abs(distanceDeviation))
        } else if distanceDeviation < -15 || (!paceComparison && distanceDeviation < -5) {
            // Negative deviation = behind (slower pace) OR average pace slower than target
            return .wayBehind(deviation: abs(distanceDeviation))
        } else if distanceDeviation < -5 {
            // Negative deviation = slightly behind
            return .slightlyBehind(deviation: abs(distanceDeviation))
        } else if distanceDeviation > 15 || (paceComparison && distanceDeviation > 5) {
            // Positive deviation = way ahead (faster pace) OR average pace faster than target
            return .wayAhead(deviation: distanceDeviation)
        } else {
            // Positive deviation = slightly ahead
            return .slightlyAhead(deviation: distanceDeviation)
        }
    }
    
    private func buildPerformanceAnalysis(snapshot: PerformanceSnapshot) -> String {
        let currentPaceStr = formatPace(snapshot.currentPace)
        let targetPaceStr = formatPace(snapshot.targetPace)
        let distanceKm = snapshot.currentDistance / 1000
        let elapsedMin = Int(snapshot.elapsedTime / 60)
        let targetDistanceKm = snapshot.targetDistance / 1000
        let progressPercent = targetDistanceKm > 0 ? (distanceKm / targetDistanceKm) * 100 : 0
        
        // Target Awareness: on-track / slightly-behind / way-behind based on DISTANCE achieved vs expected at target pace
        let targetStatus = calculateTargetStatus(snapshot: snapshot)
        
        var analysis = "Current: \(currentPaceStr) min/km | Target: \(targetPaceStr) min/km\n"
        analysis += "Distance: \(String(format: "%.2f", distanceKm)) km | Target distance: \(String(format: "%.2f", targetDistanceKm)) km\n"
        
        // Check if runner has completed target distance
        if targetDistanceKm > 0 && distanceKm >= targetDistanceKm {
            let beyondTarget = distanceKm - targetDistanceKm
            analysis += "✅ Beyond target: +\(String(format: "%.2f", beyondTarget)) km (completed target and continuing)\n"
        } else {
            // Calculate expected distance at target pace for elapsed time
            let elapsedTimeHours = snapshot.elapsedTime / 3600.0
            let expectedDistanceKm = (elapsedTimeHours * 60.0) / snapshot.targetPace
            let distanceGap = distanceKm - expectedDistanceKm
            
            analysis += "Expected at target pace: \(String(format: "%.2f", expectedDistanceKm)) km\n"
            if abs(distanceGap) > 0.05 {
                let gapStr = distanceGap > 0 ? "+\(String(format: "%.2f", distanceGap))" : String(format: "%.2f", distanceGap)
                analysis += "Distance gap: \(gapStr) km (\(distanceGap > 0 ? "ahead" : "behind") on distance)\n"
            }
        }
        
        analysis += "Pace deviation: \(String(format: "%.1f", snapshot.paceDeviation))%\n"
        analysis += "Target status: \(targetStatus.description)\n"
        analysis += "Pace trend: \(snapshot.pacetrend.rawValue.uppercased())\n"
        
        // Add coach's perspective questions (INTERVALS ONLY - when we have intervals)
        if !snapshot.completedIntervals.isEmpty {
            analysis += "\n🧠 COACH'S PERSPECTIVE EVALUATION:\n"
            
            // 1. Is effort rising faster than distance?
            let effortVsDistance = evaluateEffortVsDistance(snapshot: snapshot)
            analysis += "1. Effort vs Distance: \(effortVsDistance)\n"
            
            // 2. Is pace being paid for too early?
            let paceCostTiming = evaluatePaceCostTiming(snapshot: snapshot, progressPercent: progressPercent)
            analysis += "2. Pace Cost Timing: \(paceCostTiming)\n"
            
            // 3. Is this discomfort expected or premature?
            let discomfortAssessment = evaluateDiscomfortTiming(snapshot: snapshot, progressPercent: progressPercent)
            analysis += "3. Discomfort Assessment: \(discomfortAssessment)\n"
            
            // 4. Would this feel okay 5km later?
            let futureProjection = projectFutureFeeling(snapshot: snapshot)
            analysis += "4. Future Projection (5km): \(futureProjection)\n"
            
            // 5. Is runner borrowing from finish?
            let borrowingCheck = checkBorrowingFromFinish(snapshot: snapshot, progressPercent: progressPercent)
            analysis += "5. Borrowing Check: \(borrowingCheck)\n"
            
            // Overall phase assessment
            let phaseAssessment = assessRunPhase(snapshot: snapshot, progressPercent: progressPercent)
            analysis += "\n📊 Run Phase: \(phaseAssessment)"
        }
        
        return analysis
    }
    
    // MARK: - Coach's Perspective Evaluation Functions (INTERVALS ONLY)
    
    /// 1. Is effort rising faster than distance?
    private func evaluateEffortVsDistance(snapshot: PerformanceSnapshot) -> String {
        guard snapshot.kmDriftData.count >= 2 else {
            return "Insufficient data - need 2+ km"
        }
        
        let recentKm = snapshot.kmDriftData.suffix(2)
        let driftChange = (recentKm.last?.driftAtKmEnd ?? 0) - (recentKm.first?.driftAtKmStart ?? 0)
        let distanceChange = 1.0 // 1 km per interval
        
        // Effort rising faster if drift increases >2% per km
        if driftChange > 2.0 {
            return "⚠️ Effort rising \(String(format: "%.1f", driftChange))% faster than distance - unsustainable"
        } else if driftChange > 1.0 {
            return "Effort rising slightly faster (\(String(format: "%.1f", driftChange))%) - monitor"
        } else if driftChange < -0.5 {
            return "Effort stable/improving - good progression"
        } else {
            return "Effort matches distance progression - sustainable"
        }
    }
    
    /// 2. Is pace being paid for too early?
    private func evaluatePaceCostTiming(snapshot: PerformanceSnapshot, progressPercent: Double) -> String {
        let isEarlyPhase = progressPercent < 30
        let isMidPhase = progressPercent >= 30 && progressPercent < 70
        
        guard let currentZone = snapshot.currentZone else {
            return "No HR data - cannot assess"
        }
        
        if isEarlyPhase {
            if currentZone >= 4 {
                return "⚠️ Paying for pace too early - Z\(currentZone) should come later"
            } else if let drift = snapshot.currentDrift, drift.driftPercent > 5.0 {
                return "⚠️ High drift (\(String(format: "%.1f", drift.driftPercent))%) too early - cost should come later"
            } else {
                return "Pace cost appropriate for early phase"
            }
        } else if isMidPhase {
            if currentZone >= 4 {
                return "High effort (Z\(currentZone)) in mid-phase - acceptable if sustainable"
            } else {
                return "Pace cost appropriate for mid-phase"
            }
        } else {
            // Late phase - high effort is expected
            return "Pace cost appropriate for late phase"
        }
    }
    
    /// 3. Is this discomfort expected or premature?
    private func evaluateDiscomfortTiming(snapshot: PerformanceSnapshot, progressPercent: Double) -> String {
        let isEarlyPhase = progressPercent < 30
        let isMidPhase = progressPercent >= 30 && progressPercent < 70
        let isLatePhase = progressPercent >= 70
        
        let discomfortLevel: String
        if let zone = snapshot.currentZone {
            if zone >= 4 {
                discomfortLevel = "high"
            } else if zone == 3 {
                discomfortLevel = "moderate"
            } else {
                discomfortLevel = "low"
            }
        } else {
            return "No HR data - cannot assess"
        }
        
        let driftLevel: String
        if let drift = snapshot.currentDrift {
            if drift.driftPercent > 8.0 {
                driftLevel = "high"
            } else if drift.driftPercent > 5.0 {
                driftLevel = "moderate"
            } else {
                driftLevel = "low"
            }
        } else {
            driftLevel = "unknown"
        }
        
        if isEarlyPhase {
            if discomfortLevel == "high" || driftLevel == "high" {
                return "⚠️ Premature discomfort - should feel easier now (early phase)"
            } else {
                return "Discomfort level expected for early phase"
            }
        } else if isMidPhase {
            if discomfortLevel == "high" && driftLevel == "high" {
                return "⚠️ High discomfort in mid-phase - may struggle later"
            } else {
                return "Discomfort level expected for mid-phase"
            }
        } else {
            // Late phase - high discomfort is expected
            return "Discomfort expected at this stage (late phase)"
        }
    }
    
    /// 4. Would this feel okay 5km later?
    private func projectFutureFeeling(snapshot: PerformanceSnapshot) -> String {
        guard let currentZone = snapshot.currentZone else {
            return "No HR data - cannot project"
        }
        
        // Project current state forward 5km
        if currentZone >= 4 {
            return "⚠️ Won't feel okay 5km later - Z\(currentZone) unsustainable"
        }
        
        if let drift = snapshot.currentDrift {
            if drift.driftPercent > 8.0 {
                return "⚠️ Won't feel okay 5km later - high drift (\(String(format: "%.1f", drift.driftPercent))%) will worsen"
            } else if drift.driftPercent > 5.0 && snapshot.pacetrend == .stable {
                return "⚠️ May struggle 5km later - drift rising despite stable pace"
            }
        }
        
        // Check drift acceleration
        if snapshot.kmDriftData.count >= 2 {
            let recentDrift = snapshot.kmDriftData.last?.driftAtKmEnd ?? 0
            let earlierDrift = snapshot.kmDriftData[snapshot.kmDriftData.count - 2].driftAtKmEnd
            let driftAcceleration = recentDrift - earlierDrift
            
            if driftAcceleration > 1.5 {
                return "⚠️ Won't feel okay 5km later - drift accelerating (\(String(format: "%.1f", driftAcceleration))% per km)"
            }
        }
        
        if currentZone <= 2 {
            return "Will feel okay 5km later - low effort sustainable"
        } else if currentZone == 3 {
            return "Should feel okay 5km later - moderate effort sustainable"
        } else {
            return "Effort level sustainable for 5km more"
        }
    }
    
    /// 5. Is runner borrowing from finish?
    private func checkBorrowingFromFinish(snapshot: PerformanceSnapshot, progressPercent: Double) -> String {
        let isEarlyPhase = progressPercent < 30
        let isMidPhase = progressPercent >= 30 && progressPercent < 50
        
        guard let currentZone = snapshot.currentZone else {
            return "No HR data - cannot assess"
        }
        
        // Check if ahead of target with high effort early
        let isAhead = snapshot.paceDeviation < -5 // Faster than target
        let isHighEffort = currentZone >= 4
        
        if isEarlyPhase && isAhead && isHighEffort {
            return "⚠️ Borrowing from finish - ahead with high effort (Z\(currentZone)) too early"
        }
        
        if isEarlyPhase && isHighEffort {
            if let drift = snapshot.currentDrift, drift.driftPercent > 5.0 {
                return "⚠️ Borrowing from finish - high effort + drift (\(String(format: "%.1f", drift.driftPercent))%) early"
            }
        }
        
        if isMidPhase && isAhead && isHighEffort {
            return "⚠️ May be borrowing - ahead with high effort in mid-phase"
        }
        
        if isAhead && currentZone <= 2 {
            return "Ahead appropriately - low effort, not borrowing"
        } else if !isAhead && isHighEffort {
            return "High effort but behind - not borrowing, may be struggling"
        } else {
            return "Pacing appropriately - not borrowing from finish"
        }
    }
    
    /// Assess which phase of the run (controlled/honest/earned)
    private func assessRunPhase(snapshot: PerformanceSnapshot, progressPercent: Double) -> String {
        let isEarlyPhase = progressPercent < 30
        let isMidPhase = progressPercent >= 30 && progressPercent < 70
        let isLatePhase = progressPercent >= 70
        
        guard let currentZone = snapshot.currentZone else {
            return "Unknown phase (no HR data)"
        }
        
        if isEarlyPhase {
            // Should feel CONTROLLED
            if currentZone <= 2 {
                return "EARLY: Feeling CONTROLLED ✓ (Z\(currentZone) - appropriate)"
            } else if currentZone >= 4 {
                return "EARLY: NOT controlled ⚠️ (Z\(currentZone) - too high, should be easier)"
            } else {
                return "EARLY: Moderately controlled (Z\(currentZone) - acceptable)"
            }
        } else if isMidPhase {
            // Should feel HONEST
            if currentZone >= 3 && currentZone <= 4 {
                return "MIDDLE: Feeling HONEST ✓ (Z\(currentZone) - effort matches pace)"
            } else if currentZone >= 5 {
                return "MIDDLE: Too intense ⚠️ (Z\(currentZone) - may not sustain)"
            } else {
                return "MIDDLE: Honest but could push (Z\(currentZone) - sustainable)"
            }
        } else {
            // Should feel EARNED
            if currentZone >= 3 {
                return "LATE: Feeling EARNED ✓ (Z\(currentZone) - can push, reserves preserved)"
            } else {
                return "LATE: Could push harder (Z\(currentZone) - may have conserved too much)"
            }
        }
    }
    
    private func buildHeartZoneAnalysis(snapshot: PerformanceSnapshot) -> String {
        guard let currentZone = snapshot.currentZone else {
            return "Heart rate data not available"
        }
        
        var analysis = "Current zone: Z\(currentZone)"
        
        if let currentHR = snapshot.currentHR {
            analysis += " (\(Int(currentHR)) BPM)"
        }
        
        // Zone distribution (zone trends)
        analysis += "\nZone distribution: "
        let zoneStrs = (1...5).compactMap { zone -> String? in
            guard let pct = snapshot.zonePercentages[zone], pct > 0 else { return nil }
            return "Z\(zone): \(String(format: "%.0f", pct))%"
        }
        analysis += zoneStrs.joined(separator: ", ")
        
        // Zone-pace correlation
        let zonePaceStrs = (1...5).compactMap { zone -> String? in
            guard let pace = snapshot.zoneAveragePace[zone], pace > 0 else { return nil }
            return "Z\(zone): \(formatPace(pace))"
        }
        if !zonePaceStrs.isEmpty {
            analysis += "\nZone-pace: " + zonePaceStrs.joined(separator: ", ")
        }
        
        // Zone Guidance: Adaptive recommendations based on target and current state
        let zoneGuidance = buildZoneGuidance(snapshot: snapshot)
        if !zoneGuidance.isEmpty {
            analysis += "\n\n🎯 Zone Guidance: \(zoneGuidance)"
        }
        
        return analysis
    }
    
    /// Zone Guidance: Adaptive recommendations based on target and current state
    private func buildZoneGuidance(snapshot: PerformanceSnapshot) -> String {
        guard let currentZone = snapshot.currentZone else {
            return ""
        }
        
        let targetStatus = calculateTargetStatus(snapshot: snapshot)
        let progressPercent = snapshot.targetDistance > 0 ? (snapshot.currentDistance / snapshot.targetDistance) * 100 : 0
        let isEarlyPhase = progressPercent < 30
        let isMidPhase = progressPercent >= 30 && progressPercent < 70
        let isLatePhase = progressPercent >= 70
        
        var guidance: [String] = []
        
        // Guidance based on target status
        switch targetStatus {
        case .onTrack:
            if currentZone <= 2 {
                guidance.append("Optimal: Z\(currentZone) is perfect for maintaining target pace")
            } else if currentZone == 3 {
                guidance.append("Good: Z3 is sustainable for target pace")
            } else if currentZone >= 4 {
                guidance.append("⚠️ High effort (Z\(currentZone)) - consider easing to Z3 to conserve energy")
            }
            
        case .slightlyBehind(let deviation):
            if currentZone <= 2 {
                guidance.append("Can push harder: Z\(currentZone) is too easy - move to Z3 to catch up")
            } else if currentZone == 3 {
                guidance.append("Good adjustment: Z3 is appropriate for catching up")
            } else if currentZone >= 4 {
                guidance.append("⚠️ High effort (Z\(currentZone)) but still behind - focus on form efficiency")
            }
            
        case .wayBehind(let deviation):
            if currentZone <= 3 {
                guidance.append("⚠️ Need more effort: Z\(currentZone) is too low - push to Z4 if sustainable")
            } else {
                guidance.append("High effort (Z\(currentZone)) but still behind - may need to accept current pace")
            }
            
        case .slightlyAhead(let deviation):
            if currentZone >= 4 {
                guidance.append("⚠️ Ease back: Z\(currentZone) is too high - drop to Z3 to conserve energy")
            } else if currentZone == 3 {
                guidance.append("Good: Z3 is sustainable while ahead")
            } else {
                guidance.append("Optimal: Z\(currentZone) is perfect while ahead - maintain")
            }
            
        case .wayAhead(let deviation):
            if currentZone >= 3 {
                guidance.append("⚠️ Ease significantly: Z\(currentZone) is too high - drop to Z2 to conserve")
            } else {
                guidance.append("Perfect: Z\(currentZone) is ideal while way ahead - maintain")
            }
        }
        
        // Phase-specific guidance
        if isEarlyPhase && currentZone >= 4 {
            guidance.append("⚠️ Early phase: Z\(currentZone) is too high - should be Z1-Z2 early")
        } else if isLatePhase && currentZone <= 2 {
            guidance.append("Late phase: Can push harder - Z\(currentZone) is too low, move to Z3-Z4")
        }
        
        // HR headroom assessment
        if let maxHR = snapshot.maxHR, let currentHR = snapshot.currentHR {
            let pctOfMax = (currentHR / maxHR) * 100
            if pctOfMax < 70 {
                guidance.append("HR headroom: \(String(format: "%.0f", pctOfMax))% of max - can push harder")
            } else if pctOfMax > 90 {
                guidance.append("⚠️ Near max HR: \(String(format: "%.0f", pctOfMax))% of max - at limit")
            }
        }
        
        return guidance.joined(separator: " | ")
    }
    
    private func buildIntervalTrendsAnalysis(snapshot: PerformanceSnapshot) -> String {
        guard !snapshot.completedIntervals.isEmpty else {
            return "No completed intervals yet"
        }
        
        var analysis = "Intervals completed: \(snapshot.completedIntervals.count)\n"
        
        // Show all intervals with pace progression
        let intervalStrs = snapshot.completedIntervals.map { interval in
            "Km \(interval.kilometer): \(formatPace(interval.pace))"
        }
        analysis += "Pace progression: " + intervalStrs.joined(separator: " → ")
        
        // Enhanced trend analysis with acceleration detection
        analysis += "\nTrend: \(snapshot.pacetrend.rawValue.uppercased())"
        
        // Detect pace acceleration/deceleration pattern
        if snapshot.completedIntervals.count >= 3 {
            let recent3 = Array(snapshot.completedIntervals.suffix(3))
            let paceChanges = zip(recent3.dropFirst(), recent3).map { $0.pace - $1.pace }
            
            // Positive = slowing, Negative = speeding up
            let avgChange = paceChanges.reduce(0, +) / Double(paceChanges.count)
            
            if avgChange > 0.15 {
                analysis += " (DECELERATING - pace slowing)"
            } else if avgChange < -0.15 {
                analysis += " (ACCELERATING - pace increasing)"
            } else {
                analysis += " (STABLE)"
            }
            
            // Detect if acceleration/deceleration is consistent
            let allPositive = paceChanges.allSatisfy { $0 > 0 }
            let allNegative = paceChanges.allSatisfy { $0 < 0 }
            if allPositive {
                analysis += " - Consistent slowdown detected"
            } else if allNegative {
                analysis += " - Consistent speedup detected"
            }
        }
        
        // Calculate consistency with enhanced metrics
        if snapshot.completedIntervals.count >= 2 {
            let paces = snapshot.completedIntervals.map { $0.pace }
            let avgPace = paces.reduce(0, +) / Double(paces.count)
            let variance = paces.map { pow($0 - avgPace, 2) }.reduce(0, +) / Double(paces.count)
            let stdDev = sqrt(variance)
            
            // Calculate coefficient of variation (CV) for better assessment
            let cv = (stdDev / avgPace) * 100
            
            if cv < 2.0 {
                analysis += "\nConsistency: EXCELLENT (CV: \(String(format: "%.1f", cv))%)"
            } else if cv < 4.0 {
                analysis += "\nConsistency: GOOD (CV: \(String(format: "%.1f", cv))%)"
            } else if cv < 6.0 {
                analysis += "\nConsistency: MODERATE (CV: \(String(format: "%.1f", cv))%)"
            } else {
                analysis += "\nConsistency: VARIABLE (CV: \(String(format: "%.1f", cv))%)"
            }
            
            // Compare first half vs second half (if enough intervals)
            if snapshot.completedIntervals.count >= 4 {
                let midpoint = snapshot.completedIntervals.count / 2
                let firstHalf = Array(snapshot.completedIntervals.prefix(midpoint))
                let secondHalf = Array(snapshot.completedIntervals.suffix(snapshot.completedIntervals.count - midpoint))
                
                let firstHalfAvg = firstHalf.map { $0.pace }.reduce(0, +) / Double(firstHalf.count)
                let secondHalfAvg = secondHalf.map { $0.pace }.reduce(0, +) / Double(secondHalf.count)
                let splitDiff = secondHalfAvg - firstHalfAvg
                
                if splitDiff < -0.1 {
                    analysis += " | Negative splits: \(String(format: "%.2f", abs(splitDiff))) min/km faster in 2nd half"
                } else if splitDiff > 0.1 {
                    analysis += " | Positive splits: \(String(format: "%.2f", splitDiff)) min/km slower in 2nd half"
                } else {
                    analysis += " | Even splits: consistent pacing"
                }
            }
        }
        
        return analysis
    }
    
    private func buildHRVariationAnalysis(snapshot: PerformanceSnapshot) -> String {
        guard let currentHR = snapshot.currentHR else {
            return "HR data not available"
        }
        
        var analysis = "Current HR: \(Int(currentHR)) BPM"
        
        if let avgHR = snapshot.averageHR {
            let diff = currentHR - avgHR
            analysis += " | Avg: \(Int(avgHR)) BPM"
            analysis += " | Diff: \(diff > 0 ? "+" : "")\(Int(diff))"
        }
        
        if let maxHR = snapshot.maxHR {
            analysis += "\nMax HR: \(Int(maxHR)) BPM"
            let pctOfMax = (currentHR / maxHR) * 100
            analysis += " | Current at \(String(format: "%.0f", pctOfMax))% of max"
        }
        
        analysis += "\nHR trend: \(snapshot.hrTrend.rawValue.uppercased())"
        
        return analysis
    }
    
    private func buildRunningQualityAssessment(snapshot: PerformanceSnapshot) -> String {
        var qualityScore = 100
        var assessments: [String] = []
        
        // Pace consistency
        switch snapshot.pacetrend {
        case .stable:
            assessments.append("✓ Pace consistency: EXCELLENT")
        case .improving:
            assessments.append("✓ Pace consistency: GOOD (negative splits)")
            qualityScore += 5
        case .declining:
            assessments.append("⚠ Pace consistency: DECLINING")
            qualityScore -= 15
        case .erratic:
            assessments.append("⚠ Pace consistency: ERRATIC")
            qualityScore -= 20
        }
        
        // HR efficiency
        switch snapshot.hrTrend {
        case .stable:
            assessments.append("✓ HR efficiency: STABLE")
        case .rising:
            assessments.append("⚠ HR efficiency: CARDIAC DRIFT detected")
            qualityScore -= 10
        case .spiking:
            assessments.append("⚠ HR efficiency: SPIKES detected")
            qualityScore -= 15
        case .recovering:
            assessments.append("✓ HR efficiency: RECOVERING well")
            qualityScore += 5
        }
        
        // Fatigue
        switch snapshot.fatigueLevel {
        case .fresh:
            assessments.append("✓ Fatigue: LOW")
        case .moderate:
            assessments.append("• Fatigue: MODERATE")
        case .high:
            assessments.append("⚠ Fatigue: HIGH")
            qualityScore -= 10
        case .critical:
            assessments.append("⚠ Fatigue: CRITICAL")
            qualityScore -= 20
        }
        
        // Zone efficiency (% in target zone 2-3 for endurance)
        let z2z3Pct = (snapshot.zonePercentages[2] ?? 0) + (snapshot.zonePercentages[3] ?? 0)
        if z2z3Pct > 60 {
            assessments.append("✓ Zone efficiency: OPTIMAL (\(String(format: "%.0f", z2z3Pct))% in Z2-Z3)")
        } else if z2z3Pct > 40 {
            assessments.append("• Zone efficiency: ACCEPTABLE")
        } else {
            assessments.append("⚠ Zone efficiency: SUBOPTIMAL (too much Z4-Z5)")
            qualityScore -= 10
        }
        
        qualityScore = max(0, min(100, qualityScore))
        
        return "Quality Score: \(qualityScore)/100\n" + assessments.joined(separator: "\n")
    }
    
    private func detectInjuryRiskSignals(snapshot: PerformanceSnapshot) -> [String] {
        var signals: [String] = []
        
        // 1. Sudden pace degradation with high HR
        if snapshot.pacetrend == .declining && snapshot.hrTrend == .rising {
            signals.append("Pace declining while HR rising - possible overexertion or strain")
        }
        
        // 2. Erratic pace with high fatigue
        if snapshot.pacetrend == .erratic && snapshot.fatigueLevel == .high {
            signals.append("Erratic pace with high fatigue - form may be breaking down")
        }
        
        // 3. Prolonged time in Zone 5
        if let z5Pct = snapshot.zonePercentages[5], z5Pct > 20 {
            signals.append("Extended time in Zone 5 (\(String(format: "%.0f", z5Pct))%) - high strain")
        }
        
        // 4. HR spiking
        if snapshot.hrTrend == .spiking {
            signals.append("HR spiking - may indicate dehydration or overheating")
        }
        
        // 5. Critical fatigue
        if snapshot.fatigueLevel == .critical {
            signals.append("Critical fatigue level - consider reducing intensity")
        }
        
        // 6. Way behind target with high effort
        if case .wayBehind = calculateTargetStatus(snapshot: snapshot) {
            if let zone = snapshot.currentZone, zone >= 4 {
                signals.append("Pace behind target despite high effort - possible biomechanical issue")
            }
        }
        
        return signals
    }
    
    private func generateAdaptiveMicrostrategy(
        snapshot: PerformanceSnapshot,
        targetStatus: TargetStatus
    ) -> String {
        
        // Generate next 500m-1km tactical plan
        var strategy: String
        
        switch targetStatus {
        case .onTrack:
            strategy = "MAINTAIN: Hold current effort. Focus on breathing rhythm and form."
            if snapshot.fatigueLevel == .moderate || snapshot.fatigueLevel == .high {
                strategy += " Consider a slight ease in the next 500m to bank energy."
            }
            
        case .slightlyBehind(let deviation):
            let secondsToMakeUp = (deviation / 100) * snapshot.targetPace * 60
            strategy = "ADJUST: Increase pace by \(String(format: "%.0f", secondsToMakeUp)) sec/km. "
            if snapshot.currentZone ?? 0 <= 3 {
                strategy += "You have HR headroom - push to Zone 3-4 for next km."
            } else {
                strategy += "HR already elevated - focus on form efficiency instead of raw speed."
            }
            
        case .wayBehind(let deviation):
            strategy = "URGENT RECOVERY: You're \(String(format: "%.0f", deviation))% off target. "
            if snapshot.fatigueLevel == .high || snapshot.fatigueLevel == .critical {
                strategy += "Accept current pace, focus on completion. Recalibrate target for next run."
            } else {
                strategy += "Run-walk strategy: 2 min hard, 30 sec easy for next km to recover pace."
            }
            
        case .slightlyAhead(let deviation):
            strategy = "BANK TIME: You're \(String(format: "%.0f", deviation))% ahead. "
            if snapshot.currentZone ?? 0 >= 4 {
                strategy += "Ease to Zone 3 to conserve energy for final push."
            } else {
                strategy += "Maintain - you're running efficiently. Save energy for strong finish."
            }
            
        case .wayAhead(let deviation):
            strategy = "CONSERVE: You're \(String(format: "%.0f", deviation))% ahead - excellent! "
            strategy += "Ease to Zone 2-3 and focus on enjoying the run. You've already exceeded target."
        }
        
        // Add interval-specific advice
        if snapshot.currentIntervalNumber > 1 {
            strategy += "\n[Km \(snapshot.currentIntervalNumber) focus: "
            switch snapshot.pacetrend {
            case .improving:
                strategy += "Maintain negative split momentum]"
            case .stable:
                strategy += "Keep this consistency]"
            case .declining:
                strategy += "Arrest the slowdown - quick cadence check]"
            case .erratic:
                strategy += "Find your rhythm - steady breathing]"
            }
        }
        
        return strategy
    }
    
    private func buildSimilarRunsContext(similarRuns: [SimilarRunResult], snapshot: PerformanceSnapshot) -> String {
        guard !similarRuns.isEmpty else {
            return "No similar past runs found in history. Building baseline data."
        }
        
        var context = "Found \(similarRuns.count) similar runs:\n"
        
        for (index, run) in similarRuns.prefix(3).enumerated() {
            let distKm = run.distance / 1000
            let paceStr = formatPace(run.pace)
            context += "\(index + 1). \(String(format: "%.1f", distKm))km at \(paceStr)"
            if let similarity = Optional(run.similarity), similarity > 0 {
                context += " (match: \(String(format: "%.0f", similarity * 100))%)"
            }
            context += "\n"
        }
        
        // Compare current run to similar runs
        let avgSimilarPace = similarRuns.map { $0.pace }.reduce(0, +) / Double(similarRuns.count)
        let paceVsSimilar = snapshot.currentPace - avgSimilarPace
        
        if abs(paceVsSimilar) < 0.2 {
            context += "→ Current pace matches your typical performance"
        } else if paceVsSimilar > 0 {
            context += "→ Running slower than similar past runs by \(formatPace(paceVsSimilar))"
        } else {
            context += "→ Running faster than similar past runs by \(formatPace(abs(paceVsSimilar)))"
        }
        
        return context
    }
    
    private func generateOverallRecommendation(
        snapshot: PerformanceSnapshot,
        targetStatus: TargetStatus,
        injuryRiskSignals: [String]
    ) -> String {
        
        // Priority 1: Safety
        if !injuryRiskSignals.isEmpty {
            return "⚠️ SAFETY FIRST: \(injuryRiskSignals.first!) - Consider easing intensity."
        }
        
        // Priority 2: Critical fatigue
        if snapshot.fatigueLevel == .critical {
            return "🛑 HIGH FATIGUE: Reduce intensity or consider stopping. Recovery is important."
        }
        
        // Priority 3: Target-based recommendation
        switch targetStatus {
        case .onTrack:
            return "✅ ON TRACK: Keep this up! You're running well. " + targetStatus.coachingUrgency
        case .slightlyBehind:
            return "📈 PUSH SLIGHTLY: " + targetStatus.coachingUrgency
        case .wayBehind:
            return "🔄 RECALIBRATE: " + targetStatus.coachingUrgency
        case .slightlyAhead:
            return "💪 STRONG RUN: " + targetStatus.coachingUrgency
        case .wayAhead:
            return "🌟 EXCELLENT: " + targetStatus.coachingUrgency
        }
    }
    
    // MARK: - Helpers
    
    private func formatPace(_ paceMinutesPerKm: Double) -> String {
        let minutes = Int(paceMinutesPerKm)
        let seconds = Int((paceMinutesPerKm - Double(minutes)) * 60)
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    private func formatDuration(_ seconds: Double) -> String {
        let totalSeconds = Int(seconds)
        let hours = totalSeconds / 3600
        let mins = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, mins, secs)
        }
        return String(format: "%d:%02d", mins, secs)
    }
    
    // MARK: - HR Drift Calculations
    
    private func calculateHRDriftData(
        intervals: [RunInterval],
        healthManager: HealthManager?,
        elapsedTime: Double
    ) -> ([KmDriftData], DriftSnapshot?) {
        guard let hm = healthManager,
              let currentHR = hm.currentHeartRate,
              let avgHR = hm.averageHeartRate,
              avgHR > 0 else {
            return ([], nil)
        }
        
        // Calculate current drift percentage
        let currentDriftPercent = ((currentHR - avgHR) / avgHR) * 100
        let currentDrift = DriftSnapshot(driftPercent: currentDriftPercent)
        
        // Build per-km drift data
        var kmDriftData: [KmDriftData] = []
        for (index, interval) in intervals.enumerated() {
            // Simplified: use average HR drift for each km
            // In a full implementation, you'd track HR at start/end of each interval
            let km = interval.index
            let driftAtStart = index > 0 ? kmDriftData[index - 1].driftAtKmEnd : 0.0
            let driftAtEnd = currentDriftPercent * Double(km) / max(1.0, Double(intervals.count))
            kmDriftData.append(KmDriftData(
                kilometer: km,
                driftAtKmStart: driftAtStart,
                driftAtKmEnd: driftAtEnd
            ))
        }
        
        return (kmDriftData, currentDrift)
    }
    
    private func buildHRDriftDataSection(snapshot: PerformanceSnapshot) -> String {
        guard !snapshot.kmDriftData.isEmpty else {
            return "HR drift data not available yet."
        }
        
        var section = "Current drift: \(String(format: "%.1f", snapshot.currentDrift?.driftPercent ?? 0))% | Level: \(snapshot.currentDrift?.driftPercent ?? 0 > 5 ? "RISING" : "STABLE")\n\n"
        section += "Per-KM Drift Patterns:\n"
        
        for driftData in snapshot.kmDriftData.suffix(3) {
            let delta = driftData.driftAtKmEnd - driftData.driftAtKmStart
            let pattern = delta > 2.0 ? "Hidden fatigue" : delta > 0.5 ? "Rising" : "Stable"
            section += "  Km \(driftData.kilometer): \(pattern) | Drift: \(String(format: "%.1f", driftData.driftAtKmEnd))% (Δ\(String(format: "%.1f", delta))%)\n"
        }
        
        if let currentDrift = snapshot.currentDrift, currentDrift.driftPercent > 5.0 {
            section += "\n⚠️ Fatigue signal detected\n"
            section += "📈 Drift trend: INCREASING (physiological cost rising)\n"
        }
        
        return section
    }
    
    private func buildHRDriftAnalysis(snapshot: PerformanceSnapshot) -> String {
        guard let currentDrift = snapshot.currentDrift else {
            return "HR drift data not available."
        }
        
        var analysis = "Current drift: \(String(format: "%.1f", currentDrift.driftPercent))% | Level: \(currentDrift.driftPercent > 5 ? "RISING" : "STABLE")\n"
        
        if !snapshot.kmDriftData.isEmpty {
            analysis += "\nPer-KM Drift Patterns:\n"
            for driftData in snapshot.kmDriftData.suffix(3) {
                let delta = driftData.driftAtKmEnd - driftData.driftAtKmStart
                let pattern = delta > 2.0 ? "Hidden fatigue" : delta > 0.5 ? "Rising" : "Stable"
                analysis += "  Km \(driftData.kilometer): \(pattern) | Drift: \(String(format: "%.1f", driftData.driftAtKmEnd))% (Δ\(String(format: "%.1f", delta))%)\n"
            }
        }
        
        if currentDrift.driftPercent > 5.0 {
            analysis += "\n⚠️ Fatigue signal detected\n"
            analysis += "📈 Drift trend: INCREASING (physiological cost rising)\n"
        }
        
        return analysis
    }
    
    private func buildRunnerInsights(snapshot: PerformanceSnapshot, targetStatus: TargetStatus) -> String {
        var insights: [String] = []
        
        // Cost check
        if let currentDrift = snapshot.currentDrift,
           currentDrift.driftPercent > 3.0,
           snapshot.pacetrend == .stable {
            insights.append("⚠️ Cost check: Same pace but HR drift RISING (\(String(format: "%.1f", currentDrift.driftPercent))%) - physiological cost rising. Future slowdown likely if not addressed.")
        }
        
        // Hidden fatigue
        if let currentDrift = snapshot.currentDrift,
           currentDrift.driftPercent > 5.0,
           snapshot.pacetrend == .stable {
            insights.append("⚠️ Hidden fatigue detected: Pace stable but drift increasing - unsustainable effort. Consider easing pace slightly.")
        }
        
        // Sustainability
        if let currentZone = snapshot.currentZone {
            if currentZone >= 4 && snapshot.elapsedTime < 600 {
                insights.append("⚠️ Sustainability check: Zone \(currentZone) too early - may struggle later.")
            } else if currentZone <= 3 {
                insights.append("✓ Sustainability check: Effort sustainable for remaining distance")
            }
        }
        
        return insights.isEmpty ? "No specific insights at this time." : insights.joined(separator: "\n")
    }
    
    private func buildTradeOffAnalysis(snapshot: PerformanceSnapshot, targetStatus: TargetStatus) -> String {
        let progressPercent = snapshot.targetDistance > 0 ? (snapshot.currentDistance / snapshot.targetDistance) * 100 : 0
        let isEarlyPhase = progressPercent < 30
        let isMidPhase = progressPercent >= 30 && progressPercent < 70
        
        var analysis = "Km \(snapshot.currentIntervalNumber) Cost Analysis:\n"
        
        // Zone cost
        if let currentZone = snapshot.currentZone {
            let zoneCost = currentZone >= 4 ? "HIGH" : currentZone == 3 ? "MODERATE" : "LOW"
            analysis += "  • Zone cost: \(zoneCost) cost (Z\(currentZone)) - \(currentZone <= 3 ? "sustainable" : "may struggle")\n"
        }
        
        // Drift cost
        if let currentDrift = snapshot.currentDrift {
            let driftCost = currentDrift.driftPercent > 8.0 ? "HIGH" : currentDrift.driftPercent > 5.0 ? "MODERATE" : "LOW"
            analysis += "  • Drift cost: \(driftCost) cost - drift \(currentDrift.driftPercent > 5 ? "rising" : "stable") (\(String(format: "%.1f", currentDrift.driftPercent))%)\n"
        }
        
        // Pace cost
        let paceCost = abs(snapshot.paceDeviation) > 10 ? "HIGH" : abs(snapshot.paceDeviation) > 5 ? "MODERATE" : "LOW"
        analysis += "  • Pace cost: \(paceCost) - \(abs(snapshot.paceDeviation) < 5 ? "on target" : "off target")\n"
        
        // Timing
        analysis += "\nTiming Analysis:\n"
        if isEarlyPhase {
            if let zone = snapshot.currentZone, zone >= 4 {
                analysis += "  ⚠️ TIMING: Effort level too high for early phase.\n"
            } else {
                analysis += "  ✓ TIMING: Effort level appropriate for early phase.\n"
            }
        } else if isMidPhase {
            analysis += "  ✓ TIMING: Effort level appropriate for mid-phase.\n"
        } else {
            analysis += "  ✓ TIMING: Effort level appropriate for late phase.\n"
        }
        
        // Sustainability
        analysis += "\nSustainability Check:\n"
        if let currentZone = snapshot.currentZone, let currentDrift = snapshot.currentDrift {
            if currentZone <= 3 && currentDrift.driftPercent < 5.0 {
                analysis += "  ✓ SUSTAINABLE: Z\(currentZone) with \(String(format: "%.1f", currentDrift.driftPercent))% drift - sustainable for remaining distance\n"
            } else if currentZone >= 4 || currentDrift.driftPercent > 8.0 {
                analysis += "  ❌ UNSUSTAINABLE: Z\(currentZone) with \(String(format: "%.1f", currentDrift.driftPercent))% drift - cannot maintain for remaining distance\n"
            } else {
                analysis += "  ⚠️ QUESTIONABLE: Z\(currentZone) with \(String(format: "%.1f", currentDrift.driftPercent))% drift - may struggle after \(Int(snapshot.targetDistance / 1000 / 2))km\n"
            }
        }
        
        // Control
        analysis += "\nControl Analysis:\n"
        if abs(snapshot.paceDeviation) < 5 {
            analysis += "  ✓ INTENTIONAL: Pace matches target - controlled, disciplined effort.\n"
        } else {
            analysis += "  ⚠️ LACKING CONTROL: Pace off target - form or focus issue\n"
        }
        
        // Future Impact
        analysis += "\nFuture Impact Assessment:\n"
        if let currentDrift = snapshot.currentDrift {
            if currentDrift.driftPercent > 8.0 {
                analysis += "  ❌ FUTURE IMPACT: Drift \(String(format: "%.1f", currentDrift.driftPercent))% - this km will cause significant slowdown.\n"
            } else if currentDrift.driftPercent > 5.0 {
                analysis += "  ⚠️ FUTURE IMPACT: Drift \(String(format: "%.1f", currentDrift.driftPercent))% - this km made future kms harder.\n"
            } else {
                analysis += "  ✓ FUTURE IMPACT: Low drift - this km sustainable for future.\n"
            }
        }
        
        return analysis
    }
}

