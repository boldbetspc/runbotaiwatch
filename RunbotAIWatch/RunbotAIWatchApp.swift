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
        print("🚀 [App] ========== RunbotAIWatchApp INITIALIZING ==========")
        print("🚀 [App] Platform: watchOS")
        print("🚀 [App] Bundle ID: com.rb.runbot.watchapp")
        print("🚀 [App] If you see this log, watch logging is working!")
        print("🚀 [App] =================================================")
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
            // CRITICAL: Don't kill sessions if workout is active
            // Workout sessions MUST continue in background for HR monitoring
            let isWorkoutActive = healthManager.workoutStatus == .running || healthManager.workoutStatus == .starting

            if newPhase == .active {
                // Re-check for Spotify tokens that arrived via applicationContext while the app was backgrounded.
                // This covers the case where the iOS Wrapper sent tokens while the watch was asleep.
                SpotifyManager.shared.checkForPendingTokens()
            } else if newPhase == .inactive || newPhase == .background {
                if isWorkoutActive {
                    print("🏃 [App] App going inactive/background BUT workout is active - keeping workout session alive")
                    print("🏃 [App] Workout will continue in background (healthkit + workout-processing modes)")
                } else {
                    print("⚠️ [App] App going inactive/background - killing AI sessions (workout not active)")
                    SessionCleanupManager.shared.killAllSessions()
                }
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
        // runbot-ios started a run with Apple Watch as HR source — start HKWorkoutSession on Watch and stream HR via WCSession.
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("WatchConnectivityStartWorkout"))) { notification in
            let runId = (notification.userInfo?["runId"] as? String) ?? UUID().uuidString
            if runTracker.isRunning {
                print("⌚ [App] iPhone startWorkout ignored — Watch run already active (HR already streaming)")
                return
            }
            print("⌚ [App] iPhone requested HR relay — starting workout on Watch, runId=\(runId)")
            healthManager.startHeartRateMonitoring(
                runId: runId,
                supabaseManager: authManager.isAuthenticated ? supabaseManager : nil
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("WatchConnectivityStopWorkout"))) { _ in
            if runTracker.isRunning {
                print("⌚ [App] iPhone stopWorkout ignored — full Watch run still active")
                return
            }
            print("⌚ [App] iPhone requested stop — ending HR relay on Watch")
            healthManager.stopHeartRateMonitoring()
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
        
        // Request HealthKit authorization ON WATCH
        // Add a small delay to ensure the app is fully initialized
        print("🚀 [App] Scheduling HealthKit authorization request on watch...")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            print("🚀 [App] Requesting HealthKit authorization on watch...")
            // Don't auto-request - user must refresh in Connections page
            // self.healthManager.requestHealthDataAccess()
            print("✅ [App] HealthKit authorization request submitted")
        }
        
        print("✅ [App] Setup complete - User ID available: \(authManager.currentUser?.id ?? "none")")
    }
}
