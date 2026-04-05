import Foundation

/// Which music service powers Run Emotion (mood-adaptive playback).
enum RunEmotionMusicSource: String, CaseIterable, Identifiable {
    case spotify = "spotify"
    case appleMusic = "appleMusic"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .spotify: return "Spotify"
        case .appleMusic: return "Apple Music"
        }
    }

    var shortLabel: String {
        switch self {
        case .spotify: return "Spotify Connect"
        case .appleMusic: return "Apple Music"
        }
    }

    private static let udKey = "run_emotion_music_source"

    static var current: RunEmotionMusicSource {
        get {
            let raw = UserDefaults.standard.string(forKey: udKey) ?? RunEmotionMusicSource.spotify.rawValue
            return RunEmotionMusicSource(rawValue: raw) ?? .spotify
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: udKey)
        }
    }
}
