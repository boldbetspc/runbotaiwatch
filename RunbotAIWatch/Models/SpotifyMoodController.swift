import Foundation
import Combine
import SwiftUI

// MARK: - Spotify Mood Controller
// Orchestrates mood-adaptive music selection using RunnerStateAnalyzer output.
// 4 moods: Calm Focus, Flow, Push, Restraint.
// Handles state rules, biofeedback scoring, song ranking, and post-run sync.
final class SpotifyMoodController: ObservableObject {
    
    // MARK: - Published State
    @Published var currentMood: Mood = .calmFocus
    @Published var moodColor: Color = .blue
    @Published var bpmRange: String = "90-110"
    @Published var isActive = false
    @Published var currentTrackScore: Int = 0
    @Published var moodSwitchReason: String = ""
    
    // MARK: - Mood Definition
    
    enum Mood: String, CaseIterable {
        case calmFocus = "Calm Focus"
        case flow = "Flow"
        case push = "Push"
        case restraint = "Restraint"
        
        var color: Color {
            switch self {
            case .calmFocus: return .blue
            case .flow: return .cyan
            case .push: return .orange
            case .restraint: return .purple
            }
        }
        
        var bpmRange: ClosedRange<Int> {
            switch self {
            case .calmFocus: return 90...110
            case .flow: return 120...140
            case .push: return 150...170
            case .restraint: return 80...100
            }
        }
        
        var bpmRangeString: String {
            "\(bpmRange.lowerBound)-\(bpmRange.upperBound) BPM"
        }
        
        var genres: [String] {
            switch self {
            case .calmFocus:
                return ["ambient", "chill", "downtempo", "instrumental", "classical", "acoustic", "piano", "jazz", "lo-fi", "soul", "r&b", "folk"]
            case .flow:
                return ["electronic", "techno", "house", "deep house", "edm", "dance", "pop", "indie", "synth", "trance", "disco", "funk"]
            case .push:
                return ["rock", "metal", "hard rock", "hip hop", "rap", "punk", "hardcore", "alternative", "trap", "dubstep", "drum and bass"]
            case .restraint:
                return ["ambient", "lo-fi", "acoustic", "classical", "chill", "folk", "jazz", "soul", "r&b", "piano"]
            }
        }
        
        var energyWord: String {
            switch self {
            case .calmFocus: return "calmly"
            case .flow: return "smoothly"
            case .push: return "energetically"
            case .restraint: return "gently"
            }
        }
    }
    
    // MARK: - Dependencies
    
    private let stateAnalyzer = RunnerStateAnalyzer()
    private let spotifyManager = SpotifyManager.shared
    
    // MARK: - Biofeedback
    
    struct TrackBiofeedback {
        let trackURI: String
        var score: Int              // -5 to +5
        var playCount: Int
        var lastPlayedAt: Date
        var baselinePace: Double?   // pace when track started (after 5s delay)
        var baselineHR: Double?     // HR when track started (after 5s delay)
        var trackStartTime: Date?
    }
    
    private var trackScores: [String: TrackBiofeedback] = [:]
    private var currentTrackBaseline: (pace: Double, hr: Double, time: Date)?
    private var baselineCaptureTimer: Timer?
    
    // MARK: - Song Waiting
    private var songEndWaitStartTime: Date?
    private let maxSongWaitDuration: TimeInterval = 120 // 2 minutes
    private var pendingMoodSwitch: Mood?
    
    // MARK: - Update Timer
    private var updateTimer: Timer?
    private let updateInterval: TimeInterval = 10.0
    
    // MARK: - AI Feedback Cooldown
    private var lastAIFeedbackTime: Date = .distantPast
    private let aiFeedbackCooldown: TimeInterval = 60
    
    // MARK: - Cancellables
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        NotificationCenter.default.publisher(for: .spotifyTrackChanged)
            .sink { [weak self] notification in
                guard let self = self else { return }
                if let uri = notification.userInfo?["trackURI"] as? String {
                    self.onTrackChanged(uri)
                }
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Start / Stop
    
    func start() {
        guard !isActive else { return }
        isActive = true
        stateAnalyzer.reset()
        startUpdateTimer()
        print("🎭 [MoodController] Started")
    }
    
    func stop() {
        guard isActive else { return }
        isActive = false
        stopUpdateTimer()
        baselineCaptureTimer?.invalidate()
        baselineCaptureTimer = nil
        pendingMoodSwitch = nil
        songEndWaitStartTime = nil
        print("🎭 [MoodController] Stopped")
    }
    
    // MARK: - Feed Stats (called every 5s from RunTracker integration)
    
    func feedStats(
        currentPace: Double,
        targetPace: Double,
        currentHR: Double?,
        targetHR: Double?,
        duration: TimeInterval,
        actualDistance: Double,
        expectedDistance: Double,
        intervalSplitDelta: Double?,
        cadence: Double?
    ) {
        guard isActive else { return }
        
        let input = RunnerStateAnalyzer.StateInput(
            currentPace: currentPace,
            targetPace: targetPace,
            currentHR: currentHR,
            targetHR: targetHR,
            actualDistance: actualDistance,
            expectedDistance: expectedDistance,
            elapsedTime: duration,
            duration: expectedDistance > 0 && targetPace > 0 ? (expectedDistance / 1000.0) * targetPace * 60 : duration * 2,
            intervalSplitDelta: intervalSplitDelta,
            cadence: cadence
        )
        
        let result = stateAnalyzer.analyze(input)
        let newMood = mapStateToMood(result.state)
        
        if newMood != currentMood {
            handleMoodTransition(to: newMood, reason: result.reason, result: result)
        }
        
        // Update biofeedback for current track
        evaluateBiofeedback(currentPace: currentPace, currentHR: currentHR)
    }
    
    // MARK: - Mood Transition
    
    private func handleMoodTransition(to newMood: Mood, reason: String, result: RunnerStateAnalyzer.AnalysisResult) {
        // Check AI feedback cooldown - don't change mood within 15s of AI feedback
        // (We use the lastAIFeedbackTime set externally via notifyAIFeedback())
        
        // Check if we should wait for natural song completion
        if spotifyManager.isPlaying {
            if let state = Task { await spotifyManager.fetchPlayerState() } as? SpotifyManager.PlayerState {
                let remainingMs = state.durationMs - state.progressMs
                if remainingMs > 0 && remainingMs < Int(maxSongWaitDuration * 1000) {
                    pendingMoodSwitch = newMood
                    if songEndWaitStartTime == nil {
                        songEndWaitStartTime = Date()
                    }
                    
                    // If we've waited too long, force switch
                    if let waitStart = songEndWaitStartTime,
                       Date().timeIntervalSince(waitStart) >= maxSongWaitDuration {
                        executeMoodSwitch(to: newMood, reason: reason, result: result)
                    }
                    return
                }
            }
        }
        
        executeMoodSwitch(to: newMood, reason: reason, result: result)
    }
    
    private func executeMoodSwitch(to newMood: Mood, reason: String, result: RunnerStateAnalyzer.AnalysisResult) {
        let previousMood = currentMood
        
        DispatchQueue.main.async {
            self.currentMood = newMood
            self.moodColor = newMood.color
            self.bpmRange = newMood.bpmRangeString
            self.moodSwitchReason = reason
        }
        
        pendingMoodSwitch = nil
        songEndWaitStartTime = nil
        
        // Post notification for voice announcement
        NotificationCenter.default.post(
            name: .moodSwitched,
            object: nil,
            userInfo: [
                "previousMood": previousMood.rawValue,
                "newMood": newMood.rawValue,
                "reason": reason,
                "trackName": spotifyManager.currentTrackName,
                "energyWord": newMood.energyWord
            ]
        )
        
        // Trigger playlist/track switch
        Task {
            await switchMusicForMood(newMood, cadenceBPM: result.cadenceBPM)
        }
        
        print("🎭 [MoodController] Mood: \(previousMood.rawValue) → \(newMood.rawValue) | Reason: \(reason)")
    }
    
    // MARK: - Music Selection (3-tier filtering)
    
    private func switchMusicForMood(_ mood: Mood, cadenceBPM: Int) async {
        guard spotifyManager.isConnected else { return }
        
        // If we have a master playlist, use context-based playback
        if let playlistId = spotifyManager.masterPlaylistId {
            let tracks = await spotifyManager.fetchPlaylistTracks(playlistId)
            let ranked = rankTracksForMood(tracks, mood: mood, cadenceBPM: cadenceBPM)
            
            if !ranked.isEmpty {
                let uris = ranked.prefix(10).map(\.uri)
                _ = await spotifyManager.playTracks(Array(uris))
                return
            }
        }
        
        // Fallback: play from master playlist context
        if let pid = spotifyManager.masterPlaylistId {
            _ = await spotifyManager.switchPlaylist(pid)
        }
    }
    
    /// 3-tier song filtering:
    /// Tier 1: cadence-locked BPM ±5 tolerance
    /// Tier 2: genre + BPM match
    /// Tier 3: genre-only
    /// Rank by biofeedback score descending, shuffle within tiers
    func rankTracksForMood(_ tracks: [SpotifyTrack], mood: Mood, cadenceBPM: Int) -> [SpotifyTrack] {
        let bpmRange = mood.bpmRange
        
        // Filter out anti-repeat tracks
        let available = tracks.filter { !spotifyManager.isInAntiRepeat($0.uri) }
        guard !available.isEmpty else { return tracks.shuffled() }
        
        // Tier 1: BPM match within ±5 of cadenceBPM (estimated from duration)
        var tier1: [SpotifyTrack] = []
        var tier2: [SpotifyTrack] = []
        var tier3: [SpotifyTrack] = []
        
        for track in available {
            let estimatedBPM = estimateTrackBPM(track)
            let bpmMatch = abs(estimatedBPM - cadenceBPM) <= 5
            let inRange = bpmRange.contains(estimatedBPM)
            
            if bpmMatch {
                tier1.append(track)
            } else if inRange {
                tier2.append(track)
            } else {
                tier3.append(track)
            }
        }
        
        // Sort each tier by biofeedback score descending, then shuffle within equal scores
        let sortByScore: ([SpotifyTrack]) -> [SpotifyTrack] = { tracks in
            tracks.sorted { a, b in
                let scoreA = self.trackScores[a.uri]?.score ?? 0
                let scoreB = self.trackScores[b.uri]?.score ?? 0
                if scoreA != scoreB { return scoreA > scoreB }
                return Bool.random()
            }
        }
        
        return sortByScore(tier1) + sortByScore(tier2) + sortByScore(tier3)
    }
    
    /// Rough BPM estimation from track duration (heuristic for unavailable audio features)
    private func estimateTrackBPM(_ track: SpotifyTrack) -> Int {
        // Without Spotify audio features API, use heuristic:
        // Shorter tracks tend to be higher energy (higher BPM)
        // 2-3 min → 140-170, 3-4 min → 120-150, 4-6 min → 100-130
        let durationSec = Double(track.durationMs) / 1000.0
        if durationSec < 180 { return 155 }
        if durationSec < 240 { return 135 }
        if durationSec < 360 { return 115 }
        return 95
    }
    
    // MARK: - Biofeedback Scoring
    
    private func onTrackChanged(_ uri: String) {
        // Finalize score for previous track
        finalizePreviousTrackScore()
        
        // Start baseline capture for new track (5s delay)
        baselineCaptureTimer?.invalidate()
        currentTrackBaseline = nil
        
        baselineCaptureTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            self?.captureBaseline()
        }
        
        // Initialize or update track score entry
        if trackScores[uri] == nil {
            trackScores[uri] = TrackBiofeedback(
                trackURI: uri,
                score: 0,
                playCount: 1,
                lastPlayedAt: Date(),
                trackStartTime: Date()
            )
        } else {
            trackScores[uri]?.playCount += 1
            trackScores[uri]?.lastPlayedAt = Date()
            trackScores[uri]?.trackStartTime = Date()
        }
    }
    
    private var lastFedPace: Double = 0
    private var lastFedHR: Double?
    
    private func captureBaseline() {
        currentTrackBaseline = (pace: lastFedPace, hr: lastFedHR ?? 0, time: Date())
        let currentURI = spotifyManager.currentTrackURI
        trackScores[currentURI]?.baselinePace = lastFedPace
        trackScores[currentURI]?.baselineHR = lastFedHR
    }
    
    /// Evaluate biofeedback: pace improved ≥3% → +1, pace dropped ≥3% AND HR spiked ≥5% → -1
    private func evaluateBiofeedback(currentPace: Double, currentHR: Double?) {
        lastFedPace = currentPace
        lastFedHR = currentHR
        
        guard let baseline = currentTrackBaseline,
              Date().timeIntervalSince(baseline.time) >= 30 else { return }
        
        let currentURI = spotifyManager.currentTrackURI
        guard !currentURI.isEmpty, baseline.pace > 0 else { return }
        
        // Lower pace = faster, so improvement means currentPace < baseline
        let paceChange = (baseline.pace - currentPace) / baseline.pace * 100
        let hrChange: Double = {
            guard let hr = currentHR, baseline.hr > 0 else { return 0 }
            return (hr - baseline.hr) / baseline.hr * 100
        }()
        
        var scoreChange = 0
        if paceChange >= 3 {
            scoreChange = 1 // pace improved ≥3%
        } else if paceChange <= -3 && hrChange >= 5 {
            scoreChange = -1 // pace dropped ≥3% AND HR spiked ≥5%
        }
        
        if scoreChange != 0, var feedback = trackScores[currentURI] {
            feedback.score = max(-5, min(5, feedback.score + scoreChange))
            trackScores[currentURI] = feedback
            
            DispatchQueue.main.async {
                self.currentTrackScore = feedback.score
            }
        }
    }
    
    private func finalizePreviousTrackScore() {
        // No-op currently; scores are updated in real-time
    }
    
    // MARK: - State Mapping
    
    private func mapStateToMood(_ state: RunnerStateAnalyzer.RunnerState) -> Mood {
        switch state {
        case .calmFocus: return .calmFocus
        case .flow: return .flow
        case .push: return .push
        case .restraint: return .restraint
        }
    }
    
    // MARK: - AI Feedback Coordination
    
    func notifyAIFeedbackScheduled() {
        lastAIFeedbackTime = Date()
    }
    
    func isAIFeedbackExpectedSoon() -> Bool {
        return Date().timeIntervalSince(lastAIFeedbackTime) < aiFeedbackCooldown
    }
    
    // MARK: - Timer
    
    private func startUpdateTimer() {
        stopUpdateTimer()
        updateTimer = Timer.scheduledTimer(withTimeInterval: updateInterval, repeats: true) { [weak self] _ in
            // Timer fires but actual updates happen via feedStats()
            self?.checkPendingMoodSwitch()
        }
        if let timer = updateTimer {
            RunLoop.current.add(timer, forMode: .common)
        }
    }
    
    private func stopUpdateTimer() {
        updateTimer?.invalidate()
        updateTimer = nil
    }
    
    private func checkPendingMoodSwitch() {
        guard let pending = pendingMoodSwitch else { return }
        
        Task {
            if let state = await spotifyManager.fetchPlayerState() {
                let remainingMs = state.durationMs - state.progressMs
                if remainingMs <= 2000 || !state.isPlaying {
                    let reason = moodSwitchReason.isEmpty ? "Natural song completion" : moodSwitchReason
                    let result = RunnerStateAnalyzer.AnalysisResult(
                        state: mapMoodToState(pending),
                        reason: reason,
                        distanceDelta: 0,
                        paceDeviation: 0,
                        hrDeviation: nil,
                        racePhase: .steady,
                        cadenceBPM: stateAnalyzer.calculateCadenceBPM(currentPace: lastFedPace),
                        confidence: 0.8
                    )
                    executeMoodSwitch(to: pending, reason: reason, result: result)
                }
            }
        }
    }
    
    private func mapMoodToState(_ mood: Mood) -> RunnerStateAnalyzer.RunnerState {
        switch mood {
        case .calmFocus: return .calmFocus
        case .flow: return .flow
        case .push: return .push
        case .restraint: return .restraint
        }
    }
    
    // MARK: - Post-Run Sync
    
    func getUpdatedScores() -> [TrackBiofeedback] {
        return Array(trackScores.values).filter { $0.playCount > 0 }
    }
    
    func loadScores(_ scores: [TrackBiofeedback]) {
        for score in scores {
            trackScores[score.trackURI] = score
        }
        print("🎵 [MoodController] Loaded \(scores.count) track scores")
    }
    
    func clearScores() {
        trackScores.removeAll()
    }
    
    // MARK: - Music Performance Correlation Summary (for Coaching DNA)
    
    func generateCorrelationSummary() -> String {
        let scores = getUpdatedScores()
        guard !scores.isEmpty else { return "No music performance data." }
        
        let positives = scores.filter { $0.score > 0 }
        let negatives = scores.filter { $0.score < 0 }
        let totalPlays = scores.reduce(0) { $0 + $1.playCount }
        
        var summary = "Music-Performance: \(scores.count) tracks played \(totalPlays) times. "
        if !positives.isEmpty {
            summary += "\(positives.count) tracks improved pace. "
        }
        if !negatives.isEmpty {
            summary += "\(negatives.count) tracks correlated with pace decline. "
        }
        
        let avgScore = scores.reduce(0) { $0 + $1.score } / max(1, scores.count)
        summary += "Avg biofeedback score: \(avgScore > 0 ? "+" : "")\(avgScore)/5. "
        summary += "Current mood: \(currentMood.rawValue)."
        
        return summary
    }
    
    // MARK: - Reset
    
    func reset() {
        stop()
        stateAnalyzer.reset()
        trackScores.removeAll()
        currentTrackBaseline = nil
        lastFedPace = 0
        lastFedHR = nil
        DispatchQueue.main.async {
            self.currentMood = .calmFocus
            self.moodColor = .blue
            self.bpmRange = "90-110 BPM"
            self.currentTrackScore = 0
            self.moodSwitchReason = ""
        }
    }
}

// MARK: - Notifications

extension NSNotification.Name {
    static let moodSwitched = NSNotification.Name("MoodSwitched")
}
