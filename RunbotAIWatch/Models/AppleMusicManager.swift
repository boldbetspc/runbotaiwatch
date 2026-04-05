import Foundation
import Combine
import MusicKit
import WatchConnectivity
import AVFoundation

// MARK: - Apple Music for Run Emotion (watch)
/// MusicKit cannot queue playback on watchOS — the iPhone Runbot Wrapper runs `ApplicationMusicPlayer`.
/// This manager: Music authorization + library playlists on watch, playback via WatchConnectivity.
@MainActor
final class AppleMusicManager: ObservableObject {

    static let shared = AppleMusicManager()

    @Published var isConnected = false
    @Published var isPlaying = false
    @Published var isAuthenticating = false
    @Published var connectionError: String?
    @Published var currentTrackName: String = ""
    @Published var currentTrackURI: String = ""
    @Published var currentTrackArtist: String = ""
    @Published var currentTrackBPM: Int = 0
    @Published var activeDeviceName: String = "iPhone"
    @Published var masterPlaylistId: String? {
        didSet { UserDefaults.standard.set(masterPlaylistId, forKey: AppleMusicManager.kMasterPlaylistId) }
    }
    @Published var masterPlaylistName: String = "" {
        didSet { UserDefaults.standard.set(masterPlaylistName, forKey: AppleMusicManager.kMasterPlaylistName) }
    }
    @Published var userPlaylists: [SpotifyPlaylist] = []
    @Published var appleMusicEnabled: Bool {
        didSet { UserDefaults.standard.set(appleMusicEnabled, forKey: AppleMusicManager.kEnabled) }
    }

    private static let kEnabled = "run_emotion_apple_music_enabled"
    private static let kMasterPlaylistId = "apple_music_master_playlist_id"
    private static let kMasterPlaylistName = "apple_music_master_playlist_name"

    private var recentTrackIds: [String] = []
    private let antiRepeatBufferSize = 20
    private var pollTimer: Timer?
    private let pollInterval: TimeInterval = 4.0

    private var wcObserver: NSObjectProtocol?

    private init() {
        masterPlaylistId = UserDefaults.standard.string(forKey: AppleMusicManager.kMasterPlaylistId)
        masterPlaylistName = UserDefaults.standard.string(forKey: AppleMusicManager.kMasterPlaylistName) ?? ""
        appleMusicEnabled = UserDefaults.standard.object(forKey: AppleMusicManager.kEnabled) as? Bool ?? false

        wcObserver = NotificationCenter.default.addObserver(
            forName: .runEmotionTrackChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                guard let self else { return }
                if let uri = note.userInfo?["trackURI"] as? String {
                    self.currentTrackURI = uri
                }
                if let name = note.userInfo?["trackName"] as? String {
                    self.currentTrackName = name
                }
            }
        }
    }

    deinit {
        if let o = wcObserver { NotificationCenter.default.removeObserver(o) }
    }

    // MARK: - Auth (on-watch library)

    func requestMusicAccess() async {
        isAuthenticating = true
        connectionError = nil
        defer { isAuthenticating = false }

        // If already authorized skip the request (avoids hang in simulator)
        if MusicAuthorization.currentStatus == .authorized {
            isConnected = true
            await loadUserPlaylists()
            return
        }

        // Wrap in a 10s timeout — simulator has no Music app so the dialog never appears
        let status: MusicAuthorization.Status = await withTaskGroup(of: MusicAuthorization.Status?.self) { group in
            group.addTask { await MusicAuthorization.request() }
            group.addTask {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                return nil   // timeout sentinel
            }
            for await result in group {
                group.cancelAll()
                return result ?? .notDetermined
            }
            return .notDetermined
        }

        switch status {
        case .authorized:
            isConnected = true
            print("🍎 [AppleMusic] MusicKit authorized on watch")
            await loadUserPlaylists()
        case .denied, .restricted:
            isConnected = false
            connectionError = "Apple Music access denied — enable in Settings > Music"
        case .notDetermined:
            isConnected = false
            connectionError = "Authorization timed out — run on a real device to grant access"
        @unknown default:
            isConnected = false
            connectionError = "Unknown Music authorization status"
        }
    }

    func disconnect() {
        Task { await stopPlayback() }
        isConnected = false
        masterPlaylistId = nil
        masterPlaylistName = ""
        userPlaylists = []
        currentTrackName = ""
        currentTrackURI = ""
        currentTrackArtist = ""
        connectionError = nil
        stopPolling()
        print("🍎 [AppleMusic] Disconnected")
    }

    func loadUserPlaylists() async {
        guard MusicAuthorization.currentStatus == .authorized else { return }
        do {
            let request = MusicLibraryRequest<Playlist>()
            let response = try await request.response()
            let items = response.items.map { pl in
                SpotifyPlaylist(
                    id: pl.id.rawValue,
                    name: pl.name,
                    trackCount: 0,
                    isRunbot: pl.name.lowercased().contains("runbot")
                )
            }
            userPlaylists = items
            if masterPlaylistId == nil, let best = items.first(where: { $0.isRunbot }) ?? items.first {
                masterPlaylistId = best.id
                masterPlaylistName = best.name
            }
            print("🍎 [AppleMusic] Loaded \(items.count) playlists")
        } catch {
            print("❌ [AppleMusic] Playlist load error: \(error.localizedDescription)")
        }
    }

    func fetchPlaylistTracks(_ playlistId: String) async -> [RunEmotionTrack] {
        guard MusicAuthorization.currentStatus == .authorized else { return [] }
        if let pl = await loadLibraryPlaylist(id: playlistId) {
            return await tracksFromPlaylist(pl)
        }
        return await fetchCatalogPlaylistTracks(playlistId: playlistId)
    }

    private func loadLibraryPlaylist(id: String) async -> Playlist? {
        do {
            let request = MusicLibraryRequest<Playlist>()
            let response = try await request.response()
            return response.items.first { $0.id.rawValue == id }
        } catch { return nil }
    }

    private func tracksFromPlaylist(_ playlist: Playlist) async -> [RunEmotionTrack] {
        do {
            let detailed = try await playlist.with([.tracks])
            guard let collection = detailed.tracks else { return [] }
            var out: [RunEmotionTrack] = []
            for track in collection {
                let ms = Int((track.duration ?? 0) * 1000)
                out.append(RunEmotionTrack(
                    id: track.id.rawValue,
                    name: track.title,
                    artist: track.artistName,
                    durationMs: ms
                ))
            }
            return out
        } catch {
            return []
        }
    }

    private func fetchCatalogPlaylistTracks(playlistId: String) async -> [RunEmotionTrack] {
        do {
            let id = MusicItemID(rawValue: playlistId)
            let request = MusicCatalogResourceRequest<Playlist>(matching: \.id, equalTo: id)
            let response = try await request.response()
            guard let playlist = response.items.first else { return [] }
            return await tracksFromPlaylist(playlist)
        } catch {
            return []
        }
    }

    // MARK: - Playback (iPhone bridge)

    func startPlayback() async -> Bool {
        guard MusicAuthorization.currentStatus == .authorized else {
            connectionError = "Authorize Apple Music on watch first"
            return false
        }
        guard let pid = masterPlaylistId else {
            connectionError = "Pick a playlist in Devices"
            return false
        }
        let tracks = await fetchPlaylistTracks(pid)
        guard !tracks.isEmpty else { return false }
        let idx = Int.random(in: 0..<min(tracks.count, 20))
        let slice = Array(tracks[idx..<tracks.count])
        return await playRunEmotionTracks(slice)
    }

    func playTracks(_ ids: [String]) async -> Bool {
        guard let pid = masterPlaylistId else { return false }
        let all = await fetchPlaylistTracks(pid)
        let idSet = Set(ids)
        let ordered = all.filter { idSet.contains($0.id) }
        let use = ordered.isEmpty ? all : ordered
        return await playRunEmotionTracks(use)
    }

    private func playRunEmotionTracks(_ tracks: [RunEmotionTrack]) async -> Bool {
        guard !tracks.isEmpty else { return false }
        let ids = tracks.prefix(20).map(\.id)
        guard WCSession.default.activationState == .activated else {
            connectionError = "iPhone not connected"
            return false
        }

        return await withCheckedContinuation { cont in
            let msg: [String: Any] = [
                "command": "appleMusicPlayTracks",
                "trackIds": ids
            ]
            if WCSession.default.isReachable {
                WCSession.default.sendMessage(msg, replyHandler: { reply in
                    Task { @MainActor in
                        if (reply["ok"] as? Bool) == true {
                            self.isPlaying = true
                            self.connectionError = nil
                            self.startPolling()
                            await self.refreshStateFromPhone()
                            cont.resume(returning: true)
                        } else {
                            self.connectionError = (reply["error"] as? String) ?? "Playback failed"
                            cont.resume(returning: false)
                        }
                    }
                }, errorHandler: { err in
                    Task { @MainActor in
                        self.connectionError = err.localizedDescription
                        cont.resume(returning: false)
                    }
                })
            } else {
                self.connectionError = "Open Runbot on iPhone — Apple Music plays on phone"
                cont.resume(returning: false)
            }
        }
    }

    func switchPlaylist(_ playlistId: String) async -> Bool {
        masterPlaylistId = playlistId
        if let name = userPlaylists.first(where: { $0.id == playlistId })?.name {
            masterPlaylistName = name
        }
        return await startPlayback()
    }

    func stopPlayback() async {
        guard WCSession.default.isReachable else {
            isPlaying = false
            stopPolling()
            return
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            WCSession.default.sendMessage(["command": "appleMusicStop"], replyHandler: { _ in
                Task { @MainActor in
                    self.isPlaying = false
                    self.stopPolling()
                    cont.resume()
                }
            }, errorHandler: { _ in
                Task { @MainActor in
                    self.isPlaying = false
                    self.stopPolling()
                    cont.resume()
                }
            })
        }
    }

    func duckVolume() async {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.duckOthers])
        try? session.setActive(true)
    }

    func restoreVolume() async {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func discoverActiveDevice() async -> String? {
        activeDeviceName = WCSession.default.isReachable ? "iPhone (Music)" : "—"
        return activeDeviceName
    }

    func prepareForRun() async {
        if MusicAuthorization.currentStatus != .authorized {
            await requestMusicAccess()
        }
        if userPlaylists.isEmpty {
            await loadUserPlaylists()
        }
    }

    struct PlayerState {
        let trackName: String
        let trackURI: String
        let artistName: String
        let isPlaying: Bool
        let progressMs: Int
        let durationMs: Int
        let volumePercent: Int
    }

    func fetchPlayerState() async -> PlayerState? {
        await refreshStateFromPhone()
        guard !currentTrackURI.isEmpty else { return nil }
        return PlayerState(
            trackName: currentTrackName,
            trackURI: currentTrackURI,
            artistName: currentTrackArtist,
            isPlaying: isPlaying,
            progressMs: 0,
            durationMs: 0,
            volumePercent: 100
        )
    }

    private func refreshStateFromPhone() async {
        guard WCSession.default.isReachable else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            WCSession.default.sendMessage(["command": "appleMusicStateRequest"], replyHandler: { reply in
                Task { @MainActor in
                    self.applyNowPlayingPayload(reply)
                    cont.resume()
                }
            }, errorHandler: { _ in
                cont.resume()
            })
        }
    }

    func applyNowPlayingFromWC(_ message: [String: Any]) {
        applyNowPlayingPayload(message)
    }

    private func applyNowPlayingPayload(_ reply: [String: Any]) {
        let previousURI = currentTrackURI
        if let name = reply["trackName"] as? String { currentTrackName = name }
        if let uri = reply["trackURI"] as? String { currentTrackURI = uri }
        if let a = reply["artist"] as? String { currentTrackArtist = a }
        if let p = reply["playing"] as? Bool { isPlaying = p }
        if let uri = reply["trackURI"] as? String, !uri.isEmpty, uri != previousURI {
            NotificationCenter.default.post(
                name: .runEmotionTrackChanged,
                object: nil,
                userInfo: ["trackURI": uri, "trackName": currentTrackName]
            )
        }
    }

    private func startPolling() {
        stopPolling()
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshStateFromPhone()
            }
        }
        if let t = pollTimer { RunLoop.main.add(t, forMode: .common) }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func isInAntiRepeat(_ id: String) -> Bool { recentTrackIds.contains(id) }

    func clearAntiRepeat() { recentTrackIds.removeAll() }
}
