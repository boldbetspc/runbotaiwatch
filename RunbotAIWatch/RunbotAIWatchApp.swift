import SwiftUI
import WatchKit
import HealthKit
import CoreLocation

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
        print("🚀 [App] Bundle ID: com.runbotai.ioswrapper.watchapp")
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
            
            if newPhase == .inactive || newPhase == .background {
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
    @State private var hasRequestedPermissions = false
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            // Normal flow - email authentication only
            if authManager.isAuthenticated {
                MainRunbotView()
                    .onAppear {
                        // Request permissions when authenticated (if not already requested)
                        requestPermissionsAfterAuth()
                    }
            } else {
                AuthenticationView()
            }
        }
        .onChange(of: authManager.isAuthenticated) { oldValue, newValue in
            print("🔐 [ContentViewWrapper] isAuthenticated changed: \(oldValue) -> \(newValue)")
            // Request permissions when user becomes authenticated
            if newValue && !oldValue {
                requestPermissionsAfterAuth()
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
            // Re-initialize Supabase session after authentication
            if let userId = notification.object as? String {
                print("🚀 [App] User authenticated - re-initializing services for: \(userId)")
                supabaseManager.initializeSession(for: userId)
                print("✅ [App] Services re-initialized")
            }
        }
    }
    
    private func setupApp() {
        print("🚀 [App] Starting RunbotAIWatch setup...")
        
        // Set workout status references in AuthenticationManager (prevents session expiration during runs)
        authManager.runTracker = runTracker
        authManager.healthManager = healthManager
        print("🏃 [App] Set workout status references in AuthenticationManager (prevents session expiration during marathons)")
        
        // Check authentication FIRST
        authManager.checkAuthentication()
        print("🚀 [App] Auth status: \(authManager.isAuthenticated ? "✅ Authenticated" : "❌ Not authenticated")")
        if let user = authManager.currentUser {
            print("🚀 [App] User: \(user.email), ID: \(user.id)")
        }
        
        // Initialize voice
        voiceManager.setupSpeech()
        
        // Initialize Supabase session if authenticated
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
    
    /// Request HealthKit and Location permissions after authentication
    /// Only requests if permissions are not already granted
    private func requestPermissionsAfterAuth() {
        guard authManager.isAuthenticated else {
            print("⚠️ [ContentViewWrapper] Cannot request permissions - user not authenticated")
            return
        }
        
        // Check current permission status BEFORE requesting
        let workoutType = HKObjectType.workoutType()
        let heartRateType = HKQuantityType.quantityType(forIdentifier: .heartRate)!
        let healthStore = HKHealthStore()
        let workoutStatus = healthStore.authorizationStatus(for: workoutType)
        let hrStatus = healthStore.authorizationStatus(for: heartRateType)
        let locationStatus = runTracker.locationAuthorizationStatus
        
        print("🔐 [ContentViewWrapper] Checking permission status...")
        print("   - HealthKit Workout: \(workoutStatus.rawValue)")
        print("   - HealthKit HR: \(hrStatus.rawValue)")
        print("   - Location: \(locationStatus.rawValue)")
        
        // Check if all permissions are already granted
        let healthKitGranted = (workoutStatus == .sharingAuthorized && hrStatus == .sharingAuthorized)
        let locationGranted = (locationStatus == .authorizedWhenInUse || locationStatus == .authorizedAlways)
        
        if healthKitGranted && locationGranted {
            print("✅ [ContentViewWrapper] All permissions already granted - skipping request")
            hasRequestedPermissions = true
            return
        }
        
        // Prevent duplicate requests within the same session
        guard !hasRequestedPermissions else {
            print("🔐 [ContentViewWrapper] Permissions already requested in this session - skipping")
            return
        }
        
        hasRequestedPermissions = true
        print("🔐 [ContentViewWrapper] Requesting permissions after authentication...")
        
        // STEP 1: Request HealthKit authorization FIRST (before location) - only if not already granted
        if !healthKitGranted {
            print("💓 [ContentViewWrapper] STEP 1: Requesting HealthKit authorization...")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                // requestHealthDataAccess() already checks status internally and won't request if authorized
                healthManager.requestHealthDataAccess()
                print("✅ [ContentViewWrapper] HealthKit authorization request submitted")
            }
        } else {
            print("✅ [ContentViewWrapper] HealthKit already authorized - skipping request")
        }
        
        // STEP 2: Request location permission AFTER HealthKit (with delay to avoid overlap) - only if not already granted
        if !locationGranted {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                print("📍 [ContentViewWrapper] STEP 2: Requesting location permission...")
                // requestLocationPermission() already checks status internally and won't request if authorized
                runTracker.requestLocationPermission()
                print("✅ [ContentViewWrapper] Location permission request submitted")
            }
        } else {
            print("✅ [ContentViewWrapper] Location already authorized - skipping request")
        }
    }
}
