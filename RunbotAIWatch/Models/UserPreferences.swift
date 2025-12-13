import Foundation
import Combine

// MARK: - User Preferences Manager
/// Manages user preferences with iOS sync support via WatchConnectivity
final class UserPreferences: ObservableObject {
    
    // MARK: - Published State
    @Published var settings: Settings = Settings()
    @Published var runnerName: String = "Runner"
    @Published var userId: String?
    
    // MARK: - Settings Model
    struct Settings: Codable, Equatable {
        var coachPersonality: CoachPersonality = .pacer
        var voiceOption: VoiceOption = .samantha
        var coachEnergy: CoachEnergy = .medium
        var feedbackFrequency: Int = 1 // Distance in km (1, 2, 5, etc.)
        var targetPaceMinPerKm: Double = 7.0 // Default: 7:00 min/km
        var voiceAIModel: VoiceAIModel = .apple // Apple Samantha vs OpenAI GPT-4
        var language: SupportedLanguage = .english
        var targetDistance: TargetDistance = .fiveK // Default: 5K race
        var customDistanceKm: Double = 5.0 // For custom distance
        
        /// Get actual target distance in meters
        var targetDistanceMeters: Double {
            if targetDistance == .custom {
                return customDistanceKm * 1000
            }
            return targetDistance.distanceMeters
        }
        
        /// Get actual target distance in km
        var targetDistanceKm: Double {
            return targetDistanceMeters / 1000
        }
        
        enum CodingKeys: String, CodingKey {
            case coachPersonality = "coach_personality"
            case voiceOption = "voice_option"
            case coachEnergy = "coach_energy"
            case feedbackFrequency = "feedback_frequency"
            case targetPaceMinPerKm = "target_pace_min_per_km"
            case voiceAIModel = "voice_ai_model"
            case language
            case targetDistance = "target_distance"
            case customDistanceKm = "custom_distance_km"
        }
    }
    
    // MARK: - Initialization
    
    init() {
        loadFromStorage()
    }
    
    // MARK: - Public API
    
    func updatePersonality(_ personality: CoachPersonality) {
        settings.coachPersonality = personality
        saveToStorage()
    }
    
    func updateVoice(_ voice: VoiceOption) {
        settings.voiceOption = voice
        saveToStorage()
    }
    
    func updateEnergy(_ energy: CoachEnergy) {
        settings.coachEnergy = energy
        saveToStorage()
    }
    
    func updateFeedbackFrequency(_ frequency: Int) {
        settings.feedbackFrequency = frequency
        saveToStorage()
    }
    
    func updateTargetPace(_ pace: Double) {
        settings.targetPaceMinPerKm = pace
        saveToStorage()
    }
    
    func updateVoiceAIModel(_ model: VoiceAIModel) {
        let oldModel = settings.voiceAIModel
        settings.voiceAIModel = model
        saveToStorage()
        print("🎤 [Preferences] Voice AI Model updated: \(oldModel.rawValue) -> \(model.rawValue)")
        // Note: Settings are saved to Supabase when user taps Save button in SettingsView
    }
    
    func updateLanguage(_ language: SupportedLanguage) {
        settings.language = language
        saveToStorage()
    }
    
    func updateTargetDistance(_ distance: TargetDistance) {
        settings.targetDistance = distance
        saveToStorage()
    }
    
    func updateCustomDistance(_ distanceKm: Double) {
        settings.customDistanceKm = distanceKm
        saveToStorage()
    }
    
    func updateRunnerName(_ name: String) {
        runnerName = name
        UserDefaults.standard.set(name, forKey: "runnerName")
    }
    
    /// Apply settings received from iOS via WatchConnectivity
    func applyFromiOS(data: [String: Any]) {
        if let personality = data["coachPersonality"] as? String,
           let p = CoachPersonality(rawValue: personality) {
            settings.coachPersonality = p
        }
        
        if let energy = data["coachEnergy"] as? String,
           let e = CoachEnergy(rawValue: energy) {
            settings.coachEnergy = e
        }
        
        if let frequency = data["feedbackFrequency"] as? Int {
            settings.feedbackFrequency = frequency
        }
        
        if let targetPace = data["targetPace"] as? Double {
            settings.targetPaceMinPerKm = targetPace
        }
        
        if let name = data["runnerName"] as? String {
            runnerName = name
        }
        
        if let uid = data["userId"] as? String {
            userId = uid
        }
        
        if let lang = data["language"] as? String,
           let l = SupportedLanguage(rawValue: lang) {
            settings.language = l
        }
        
        if let voiceModel = data["voiceAIModel"] as? String,
           let v = VoiceAIModel(rawValue: voiceModel) {
            settings.voiceAIModel = v
        }
        
        if let targetDist = data["targetDistance"] as? String,
           let t = TargetDistance(rawValue: targetDist) {
            settings.targetDistance = t
        }
        
        if let customDist = data["customDistanceKm"] as? Double {
            settings.customDistanceKm = customDist
        }
        
        saveToStorage()
        print("📲 [Preferences] Applied settings from iOS")
    }
    
    /// Export settings for iOS sync
    func exportForiOS() -> [String: Any] {
        return [
            "coachPersonality": settings.coachPersonality.rawValue,
            "coachEnergy": settings.coachEnergy.rawValue,
            "feedbackFrequency": settings.feedbackFrequency,
            "targetPace": settings.targetPaceMinPerKm,
            "runnerName": runnerName,
            "language": settings.language.rawValue,
            "voiceAIModel": settings.voiceAIModel.rawValue,
            "targetDistance": settings.targetDistance.rawValue,
            "customDistanceKm": settings.customDistanceKm
        ]
    }
    
    // MARK: - Persistence
    
    private func saveToStorage() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: "userPreferences")
        }
        UserDefaults.standard.set(runnerName, forKey: "runnerName")
    }
    
    private func loadFromStorage() {
        if let data = UserDefaults.standard.data(forKey: "userPreferences"),
           let saved = try? JSONDecoder().decode(Settings.self, from: data) {
            settings = saved
        }
        
        if let name = UserDefaults.standard.string(forKey: "runnerName") {
            runnerName = name
        }
        
        print("📂 [Preferences] Loaded from storage")
    }
    
    /// Refresh preferences from Supabase (call after saving or at start of run)
    func refreshFromSupabase(supabaseManager: SupabaseManager, userId: String) async {
        guard let freshSettings = await supabaseManager.loadUserPreferences(userId: userId) else {
            print("⚠️ [Preferences] Could not refresh from Supabase - using cached settings")
            return
        }
        
        await MainActor.run {
            // Update local settings with fresh data from Supabase
            self.settings = freshSettings
            self.saveToStorage() // Also update local storage
            print("✅ [Preferences] Refreshed from Supabase - Language: \(freshSettings.language.displayName)")
        }
    }
}
