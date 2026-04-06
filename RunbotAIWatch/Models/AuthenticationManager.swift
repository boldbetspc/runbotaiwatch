import Foundation
import SwiftUI
import Combine
import WatchConnectivity

class AuthenticationManager: NSObject, ObservableObject {
    @Published var isAuthenticated = false
    @Published var currentUser: User?
    @Published var isLoading = false
    @Published var errorMessage: String?
    
    private let supabaseURL: String
    private let supabaseKey: String
    private var sessionToken: String?
    private let keychainManager = KeychainManager.shared
    
    private var authRelayObserver: NSObjectProtocol?
    
    override init() {
        print("🔐 [AuthenticationManager] Initializing...")
        if let config = ConfigLoader.loadConfig(),
           let url = config["SUPABASE_URL"] as? String,
           let key = config["SUPABASE_ANON_KEY"] as? String {
            self.supabaseURL = url
            self.supabaseKey = key
            print("🔐 [AuthenticationManager] ✅ Config loaded - URL: \(url.prefix(30))...")
        } else {
            self.supabaseURL = ""
            self.supabaseKey = ""
            print("🔐 [AuthenticationManager] ❌ Config NOT loaded!")
        }
        super.init()
        
        authRelayObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("AuthRelayFromPhone"),
            object: nil, queue: .main
        ) { [weak self] note in
            guard let self = self, let info = note.userInfo else { return }
            self.applyAuthRelay(info)
        }
        
        checkForPendingAuthRelay()
    }
    
    deinit {
        if let obs = authRelayObserver { NotificationCenter.default.removeObserver(obs) }
    }
    
    /// Apply auth credentials relayed from runbot-ios via WCSession.
    func applyAuthRelay(_ info: [AnyHashable: Any]) {
        guard let userId = info["userId"] as? String,
              let email = info["email"] as? String,
              let token = info["accessToken"] as? String,
              !userId.isEmpty, !token.isEmpty else {
            print("🔐 [AuthRelay] Incomplete payload — ignoring")
            return
        }
        
        if isAuthenticated, currentUser?.id == userId {
            // Already signed in as this user — just update the token silently
            UserDefaults.standard.set(token, forKey: "sessionToken")
            sessionToken = token
            print("🔐 [AuthRelay] Token refreshed silently for \(email)")
            return
        }
        
        let name = (info["name"] as? String) ?? email
        let user = User(id: userId, email: email, name: name)
        
        if let userData = try? JSONEncoder().encode(user) {
            UserDefaults.standard.set(userData, forKey: "currentUser")
        }
        UserDefaults.standard.set(token, forKey: "sessionToken")
        
        self.currentUser = user
        self.sessionToken = token
        self.isAuthenticated = true
        self.errorMessage = nil
        
        // Post the same notification that the normal login posts so the rest of the app initializes
        NotificationCenter.default.post(name: NSNotification.Name("UserAuthenticated"), object: userId)
        
        print("🔐 [AuthRelay] ✅ Auto signed in from iPhone — \(email) (id: \(userId))")
    }
    
    /// Check WCSession applicationContext for auth that arrived while the Watch wasn't running.
    private func checkForPendingAuthRelay() {
        guard WCSession.isSupported() else { return }
        let ctx = WCSession.default.receivedApplicationContext
        guard ctx["command"] as? String == "authRelay",
              let token = ctx["accessToken"] as? String, !token.isEmpty else { return }
        print("🔐 [AuthRelay] Found pending auth in applicationContext")
        applyAuthRelay(ctx)
    }
    
    func checkAuthentication() {
        print("🔐 [AuthenticationManager] checkAuthentication() called")
        
        // Check if user session exists in UserDefaults
        if let savedUser = UserDefaults.standard.data(forKey: "currentUser"),
           let user = try? JSONDecoder().decode(User.self, from: savedUser),
           let token = UserDefaults.standard.string(forKey: "sessionToken") {
            
            // Check if token is expired (with smaller buffer - only clear if actually expired)
            if isTokenExpired(token) {
                print("🔐 [AuthenticationManager] ⚠️ Saved token is expired - user needs to re-login")
                // Don't auto-logout on app launch - let user use app, will fail gracefully on API calls
                // Only clear if token is significantly expired (more than 1 hour past expiration)
                let expTime = getTokenExpirationTime(token)
                if let exp = expTime, Date().timeIntervalSince1970 > (exp + 3600) {
                    print("🔐 [AuthenticationManager] Token expired more than 1 hour ago - clearing credentials")
                    logout()
                    return
                } else {
                    print("🔐 [AuthenticationManager] Token recently expired - keeping session, will handle on API calls")
                }
            }
            
            print("🔐 [AuthenticationManager] ✅ Found saved user: \(user.email)")
            self.currentUser = user
            self.sessionToken = token
            self.isAuthenticated = true
            print("🔐 [AuthenticationManager] User authenticated successfully")
        } else {
            print("🔐 [AuthenticationManager] ❌ No saved user found - user needs to login")
            self.isAuthenticated = false
        }
    }
    
    private func getTokenExpirationTime(_ token: String) -> TimeInterval? {
        let parts = token.components(separatedBy: ".")
        guard parts.count == 3 else { return nil }
        
        let payload = parts[1]
        var base64 = payload
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 {
            base64.append("=")
        }
        
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = json["exp"] as? TimeInterval else {
            return nil
        }
        
        return exp
    }
    
    private func isTokenExpired(_ token: String) -> Bool {
        // JWT tokens have 3 parts separated by dots: header.payload.signature
        let parts = token.components(separatedBy: ".")
        guard parts.count == 3 else { return true }
        
        // Decode the payload (second part)
        let payload = parts[1]
        
        // Add padding if needed for base64 decoding
        var base64 = payload
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 {
            base64.append("=")
        }
        
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = json["exp"] as? TimeInterval else {
            return true // If we can't decode, assume expired
        }
        
        // Check if current time is past expiration (with 1 minute buffer for safety)
        let currentTime = Date().timeIntervalSince1970
        let isExpired = currentTime > (exp - 60) // 1 minute buffer before actual expiration
        
        if isExpired {
            print("🔐 [AuthenticationManager] Token expired at: \(Date(timeIntervalSince1970: exp))")
        }
        
        return isExpired
    }
    
    func login(email: String, password: String) async {
        print("🔐 [Auth] Login attempt for: \(email)")
        await MainActor.run { self.isLoading = true }
        
        guard !supabaseURL.isEmpty, !supabaseKey.isEmpty else {
            print("🔐 [Auth] ❌ Supabase not configured!")
            await MainActor.run {
                self.isLoading = false
                self.errorMessage = "App not configured properly"
            }
            return
        }
        
        do {
            let loginRequest = LoginRequest(email: email, password: password)
            let data = try JSONEncoder().encode(loginRequest)
            
            let urlString = "\(supabaseURL)/auth/v1/token?grant_type=password"
            print("🔐 [Auth] Request URL: \(urlString)")
            
            var request = URLRequest(url: URL(string: urlString)!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(supabaseKey, forHTTPHeaderField: "apikey")
            request.httpBody = data
            request.timeoutInterval = 30
            
            print("🔐 [Auth] Sending login request...")
            let (responseData, response) = try await URLSession.shared.data(for: request)
            
            if let httpResponse = response as? HTTPURLResponse {
                print("🔐 [Auth] Response status: \(httpResponse.statusCode)")
                
                if httpResponse.statusCode == 200 {
                    let authResponse = try JSONDecoder().decode(AuthResponse.self, from: responseData)
                    print("🔐 [Auth] ✅ Login successful! User ID: \(authResponse.user.id)")
                    
                    // Create user object
                    let user = User(
                        id: authResponse.user.id,
                        email: authResponse.user.email ?? email,
                        name: authResponse.user.user_metadata?["name"] as? String ?? "Runner"
                    )
                    
                    await MainActor.run {
                        self.currentUser = user
                        self.sessionToken = authResponse.access_token
                        self.isAuthenticated = true
                        self.isLoading = false
                        self.errorMessage = nil
                        
                        // Save to UserDefaults
                        if let userData = try? JSONEncoder().encode(user) {
                            UserDefaults.standard.set(userData, forKey: "currentUser")
                        }
                        UserDefaults.standard.set(authResponse.access_token, forKey: "sessionToken")
                        print("🔐 [Auth] ✅ Session saved to UserDefaults")
                        print("🔐 [Auth] User ID: \(user.id) - available for all services")
                    }
                } else {
                    let errorString = String(data: responseData, encoding: .utf8) ?? "Unknown error"
                    print("🔐 [Auth] ❌ Login failed: \(errorString)")
                    throw NSError(domain: "Auth", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Login failed: \(errorString)"])
                }
            }
        } catch {
            print("🔐 [Auth] ❌ Error: \(error.localizedDescription)")
            await MainActor.run {
                self.isLoading = false
                self.errorMessage = error.localizedDescription
            }
        }
    }
    
    func signup(email: String, password: String, name: String) async {
        await MainActor.run { self.isLoading = true }
        
        do {
            let signupRequest = SignupRequest(email: email, password: password, data: ["name": name])
            let data = try JSONEncoder().encode(signupRequest)
            
            var request = URLRequest(url: URL(string: "\(supabaseURL)/auth/v1/signup")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(supabaseKey, forHTTPHeaderField: "apikey")
            request.httpBody = data
            
            let (responseData, response) = try await URLSession.shared.data(for: request)
            
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                let authResponse = try JSONDecoder().decode(AuthResponse.self, from: responseData)
                
                let user = User(
                    id: authResponse.user.id,
                    email: email,
                    name: name
                )
                
                await MainActor.run {
                    self.currentUser = user
                    self.sessionToken = authResponse.access_token
                    self.isAuthenticated = true
                    self.isLoading = false
                    self.errorMessage = nil
                    
                    if let userData = try? JSONEncoder().encode(user) {
                        UserDefaults.standard.set(userData, forKey: "currentUser")
                    }
                    UserDefaults.standard.set(authResponse.access_token, forKey: "sessionToken")
                }
            }
        } catch {
            await MainActor.run {
                self.isLoading = false
                self.errorMessage = error.localizedDescription
            }
        }
    }
    
    func logout() {
        print("🚪 [AuthenticationManager] Logging out user")
        
        // GUARDRAIL: Kill all AI sessions before logout
        NotificationCenter.default.post(name: NSNotification.Name("EmergencyStopAll"), object: nil)
        
        currentUser = nil
        sessionToken = nil
        isAuthenticated = false
        
        UserDefaults.standard.removeObject(forKey: "currentUser")
        UserDefaults.standard.removeObject(forKey: "sessionToken")
        
        print("✅ [AuthenticationManager] Logout complete - all sessions killed")
    }
}

// MARK: - Models
struct User: Identifiable, Codable {
    let id: String
    let email: String
    let name: String
}

private struct LoginRequest: Encodable {
    let email: String
    let password: String
}

private struct SignupRequest: Encodable {
    let email: String
    let password: String
    let data: [String: String]
}

private struct AuthResponse: Decodable {
    let access_token: String
    let user: AuthUser
}

private struct AuthUser: Decodable {
    let id: String
    let email: String?
    let user_metadata: [String: Any]?
    
    enum CodingKeys: String, CodingKey {
        case id, email, user_metadata
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        email = try container.decodeIfPresent(String.self, forKey: .email)
        if let metadata = try container.decodeIfPresent([String: AnyCodable].self, forKey: .user_metadata) {
            user_metadata = metadata.mapValues { $0.value }
        } else {
            user_metadata = nil
        }
    }
}

private struct AnyCodable: Codable {
    let value: Any
    
    init(_ value: Any) {
        self.value = value
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intVal = try? container.decode(Int.self) {
            value = intVal
        } else if let doubleVal = try? container.decode(Double.self) {
            value = doubleVal
        } else if let boolVal = try? container.decode(Bool.self) {
            value = boolVal
        } else if let stringVal = try? container.decode(String.self) {
            value = stringVal
        } else {
            value = NSNull()
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let intVal = value as? Int {
            try container.encode(intVal)
        } else if let doubleVal = value as? Double {
            try container.encode(doubleVal)
        } else if let boolVal = value as? Bool {
            try container.encode(boolVal)
        } else if let stringVal = value as? String {
            try container.encode(stringVal)
        }
    }
}
