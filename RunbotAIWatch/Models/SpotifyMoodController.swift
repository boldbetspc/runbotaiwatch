import Foundation
import Combine
import SwiftUI

// MARK: - Spotify Mood Controller
// Orchestrates mood-adaptive music selection using RunnerStateAnalyzer output.
// 4 moods: Calm Focus, Flow, Push, Restraint.
// Handles state rules, biofeedback scoring, song ranking, and post-run sync.
@MainActor
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
    private let appleMusic = AppleMusicManager.shared
    
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
                if let uri = notification.userInfo?["trackURI"] as? String {
                    Task { @MainActor in
                        self?.onTrackChanged(uri)
                    }
                }
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Dual-Provider Helpers
    
    private func masterPlaylistId() -> String? {
        switch RunEmotionMusicSource.current {
        case .spotify: return spotifyManager.masterPlaylistId
        case .appleMusic: return appleMusic.masterPlaylistId
        }
    }

    private func isMusicConnected() -> Bool {
        switch RunEmotionMusicSource.current {
        case .spotify: return spotifyManager.isConnected
        case .appleMusic: return appleMusic.isConnected
        }
    }

    private func fetchPlaylistTracksUnified(_ playlistId: String) async -> [RunEmotionTrack] {
        switch RunEmotionMusicSource.current {
        case .spotify:
            let tracks = await spotifyManager.fetchPlaylistTracks(playlistId)
            return tracks.map { $0.asRunEmotionTrack() }
        case .appleMusic:
            return await appleMusic.fetchPlaylistTracks(playlistId)
        }
    }

    private func playTrackIdsUnified(_ ids: [String]) async -> Bool {
        switch RunEmotionMusicSource.current {
        case .spotify: return await spotifyManager.playTracks(ids)
        case .appleMusic: return await appleMusic.playTracks(ids)
        }
    }

    private func currentTrackId() -> String {
        switch RunEmotionMusicSource.current {
        case .spotify: return spotifyManager.currentTrackURI
        case .appleMusic: return appleMusic.currentTrackURI
        }
    }

    private func isInAntiRepeatUnified(_ id: String) -> Bool {
        switch RunEmotionMusicSource.current {
        case .spotify: return spotifyManager.isInAntiRepeat(id)
        case .appleMusic: return appleMusic.isInAntiRepeat(id)
        }
    }

    private func fetchPlayerStateUnified() async -> (durationMs: Int, progressMs: Int, isPlaying: Bool)? {
        switch RunEmotionMusicSource.current {
        case .spotify:
            guard let s = await spotifyManager.fetchPlayerState() else { return nil }
            return (s.durationMs, s.progressMs, s.isPlaying)
        case .appleMusic:
            guard let s = await appleMusic.fetchPlayerState() else { return nil }
            return (s.durationMs, s.progressMs, s.isPlaying)
        }
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
        Task {
            if let state = await fetchPlayerStateUnified() {
                if state.isPlaying {
                    let remainingMs = state.durationMs - state.progressMs
                    if remainingMs > 0 && remainingMs < Int(maxSongWaitDuration * 1000) {
                        pendingMoodSwitch = newMood
                        if songEndWaitStartTime == nil {
                            songEndWaitStartTime = Date()
                        }
                        
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
    }
    
    private func executeMoodSwitch(to newMood: Mood, reason: String, result: RunnerStateAnalyzer.AnalysisResult) {
        let previousMood = currentMood
        
        currentMood = newMood
        moodColor = newMood.color
        bpmRange = newMood.bpmRangeString
        moodSwitchReason = reason
        
        pendingMoodSwitch = nil
        songEndWaitStartTime = nil
        
        let trackName: String = {
            switch RunEmotionMusicSource.current {
            case .spotify: return spotifyManager.currentTrackName
            case .appleMusic: return appleMusic.currentTrackName
            }
        }()
        
        NotificationCenter.default.post(
            name: .moodSwitched,
            object: nil,
            userInfo: [
                "previousMood": previousMood.rawValue,
                "newMood": newMood.rawValue,
                "reason": reason,
                "trackName": trackName,
                "energyWord": newMood.energyWord
            ]
        )
        
        Task {
            await switchMusicForMood(newMood, cadenceBPM: result.cadenceBPM)
        }
        
        print("🎭 [MoodController] Mood: \(previousMood.rawValue) → \(newMood.rawValue) | Reason: \(reason)")
    }
    
    // MARK: - Music Selection (3-tier filtering)
    
    private func switchMusicForMood(_ mood: Mood, cadenceBPM: Int) async {
        guard isMusicConnected() else { return }
        
        if let playlistId = masterPlaylistId() {
            let tracks = await fetchPlaylistTracksUnified(playlistId)
            let ranked = rankTracksForMood(tracks, mood: mood, cadenceBPM: cadenceBPM)
            
            if !ranked.isEmpty {
                let ids = ranked.prefix(10).map(\.id)
                _ = await playTrackIdsUnified(Array(ids))
                return
            }
        }
        
        // Fallback: play from master playlist context
        if let pid = masterPlaylistId() {
            switch RunEmotionMusicSource.current {
            case .spotify:
                _ = await spotifyManager.switchPlaylist(pid)
            case .appleMusic:
                _ = await appleMusic.switchPlaylist(pid)
            }
        }
    }
    
    /// 3-tier song filtering:
    /// Tier 1: cadence-locked BPM ±5 tolerance
    /// Tier 2: genre + BPM match
    /// Tier 3: genre-only
    /// Rank by biofeedback score descending, shuffle within tiers
    func rankTracksForMood(_ tracks: [RunEmotionTrack], mood: Mood, cadenceBPM: Int) -> [RunEmotionTrack] {
        let bpmRange = mood.bpmRange
        
        let available = tracks.filter { !isInAntiRepeatUnified($0.id) }
        guard !available.isEmpty else { return tracks.shuffled() }
        
        var tier1: [RunEmotionTrack] = []
        var tier2: [RunEmotionTrack] = []
        var tier3: [RunEmotionTrack] = []
        
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
        
        let sortByScore: ([RunEmotionTrack]) -> [RunEmotionTrack] = { tracks in
            tracks.sorted { a, b in
                let scoreA = self.trackScores[a.id]?.score ?? 0
                let scoreB = self.trackScores[b.id]?.score ?? 0
                if scoreA != scoreB { return scoreA > scoreB }
                return Bool.random()
            }
        }
        
        return sortByScore(tier1) + sortByScore(tier2) + sortByScore(tier3)
    }
    
    private func estimateTrackBPM(_ track: RunEmotionTrack) -> Int {
        let durationSec = Double(track.durationMs) / 1000.0
        if durationSec < 180 { return 155 }
        if durationSec < 240 { return 135 }
        if durationSec < 360 { return 115 }
        return 95
    }
    
    // MARK: - Biofeedback Scoring
    
    private func onTrackChanged(_ uri: String) {
        finalizePreviousTrackScore()
        
        baselineCaptureTimer?.invalidate()
        currentTrackBaseline = nil
        
        baselineCaptureTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.captureBaseline()
            }
        }
        
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
        let currentURI = currentTrackId()
        trackScores[currentURI]?.baselinePace = lastFedPace
        trackScores[currentURI]?.baselineHR = lastFedHR
    }
    
    /// Evaluate biofeedback: pace improved ≥3% → +1, pace dropped ≥3% AND HR spiked ≥5% → -1
    private func evaluateBiofeedback(currentPace: Double, currentHR: Double?) {
        lastFedPace = currentPace
        lastFedHR = currentHR
        
        guard let baseline = currentTrackBaseline,
              Date().timeIntervalSince(baseline.time) >= 30 else { return }
        
        let currentURI = currentTrackId()
        guard !currentURI.isEmpty, baseline.pace > 0 else { return }
        
        let paceChange = (baseline.pace - currentPace) / baseline.pace * 100
        let hrChange: Double = {
            guard let hr = currentHR, baseline.hr > 0 else { return 0 }
            return (hr - baseline.hr) / baseline.hr * 100
        }()
        
        var scoreChange = 0
        if paceChange >= 3 {
            scoreChange = 1
        } else if paceChange <= -3 && hrChange >= 5 {
            scoreChange = -1
        }
        
        if scoreChange != 0, var feedback = trackScores[currentURI] {
            feedback.score = max(-5, min(5, feedback.score + scoreChange))
            trackScores[currentURI] = feedback
            currentTrackScore = feedback.score
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
            Task { @MainActor in
                self?.checkPendingMoodSwitch()
            }
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
            if let state = await fetchPlayerStateUnified() {
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
        currentMood = .calmFocus
        moodColor = .blue
        bpmRange = "90-110 BPM"
        currentTrackScore = 0
        moodSwitchReason = ""
    }
}

// MARK: - Notifications

extension NSNotification.Name {
    static let moodSwitched = NSNotification.Name("MoodSwitched")
}
