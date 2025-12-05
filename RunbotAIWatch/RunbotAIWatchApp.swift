import SwiftUI
import WatchKit

@main
struct RunbotAIWatchApp: App {
    // MARK: - State Objects
    @StateObject private var authManager = AuthenticationManager()
    @StateObject private var runTracker = RunTracker()
    @StateObject private var voiceManager = VoiceManager()
    @StateObject private var aiCoachManager = AICoachManager()
    @StateObject private var userPreferences = UserPreferences()
    @StateObject private var supabaseManager = SupabaseManager()
    @StateObject private var healthManager = HealthManager()
    
    // Shared managers (singletons)
    private let watchConnectivity = WatchConnectivityManager.shared
    private let mem0Manager = Mem0Manager.shared
    
    @Environment(\.scenePhase) private var scenePhase
    
    init() {
        print("🚀 [App] RunbotAIWatchApp initializing...")
    }
    
    var body: some Scene {
        WindowGroup {
            ContentViewWrapper(
                authManager: authManager,
                runTracker: runTracker,
                voiceManager: voiceManager,
                aiCoachManager: aiCoachManager,
                userPreferences: userPreferences,
                supabaseManager: supabaseManager,
                healthManager: healthManager
            )
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            if newPhase == .inactive || newPhase == .background {
                print("⚠️ [App] App going inactive/background - killing all sessions")
                SessionCleanupManager.shared.killAllSessions()
            }
        }
    }
}

// Wrapper view to handle initialization properly
struct ContentViewWrapper: View {
    @ObservedObject var authManager: AuthenticationManager
    @ObservedObject var runTracker: RunTracker
    @ObservedObject var voiceManager: VoiceManager
    @ObservedObject var aiCoachManager: AICoachManager
    @ObservedObject var userPreferences: UserPreferences
    @ObservedObject var supabaseManager: SupabaseManager
    @ObservedObject var healthManager: HealthManager
    
    @State private var hasInitialized = false
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            if authManager.isAuthenticated {
                MainRunbotView()
            } else {
                AuthenticationView()
            }
        }
        .environmentObject(authManager)
        .environmentObject(runTracker)
        .environmentObject(voiceManager)
        .environmentObject(aiCoachManager)
        .environmentObject(userPreferences)
        .environmentObject(supabaseManager)
        .environmentObject(healthManager)
        .preferredColorScheme(.dark)
        .onAppear {
            if !hasInitialized {
                setupApp()
                hasInitialized = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("UserAuthenticated"))) { notification in
            // Re-initialize Supabase session after PIN login
            if let userId = notification.object as? String {
                print("🚀 [App] User authenticated via PIN - re-initializing services for: \(userId)")
                supabaseManager.initializeSession(for: userId)
                print("✅ [App] Services re-initialized")
            }
        }
    }
    
    private func setupApp() {
        print("🚀 [App] Starting RunbotAIWatch setup...")
        
        // Check authentication FIRST
        authManager.checkAuthentication()
        print("🚀 [App] Auth status: \(authManager.isAuthenticated ? "✅ Authenticated" : "❌ Not authenticated")")
        if let user = authManager.currentUser {
            print("🚀 [App] User: \(user.email), ID: \(user.id)")
        }
        
        // Initialize voice
        voiceManager.setupSpeech()
        
        // Initialize Supabase session if authenticated (including after PIN login)
        if let userId = authManager.currentUser?.id {
            supabaseManager.initializeSession(for: userId)
            print("🚀 [App] Supabase session initialized for: \(userId)")
        }
        
        // Wire HealthManager to RunTracker
        runTracker.healthManager = healthManager
        runTracker.supabaseManager = supabaseManager
        
        // Request HealthKit authorization
        healthManager.requestHealthDataAccess()
        
        print("✅ [App] Setup complete - User ID available: \(authManager.currentUser?.id ?? "none")")
    }
}
