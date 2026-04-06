import Foundation
import Combine
import AVFoundation
import AuthenticationServices
import CryptoKit
import WatchConnectivity

// MARK: - Spotify Manager for watchOS
// Handles OAuth via ASWebAuthenticationSession + Supabase edge function,
// Spotify Web API playback, device discovery, track polling, volume ducking, and song filtering.
final class SpotifyManager: NSObject, ObservableObject {
    
    static let shared = SpotifyManager()
    
    // MARK: - Published State
    @Published var isConnected = false
    @Published var isPlaying = false
    @Published var currentTrackName: String = ""
    @Published var currentTrackURI: String = ""
    @Published var currentTrackArtist: String = ""
    @Published var currentTrackBPM: Int = 0
    @Published var activeDeviceId: String?
    @Published var activeDeviceName: String = ""
    @Published var spotifyEnabled = false
    @Published var masterPlaylistId: String? {
        didSet { UserDefaults.standard.set(masterPlaylistId, forKey: "spotify_master_playlist_id") }
    }
    @Published var masterPlaylistName: String = "" {
        didSet { UserDefaults.standard.set(masterPlaylistName, forKey: "spotify_master_playlist_name") }
    }
    @Published var connectionError: String?
    @Published var userPlaylists: [SpotifyPlaylist] = []
    @Published var isAuthenticating = false
    
    // MARK: - Token State
    private var accessToken: String? {
        get { UserDefaults.standard.string(forKey: "spotify_access_token") }
        set { UserDefaults.standard.set(newValue, forKey: "spotify_access_token") }
    }
    private var refreshToken: String? {
        get { UserDefaults.standard.string(forKey: "spotify_refresh_token") }
        set { UserDefaults.standard.set(newValue, forKey: "spotify_refresh_token") }
    }
    private var tokenExpiresAt: Date? {
        get {
            let ts = UserDefaults.standard.double(forKey: "spotify_token_expires_at")
            return ts > 0 ? Date(timeIntervalSince1970: ts) : nil
        }
        set {
            UserDefaults.standard.set(newValue?.timeIntervalSince1970 ?? 0, forKey: "spotify_token_expires_at")
        }
    }
    
    // MARK: - Configuration
    private let supabaseURL: String
    private let supabaseKey: String
    private let spotifyClientId: String
    private let spotifyRedirectURI = "runbot://spotify-callback"
    private let spotifyAPIBase = "https://api.spotify.com/v1"
    private let spotifyScopes = "user-read-playback-state user-modify-playback-state user-read-currently-playing playlist-read-private playlist-read-collaborative"
    private let session = URLSession.shared
    
    // PKCE: store verifier until callback (Spotify requires PKCE for mobile/watch)
    private var pendingPKCEVerifier: String?
    
    // Track polling
    private var trackPollTimer: Timer?
    private let trackPollInterval: TimeInterval = 5.0
    
    // Anti-repeat ring buffer
    private var recentTrackURIs: [String] = []
    private let antiRepeatBufferSize = 20
    
    // Volume ducking
    private var originalVolume: Int = 100
    private var isDucked = false
    
    // Listener for tokens coming back from iOS via WatchConnectivity
    private var authTokenObserver: NSObjectProtocol?
    
    // MARK: - Init
    
    private override init() {
        if let config = ConfigLoader.loadConfig() {
            self.supabaseURL = (config["SUPABASE_URL"] as? String) ?? ""
            self.supabaseKey = (config["SUPABASE_ANON_KEY"] as? String) ?? ""
            self.spotifyClientId = (config["SPOTIFY_CLIENT_ID"] as? String) ?? "e9e755d6173346b5a1c6235dfd43c5fd"
        } else {
            self.supabaseURL = ""
            self.supabaseKey = ""
            self.spotifyClientId = "e9e755d6173346b5a1c6235dfd43c5fd"
        }
        super.init()
        
        if accessToken != nil {
            isConnected = true
        }
        
        masterPlaylistId = UserDefaults.standard.string(forKey: "spotify_master_playlist_id")
        masterPlaylistName = UserDefaults.standard.string(forKey: "spotify_master_playlist_name") ?? ""
        
        // Legacy / in-app posts: userInfo is [AnyHashable: Any] — never use `as? [String: Any]` (it fails).
        authTokenObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("SpotifyTokensFromPhone"),
            object: nil, queue: .main
        ) { [weak self] note in
            guard let self = self,
                  let tokens = Self.tokensDictionary(from: note.userInfo) else { return }
            self.completeAuthWithTokensFromPhone(tokens)
        }
        
        // Check if tokens arrived via applicationContext while we weren't running
        checkForPendingTokens()
    }
    
    deinit {
        if let obs = authTokenObserver { NotificationCenter.default.removeObserver(obs) }
    }
    
    // MARK: - PKCE Helpers (Spotify requires PKCE for mobile/watch)
    
    private static func makeCodeVerifier() -> String? {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, 32, &bytes) == errSecSuccess else { return nil }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    
    private static func makeCodeChallenge(verifier: String) -> String {
        let data = Data(verifier.utf8)
        let hash = SHA256.hash(data: data)
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    
    // MARK: - Auth (ASWebAuthenticationSession + PKCE)
    
    /// Spotify login on watch. Uses PKCE (required by Spotify for mobile/watch).
    /// Dashboard: Redirect URI exactly "runbot://spotify-callback". In Development Mode, add your email to User Management.
    func authenticateWithWebAuth() {
        guard let codeVerifier = Self.makeCodeVerifier() else {
            DispatchQueue.main.async { self.connectionError = "Could not start login" }
            return
        }
        let codeChallenge = Self.makeCodeChallenge(verifier: codeVerifier)
        let state = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16).description
        
        pendingPKCEVerifier = codeVerifier
        
        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: spotifyClientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: spotifyRedirectURI),
            URLQueryItem(name: "scope", value: spotifyScopes),
            URLQueryItem(name: "state", value: String(state)),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "show_dialog", value: "true")
        ]
        
        guard let authURL = components.url else {
            pendingPKCEVerifier = nil
            DispatchQueue.main.async { self.connectionError = "Invalid auth URL" }
            return
        }
        
        let callbackScheme = "runbot"
        
        DispatchQueue.main.async { self.isAuthenticating = true }
        
        let webAuthSession = ASWebAuthenticationSession(
            url: authURL,
            callbackURLScheme: callbackScheme
        ) { [weak self] callbackURL, error in
            guard let self = self else { return }
            
            DispatchQueue.main.async { self.isAuthenticating = false }
            
            defer { self.pendingPKCEVerifier = nil }
            
            if let error = error {
                let nsError = error as NSError
                if nsError.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                    print("🔵 [Spotify] User cancelled login")
                    return
                }
                print("❌ [Spotify] Web auth error: \(error.localizedDescription)")
                DispatchQueue.main.async { self.connectionError = "Login failed" }
                return
            }
            
            guard let callbackURL = callbackURL,
                  let comps = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
                  let code = comps.queryItems?.first(where: { $0.name == "code" })?.value else {
                print("❌ [Spotify] No code in callback")
                DispatchQueue.main.async { self.connectionError = "No authorization code received" }
                return
            }
            
            let verifier = self.pendingPKCEVerifier
            print("✅ [Spotify] Got auth code, exchanging for tokens (PKCE)...")
            Task {
                let success = await self.exchangeCode(code, codeVerifier: verifier)
                if !success {
                    await MainActor.run { self.connectionError = "Token exchange failed" }
                }
            }
        }
        
        // Non-ephemeral so Spotify can complete login (cookies/session). Try false if "Something went wrong".
        webAuthSession.prefersEphemeralWebBrowserSession = false
        webAuthSession.start()
    }
    
    // MARK: - Auth via iPhone (reCAPTCHA workaround + reliable network)
    
    /// Build the Spotify auth URL with PKCE, send everything to the paired iPhone.
    /// iPhone handles login + token exchange (reliable network), sends finished tokens back.
    func authenticateViaPhone() {
        guard let codeVerifier = Self.makeCodeVerifier() else {
            DispatchQueue.main.async { self.connectionError = "Could not start login" }
            return
        }
        let codeChallenge = Self.makeCodeChallenge(verifier: codeVerifier)
        let state = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16).description
        
        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: spotifyClientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: spotifyRedirectURI),
            URLQueryItem(name: "scope", value: spotifyScopes),
            URLQueryItem(name: "state", value: String(state)),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "show_dialog", value: "true")
        ]
        
        guard let authURL = components.url else {
            DispatchQueue.main.async { self.connectionError = "Invalid auth URL" }
            return
        }
        
        DispatchQueue.main.async {
            self.isAuthenticating = true
            self.connectionError = nil
        }
        
        WatchConnectivityManager.shared.sendSpotifyAuthRequest(
            url: authURL.absoluteString,
            codeVerifier: codeVerifier,
            redirectURI: spotifyRedirectURI,
            clientId: spotifyClientId
        )
        print("📱 [Spotify] Auth request sent to iPhone (iPhone will do full exchange)")
        
        // Auto-timeout after 90 seconds so the UI doesn't hang forever
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) { [weak self] in
            guard let self = self, self.isAuthenticating else { return }
            self.isAuthenticating = false
            self.connectionError = "Timed out — tap to retry"
            print("⏰ [Spotify] Auth via iPhone timed out")
        }
    }
    
    /// WatchConnectivity delivers `[String: Any]` directly — use this path (NotificationCenter casts are unreliable).
    func applyTokensFromPhone(_ payload: [String: Any]) {
        completeAuthWithTokensFromPhone(payload)
    }
    
    private static func tokensDictionary(from userInfo: [AnyHashable: Any]?) -> [String: Any]? {
        guard let userInfo = userInfo, !userInfo.isEmpty else { return nil }
        var out: [String: Any] = [:]
        for (k, v) in userInfo {
            guard let sk = k as? String else { continue }
            out[sk] = v
        }
        return out["access_token"] != nil ? out : nil
    }
    
    /// Called when the iOS app sends finished tokens back via WatchConnectivity.
    /// Always processes tokens — even if already connected (handles re-auth and token refresh).
    private func completeAuthWithTokensFromPhone(_ tokens: [String: Any]) {
        let success = processTokenResponse(tokens)
        
        // Apply suggested playlist from iOS if we don't have one
        if success,
           masterPlaylistId == nil || masterPlaylistId!.isEmpty,
           let pid = tokens["suggested_playlist_id"] as? String {
            let pname = tokens["suggested_playlist_name"] as? String ?? ""
            DispatchQueue.main.async {
                self.masterPlaylistId = pid
                self.masterPlaylistName = pname
            }
            print("🎵 [Spotify] Using playlist from iPhone: \(pname)")
        }
        
        DispatchQueue.main.async {
            self.isAuthenticating = false
            if success {
                print("✅ [Spotify] Tokens received from iPhone — connected!")
            } else {
                self.connectionError = "Token exchange failed on iPhone"
            }
        }
    }
    
    /// Check WCSession applicationContext for tokens that arrived while the app wasn't active.
    /// Called at init and can be called manually to poll for pending tokens.
    func checkForPendingTokens() {
        guard WCSession.isSupported() else { return }
        let ctx = WCSession.default.receivedApplicationContext
        guard ctx["command"] as? String == "spotifyTokens",
              let token = ctx["access_token"] as? String, !token.isEmpty else { return }
        print("📱 [Spotify] Found pending tokens in applicationContext")
        completeAuthWithTokensFromPhone(ctx)
    }
    
    func exchangeCode(_ code: String, codeVerifier: String? = nil) async -> Bool {
        guard !supabaseURL.isEmpty else { return false }
        
        let url = URL(string: "\(supabaseURL)/functions/v1/spotify-auth")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(supabaseKey, forHTTPHeaderField: "apikey")
        request.setValue(getSupabaseAuthHeader(), forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        
        // If code_verifier is set, edge function must call Spotify token endpoint with PKCE
        // (grant_type=authorization_code, code, redirect_uri, client_id, code_verifier — no client_secret).
        var body: [String: Any] = ["action": "exchange", "code": code, "redirect_uri": spotifyRedirectURI]
        if let verifier = codeVerifier {
            body["code_verifier"] = verifier
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                print("❌ [Spotify] Code exchange failed")
                return false
            }
            
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return processTokenResponse(json)
            }
        } catch {
            print("❌ [Spotify] Code exchange error: \(error.localizedDescription)")
        }
        return false
    }
    
    func refreshAccessToken() async -> Bool {
        guard let refresh = refreshToken, !supabaseURL.isEmpty else { return false }
        
        let url = URL(string: "\(supabaseURL)/functions/v1/spotify-auth")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(supabaseKey, forHTTPHeaderField: "apikey")
        request.setValue(getSupabaseAuthHeader(), forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        
        let body: [String: Any] = ["action": "refresh", "refresh_token": refresh]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                print("❌ [Spotify] Token refresh failed, keeping refresh token for retry")
                return false
            }
            
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return processTokenResponse(json)
            }
        } catch {
            print("❌ [Spotify] Token refresh error: \(error.localizedDescription)")
        }
        return false
    }
    
    private func processTokenResponse(_ json: [String: Any]) -> Bool {
        guard let token = json["access_token"] as? String else { return false }
        
        accessToken = token
        if let refresh = json["refresh_token"] as? String {
            refreshToken = refresh
        }
        let expiresIn: TimeInterval
        if let d = json["expires_in"] as? Double {
            expiresIn = d
        } else if let i = json["expires_in"] as? Int {
            expiresIn = TimeInterval(i)
        } else if let n = json["expires_in"] as? NSNumber {
            expiresIn = n.doubleValue
        } else {
            expiresIn = 3600
        }
        tokenExpiresAt = Date().addingTimeInterval(expiresIn)
        
        DispatchQueue.main.async {
            self.isConnected = true
            self.connectionError = nil
        }
        print("✅ [Spotify] Token acquired, expires in \(Int(expiresIn))s. Credentials stored permanently.")
        
        Task { await autoSetupAfterConnect() }
        return true
    }
    
    /// After successful connection, auto-load playlists, pick one if needed, and discover device.
    private func autoSetupAfterConnect() async {
        async let deviceTask: String? = discoverActiveDevice()
        async let playlistTask: () = autoSelectPlaylistIfNeeded()
        _ = await deviceTask
        await playlistTask
    }
    
    /// Load user playlists and auto-select the best one if none is saved.
    func autoSelectPlaylistIfNeeded() async {
        await loadUserPlaylists()
        
        if masterPlaylistId != nil, !masterPlaylistId!.isEmpty {
            print("🎵 [Spotify] Playlist already selected: \(masterPlaylistName)")
            return
        }
        
        let playlists = await MainActor.run { userPlaylists }
        guard !playlists.isEmpty else {
            print("⚠️ [Spotify] No playlists available to auto-select")
            return
        }
        
        let chosen = playlists.first(where: { $0.isRunbot }) ?? playlists.first!
        await MainActor.run {
            self.masterPlaylistId = chosen.id
            self.masterPlaylistName = chosen.name
        }
        print("🎵 [Spotify] Auto-selected playlist: \(chosen.name) (\(chosen.trackCount) tracks)")
    }
    
    /// Ensure token is valid; auto-refresh silently using stored refresh token.
    /// Refresh token persists in UserDefaults forever — user never re-auths.
    func ensureValidToken() async -> Bool {
        guard accessToken != nil else {
            if refreshToken != nil {
                print("🔄 [Spotify] Access token missing but refresh token available, refreshing...")
                return await refreshAccessToken()
            }
            return false
        }
        
        if let expires = tokenExpiresAt, Date().addingTimeInterval(300) >= expires {
            print("🔄 [Spotify] Token expiring soon, refreshing silently...")
            return await refreshAccessToken()
        }
        return true
    }
    
    func disconnect() {
        accessToken = nil
        refreshToken = nil
        tokenExpiresAt = nil
        DispatchQueue.main.async {
            self.isConnected = false
            self.isPlaying = false
            self.isAuthenticating = false
            self.connectionError = nil
            self.currentTrackName = ""
            self.currentTrackURI = ""
            self.currentTrackArtist = ""
            self.activeDeviceId = nil
            self.activeDeviceName = ""
            self.masterPlaylistId = nil
            self.masterPlaylistName = ""
            self.userPlaylists = []
        }
        stopTrackPolling()
        print("🔴 [Spotify] Disconnected and credentials cleared")
    }
    
    /// Cancel any in-progress auth and reset to clean state
    func cancelAuth() {
        DispatchQueue.main.async {
            self.isAuthenticating = false
            self.connectionError = nil
        }
        print("🔴 [Spotify] Auth cancelled — ready for retry")
    }
    
    // MARK: - Device Discovery
    
    func discoverActiveDevice() async -> String? {
        guard await ensureValidToken(), let token = accessToken else { return nil }
        
        let url = URL(string: "\(spotifyAPIBase)/me/player/devices")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10
        
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let devices = json["devices"] as? [[String: Any]] {
                // Prefer active device, then smartphone, then any
                let active = devices.first(where: { $0["is_active"] as? Bool == true })
                let phone = devices.first(where: { ($0["type"] as? String)?.lowercased() == "smartphone" })
                let chosen = active ?? phone ?? devices.first
                
                if let device = chosen,
                   let id = device["id"] as? String,
                   let name = device["name"] as? String {
                    await MainActor.run {
                        self.activeDeviceId = id
                        self.activeDeviceName = name
                    }
                    print("🎵 [Spotify] Active device: \(name) (\(id.prefix(8))...)")
                    return id
                }
            }
        } catch {
            print("❌ [Spotify] Device discovery error: \(error.localizedDescription)")
        }
        return nil
    }
    
    private func setShuffleEnabled(_ enabled: Bool, deviceId: String, token: String) async {
        var components = URLComponents(string: "\(spotifyAPIBase)/me/player/shuffle")!
        components.queryItems = [
            URLQueryItem(name: "state", value: enabled ? "true" : "false"),
            URLQueryItem(name: "device_id", value: deviceId)
        ]
        guard let url = components.url else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10
        do {
            let (_, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 200 || http.statusCode == 204 {
                print("🎵 [Spotify] Shuffle \(enabled ? "enabled" : "disabled") for device")
            } else {
                print("⚠️ [Spotify] Shuffle API non-success (playback may still work)")
            }
        } catch {
            print("⚠️ [Spotify] Shuffle request failed: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Playback Control
    
    func startPlayback(playlistId: String? = nil, trackURIs: [String]? = nil) async -> Bool {
        guard await ensureValidToken(), let token = accessToken else {
            print("❌ [Spotify] No valid token for playback")
            return false
        }
        
        // Auto-select playlist if none set
        let resolvedPlaylistId = playlistId ?? masterPlaylistId
        if resolvedPlaylistId == nil && (trackURIs == nil || trackURIs!.isEmpty) {
            print("🎵 [Spotify] No playlist set — auto-selecting...")
            await autoSelectPlaylistIfNeeded()
        }
        let finalPlaylistId = playlistId ?? masterPlaylistId
        
        // Discover device
        let deviceId: String?
        if let active = activeDeviceId {
            deviceId = active
        } else {
            deviceId = await discoverActiveDevice()
        }
        
        if deviceId == nil {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            _ = await discoverActiveDevice()
        }
        if activeDeviceId == nil {
            print("🎵 [Spotify] No Connect device — asking iPhone to open Spotify, then retrying…")
            await MainActor.run { connectionError = "Open Spotify on iPhone…" }
            WatchConnectivityManager.shared.requestIPhoneOpenSpotifyApp()
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            _ = await discoverActiveDevice()
        }
        if activeDeviceId == nil {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            _ = await discoverActiveDevice()
        }
        guard let device = activeDeviceId else {
            await MainActor.run {
                connectionError = "No Spotify device. Open Spotify on your iPhone (Premium) and try again."
            }
            print("❌ [Spotify] No device found after retries")
            return false
        }
        
        let urlStr = "\(spotifyAPIBase)/me/player/play?device_id=\(device)"
        var request = URLRequest(url: URL(string: urlStr)!)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10
        
        var body: [String: Any] = [:]
        if let pid = finalPlaylistId {
            body["context_uri"] = "spotify:playlist:\(pid)"
            body["offset"] = ["position": Int.random(in: 0..<20)]
        } else if let uris = trackURIs, !uris.isEmpty {
            body["uris"] = uris
        }
        
        if !body.isEmpty {
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        
        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse {
                if http.statusCode == 200 || http.statusCode == 204 {
                    await setShuffleEnabled(true, deviceId: device, token: token)
                    await MainActor.run {
                        self.isPlaying = true
                        self.connectionError = nil
                    }
                    startTrackPolling()
                    print("▶️ [Spotify] Playback started on \(activeDeviceName)")
                    return true
                } else {
                    let bodyStr = String(data: data, encoding: .utf8) ?? ""
                    print("❌ [Spotify] Playback failed HTTP \(http.statusCode): \(bodyStr)")
                    await MainActor.run { connectionError = "Playback error (\(http.statusCode))" }
                }
            }
        } catch {
            print("❌ [Spotify] Start playback error: \(error.localizedDescription)")
            await MainActor.run { connectionError = "Playback error" }
        }
        return false
    }
    
    func stopPlayback() async {
        guard await ensureValidToken(), let token = accessToken else { return }
        
        let url = URL(string: "\(spotifyAPIBase)/me/player/pause")!
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10
        
        do {
            let (_, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse,
               http.statusCode == 200 || http.statusCode == 204 {
                await MainActor.run { self.isPlaying = false }
                stopTrackPolling()
                print("⏸ [Spotify] Playback paused")
            }
        } catch {
            print("❌ [Spotify] Stop playback error: \(error.localizedDescription)")
        }
    }
    
    func skipToNext() async {
        guard await ensureValidToken(), let token = accessToken else { return }
        
        let url = URL(string: "\(spotifyAPIBase)/me/player/next")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10
        
        do {
            _ = try await session.data(for: request)
            print("⏭ [Spotify] Skipped to next track")
        } catch {
            print("❌ [Spotify] Skip error: \(error.localizedDescription)")
        }
    }
    
    /// Switch to a specific playlist context
    func switchPlaylist(_ playlistId: String) async -> Bool {
        return await startPlayback(playlistId: playlistId)
    }
    
    /// Play specific track URIs (ranked by biofeedback score)
    func playTracks(_ uris: [String]) async -> Bool {
        let filtered = uris.filter { !recentTrackURIs.contains($0) }
        guard !filtered.isEmpty else {
            print("⚠️ [Spotify] All tracks in anti-repeat buffer, resetting")
            recentTrackURIs.removeAll()
            return await startPlayback(trackURIs: uris)
        }
        return await startPlayback(trackURIs: filtered)
    }
    
    // MARK: - Volume Ducking (for AI speech)
    
    func duckVolume() async {
        guard await ensureValidToken(), let token = accessToken, !isDucked else { return }
        
        // Read current volume first
        if let state = await fetchPlayerState() {
            originalVolume = state.volumePercent
        }
        
        let targetVolume = max(5, Int(Double(originalVolume) * 0.2)) // 80% reduction
        await setVolume(targetVolume, token: token)
        isDucked = true
        print("🔉 [Spotify] Volume ducked: \(originalVolume)% → \(targetVolume)%")
    }
    
    func restoreVolume() async {
        guard await ensureValidToken(), let token = accessToken, isDucked else { return }
        
        await setVolume(originalVolume, token: token)
        isDucked = false
        print("🔊 [Spotify] Volume restored: \(originalVolume)%")
    }
    
    private func setVolume(_ percent: Int, token: String) async {
        let clamped = min(100, max(0, percent))
        let url = URL(string: "\(spotifyAPIBase)/me/player/volume?volume_percent=\(clamped)")!
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10
        
        do {
            _ = try await session.data(for: request)
        } catch {
            print("❌ [Spotify] Volume set error: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Track Polling
    
    func startTrackPolling() {
        stopTrackPolling()
        trackPollTimer = Timer.scheduledTimer(withTimeInterval: trackPollInterval, repeats: true) { [weak self] _ in
            Task { [weak self] in
                await self?.pollCurrentTrack()
            }
        }
        if let timer = trackPollTimer {
            RunLoop.current.add(timer, forMode: .common)
        }
    }
    
    func stopTrackPolling() {
        trackPollTimer?.invalidate()
        trackPollTimer = nil
    }
    
    private func pollCurrentTrack() async {
        guard let state = await fetchPlayerState() else { return }
        
        let newURI = state.trackURI
        let trackChanged = newURI != currentTrackURI && !newURI.isEmpty
        
        await MainActor.run {
            self.currentTrackName = state.trackName
            self.currentTrackURI = state.trackURI
            self.currentTrackArtist = state.artistName
            self.isPlaying = state.isPlaying
        }
        
        if trackChanged {
            addToAntiRepeat(newURI)
            NotificationCenter.default.post(
                name: .spotifyTrackChanged,
                object: nil,
                userInfo: ["trackURI": newURI, "trackName": state.trackName]
            )
            NotificationCenter.default.post(
                name: .runEmotionTrackChanged,
                object: nil,
                userInfo: ["trackURI": newURI, "trackName": state.trackName]
            )
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
        guard await ensureValidToken(), let token = accessToken else { return nil }
        
        let url = URL(string: "\(spotifyAPIBase)/me/player")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10
        
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let item = json["item"] as? [String: Any] {
                let trackName = item["name"] as? String ?? ""
                let trackURI = item["uri"] as? String ?? ""
                let artists = item["artists"] as? [[String: Any]]
                let artistName = artists?.first?["name"] as? String ?? ""
                let isPlaying = json["is_playing"] as? Bool ?? false
                let progressMs = json["progress_ms"] as? Int ?? 0
                let durationMs = item["duration_ms"] as? Int ?? 0
                let device = json["device"] as? [String: Any]
                let volume = device?["volume_percent"] as? Int ?? 50
                
                return PlayerState(
                    trackName: trackName,
                    trackURI: trackURI,
                    artistName: artistName,
                    isPlaying: isPlaying,
                    progressMs: progressMs,
                    durationMs: durationMs,
                    volumePercent: volume
                )
            }
        } catch {
            print("❌ [Spotify] Player state fetch error: \(error.localizedDescription)")
        }
        return nil
    }
    
    // MARK: - Playlist Loading
    
    func loadUserPlaylists() async {
        guard await ensureValidToken(), let token = accessToken else { return }
        
        let url = URL(string: "\(spotifyAPIBase)/me/playlists?limit=50")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let items = json["items"] as? [[String: Any]] {
                var playlists: [SpotifyPlaylist] = []
                for item in items {
                    guard let id = item["id"] as? String,
                          let name = item["name"] as? String else { continue }
                    let trackCount = (item["tracks"] as? [String: Any])?["total"] as? Int ?? 0
                    let isRunbot = name.lowercased().contains("runbot")
                    playlists.append(SpotifyPlaylist(id: id, name: name, trackCount: trackCount, isRunbot: isRunbot))
                }
                
                // Sort: Runbot playlists first, then alphabetical
                playlists.sort { a, b in
                    if a.isRunbot != b.isRunbot { return a.isRunbot }
                    return a.name < b.name
                }
                
                let result = playlists
                await MainActor.run {
                    self.userPlaylists = result
                }
                print("🎵 [Spotify] Loaded \(result.count) playlists (\(result.filter(\.isRunbot).count) Runbot)")
            }
        } catch {
            print("❌ [Spotify] Playlist load error: \(error.localizedDescription)")
        }
    }
    
    /// Fetch track URIs from a playlist
    func fetchPlaylistTracks(_ playlistId: String, limit: Int = 100) async -> [SpotifyTrack] {
        guard await ensureValidToken(), let token = accessToken else { return [] }
        
        let url = URL(string: "\(spotifyAPIBase)/playlists/\(playlistId)/tracks?limit=\(limit)&fields=items(track(uri,name,artists(name),duration_ms))")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
            
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let items = json["items"] as? [[String: Any]] {
                var tracks: [SpotifyTrack] = []
                for item in items {
                    guard let track = item["track"] as? [String: Any],
                          let uri = track["uri"] as? String,
                          let name = track["name"] as? String else { continue }
                    let artists = track["artists"] as? [[String: Any]]
                    let artist = artists?.first?["name"] as? String ?? ""
                    let durationMs = track["duration_ms"] as? Int ?? 0
                    tracks.append(SpotifyTrack(uri: uri, name: name, artist: artist, durationMs: durationMs))
                }
                return tracks
            }
        } catch {
            print("❌ [Spotify] Playlist tracks fetch error: \(error.localizedDescription)")
        }
        return []
    }
    
    // MARK: - Anti-Repeat
    
    private func addToAntiRepeat(_ uri: String) {
        recentTrackURIs.append(uri)
        if recentTrackURIs.count > antiRepeatBufferSize {
            recentTrackURIs.removeFirst()
        }
    }
    
    func isInAntiRepeat(_ uri: String) -> Bool {
        return recentTrackURIs.contains(uri)
    }
    
    func clearAntiRepeat() {
        recentTrackURIs.removeAll()
    }
    
    // MARK: - Helpers
    
    private func getSupabaseAuthHeader() -> String {
        if let token = UserDefaults.standard.string(forKey: "sessionToken") {
            return "Bearer \(token)"
        }
        return "Bearer \(supabaseKey)"
    }
}

// MARK: - Models

struct SpotifyPlaylist: Identifiable {
    let id: String
    let name: String
    let trackCount: Int
    let isRunbot: Bool
}

struct SpotifyTrack: Identifiable {
    var id: String { uri }
    let uri: String
    let name: String
    let artist: String
    let durationMs: Int
}

// MARK: - Notifications

extension NSNotification.Name {
    static let spotifyTrackChanged = NSNotification.Name("SpotifyTrackChanged")
}
