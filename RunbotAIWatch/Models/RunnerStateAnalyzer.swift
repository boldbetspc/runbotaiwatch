import Foundation

// MARK: - Runner State Analyzer
// Evaluates BOTH biometrics (HR vs target HR, cadence) AND running performance
// (current pace vs target pace, actual distance vs expected distance, interval splits,
// race phase) to determine the runner's emotional/performance state.
final class RunnerStateAnalyzer {
    
    // MARK: - Runner State
    
    enum RunnerState: String, CaseIterable {
        case calmFocus = "Calm Focus"
        case flow = "Flow"
        case push = "Push"
        case restraint = "Restraint"
    }
    
    // MARK: - State Input
    
    struct StateInput {
        let currentPace: Double          // min/km
        let targetPace: Double           // min/km
        let currentHR: Double?           // BPM
        let targetHR: Double?            // BPM
        let actualDistance: Double        // meters
        let expectedDistance: Double      // meters (targetPace * elapsedTime)
        let elapsedTime: TimeInterval    // seconds
        let duration: TimeInterval       // total expected duration seconds
        let intervalSplitDelta: Double?  // current interval pace - target pace (positive = slow)
        let cadence: Double?             // steps per minute
    }
    
    // MARK: - Analysis Result
    
    struct AnalysisResult {
        let state: RunnerState
        let reason: String
        let distanceDelta: Double        // meters ahead(+) or behind(-)
        let paceDeviation: Double        // percentage deviation from target
        let hrDeviation: Double?         // percentage deviation from target HR
        let racePhase: RacePhase
        let cadenceBPM: Int              // recommended music BPM from cadence
        let confidence: Double           // 0-1, how certain we are about this state
    }
    
    enum RacePhase: String {
        case warmup = "Warmup"
        case steady = "Steady"
        case push = "Push"
        case cooldown = "Cooldown"
    }
    
    // MARK: - Internal State Tracking
    
    private var readingHistory: [RunnerState] = []
    private let requiredConsecutiveReadings = 3 // 30s at 10s interval
    private var currentState: RunnerState = .calmFocus
    private var stateEntryTime: Date = Date()
    private var flowLockActive = false
    private var flowConsecutiveCount = 0
    private var nonFlowCount = 0
    private let flowLockDuration: TimeInterval = 180 // 3 minutes
    private var lastMoodChangeTime: Date = Date.distantPast
    private let moodChangeCooldown: TimeInterval = 15
    
    // MARK: - Analyze
    
    func analyze(_ input: StateInput) -> AnalysisResult {
        let distanceDelta = input.actualDistance - input.expectedDistance
        
        // Pace deviation: positive means slower than target (bad), negative means faster (good)
        // Lower pace = faster, so if currentPace > targetPace, runner is slower
        let paceDeviation: Double = input.targetPace > 0
            ? ((input.currentPace - input.targetPace) / input.targetPace) * 100
            : 0
        
        let hrDeviation: Double? = {
            guard let hr = input.currentHR, let target = input.targetHR, target > 0 else { return nil }
            return ((hr - target) / target) * 100
        }()
        
        let racePhase = determineRacePhase(input)
        let cadenceBPM = calculateCadenceBPM(currentPace: input.currentPace)
        
        // Determine raw state from inputs
        let rawState = determineRawState(
            distanceDelta: distanceDelta,
            paceDeviation: paceDeviation,
            hrDeviation: hrDeviation,
            racePhase: racePhase,
            intervalSplitDelta: input.intervalSplitDelta
        )
        
        // Apply HR drift moderation
        let moderatedState = applyHRDriftModeration(rawState, hrDeviation: hrDeviation)
        
        // Track reading history for hysteresis (require 3 consecutive same-state readings)
        readingHistory.append(moderatedState)
        if readingHistory.count > requiredConsecutiveReadings {
            readingHistory.removeFirst()
        }
        
        // Check if we should switch states
        let confirmedState = resolveStateWithHysteresis(moderatedState)
        
        let reason = generateReason(confirmedState, distanceDelta: distanceDelta, paceDeviation: paceDeviation)
        let confidence = calculateConfidence(moderatedState)
        
        return AnalysisResult(
            state: confirmedState,
            reason: reason,
            distanceDelta: distanceDelta,
            paceDeviation: paceDeviation,
            hrDeviation: hrDeviation,
            racePhase: racePhase,
            cadenceBPM: cadenceBPM,
            confidence: confidence
        )
    }
    
    // MARK: - Raw State Determination
    
    private func determineRawState(
        distanceDelta: Double,
        paceDeviation: Double,
        hrDeviation: Double?,
        racePhase: RacePhase,
        intervalSplitDelta: Double?
    ) -> RunnerState {
        // Restraint: significantly ahead on distance, needs to conserve
        if distanceDelta > 100 && paceDeviation < -5 {
            return .restraint
        }
        
        // Push: behind on expected distance or interval demands effort
        if distanceDelta < -80 || paceDeviation > 10 {
            return .push
        }
        if let splitDelta = intervalSplitDelta, splitDelta > 0.3 {
            return .push
        }
        
        // Flow: in rhythm, hitting splits, pace close to target
        if abs(paceDeviation) <= 5 && abs(distanceDelta) < 80 {
            if let splitDelta = intervalSplitDelta, abs(splitDelta) < 0.15 {
                return .flow
            }
            return .flow
        }
        
        // Calm Focus: on-target and steady, early race phase or recovery
        if racePhase == .warmup || racePhase == .cooldown {
            return .calmFocus
        }
        
        // Default: if close to target but not quite in flow
        if abs(paceDeviation) <= 8 {
            return .calmFocus
        }
        
        // Behind but not drastically
        if paceDeviation > 5 {
            return .push
        }
        
        return .calmFocus
    }
    
    // MARK: - HR Drift Moderation
    // If HR >15% above target, downshift: Push→Flow, Flow→Calm
    
    private func applyHRDriftModeration(_ state: RunnerState, hrDeviation: Double?) -> RunnerState {
        guard let deviation = hrDeviation, deviation > 15 else { return state }
        
        switch state {
        case .push: return .flow
        case .flow: return .calmFocus
        default: return state
        }
    }
    
    // MARK: - Hysteresis & Flow Lock
    
    private func resolveStateWithHysteresis(_ proposed: RunnerState) -> RunnerState {
        // Don't change within cooldown period
        if Date().timeIntervalSince(lastMoodChangeTime) < moodChangeCooldown {
            return currentState
        }
        
        // Flow lock: after 3+ minutes of Flow, lock it; unlock after 3 non-flow readings
        if currentState == .flow {
            let timeInFlow = Date().timeIntervalSince(stateEntryTime)
            if timeInFlow >= flowLockDuration {
                flowLockActive = true
            }
        }
        
        if flowLockActive {
            if proposed != .flow {
                nonFlowCount += 1
                if nonFlowCount >= 3 {
                    flowLockActive = false
                    nonFlowCount = 0
                } else {
                    return .flow
                }
            } else {
                nonFlowCount = 0
                return .flow
            }
        }
        
        // Require N consecutive same readings before switching
        let last = readingHistory.suffix(requiredConsecutiveReadings)
        let allSame = last.count >= requiredConsecutiveReadings && Set(last).count == 1
        
        if allSame, let confirmed = last.first, confirmed != currentState {
            let previousState = currentState
            currentState = confirmed
            stateEntryTime = Date()
            lastMoodChangeTime = Date()
            
            if confirmed == .flow {
                flowConsecutiveCount += 1
            } else {
                flowConsecutiveCount = 0
            }
            
            print("🎭 [RunnerState] State change: \(previousState.rawValue) → \(confirmed.rawValue)")
            return confirmed
        }
        
        return currentState
    }
    
    // MARK: - Race Phase
    
    private func determineRacePhase(_ input: StateInput) -> RacePhase {
        guard input.duration > 0 else { return .steady }
        
        let progress = input.elapsedTime / input.duration
        
        if progress < 0.15 { return .warmup }
        if progress > 0.85 { return .cooldown }
        if progress > 0.65 { return .push }
        return .steady
    }
    
    // MARK: - Cadence BPM Formula
    // max(140, min(200, Int(220 - currentPace * 8)))
    
    func calculateCadenceBPM(currentPace: Double) -> Int {
        guard currentPace > 0 else { return 160 }
        return max(140, min(200, Int(220 - currentPace * 8)))
    }
    
    // MARK: - Reason Generation
    
    private func generateReason(_ state: RunnerState, distanceDelta: Double, paceDeviation: Double) -> String {
        switch state {
        case .calmFocus:
            return "Your pace is steady and controlled"
        case .flow:
            return "You're in the zone, hitting your splits"
        case .push:
            if distanceDelta < -50 {
                return "You're behind on distance, time to dig in"
            }
            return "Time to push harder, pick up the pace"
        case .restraint:
            return "You're ahead on distance, conserve energy"
        }
    }
    
    // MARK: - Confidence
    
    private func calculateConfidence(_ proposed: RunnerState) -> Double {
        let last = readingHistory.suffix(requiredConsecutiveReadings)
        guard !last.isEmpty else { return 0.5 }
        let matching = last.filter { $0 == proposed }.count
        return Double(matching) / Double(last.count)
    }
    
    // MARK: - Reset
    
    func reset() {
        readingHistory.removeAll()
        currentState = .calmFocus
        stateEntryTime = Date()
        flowLockActive = false
        flowConsecutiveCount = 0
        nonFlowCount = 0
        lastMoodChangeTime = .distantPast
    }
    
    var current: RunnerState { currentState }
    var timeSinceLastChange: TimeInterval { Date().timeIntervalSince(lastMoodChangeTime) }
}
