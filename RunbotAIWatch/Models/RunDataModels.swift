import Foundation
import CoreLocation

// MARK: - Running Session
struct RunSession: Identifiable, Codable {
    let id: String
    let userId: String
    var startTime: Date
    var endTime: Date?
    var distance: Double = 0.0 // in meters
    var duration: TimeInterval = 0.0 // in seconds
    var pace: Double = 0.0 // minutes per km
    var avgSpeed: Double = 0.0 // km/h
    var calories: Double = 0.0
    var elevation: Double = 0.0 // meters
    var maxSpeed: Double = 0.0
    var minSpeed: Double = 0.0
    var locations: [LocationPoint] = []
    var intervals: [RunInterval] = []
    var coachingSessions: [CoachingSession] = []
    var isCompleted: Bool = false
    var isSyncedToSupabase: Bool = false
    var mode: RunMode = .run // run or train mode
    var shadowRunData: ShadowRunData? = nil // populated in train mode
    var shadowReferenceRunId: String? = nil // preserve baseline PR run id for train mode saves
    
    var elapsedTime: TimeInterval {
        if let endTime = endTime {
            return endTime.timeIntervalSince(startTime)
        }
        return Date().timeIntervalSince(startTime)
    }
    
    var formattedDistance: String {
        String(format: "%.2f", distance / 1000.0)
    }
    
    var formattedPace: String {
        let minutes = Int(pace)
        let seconds = Int((pace - Double(minutes)) * 60)
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    var formattedDuration: String {
        let hours = Int(elapsedTime / 3600)
        let minutes = Int((elapsedTime.truncatingRemainder(dividingBy: 3600)) / 60)
        let seconds = Int(elapsedTime.truncatingRemainder(dividingBy: 60))
        
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Location Point
struct LocationPoint: Codable, Equatable {
    let latitude: Double
    let longitude: Double
    let altitude: Double
    let timestamp: Date
    let speed: Double // m/s
    let accuracy: Double
    
    init(location: CLLocation) {
        self.latitude = location.coordinate.latitude
        self.longitude = location.coordinate.longitude
        self.altitude = location.altitude
        self.timestamp = location.timestamp
        self.speed = location.speed
        self.accuracy = location.horizontalAccuracy
    }
}

// MARK: - Run Interval
struct RunInterval: Identifiable, Codable {
    let id: String
    let runId: String
    let index: Int
    let startTime: Date
    let endTime: Date
    let distanceMeters: Double
    let durationSeconds: Double
    let paceMinPerKm: Double
    
    enum CodingKeys: String, CodingKey {
        case id, runId = "run_id", index, startTime = "start_time", 
             endTime = "end_time", distanceMeters = "distance_meters",
             durationSeconds = "duration_seconds", paceMinPerKm = "pace_min_per_km"
    }
}

// MARK: - Coaching Session
struct CoachingSession: Identifiable, Codable {
    let id: String
    let runSessionId: String
    let timestamp: Date
    var feedbackText: String = ""
    var voiceOutput: String = ""
    var durationSeconds: Double = 0.0
    var status: CoachingStatus = .pending
    var coachPersonality: String = "motivated"
    var coachEnergy: CoachEnergy = .medium
    
    enum CodingKeys: String, CodingKey {
        case id, runSessionId, timestamp, feedbackText, voiceOutput, durationSeconds, status, coachPersonality, coachEnergy
    }
}

// MARK: - Coaching Status
enum CoachingStatus: String, Codable {
    case pending
    case speaking
    case completed
    case interrupted
    case timedOut
}

// MARK: - Coach Energy Level
enum CoachEnergy: String, Codable, CaseIterable {
    case low = "Low"
    case medium = "Medium"
    case high = "High"
}

// MARK: - Coach Personality
enum CoachPersonality: String, Codable, CaseIterable {
    case pacer = "Pacer"
    case strategist = "Strategist"
    case finisher = "Finisher"
}

// MARK: - Voice AI Model (for TTS)
enum VoiceAIModel: String, Codable, CaseIterable {
    case apple = "apple"
    case openai = "openai"
    
    var displayName: String {
        switch self {
        case .apple: return "Apple Samantha"
        case .openai: return "OpenAI GPT-4"
        }
    }
}

// MARK: - Voice Option (legacy, maps to VoiceAIModel)
enum VoiceOption: String, Codable, CaseIterable {
    case samantha = "Apple Samantha"
    case gpt4 = "GPT-4 Mini"
}

// MARK: - Supported Languages
enum SupportedLanguage: String, Codable, CaseIterable {
    case english = "english"
    case dutch = "dutch"
    case german = "german"
    case french = "french"
    case spanish = "spanish"
    case portuguese = "portuguese"
    case polish = "polish"
    case hindi = "hindi"
    case bulgarian = "bulgarian"
    case greek = "greek"
    case croatian = "croatian"
    case czech = "czech"
    case danish = "danish"
    case italian = "italian"
    case slovak = "slovak"
    case hungarian = "hungarian"
    case swedish = "swedish"
    case norwegian = "norwegian"
    case finnish = "finnish"
    case russian = "russian"
    case ukrainian = "ukrainian"
    case indonesian = "indonesian"
    case malay = "malay"
    case japanese = "japanese"
    case korean = "korean"
    case mandarin = "mandarin"
    
    var displayName: String {
        switch self {
        case .english: return "English"
        case .dutch: return "Dutch"
        case .german: return "German"
        case .french: return "French"
        case .spanish: return "Spanish"
        case .portuguese: return "Portuguese"
        case .polish: return "Polish"
        case .hindi: return "Hindi"
        case .bulgarian: return "Bulgarian"
        case .greek: return "Greek"
        case .croatian: return "Croatian"
        case .czech: return "Czech"
        case .danish: return "Danish"
        case .italian: return "Italian"
        case .slovak: return "Slovak"
        case .hungarian: return "Hungarian"
        case .swedish: return "Swedish"
        case .norwegian: return "Norwegian"
        case .finnish: return "Finnish"
        case .russian: return "Russian"
        case .ukrainian: return "Ukrainian"
        case .indonesian: return "Indonesian"
        case .malay: return "Malay"
        case .japanese: return "Japanese"
        case .korean: return "Korean"
        case .mandarin: return "Mandarin"
        }
    }
    
    var localeCode: String {
        switch self {
        case .english: return "en-US"
        case .dutch: return "nl-NL"
        case .german: return "de-DE"
        case .french: return "fr-FR"
        case .spanish: return "es-ES"
        case .portuguese: return "pt-PT"
        case .polish: return "pl-PL"
        case .hindi: return "hi-IN"
        case .bulgarian: return "bg-BG"
        case .greek: return "el-GR"
        case .croatian: return "hr-HR"
        case .czech: return "cs-CZ"
        case .danish: return "da-DK"
        case .italian: return "it-IT"
        case .slovak: return "sk-SK"
        case .hungarian: return "hu-HU"
        case .swedish: return "sv-SE"
        case .norwegian: return "nb-NO"
        case .finnish: return "fi-FI"
        case .russian: return "ru-RU"
        case .ukrainian: return "uk-UA"
        case .indonesian: return "id-ID"
        case .malay: return "ms-MY"
        case .japanese: return "ja-JP"
        case .korean: return "ko-KR"
        case .mandarin: return "zh-CN"
        }
    }
}

// MARK: - Running Stats Update
struct RunningStatsUpdate {
    let distance: Double
    let pace: Double
    let avgSpeed: Double
    let calories: Double
    let elevation: Double
    let maxSpeed: Double
    let minSpeed: Double
    let currentLocation: CLLocation?
}

// MARK: - Run Mode
enum RunMode: String, Codable {
    case run = "run"
    case train = "train"
}

// MARK: - Target Distance (Race Type)
enum TargetDistance: String, Codable, CaseIterable {
    case casual = "casual"       // 3km - Easy/recovery run
    case fiveK = "5k"            // 5km
    case tenK = "10k"            // 10km
    case halfMarathon = "half"   // 21.1km
    case marathon = "marathon"   // 42.2km
    case custom = "custom"       // Custom distance
    
    var displayName: String {
        switch self {
        case .casual: return "Casual (3K)"
        case .fiveK: return "5K"
        case .tenK: return "10K"
        case .halfMarathon: return "Half Marathon"
        case .marathon: return "Marathon"
        case .custom: return "Custom"
        }
    }
    
    var distanceMeters: Double {
        switch self {
        case .casual: return 3000
        case .fiveK: return 5000
        case .tenK: return 10000
        case .halfMarathon: return 21097.5
        case .marathon: return 42195
        case .custom: return 0 // Will use custom value
        }
    }
    
    var distanceKm: Double {
        return distanceMeters / 1000
    }
    
    /// Pacing strategy guidance based on race type
    var pacingStrategy: String {
        switch self {
        case .casual:
            return "Easy effort, recovery pace. Focus on enjoyment, not speed."
        case .fiveK:
            return "Fast race. Start controlled, build through middle, strong finish. Zone 4-5 acceptable."
        case .tenK:
            return "Sustained effort. Even pacing critical. Zone 3-4 target. Don't go out too fast."
        case .halfMarathon:
            return "Endurance race. Conservative start, Zone 2-3 for first half. Negative splits ideal."
        case .marathon:
            return "Ultra-conservative start. Zone 2-3 only for first 30km. Save energy for final 10km."
        case .custom:
            return "Pace according to your custom distance goal."
        }
    }
}

// MARK: - PR Model (Shadow Run)
struct PRModel: Identifiable, Codable {
    let id: String
    let runId: String
    let userId: String
    let name: String
    let distanceMeters: Double
    let durationSeconds: Int
    let averagePaceMinPerKm: Double
    let checkpoints: [String: Any]? // jsonb data
    let createdAt: Date
    let isActive: Bool
    
    enum CodingKeys: String, CodingKey {
        case id, name
        case runId = "run_id"
        case userId = "user_id"
        case distanceMeters = "distance_meters"
        case durationSeconds = "duration_seconds"
        case averagePaceMinPerKm = "average_pace_min_per_km"
        case checkpoints
        case createdAt = "created_at"
        case isActive = "is_active"
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        runId = try container.decode(String.self, forKey: .runId)
        userId = try container.decode(String.self, forKey: .userId)
        name = try container.decode(String.self, forKey: .name)
        
        // Database returns these as numbers, not strings
        distanceMeters = try container.decode(Double.self, forKey: .distanceMeters)
        durationSeconds = try container.decode(Int.self, forKey: .durationSeconds)
        averagePaceMinPerKm = try container.decode(Double.self, forKey: .averagePaceMinPerKm)
        
        // Skip checkpoints - it's optional jsonb data we don't use in watch app
        checkpoints = nil
        
        let dateString = try container.decode(String.self, forKey: .createdAt)
        createdAt = ISO8601DateFormatter().date(from: dateString) ?? Date()
        
        isActive = try container.decode(Bool.self, forKey: .isActive)
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(runId, forKey: .runId)
        try container.encode(userId, forKey: .userId)
        try container.encode(name, forKey: .name)
        try container.encode(distanceMeters, forKey: .distanceMeters)
        try container.encode(durationSeconds, forKey: .durationSeconds)
        try container.encode(averagePaceMinPerKm, forKey: .averagePaceMinPerKm)
        // Skip checkpoints as it's optional and complex
        try container.encode(ISO8601DateFormatter().string(from: createdAt), forKey: .createdAt)
        try container.encode(isActive, forKey: .isActive)
    }
}

// MARK: - Shadow Run Comparison Data
struct ShadowRunData: Codable {
    let prModel: PRModel
    let intervals: [ShadowInterval]
    var currentKm: Int = 0
    var timeDifference: Double = 0.0 // seconds ahead(+) or behind(-)
    var paceDifference: Double = 0.0 // pace difference
}

// MARK: - Shadow Interval (from run_intervals)
struct ShadowInterval: Identifiable, Codable {
    let id: String
    let runId: String
    let userId: String
    let kilometer: Int
    let durationS: Double
    let pacePerKm: Double
    let averageHeartRate: Double?
    let maxHeartRate: Double?
    let latitude: Double?
    let longitude: Double?
    let timeRecorded: Date?
    
    enum CodingKeys: String, CodingKey {
        case id
        case runId = "run_id"
        case userId = "user_id"
        case kilometer
        case durationS = "duration_s"
        case pacePerKm = "pace_per_km"
        case averageHeartRate = "average_heart_rate"
        case maxHeartRate = "max_heart_rate"
        case latitude, longitude
        case timeRecorded = "time_recorded"
    }
}
