import Foundation
import MusicKit

// MARK: - Apple Music playback on iPhone (ApplicationMusicPlayer is unavailable on watchOS)
/// Handles Run Emotion playback from the watch via WatchConnectivity.
@MainActor
final class AppleMusicBridgeiOS {

    static let shared = AppleMusicBridgeiOS()

    private let player = ApplicationMusicPlayer.shared

    private init() {}

    func ensureMusicAuthorized() async -> Bool {
        let s = await MusicAuthorization.request()
        return s == .authorized
    }

    func playTrackIds(_ ids: [String]) async throws {
        guard await ensureMusicAuthorized() else {
            throw NSError(domain: "AppleMusicBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: "Music not authorized"])
        }
        var songs: [Song] = []
        for raw in ids.prefix(20) {
            let mid = MusicItemID(rawValue: raw)
            let req = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: mid)
            let res = try await req.response()
            if let s = res.items.first { songs.append(s) }
        }
        guard !songs.isEmpty else {
            throw NSError(domain: "AppleMusicBridge", code: 2, userInfo: [NSLocalizedDescriptionKey: "No songs resolved"])
        }
        try await player.queue = ApplicationMusicPlayer.Queue(for: songs)
        try await player.play()
    }

    func pause() async throws {
        try await player.pause()
    }

    func stop() async throws {
        try await player.stop()
    }

    func currentStateDictionary() -> [String: Any] {
        guard let entry = player.queue.currentEntry else {
            return ["playing": false, "trackURI": "", "trackName": "", "artist": "", "progressMs": 0, "durationMs": 0]
        }
        let item = entry.item
        let title: String
        let artist: String
        let tid: String
        let dur: Double
        switch item {
        case let song as Song:
            title = song.title
            artist = song.artistName
            tid = song.id.rawValue
            dur = song.duration ?? 0
        default:
            return ["playing": false, "trackURI": "", "trackName": "", "artist": "", "progressMs": 0, "durationMs": 0]
        }
        let progressMs = Int(player.playbackTime * 1000)
        let durationMs = Int(dur * 1000)
        return [
            "playing": player.state.playbackStatus == .playing,
            "trackURI": tid,
            "trackName": title,
            "artist": artist,
            "progressMs": progressMs,
            "durationMs": durationMs
        ]
    }
}
