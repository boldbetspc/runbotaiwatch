import SwiftUI
import WatchConnectivity
import AuthenticationServices

@main
struct RunbotAIWatchiOSApp: App {
    @StateObject private var wcManager = iOSWatchConnectivityManager.shared

    var body: some Scene {
        WindowGroup {
            SpotifyAuthRootView()
                .environmentObject(wcManager)
        }
    }
}

// MARK: - Root View

struct SpotifyAuthRootView: View {
    @EnvironmentObject var wcManager: iOSWatchConnectivityManager

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            
            Image(systemName: "applewatch")
                .font(.system(size: 60))
                .foregroundColor(.blue)
            Text("RunbotAI Watch")
                .font(.title)
                .fontWeight(.bold)

            switch wcManager.spotifyAuthStatus {
            case .waitingForLogin:
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        ProgressView().tint(.green)
                        Text("Spotify login in progress...")
                            .font(.body).foregroundColor(.green)
                    }
                    Text("Complete the login in the browser window")
                        .font(.caption).foregroundColor(.secondary)
                }
            case .exchangingTokens:
                HStack(spacing: 8) {
                    ProgressView().tint(.orange)
                    Text("Connecting to Spotify...")
                        .font(.body).foregroundColor(.orange)
                }
            case .completed:
                VStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                        Text("Spotify connected!")
                            .font(.body).fontWeight(.semibold).foregroundColor(.green)
                    }
                    Text("Return to your Apple Watch")
                        .font(.caption).foregroundColor(.secondary)
                }
            case .failed(let msg):
                VStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.red)
                        Text(msg).font(.body).foregroundColor(.red)
                    }
                    Text("Try again from the watch or check your Spotify account")
                        .font(.caption).foregroundColor(.secondary)
                }
            case .idle:
                EmptyView()
            }

            Spacer()
            
            Text("This app relays Spotify login for your Apple Watch.\nTap 'Connect on iPhone' in the watch app to start.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            
            Spacer()
        }
        .padding()
    }
}

// MARK: - Spotify Auth Status
enum SpotifyAuthFlowStatus: Equatable {
    case idle
    case waitingForLogin
    case exchangingTokens
    case completed
    case failed(String)
}

// MARK: - Pending auth request from watch
struct PendingSpotifyAuth {
    let codeVerifier: String
    let redirectURI: String
    let clientId: String
}

// MARK: - iOS WatchConnectivity Manager
final class iOSWatchConnectivityManager: NSObject, ObservableObject {
    static let shared = iOSWatchConnectivityManager()

    @Published var spotifyAuthStatus: SpotifyAuthFlowStatus = .idle

    private var wcSession: WCSession?
    private var webAuthSession: ASWebAuthenticationSession?
    private var pendingAuth: PendingSpotifyAuth?

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        wcSession = WCSession.default
        wcSession?.delegate = self
        wcSession?.activate()
    }

    // MARK: - Spotify Auth Flow

    private func openSpotifyAuth(urlString: String, codeVerifier: String, redirectURI: String, clientId: String,
                                timestamp: TimeInterval? = nil) {
        // Reject stale requests (e.g. old applicationContext deliveries from a previous session).
        // Any request older than 90 seconds is dropped so it can't cancel an active OAuth popup.
        if let ts = timestamp, Date().timeIntervalSince1970 - ts > 90 {
            print("⚠️ [iOS] Ignoring stale spotifyAuthRequest (age: \(Int(Date().timeIntervalSince1970 - ts))s)")
            return
        }

        guard let url = URL(string: urlString) else { return }

        pendingAuth = PendingSpotifyAuth(
            codeVerifier: codeVerifier,
            redirectURI: redirectURI,
            clientId: clientId
        )

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // If an OAuth session is already active, don't cancel it — skip this duplicate.
            if self.webAuthSession != nil {
                print("⚠️ [iOS] Auth session already active — ignoring duplicate request")
                return
            }

            self.spotifyAuthStatus = .waitingForLogin

            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: "runbot"
            ) { [weak self] callbackURL, error in
                guard let self = self else { return }

                // Always clear the session reference when it finishes (success, cancel, or error).
                DispatchQueue.main.async { self.webAuthSession = nil }

                if let error = error {
                    let nsError = error as NSError
                    if nsError.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                        DispatchQueue.main.async { self.spotifyAuthStatus = .idle }
                        return
                    }
                    print("📱 [iOS] Auth error: \(error.localizedDescription)")
                    DispatchQueue.main.async { self.spotifyAuthStatus = .failed("Login error") }
                    return
                }

                guard let callbackURL = callbackURL,
                      let comps = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
                      let code = comps.queryItems?.first(where: { $0.name == "code" })?.value else {
                    DispatchQueue.main.async { self.spotifyAuthStatus = .failed("No auth code") }
                    return
                }

                print("📱 [iOS] Got auth code — exchanging directly with Spotify...")
                DispatchQueue.main.async { self.spotifyAuthStatus = .exchangingTokens }
                self.exchangeCodeDirectly(code)
            }

            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            session.start()
            self.webAuthSession = session
        }
    }

    // MARK: - Direct Spotify Token Exchange (no edge function needed for PKCE)

    private func exchangeCodeDirectly(_ code: String) {
        guard let auth = pendingAuth else {
            DispatchQueue.main.async { self.spotifyAuthStatus = .failed("Missing auth params") }
            return
        }

        let url = URL(string: "https://accounts.spotify.com/api/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20

        // Build form body manually to avoid any URLComponents encoding issues
        let formParts = [
            "grant_type=authorization_code",
            "code=\(code)",
            "redirect_uri=\(auth.redirectURI.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? auth.redirectURI)",
            "client_id=\(auth.clientId)",
            "code_verifier=\(auth.codeVerifier)"
        ]
        let formBody = formParts.joined(separator: "&")
        request.httpBody = formBody.data(using: .utf8)
        
        print("📱 [iOS] Exchanging code with Spotify (verifier length: \(auth.codeVerifier.count), client: \(auth.clientId.prefix(8))...)")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            self.pendingAuth = nil

            if let error = error {
                print("❌ [iOS] Token exchange error: \(error.localizedDescription)")
                DispatchQueue.main.async { self.spotifyAuthStatus = .failed("Network error") }
                return
            }

            guard let data = data,
                  let http = response as? HTTPURLResponse else {
                DispatchQueue.main.async { self.spotifyAuthStatus = .failed("No response") }
                return
            }

            guard http.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? ""
                print("❌ [iOS] Spotify token exchange HTTP \(http.statusCode): \(body)")
                DispatchQueue.main.async { self.spotifyAuthStatus = .failed("Token error (\(http.statusCode))") }
                return
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["access_token"] is String else {
                print("❌ [iOS] Invalid token response")
                DispatchQueue.main.async { self.spotifyAuthStatus = .failed("Invalid response") }
                return
            }

            print("✅ [iOS] Spotify tokens received — fetching playlists then sending to Watch")
            self.fetchPlaylistsAndSend(tokens: json)
        }.resume()
    }
    
    // MARK: - Fetch Playlists (so watch has them right away)
    
    private func fetchPlaylistsAndSend(tokens: [String: Any]) {
        guard let accessToken = tokens["access_token"] as? String else {
            sendTokensToWatch(tokens)
            DispatchQueue.main.async { self.spotifyAuthStatus = .completed }
            return
        }
        
        let url = URL(string: "https://api.spotify.com/v1/me/playlists?limit=50")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            
            var enrichedTokens = tokens
            
            if let data = data,
               let http = response as? HTTPURLResponse, http.statusCode == 200,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let items = json["items"] as? [[String: Any]] {
                
                var playlistNames: [String] = []
                var playlistIds: [String] = []
                var bestPlaylistId: String?
                var bestPlaylistName: String?
                
                for item in items {
                    guard let id = item["id"] as? String,
                          let name = item["name"] as? String else { continue }
                    playlistIds.append(id)
                    playlistNames.append(name)
                    if bestPlaylistId == nil && name.lowercased().contains("runbot") {
                        bestPlaylistId = id
                        bestPlaylistName = name
                    }
                }
                
                if bestPlaylistId == nil, let firstId = playlistIds.first {
                    bestPlaylistId = firstId
                    bestPlaylistName = playlistNames.first
                }
                
                if let pid = bestPlaylistId {
                    enrichedTokens["suggested_playlist_id"] = pid
                    enrichedTokens["suggested_playlist_name"] = bestPlaylistName ?? ""
                }
                enrichedTokens["playlist_ids"] = playlistIds
                enrichedTokens["playlist_names"] = playlistNames
                print("📱 [iOS] Fetched \(playlistIds.count) playlists, suggested: \(bestPlaylistName ?? "none")")
            } else {
                print("⚠️ [iOS] Could not fetch playlists — sending tokens only")
            }
            
            self.sendTokensToWatch(enrichedTokens)
            DispatchQueue.main.async {
                self.spotifyAuthStatus = .completed
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    self.spotifyAuthStatus = .idle
                }
            }
        }.resume()
    }

    // MARK: - Send Tokens to Watch (triple delivery for reliability)

    private func sendTokensToWatch(_ tokens: [String: Any]) {
        guard let session = wcSession, session.activationState == .activated else {
            print("❌ [iOS] WCSession not activated")
            return
        }

        var message: [String: Any] = ["command": "spotifyTokens"]
        for (key, value) in tokens {
            message[key] = value
        }

        // 1. applicationContext — always available on next watch app launch / foreground
        try? session.updateApplicationContext(message)
        print("📱 [iOS] Tokens set via applicationContext")

        // 2. transferUserInfo — queued, guaranteed delivery
        session.transferUserInfo(message)
        print("📱 [iOS] Tokens queued via transferUserInfo")

        // 3. sendMessage — immediate if watch is reachable right now
        if session.isReachable {
            session.sendMessage(message, replyHandler: nil) { error in
                print("⚠️ [iOS] sendMessage failed: \(error.localizedDescription)")
            }
            print("📱 [iOS] Tokens sent via sendMessage")
        }
    }
}

// MARK: - ASWebAuthenticationPresentationContextProviding
extension iOSWatchConnectivityManager: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = scene.windows.first else {
            return ASPresentationAnchor()
        }
        return window
    }
}

// MARK: - WCSessionDelegate
extension iOSWatchConnectivityManager: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        if let error = error {
            print("❌ [iOS WC] Activation error: \(error.localizedDescription)")
        } else {
            print("✅ [iOS WC] Activated — state: \(state.rawValue)")
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handleWatchMessage(message)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        handleWatchMessage(message)
        replyHandler(["status": "received"])
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        handleWatchMessage(applicationContext)
    }

    private func handleWatchMessage(_ message: [String: Any]) {
        guard let command = message["command"] as? String else { return }

        switch command {
        case "spotifyAuthRequest":
            guard let urlString = message["authURL"] as? String,
                  let codeVerifier = message["codeVerifier"] as? String,
                  let redirectURI = message["redirectURI"] as? String,
                  let clientId = message["clientId"] as? String else {
                print("❌ [iOS] Incomplete spotifyAuthRequest")
                return
            }
            let timestamp = message["timestamp"] as? TimeInterval
            openSpotifyAuth(
                urlString: urlString,
                codeVerifier: codeVerifier,
                redirectURI: redirectURI,
                clientId: clientId,
                timestamp: timestamp
            )
        default:
            break
        }
    }
}
