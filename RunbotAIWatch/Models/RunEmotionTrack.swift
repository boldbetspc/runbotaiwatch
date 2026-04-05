import Foundation

/// Unified track model for Run Emotion ranking (Spotify URIs or Apple Music catalog IDs).
struct RunEmotionTrack: Identifiable, Equatable {
    var id: String
    let name: String
    let artist: String
    let durationMs: Int
}

extension SpotifyTrack {
    func asRunEmotionTrack() -> RunEmotionTrack {
        RunEmotionTrack(id: uri, name: name, artist: artist, durationMs: durationMs)
    }
}

extension Notification.Name {
    /// Fired when Run Emotion track changes (Spotify or Apple Music).
    static let runEmotionTrackChanged = Notification.Name("RunEmotionTrackChanged")
}
