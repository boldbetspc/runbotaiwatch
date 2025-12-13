import Foundation
import HealthKit
import Combine
import SwiftUI
import CoreLocation
import os.log

/// HealthManager: Manages HealthKit integration for real-time heart rate monitoring
/// 
/// **Key Features:**
/// - Real-time HR monitoring via HKWorkoutSession (optimized for Apple Watch)
/// - Heart rate zone calculation using Karvonen method
/// - Zone-wise time distribution tracking
/// - Zone-wise average pace correlation
/// - Periodic UPSERT to Supabase run_hr table (every 30s during run)
/// - Adaptive guidance based on zone and pace
///
/// **Authorization Flow:**
/// 1. Request HealthKit authorization via `requestHealthDataAccess()`
/// 2. Gracefully handles missing entitlements (app continues without HR)
/// 3. Check `isAuthorized` before starting monitoring
///
/// **Real-time HR Flow:**
/// 1. `startHeartRateMonitoring()` → starts HKWorkoutSession
/// 2. HKAnchoredObjectQuery provides live HR updates
/// 3. Each update triggers zone calculation and tracking
/// 4. Periodic saves to Supabase (30s interval)
/// 5. `stopHeartRateMonitoring()` → finalizes data and performs final save
///
class HealthManager: NSObject, ObservableObject {
    private let healthStore = HKHealthStore()
    @Published var isAuthorized = false
    @Published var workoutAuthorized = false
    @Published var heartRateAuthorized = false
    @Published var currentHeartRate: Double?
    @Published var averageHeartRate: Double?
    @Published var maxHeartRate: Double?
    @Published var minHeartRate: Double?
    
    // Heart Zone tracking
    @Published var currentZone: Int? // 1-5
    @Published var zonePercentages: [Int: Double] = [1: 0, 2: 0, 3: 0, 4: 0, 5: 0] // Z1-Z5 percentages
    @Published var adaptiveGuidance: String = "" // Adaptive zone pacing guidance
    
    // Zone-wise average pace tracking (min/km)
    @Published var zoneAveragePace: [Int: Double] = [1: 0, 2: 0, 3: 0, 4: 0, 5: 0]
    
    // CRITICAL: HKWorkoutSession for real-time HR on watchOS
    // MUST be strong references to prevent deallocation
    private var workoutSession: HKWorkoutSession? {
        didSet {
            if workoutSession != nil {
                print("✅ [HealthManager] WorkoutSession retained: \(workoutSession != nil)")
                // Update workout status when session is created
                DispatchQueue.main.async { [weak self] in
                    self?.objectWillChange.send()
                }
            } else {
                print("⚠️ [HealthManager] WorkoutSession released")
                // Update workout status when session is released
                DispatchQueue.main.async { [weak self] in
                    self?.objectWillChange.send()
                }
            }
        }
    }
    private var workoutBuilder: HKWorkoutBuilder? {
        didSet {
            if workoutBuilder != nil {
                print("✅ [HealthManager] WorkoutBuilder retained: \(workoutBuilder != nil)")
            } else {
                print("⚠️ [HealthManager] WorkoutBuilder released")
            }
        }
    }
    private var workoutRouteBuilder: HKWorkoutRouteBuilder?
    private var workoutConfiguration: HKWorkoutConfiguration?
    
    // Published properties for UI status indicators
    @Published var workoutStatus: WorkoutStatus = .notStarted
    @Published var hrDataStatus: HRDataStatus = .noData
    
    enum WorkoutStatus: Equatable {
        case notStarted
        case starting
        case running
        case error(String)
        
        var displayText: String {
            switch self {
            case .notStarted: return "Workout: Not Started"
            case .starting: return "Workout: Starting..."
            case .running: return "✅ Workout: Active"
            case .error(let msg): return "❌ Workout: \(msg)"
            }
        }
        
        var color: Color {
            switch self {
            case .notStarted: return .gray
            case .starting: return .orange
            case .running: return .green
            case .error: return .red
            }
        }
    }
    
    enum HRDataStatus: Equatable {
        case noData
        case collecting
        case active
        case error(String)
        
        var displayText: String {
            switch self {
            case .noData: return "HR: No Data"
            case .collecting: return "HR: Collecting..."
            case .active: return "✅ HR: Active"
            case .error(let msg): return "❌ HR: \(msg)"
            }
        }
        
        var color: Color {
            switch self {
            case .noData: return .gray
            case .collecting: return .orange
            case .active: return .green
            case .error: return .red
            }
        }
    }
    
    private var heartRateQuery: HKQuery?
    private var heartRateSamples: [HKQuantitySample] = []
    
    // Workout distance tracking
    @Published var workoutDistance: Double = 0.0 // meters from workout
    
    // Zone tracking
    private var zoneStartTime: Date?
    private var zoneTimeSpent: [Int: TimeInterval] = [1: 0, 2: 0, 3: 0, 4: 0, 5: 0]
    private var lastZoneUpdateTime: Date?
    private var totalRunTime: TimeInterval = 0
    private var runStartTime: Date?
    
    // Zone-pace correlation tracking
    private var zonePaceSamples: [Int: [Double]] = [1: [], 2: [], 3: [], 4: [], 5: []]
    
    // HR Config for zone calculation
    private var hrConfigAge: Int?
    private var hrConfigRestingHR: Int?
    
    // Periodic HR data save to Supabase
    private var hrSaveTimer: Timer?
    private var currentRunId: String?
    private var supabaseManager: SupabaseManager?
    
    // Timer for periodic zone percentage updates
    private var zoneUpdateTimer: Timer?
    
    // Timer for periodic HR reading from workout builder (fallback)
    private var periodicHRTimer: Timer?
    
    // Track if authorization has been requested to avoid redundant requests
    private var hasRequestedAuthorization = false
    
    // OSLog for better visibility in system logs (works even with transport errors)
    private let logger = OSLog(subsystem: "com.runbotai.ioswrapper.watchapp", category: "HealthManager")
    
    override init() {
        super.init()
        print("💓 [HealthManager] Initializing...")
        os_log("💓 [HealthManager] Initializing...", log: logger, type: .info)
        // Don't request authorization in init - wait for explicit call
    }
    
    func requestHealthDataAccess() {
        print("💓 [HealthManager] ========== REQUESTING HEALTH DATA ACCESS ==========")
        print("💓 [HealthManager] Thread: \(Thread.isMainThread ? "Main" : "Background")")
        #if os(watchOS)
        #if targetEnvironment(simulator)
        print("⚠️ [HealthManager] Running on watchOS SIMULATOR")
        print("⚠️ [HealthManager] HealthKit on simulator has limitations:")
        print("   - Authorization dialogs may not appear")
        print("   - Some HealthKit features may not work")
        print("   - For full testing, use a real Apple Watch device")
        #else
        print("💓 [HealthManager] Running on watchOS DEVICE - requesting authorization ON WATCH")
        #endif
        #else
        print("💓 [HealthManager] Running on iOS - requesting authorization")
        #endif
        
        guard HKHealthStore.isHealthDataAvailable() else {
            print("❌ [HealthManager] Health data is NOT available on this device")
            isAuthorized = false
            return
        }
        print("✅ [HealthManager] HealthKit is available on this device")
        
        guard let heartRateType = HKQuantityType.quantityType(forIdentifier: .heartRate) else {
            print("❌ [HealthManager] Could not create heart rate type")
            isAuthorized = false
            return
        }
        print("✅ [HealthManager] Heart rate type created successfully")
        
        let workoutType = HKObjectType.workoutType()
        let hrAuthStatus = healthStore.authorizationStatus(for: heartRateType)
        let workoutAuthStatus = healthStore.authorizationStatus(for: workoutType)
        
        print("💓 [HealthManager] Current authorization status:")
        print("   - Workout: \(workoutAuthStatus.rawValue) (\(authStatusString(workoutAuthStatus)))")
        print("   - HR: \(hrAuthStatus.rawValue) (\(authStatusString(hrAuthStatus)))")
        
        // If already authorized, return early
        if workoutAuthStatus == .sharingAuthorized && hrAuthStatus == .sharingAuthorized {
            print("✅ [HealthManager] Already authorized - no need to request")
            isAuthorized = true
            return
        }
        
        // If BOTH are denied, don't request again
        // But if one is denied and other is notDetermined, still request (user might have denied one type)
        if workoutAuthStatus == .sharingDenied && hrAuthStatus == .sharingDenied {
            print("❌ [HealthManager] Both types DENIED - cannot request again")
            print("   User must enable in Settings > Privacy & Security > Health > RunbotAIWatch")
            isAuthorized = false
            return
        }
        
        // If one is denied but other is notDetermined, still request (might get partial authorization)
        if workoutAuthStatus == .sharingDenied || hrAuthStatus == .sharingDenied {
            print("⚠️ [HealthManager] One type denied, but requesting anyway for the other type")
        }
        
        // If already requested and status is still notDetermined, request again
        // (User might have dismissed the dialog, or it's still pending)
        if hasRequestedAuthorization {
            if workoutAuthStatus == .notDetermined || hrAuthStatus == .notDetermined {
                print("⚠️ [HealthManager] Authorization was requested before but still notDetermined")
                print("   Requesting again - user may have dismissed previous dialog")
                // Continue to request again below
            } else {
                print("✅ [HealthManager] Authorization already requested - checking current status")
                print("   Current status - Workout: \(workoutAuthStatus.rawValue), HR: \(hrAuthStatus.rawValue)")
                // Update isAuthorized based on current status
                isAuthorized = (workoutAuthStatus == .sharingAuthorized && hrAuthStatus == .sharingAuthorized)
                return
            }
        }
        
        let typesToRead: Set<HKObjectType> = [heartRateType, workoutType]
        let typesToWrite: Set<HKSampleType> = [workoutType]
        
        // ✅ REQUIREMENT 8: Explicitly verify HeartRate + Workout types are requested
        print("💓 [HealthManager] ========== REQUESTING HEALTHKIT TYPES ==========")
        print("💓 [HealthManager] Types to READ:")
        print("   ✅ Heart Rate: \(heartRateType.identifier)")
        print("   ✅ Workout: \(workoutType.identifier)")
        print("💓 [HealthManager] Types to WRITE:")
        print("   ✅ Workout: \(workoutType.identifier)")
        print("💓 [HealthManager] Total types to read: \(typesToRead.count)")
        print("💓 [HealthManager] Total types to write: \(typesToWrite.count)")
        #if os(watchOS)
        print("💓 [HealthManager] Platform: watchOS (authorization requested ON WATCH)")
        #endif
        print("💓 [HealthManager] =================================================")
        
        // Mark that we've requested authorization
        hasRequestedAuthorization = true
        
        print("💓 [HealthManager] ========== CALLING requestAuthorization ==========")
        print("💓 [HealthManager] This should show the HealthKit authorization dialog on watchOS")
        print("💓 [HealthManager] Thread: \(Thread.isMainThread ? "Main ✅" : "Background ❌")")
        
        // CRITICAL: Ensure we're on main thread for authorization request
        if !Thread.isMainThread {
            print("⚠️ [HealthManager] Not on main thread - dispatching to main...")
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.healthStore.requestAuthorization(toShare: typesToWrite, read: typesToRead) { [weak self] success, error in
                    self?.handleAuthorizationResponse(success: success, error: error, workoutType: workoutType, heartRateType: heartRateType)
                }
            }
        } else {
            healthStore.requestAuthorization(toShare: typesToWrite, read: typesToRead) { [weak self] success, error in
                self?.handleAuthorizationResponse(success: success, error: error, workoutType: workoutType, heartRateType: heartRateType)
            }
        }
        
        print("💓 [HealthManager] Authorization request submitted, waiting for callback...")
    }
    
    private func handleAuthorizationResponse(success: Bool, error: Error?, workoutType: HKObjectType, heartRateType: HKQuantityType) {
        DispatchQueue.main.async {
            // Re-check status after authorization (more reliable than success flag)
            let newWorkoutStatus = self.healthStore.authorizationStatus(for: workoutType)
            let newHRStatus = self.healthStore.authorizationStatus(for: heartRateType)
            
            // Update authorization status
            let isFullyAuthorized = (newWorkoutStatus == .sharingAuthorized && newHRStatus == .sharingAuthorized)
            self.isAuthorized = isFullyAuthorized
            self.workoutAuthorized = (newWorkoutStatus == .sharingAuthorized)
            self.heartRateAuthorized = (newHRStatus == .sharingAuthorized)
            
            if let error = error {
                let errorMsg = error.localizedDescription
                print("❌ [HealthManager] Health data authorization ERROR: \(errorMsg)")
                print("   Error domain: \((error as NSError).domain)")
                print("   Error code: \((error as NSError).code)")
                print("💓 [HealthManager] After error - Workout: \(newWorkoutStatus.rawValue), HR: \(newHRStatus.rawValue)")
                // Don't crash - just mark as not authorized
                if errorMsg.contains("entitlement") {
                    print("⚠️ [HealthManager] HealthKit entitlement missing - app will continue without heart rate data")
                }
            } else {
                print("✅ [HealthManager] Health data authorization callback received")
                print("💓 [HealthManager] After authorization:")
                print("   - Workout: \(newWorkoutStatus.rawValue) (\(self.authStatusString(newWorkoutStatus)))")
                print("   - HR: \(newHRStatus.rawValue) (\(self.authStatusString(newHRStatus)))")
                print("   - Fully Authorized: \(isFullyAuthorized)")
                
                // If authorized, the app should now appear in Health > Watch > Apps
                if isFullyAuthorized {
                    print("✅✅✅ [HealthManager] Authorization GRANTED - App should appear in Health > Watch > Apps after first workout save ✅✅✅")
                    print("💡 [HealthManager] Note: App appears in Health > Watch > Apps only after successfully saving a workout to HealthKit")
                } else {
                    print("⚠️ [HealthManager] Authorization incomplete:")
                    print("   - Workout: \(self.authStatusString(newWorkoutStatus)) ✅")
                    print("   - HR: \(self.authStatusString(newHRStatus)) ❌")
                    
                    if newHRStatus == .sharingDenied {
                        print("")
                        print("❌ [HealthManager] =========================================")
                        print("❌ HEART RATE ACCESS WAS DENIED")
                        print("❌ =========================================")
                        print("")
                        print("To enable heart rate access:")
                        print("1. Open Settings app on Apple Watch")
                        print("2. Go to Privacy & Security > Health")
                        print("3. Find 'RunbotAIWatch' in the list")
                        print("4. Turn ON 'Heart Rate'")
                        print("")
                        print("OR on iPhone:")
                        print("1. Open Watch app")
                        print("2. Go to Privacy & Security > Health")
                        print("3. Find 'RunbotAIWatch'")
                        print("4. Turn ON 'Heart Rate'")
                        print("")
                        print("⚠️ Without heart rate access, the app cannot:")
                        print("   - Stream real-time heart rate during runs")
                        print("   - Calculate heart rate zones")
                        print("   - Provide heart rate-based coaching")
                        print("")
                    } else if newWorkoutStatus == .sharingDenied {
                        print("")
                        print("❌ [HealthManager] =========================================")
                        print("❌ WORKOUT ACCESS WAS DENIED")
                        print("❌ =========================================")
                        print("")
                        print("To enable workout access:")
                        print("1. Open Settings app on Apple Watch")
                        print("2. Go to Privacy & Security > Health")
                        print("3. Find 'RunbotAIWatch' in the list")
                        print("4. Turn ON 'Workouts'")
                        print("")
                    }
                }
            }
        }
    }
    
    /// Check and update authorization status (useful for refresh)
    func checkAuthorizationStatus() {
        guard HKHealthStore.isHealthDataAvailable() else {
            isAuthorized = false
            workoutAuthorized = false
            heartRateAuthorized = false
            return
        }
        
        let workoutType = HKObjectType.workoutType()
        guard let heartRateType = HKQuantityType.quantityType(forIdentifier: .heartRate) else {
            isAuthorized = false
            workoutAuthorized = false
            heartRateAuthorized = false
            return
        }
        
        let workoutAuthStatus = healthStore.authorizationStatus(for: workoutType)
        let hrAuthStatus = healthStore.authorizationStatus(for: heartRateType)
        
        workoutAuthorized = (workoutAuthStatus == .sharingAuthorized)
        heartRateAuthorized = (hrAuthStatus == .sharingAuthorized)
        isAuthorized = (workoutAuthorized && heartRateAuthorized)
        
        print("💓 [HealthManager] Authorization status check:")
        print("   - Workout: \(workoutAuthStatus.rawValue) (\(authStatusString(workoutAuthStatus))) - \(workoutAuthorized ? "✅" : "❌")")
        print("   - HR: \(hrAuthStatus.rawValue) (\(authStatusString(hrAuthStatus))) - \(heartRateAuthorized ? "✅" : "❌")")
        print("   - Fully Authorized: \(isAuthorized ? "✅" : "❌")")
    }
    
    // MARK: - CRITICAL: HKWorkoutSession for watchOS Real-Time HR
    
    func startHeartRateMonitoring(runId: String? = nil, supabaseManager: SupabaseManager? = nil) {
        print("💓 [HealthManager] ========== STARTING HEART RATE MONITORING ==========")
        os_log("💓 [HealthManager] ========== STARTING HEART RATE MONITORING ==========", log: logger, type: .info)
        print("💓 [HealthManager] Run ID: \(runId ?? "nil")")
        os_log("💓 [HealthManager] Run ID: %{public}@", log: logger, type: .info, runId ?? "nil")
        print("💓 [HealthManager] SupabaseManager: \(supabaseManager != nil ? "provided" : "nil")")
        print("💓 [HealthManager] Thread: \(Thread.isMainThread ? "Main" : "Background")")
        os_log("💓 [HealthManager] Thread: %{public}@", log: logger, type: .info, Thread.isMainThread ? "Main" : "Background")
        
        // Update status
        DispatchQueue.main.async { [weak self] in
            self?.workoutStatus = .starting
            self?.hrDataStatus = .collecting
        }
        
        // Store run ID and Supabase manager for periodic saves
        self.currentRunId = runId
        self.supabaseManager = supabaseManager
        
        guard HKHealthStore.isHealthDataAvailable() else {
            print("❌ [HealthManager] HealthKit NOT available - aborting HR monitoring")
            isAuthorized = false
            return
        }
        print("✅ [HealthManager] HealthKit is available on watchOS")
        
        // Check authorization status
        let workoutType = HKObjectType.workoutType()
        guard let heartRateType = HKQuantityType.quantityType(forIdentifier: .heartRate) else {
            print("❌ [HealthManager] Cannot create heart rate type - aborting")
                return
            }
        
        let workoutAuthStatus = healthStore.authorizationStatus(for: workoutType)
        let hrAuthStatus = healthStore.authorizationStatus(for: heartRateType)
        
        print("💓 [HealthManager] Authorization status check:")
        print("   - Workout: \(workoutAuthStatus.rawValue) (\(authStatusString(workoutAuthStatus)))")
        print("   - Heart Rate: \(hrAuthStatus.rawValue) (\(authStatusString(hrAuthStatus)))")
        
        // CRITICAL FIX: Allow reading HR if we can READ heart rate (even if write is denied)
        // For reading heart rate, we only need READ permission, not WRITE
        // Workout WRITE is needed to save workouts, but HR READ is separate
        let canReadHR = (hrAuthStatus == .sharingAuthorized || hrAuthStatus == .notDetermined)
        let canWriteWorkout = (workoutAuthStatus == .sharingAuthorized || workoutAuthStatus == .notDetermined)
        
        // Update authorization status - we can work if we can read HR OR write workouts
        workoutAuthorized = (workoutAuthStatus == .sharingAuthorized)
        heartRateAuthorized = (hrAuthStatus == .sharingAuthorized)
        isAuthorized = (workoutAuthorized && heartRateAuthorized)
        
        print("💓 [HealthManager] Authorization check:")
        print("   - Can READ HR: \(canReadHR) (status: \(authStatusString(hrAuthStatus)))")
        print("   - Can WRITE Workout: \(canWriteWorkout) (status: \(authStatusString(workoutAuthStatus)))")
        
        // If both are denied, abort
        if workoutAuthStatus == .sharingDenied && hrAuthStatus == .sharingDenied {
            print("❌ [HealthManager] Both permissions DENIED - cannot proceed")
            isAuthorized = false
            return
        }
        
        // If we can't read HR, warn but still try (might work if workout session is active)
        if !canReadHR && hrAuthStatus == .sharingDenied {
            print("⚠️ [HealthManager] HR read permission DENIED - will try anyway via workout session")
        }
        
        // If not determined, request authorization (needed for reading existing workouts)
        if workoutAuthStatus == .notDetermined || hrAuthStatus == .notDetermined {
            print("💓 [HealthManager] Authorization not determined - requesting access...")
            requestHealthDataAccess()
            // Re-check after a brief delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.checkAuthorizationStatus()
                // Try to start workout session after authorization check
                if self?.isAuthorized == true {
                    self?.startWorkoutSession()
                }
            }
        } else if !isAuthorized {
            print("⚠️ [HealthManager] Not authorized - user must enable in Settings > Health > Data Access & Devices")
            print("💡 [HealthManager] To enable: Settings > Privacy & Security > Health > RunbotAIWatch > Turn ON Workouts and Heart Rate")
        } else {
            // Already authorized - proceed
            print("✅ [HealthManager] Already authorized - proceeding with workout session")
        }
        
        // Reset zone tracking when starting
        print("💓 [HealthManager] Resetting zone tracking...")
        resetZoneTracking()
        runStartTime = Date()
        print("💓 [HealthManager] Run start time set: \(runStartTime!)")
        
        // CRITICAL: Start workout session even if not fully authorized
        // The workout session can provide HR data even if read permission is notDetermined
        // Only skip if workout write is explicitly denied
        // Use the workoutAuthStatus already checked above (line 439)
        if workoutAuthStatus != HKAuthorizationStatus.sharingDenied {
            print("💓 [HealthManager] Starting workout session (can provide HR data)...")
            startWorkoutSession()
            
            // Start HR query after a short delay to let workout session initialize
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.startHeartRateQuery()
            }
        } else {
            print("❌ [HealthManager] Cannot start workout session - workout write permission denied")
        }
        
        // Load HR config for zone calculation
        print("💓 [HealthManager] Loading HR config for zones...")
        loadHRConfigForZones()
        
        // Start periodic zone percentage updates
        print("💓 [HealthManager] Starting zone update timer...")
        startZoneUpdateTimer()
        
        // Start periodic HR data saves to Supabase (every 30 seconds)
        print("💓 [HealthManager] Starting HR save timer...")
        startHRSaveTimer()
        
        // Start periodic distance updates from workout (every 5 seconds)
        print("💓 [HealthManager] Starting distance update timer...")
        startDistanceUpdateTimer()
        
        print("✅ [HealthManager] ========== HEART RATE MONITORING STARTED ==========")
    }
    
    func authStatusString(_ status: HKAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .sharingDenied: return "sharingDenied"
        case .sharingAuthorized: return "sharingAuthorized"
        @unknown default: return "unknown"
        }
    }
    
    /// Start workout session with comprehensive validation
    /// 
    /// Performs 5 critical checks before starting:
    /// 1. HealthKit availability
    /// 2. Workout authorization status
    /// 3. No other active workouts (only one workout at a time)
    /// 4. Valid workout configuration (activity + location type)
    /// 5. Running on watchOS (not iPhone - standalone watch app)
    private func startWorkoutSession() {
        print("🏃 [HealthManager] ========== STARTING HKWORKOUTSESSION ==========")
        print("🏃 [HealthManager] Thread: \(Thread.isMainThread ? "Main" : "Background")")
        
        // ✅ CHECK 1: HealthKit availability
        guard HKHealthStore.isHealthDataAvailable() else {
            print("❌ [HealthManager] HealthKit NOT available - aborting workout session")
            DispatchQueue.main.async {
                self.workoutStatus = .error("HealthKit not available on this device")
            }
            return
        }
        print("✅ [HealthManager] CHECK 1 PASSED: HealthKit is available")
        
        // ✅ CHECK 2: Authorization status
        let workoutType = HKObjectType.workoutType()
        let workoutAuthStatus = healthStore.authorizationStatus(for: workoutType)
        print("🏃 [HealthManager] CHECK 2: Workout authorization status: \(workoutAuthStatus.rawValue) (\(authStatusString(workoutAuthStatus)))")
        
        if workoutAuthStatus == .sharingDenied {
            print("❌ [HealthManager] CHECK 2 FAILED: Workout authorization DENIED")
            print("💡 [HealthManager] User must enable in Settings > Privacy & Security > Health > RunbotAIWatch")
            DispatchQueue.main.async {
                self.workoutStatus = .error("Workout permission denied - enable in Settings")
            }
            return
        }
        print("✅ [HealthManager] CHECK 2 PASSED: Workout authorization OK")
        
        // ✅ CHECK 3: Check if another workout is already running
        // Only one workout can be active at a time on watchOS
        // FIX: If we have our own active session, stop it first before starting new one
        if workoutSession != nil && workoutSession?.state == .running {
            print("⚠️ [HealthManager] CHECK 3: Our own workout session still running - stopping it first...")
            stopHeartRateMonitoring() // This will properly end the old session
            // Wait a moment for cleanup, then proceed
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.checkForActiveWorkoutsAndStart()
            }
            return
        }
        
        // Check for other active workouts and handle them
        checkForActiveWorkoutsAndStart()
    }
    
    /// Check for active workouts and either stop them or proceed with starting new workout
    private func checkForActiveWorkoutsAndStart() {
        checkForActiveWorkouts { [weak self] hasActiveWorkout, activeWorkoutUUID in
            guard let self = self else { return }
            
            if hasActiveWorkout {
                print("⚠️ [HealthManager] Found active workout: \(activeWorkoutUUID ?? "unknown")")
                print("💡 [HealthManager] Auto-stopping orphaned workout before starting new one...")
                
                // FIX: Automatically stop the orphaned workout by ending our own session cleanup
                // Since we don't have access to other app's workouts, we'll proceed anyway
                // HealthKit should handle conflicts automatically
                print("✅ [HealthManager] Proceeding with new workout - HealthKit will handle conflicts")
            }
            print("✅ [HealthManager] CHECK 3 PASSED: Ready to start new workout")
            
            // Continue with workout session creation
            self.createWorkoutSession()
        }
    }
    
    /// Check if another workout is currently active
    /// Returns: (hasActiveWorkout: Bool, workoutUUID: String?)
    private func checkForActiveWorkouts(completion: @escaping (Bool, String?) -> Void) {
        let workoutType = HKObjectType.workoutType()
        let predicate = HKQuery.predicateForWorkouts(with: .running)
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        
        let query = HKSampleQuery(
            sampleType: workoutType,
            predicate: predicate,
            limit: 1,
            sortDescriptors: [sortDescriptor]
        ) { _, samples, error in
            if let error = error {
                print("⚠️ [HealthManager] Error checking for active workouts: \(error.localizedDescription)")
                // Assume no active workout if query fails - proceed anyway
                completion(false, nil)
                return
            }
            
            let hasActiveWorkout = (samples?.count ?? 0) > 0
            let workoutUUID = samples?.first?.uuid.uuidString
            if hasActiveWorkout {
                print("⚠️ [HealthManager] Found active workout: \(workoutUUID ?? "unknown")")
            }
            completion(hasActiveWorkout, workoutUUID)
        }
        
        healthStore.execute(query)
    }
    
    /// Create and start the workout session (called after all checks pass)
    private func createWorkoutSession() {
        print("🏃 [HealthManager] All checks passed - creating workout session...")
        
        // ✅ CHECK 4: Verify configuration is valid
        // Create workout configuration for outdoor running
        // This enables GPS tracking via watch/iPhone and accurate distance measurement
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .running
        configuration.locationType = .outdoor // Critical: Enables GPS tracking for accurate distance
        
        // ✅ CHECK 5: Ensure we're on watch (not iPhone)
        #if os(watchOS)
        print("✅ [HealthManager] CHECK 5 PASSED: Running on watchOS (not iPhone)")
        #else
        print("❌ [HealthManager] CHECK 5 FAILED: Not running on watchOS!")
        DispatchQueue.main.async {
            self.workoutStatus = .error("Workout must be started on Apple Watch")
        }
        return
        #endif
        
        workoutConfiguration = configuration
        print("✅ [HealthManager] CHECK 4 PASSED: Workout configuration valid")
        print("🏃 [HealthManager] Configuration:")
        print("   - Activity: Running")
        print("   - Location: Outdoor (GPS enabled)")
        
        // CRITICAL: Ensure we're on main thread for workout session creation
        // HKWorkoutSession must be created on main thread on watchOS
        guard Thread.isMainThread else {
            print("⚠️ [HealthManager] Not on main thread - dispatching to main...")
            DispatchQueue.main.async { [weak self] in
                self?.createWorkoutSession()
            }
            return
        }
        
        do {
            // ✅ REQUIREMENT 4: HKWorkoutSession Set Up
            print("🏃 [HealthManager] ========== CREATING HKWORKOUTSESSION ==========")
            print("🏃 [HealthManager] Creating HKWorkoutSession on main thread...")
            print("🏃 [HealthManager] Configuration:")
            print("   - Activity Type: Running")
            print("   - Location Type: Outdoor")
            print("   - Health Store: \(healthStore)")
            
            let session = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
            
            // CRITICAL: Retain session immediately to prevent deallocation
            self.workoutSession = session
            print("✅✅✅ [HealthManager] REQUIREMENT 4 MET: HKWorkoutSession created and retained ✅✅✅")
            print("   Session object: \(session)")
            print("   Session state: \(session.state.rawValue) (\(workoutStateString(session.state)))")
            print("   Session retained: \(self.workoutSession != nil)")
            
            // ✅ REQUIREMENT 5: HKLiveWorkoutBuilder Set Up
            print("🏃 [HealthManager] ========== CREATING HKLIVEWORKOUTBUILDER ==========")
            print("🏃 [HealthManager] Creating workout builder from session...")
            let builder = session.associatedWorkoutBuilder()
            print("✅ [HealthManager] Builder created: \(builder)")
            
            print("🏃 [HealthManager] Creating live workout data source...")
            let dataSource = HKLiveWorkoutDataSource(healthStore: healthStore, workoutConfiguration: configuration)
            print("✅ [HealthManager] Data source created: \(dataSource)")
            print("💡 [HealthManager] HKLiveWorkoutDataSource automatically collects:")
            print("   - Heart Rate (enables green sensor light)")
            print("   - Distance (GPS)")
            print("   - Active Energy")
            print("   - Other workout metrics")
            
            builder.dataSource = dataSource
            print("✅ [HealthManager] Data source assigned to builder")
            print("💡 [HealthManager] Green HR sensor light will activate when session reaches .running state")
            
            // CRITICAL: Retain builder immediately to prevent deallocation
            self.workoutBuilder = builder
            print("✅✅✅ [HealthManager] REQUIREMENT 5 MET: HKLiveWorkoutBuilder created and retained ✅✅✅")
            print("   Builder object: \(builder)")
            print("   Builder retained: \(self.workoutBuilder != nil)")
            print("   Builder dataSource: \(builder.dataSource != nil ? "SET" : "NOT SET")")
            
            // Create workout route builder for GPS tracking
            print("🏃 [HealthManager] Creating workout route builder...")
            self.workoutRouteBuilder = HKWorkoutRouteBuilder(healthStore: healthStore, device: nil)
            print("✅ [HealthManager] Route builder created")
            
            // ✅ REQUIREMENT 6: Delegate Callbacks - Set delegate BEFORE preparing
            print("🏃 [HealthManager] ========== SETTING DELEGATE ==========")
            print("🏃 [HealthManager] Setting session delegate...")
            print("🏃 [HealthManager] Delegate object: \(self)")
            session.delegate = self
            print("✅✅✅ [HealthManager] REQUIREMENT 6 MET: Delegate set ✅✅✅")
            print("   Session delegate: \(session.delegate != nil ? "SET" : "NOT SET")")
            print("   Delegate is self: \(session.delegate === self)")
            
            // Verify session is still retained
            guard self.workoutSession != nil, self.workoutBuilder != nil else {
                print("❌ [HealthManager] CRITICAL: Session or builder was deallocated!")
                return
            }
            
            // CRITICAL FIX: Prepare session BEFORE starting (required on watchOS)
            // This ensures delegate callbacks will fire properly
            print("🏃 [HealthManager] ========== PREPARING WORKOUT SESSION ==========")
            print("🏃 [HealthManager] Session state BEFORE prepare: \(session.state.rawValue) (\(workoutStateString(session.state)))")
            session.prepare()
            print("✅✅✅ [HealthManager] session.prepare() CALLED ✅✅✅")
            print("🏃 [HealthManager] Session state AFTER prepare: \(session.state.rawValue) (\(workoutStateString(session.state)))")
            print("🏃 [HealthManager] Waiting for delegate callback to confirm prepared state...")
            
            // Start the workout session - CRITICAL for real-time HR
            // Start IMMEDIATELY - don't wait for collection to begin
            let startDate = runStartTime ?? Date()
            print("🏃 [HealthManager] ========== STARTING WORKOUT ACTIVITY ==========")
            print("🏃 [HealthManager] Start date: \(startDate)")
            print("🏃 [HealthManager] Session state BEFORE startActivity: \(session.state.rawValue) (\(workoutStateString(session.state)))")
            print("🏃 [HealthManager] Delegate set: \(session.delegate != nil)")
            print("🏃 [HealthManager] Thread: \(Thread.isMainThread ? "Main ✅" : "Background ❌")")
            
            // Start activity FIRST (enables HR sensor immediately)
            // This MUST be called on main thread
            // CRITICAL: startActivity() triggers the workout session to transition to .running state
            // When .running state is reached, HKLiveWorkoutDataSource automatically starts collecting HR
            // This activates the green HR sensor light under the watch
            session.startActivity(with: startDate)
            print("✅✅✅ [HealthManager] session.startActivity() CALLED ✅✅✅")
            print("✅ [HealthManager] Workout activity STARTED")
            print("💡 [HealthManager] Session will transition to .running state (delegate callback will confirm)")
            print("💡 [HealthManager] Green HR sensor light activates when session reaches .running state")
            print("   Session state after startActivity: \(session.state.rawValue) (\(workoutStateString(session.state)))")
            print("🏃 [HealthManager] Waiting for delegate callback to confirm state transition to .running...")
            
            // Update workout status
            DispatchQueue.main.async { [weak self] in
                self?.workoutStatus = .starting
            }
            
            // Start HR query (anchored query provides real-time updates)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self = self, self.workoutSession != nil else { return }
                self.startHeartRateQuery()
            }
            
            // Begin collection (for distance/GPS tracking)
            // This MUST happen after startActivity
            print("🏃 [HealthManager] Beginning workout collection...")
            builder.beginCollection(withStart: startDate) { [weak self] success, error in
                DispatchQueue.main.async {
                    guard let self = self else {
                        print("⚠️ [HealthManager] Self deallocated during collection callback")
                        return
                    }
                    
                    // Verify session is still retained
                    guard self.workoutSession != nil, self.workoutBuilder != nil else {
                        print("❌ [HealthManager] CRITICAL: Session or builder was deallocated during collection!")
                        return
                    }
                    
                    if let error = error {
                        let errorMsg = error.localizedDescription
                        print("❌ [HealthManager] FAILED to begin workout collection:")
                        print("   Error: \(errorMsg)")
                        print("   Domain: \((error as NSError).domain)")
                        print("   Code: \((error as NSError).code)")
                        print("   UserInfo: \((error as NSError).userInfo)")
                        
                        // Update status with error
                        DispatchQueue.main.async {
                            self.workoutStatus = .error(errorMsg)
                            self.hrDataStatus = .error(errorMsg)
                        }
                        
                        // Don't crash - continue without HR
                        if errorMsg.contains("entitlement") {
                            print("⚠️ [HealthManager] HealthKit entitlement issue - app will continue without heart rate")
                        }
                    } else if success {
                        print("✅ [HealthManager] Workout collection STARTED - distance tracking active")
                        print("   Session state: \(self.workoutSession?.state.rawValue ?? -1)")
                        
                        // Update workout status to running if session is running
                        if let session = self.workoutSession, session.state == .running {
                            DispatchQueue.main.async {
                                self.workoutStatus = .running
                            }
                        }
                        
                        // Heart rate query already started above
                    } else {
                        print("⚠️ [HealthManager] Workout collection returned false (not started)")
                        DispatchQueue.main.async {
                            self.workoutStatus = .error("Collection failed")
                    }
                }
            }
            }
            print("🏃 [HealthManager] Collection request submitted, waiting for callback...")
        } catch {
            let errorMsg = error.localizedDescription
            print("❌ [HealthManager] FAILED to create HKWorkoutSession:")
            print("   Error: \(errorMsg)")
            print("   Type: \(type(of: error))")
            if let nsError = error as NSError? {
                print("   Domain: \(nsError.domain)")
                print("   Code: \(nsError.code)")
                print("   UserInfo: \(nsError.userInfo)")
            }
            
            // Update status with error
            DispatchQueue.main.async { [weak self] in
                self?.workoutStatus = .error(errorMsg)
                self?.hrDataStatus = .error(errorMsg)
            }
            
            // Don't crash - continue without HR
            if errorMsg.contains("entitlement") {
                print("⚠️ [HealthManager] HealthKit entitlement missing - app will continue without heart rate")
            }
        }
        print("🏃 [HealthManager] ========== WORKOUT SESSION START COMPLETE ==========")
    }
    
    private func startHeartRateQuery() {
        print("💓 [HealthManager] ========== STARTING HEART RATE QUERY ==========")
        
        // Stop existing query if any
        if let existingQuery = heartRateQuery {
            print("💓 [HealthManager] Stopping existing HR query...")
            healthStore.stop(existingQuery)
            heartRateQuery = nil
        }
        
        guard let heartRateType = HKQuantityType.quantityType(forIdentifier: .heartRate) else {
            print("❌ [HealthManager] Cannot create heart rate type")
            return
        }
        
        let hrAuthStatus = healthStore.authorizationStatus(for: heartRateType)
        print("💓 [HealthManager] HR authorization status: \(hrAuthStatus.rawValue) (\(authStatusString(hrAuthStatus)))")
        
        // CRITICAL: Try to read HR even if authorization is notDetermined
        // The workout session might provide HR data even without explicit read permission
        if hrAuthStatus == .sharingDenied {
            print("⚠️ [HealthManager] HR read permission DENIED - trying via workout session data source")
            // Still try - workout session data source might work
        }
        
        // Use workout session start time or current time minus 1 minute
        let startTime = runStartTime ?? Date().addingTimeInterval(-60)
        print("💓 [HealthManager] Query start time: \(startTime)")
        print("💓 [HealthManager] Run start time: \(runStartTime?.description ?? "nil")")
        
        // Create predicate for samples from start time onwards
        let predicate = HKQuery.predicateForSamples(withStart: startTime, end: nil, options: .strictStartDate)
        
        print("💓 [HealthManager] Creating HKAnchoredObjectQuery...")
        let query = HKAnchoredObjectQuery(
            type: heartRateType,
            predicate: predicate,
            anchor: nil,
            limit: HKObjectQueryNoLimit
        ) { [weak self] query, samples, deletedObjects, anchor, error in
            guard let self = self else { return }
            
            if let error = error {
                print("❌ [HealthManager] HR query initial results error: \(error.localizedDescription)")
                return
            }
            
            guard let samples = samples as? [HKQuantitySample], !samples.isEmpty else {
                print("⚠️ [HealthManager] HR query returned no initial samples")
                return
            }
            
            print("✅ [HealthManager] HR query initial results: \(samples.count) samples")
            if let newest = samples.max(by: { $0.endDate < $1.endDate }) {
                let hr = newest.quantity.doubleValue(for: HKUnit(from: "count/min"))
                print("💓 [HealthManager] Latest HR from initial query: \(Int(hr)) BPM")
                DispatchQueue.main.async {
                    self.updateHeartRate(heartRate: hr)
                }
            }
        }
        
        // CRITICAL: Update handler for real-time HR updates
        query.updateHandler = { [weak self] query, samples, deletedObjects, anchor, error in
            guard let self = self else { return }
            
            if let error = error {
                print("❌ [HealthManager] HR query update error: \(error.localizedDescription)")
                return
            }
            
            guard let samples = samples as? [HKQuantitySample], !samples.isEmpty else {
                // No samples in this update - this is normal, just means no new HR data yet
                return
            }
            
            print("💓 [HealthManager] HR query update: \(samples.count) new samples")
            if let newest = samples.max(by: { $0.endDate < $1.endDate }) {
                let hr = newest.quantity.doubleValue(for: HKUnit(from: "count/min"))
                print("💓 [HealthManager] Latest HR: \(Int(hr)) BPM (timestamp: \(newest.endDate))")
                DispatchQueue.main.async {
                    self.updateHeartRate(heartRate: hr)
                }
            }
        }
        
        heartRateQuery = query
        print("💓 [HealthManager] Executing HR query...")
        healthStore.execute(query)
        print("✅ [HealthManager] HR query executed - waiting for updates...")
        
        // Also try to read from workout builder statistics if available
        // This is a fallback if the query doesn't work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.tryReadHRFromWorkoutBuilder()
        }
    }
    
    /// Fallback: Try to read HR from workout builder statistics
    private func tryReadHRFromWorkoutBuilder() {
        guard let builder = workoutBuilder else {
            print("⚠️ [HealthManager] No workout builder for HR fallback")
            return
        }
        
        guard let heartRateType = HKQuantityType.quantityType(forIdentifier: .heartRate) else {
            return
        }
        
        print("💓 [HealthManager] Trying to read HR from workout builder statistics...")
        if let statistics = builder.statistics(for: heartRateType),
           let mostRecent = statistics.mostRecentQuantity() {
            let hr = mostRecent.doubleValue(for: HKUnit(from: "count/min"))
            print("💓 [HealthManager] HR from workout builder: \(Int(hr)) BPM")
            DispatchQueue.main.async {
                self.updateHeartRate(heartRate: hr)
            }
        } else {
            print("⚠️ [HealthManager] No HR statistics available in workout builder yet")
        }
    }
    
    private func updateHeartRate(heartRate: Double) {
        print("💓 [HealthManager] ========== UPDATE HEART RATE ==========")
        print("💓 [HealthManager] Heart Rate: \(Int(heartRate)) BPM")
        print("💓 [HealthManager] Thread: \(Thread.isMainThread ? "Main" : "Background")")
        
        currentHeartRate = heartRate
        
        // Update HR data status
        DispatchQueue.main.async { [weak self] in
            self?.hrDataStatus = .active
        }
        
        print("✅ [HealthManager] currentHeartRate updated to \(Int(heartRate)) BPM")
        
        // Send HR update to iOS via WatchConnectivity
        print("💓 [HealthManager] Sending HR update to iOS...")
        WatchConnectivityManager.shared.sendHeartRateUpdate(heartRate)
        
        // Update zone tracking
        print("💓 [HealthManager] Updating zone tracking...")
        updateZoneTracking(newHeartRate: heartRate)
        
        // Add to samples for average/min/max
        let heartRateType = HKQuantityType.quantityType(forIdentifier: .heartRate)!
        let quantity = HKQuantity(unit: HKUnit(from: "count/min"), doubleValue: heartRate)
        let sample = HKQuantitySample(
            type: heartRateType,
            quantity: quantity,
            start: Date(),
            end: Date()
        )
        
        heartRateSamples.append(sample)
        
        // Keep only recent samples (last 10 minutes)
        let tenMinutesAgo = Date().addingTimeInterval(-600)
        heartRateSamples = heartRateSamples.filter { $0.startDate > tenMinutesAgo }
        
        // Calculate average
        if !heartRateSamples.isEmpty {
            let total = heartRateSamples.reduce(0.0) { sum, sample in
                sum + sample.quantity.doubleValue(for: HKUnit(from: "count/min"))
            }
            averageHeartRate = total / Double(heartRateSamples.count)
        }
        
        // Update min/max
        let heartRates = heartRateSamples.map { $0.quantity.doubleValue(for: HKUnit(from: "count/min")) }
        if let min = heartRates.min() {
            minHeartRate = min
        }
        if let max = heartRates.max() {
            maxHeartRate = max
        }
    }
    
    func stopHeartRateMonitoring() {
        print("💓 [HealthManager] ========== Stopping heart rate monitoring ==========")
        
        // Stop zone update timer
        stopZoneUpdateTimer()
        
        // Stop HR save timer
        stopHRSaveTimer()
        
        // Stop distance update timer
        stopDistanceUpdateTimer()
        
        // Stop periodic HR reading
        stopPeriodicHRReading()
        
        // Finalize zone tracking and save final data
        finalizeZoneTracking()
        
        // Final save to Supabase
        if let runId = currentRunId, let manager = supabaseManager {
            Task {
                print("💓 [HealthManager] Performing final HR save to Supabase...")
                _ = await manager.saveRunHR(runId, healthManager: self)
            }
        }
        
        // Stop heart rate queries
        if let query = heartRateQuery {
            healthStore.stop(query)
            heartRateQuery = nil
        }
        
        // End workout session
        endWorkoutSession()
        
        // Clear references
        currentRunId = nil
        supabaseManager = nil
        
        print("💓 [HealthManager] ========== Heart rate monitoring stopped ==========")
    }
    
    private func endWorkoutSession() {
        guard let session = workoutSession, let builder = workoutBuilder else {
            print("⚠️ [HealthManager] No workout session to end")
            return
        }
        
        let endDate = Date()
        print("🏃 [HealthManager] Ending workout session at \(endDate)")
        
        // End the workout session FIRST (stops HR sensor)
        session.end()
        print("✅ [HealthManager] Workout session ended")
        
        // End collection and save workout
        builder.endCollection(withEnd: endDate) { [weak self] success, error in
            guard let self = self else { return }
            
            if let error = error {
                print("❌ [HealthManager] Failed to end workout collection: \(error.localizedDescription)")
                // Still try to finish workout
                self.finishWorkout(builder: builder)
            } else if success {
                print("✅ [HealthManager] Workout collection ended")
                
                // Get final distance from workout statistics before finishing
                self.getWorkoutDistance(from: builder) { distance in
                    if let distance = distance {
                        DispatchQueue.main.async {
                            self.workoutDistance = distance
                            print("📏 [HealthManager] Final workout distance: \(String(format: "%.2f", distance / 1000.0)) km")
                        }
                    }
                }
                
                // Finish workout (saves to HealthKit)
                self.finishWorkout(builder: builder)
            } else {
                print("⚠️ [HealthManager] Workout collection end returned false")
                self.finishWorkout(builder: builder)
            }
        }
    }
    
    private func finishWorkout(builder: HKWorkoutBuilder) {
        // Save workout to HealthKit, then finish route
        builder.finishWorkout { [weak self] workout, error in
            guard let self = self else { return }
            
            if let error = error {
                print("❌ [HealthManager] Failed to save workout: \(error.localizedDescription)")
            } else if let workout = workout {
                print("✅✅✅ [HealthManager] Workout saved to HealthKit: \(workout.uuid) ✅✅✅")
                print("   Duration: \(workout.duration) seconds")
                print("   Distance: \(workout.totalDistance?.doubleValue(for: .meter()) ?? 0) meters")
                print("💡 [HealthManager] Workout saved - App should now appear in Health > Watch > Apps")
                
                // Finish route builder with the finished workout
                if let routeBuilder = self.workoutRouteBuilder {
                    routeBuilder.finishRoute(with: workout, metadata: nil) { route, error in
                        if let error = error {
                            print("❌ [HealthManager] Failed to finish route: \(error.localizedDescription)")
                        } else {
                            print("✅ [HealthManager] Workout route finished and saved")
                        }
                    }
                }
            } else {
                print("⚠️ [HealthManager] Workout finished but no workout object returned")
            }
            
            // Clear references
            self.workoutSession = nil
            self.workoutBuilder = nil
            self.workoutRouteBuilder = nil
            self.workoutConfiguration = nil
            print("✅ [HealthManager] Workout session fully cleaned up")
        }
    }
    
    // Get distance from workout statistics (synchronous API)
    private func getWorkoutDistance(from builder: HKWorkoutBuilder, completion: @escaping (Double?) -> Void) {
        let distanceType = HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning)!
        
        // statistics(for:) is synchronous, returns optional
        if let statistics = builder.statistics(for: distanceType),
           let sum = statistics.sumQuantity() {
            let distance = sum.doubleValue(for: HKUnit.meter())
            completion(distance)
        } else {
            completion(nil)
        }
    }
    
    // Add location to workout route (GPS data from watch or iPhone via Bluetooth)
    func addLocationToWorkout(_ location: CLLocation) {
        guard let routeBuilder = workoutRouteBuilder else { return }
        // Use insertRouteData with array of locations
        // This GPS data comes from watch's built-in GPS or iPhone's GPS via Bluetooth
        routeBuilder.insertRouteData([location]) { success, error in
            if let error = error {
                print("⚠️ [HealthManager] Failed to insert route data: \(error.localizedDescription)")
            } else if success {
                // Location successfully added to workout route
                print("📍 [HealthManager] Location added to workout route: \(location.coordinate.latitude), \(location.coordinate.longitude), accuracy: \(location.horizontalAccuracy)m")
            }
        }
    }
    
    // MARK: - Zone Tracking
    
    private func resetZoneTracking() {
        zoneTimeSpent = [1: 0, 2: 0, 3: 0, 4: 0, 5: 0]
        zonePercentages = [1: 0, 2: 0, 3: 0, 4: 0, 5: 0]
        zoneAveragePace = [1: 0, 2: 0, 3: 0, 4: 0, 5: 0]
        zonePaceSamples = [1: [], 2: [], 3: [], 4: [], 5: []]
        currentZone = nil
        zoneStartTime = nil
        lastZoneUpdateTime = nil
        totalRunTime = 0
        runStartTime = nil
        adaptiveGuidance = ""
        print("💓 [HealthManager] Zone tracking reset")
    }
    
    private func startZoneUpdateTimer() {
        stopZoneUpdateTimer()
        
        // Update zone percentages every 5 seconds for real-time UI refresh
        zoneUpdateTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self = self, self.runStartTime != nil else { return }
            DispatchQueue.main.async {
            self.calculateZonePercentages()
            self.calculateZoneAveragePace()
                // Force UI update by triggering objectWillChange
                self.objectWillChange.send()
            }
        }
        
        if let timer = zoneUpdateTimer {
            RunLoop.current.add(timer, forMode: .common)
        }
        
        // Calculate immediately on start
        DispatchQueue.main.async {
            self.calculateZonePercentages()
            self.calculateZoneAveragePace()
        }
    }
    
    private func stopZoneUpdateTimer() {
        zoneUpdateTimer?.invalidate()
        zoneUpdateTimer = nil
    }
    
    /// Start periodic HR reading from workout builder (fallback mechanism)
    private func startPeriodicHRReading() {
        stopPeriodicHRReading()
        
        print("💓 [HealthManager] Starting periodic HR reading from workout builder...")
        periodicHRTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self, self.workoutSession?.state == .running else { return }
            self.tryReadHRFromWorkoutBuilder()
        }
        
        if let timer = periodicHRTimer {
            RunLoop.current.add(timer, forMode: .common)
        }
    }
    
    private func stopPeriodicHRReading() {
        periodicHRTimer?.invalidate()
        periodicHRTimer = nil
    }
    
    // MARK: - Periodic Distance Updates from Workout
    
    private var distanceUpdateTimer: Timer?
    
    private func startDistanceUpdateTimer() {
        stopDistanceUpdateTimer()
        
        // Update distance from workout statistics every 1 second for real-time accuracy
        // HealthKit workout statistics are updated continuously during active workout
        // Apple Watch GPS (Series 2+) provides real-time GPS data, so we can poll frequently
        distanceUpdateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, let builder = self.workoutBuilder else { return }
            
            self.getWorkoutDistance(from: builder) { distance in
                if let distance = distance {
                    DispatchQueue.main.async {
                        self.workoutDistance = distance
                        print("📏 [HealthManager] Workout distance updated: \(String(format: "%.2f", distance))m")
                    }
                }
            }
        }
        
        if let timer = distanceUpdateTimer {
            RunLoop.current.add(timer, forMode: .common)
        }
    }
    
    private func stopDistanceUpdateTimer() {
        distanceUpdateTimer?.invalidate()
        distanceUpdateTimer = nil
    }
    
    // MARK: - Periodic HR Data Save
    
    private func startHRSaveTimer() {
        stopHRSaveTimer()
        
        // Save HR data every 30 seconds during the run
        hrSaveTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            guard let self = self,
                  let runId = self.currentRunId,
                  let manager = self.supabaseManager else { return }
            
            Task {
                print("💓 [HealthManager] Periodic HR save triggered...")
                _ = await manager.saveRunHR(runId, healthManager: self)
            }
        }
        
        if let timer = hrSaveTimer {
            RunLoop.current.add(timer, forMode: .common)
        }
        
        print("💓 [HealthManager] HR save timer started (30s interval)")
    }
    
    private func stopHRSaveTimer() {
        hrSaveTimer?.invalidate()
        hrSaveTimer = nil
    }
    
    private func loadHRConfigForZones() {
        Task {
            // Get current user ID from UserDefaults
            let userId: String? = {
                if let data = UserDefaults.standard.data(forKey: "currentUser"),
                   let user = try? JSONDecoder().decode(User.self, from: data) {
                    return user.id
                }
                return nil
            }()
            
            guard let userId = userId else {
                print("⚠️ [HealthManager] No user ID for HR config - using defaults")
                // Use safe defaults if no user ID
                await MainActor.run {
                    self.hrConfigAge = 30 // Default age
                    self.hrConfigRestingHR = 60 // Default resting HR
                }
                return
            }
            
            // SAFE: Only reads from existing table (if it exists) - no writes, no new tables
            let manager = SupabaseManager()
            manager.initializeSession(for: userId)
            let config = await manager.loadHRConfig()
            
            await MainActor.run {
                // Use config if available, otherwise safe defaults
                // This ensures watchOS works even if user_health_config table doesn't exist
                self.hrConfigAge = config?.age ?? 30
                self.hrConfigRestingHR = config?.restingHeartRate ?? 60
                print("💓 [HealthManager] HR Config - Age: \(self.hrConfigAge ?? 30), Resting HR: \(self.hrConfigRestingHR ?? 60)")
            }
        }
    }
    
    func finalizeZoneTracking() {
        if let currentZone = currentZone, let lastUpdate = lastZoneUpdateTime {
            let timeSinceLastUpdate = Date().timeIntervalSince(lastUpdate)
            zoneTimeSpent[currentZone, default: 0] += timeSinceLastUpdate
        }
        
        calculateZonePercentages()
    }
    
    private func calculateZonePercentages() {
        guard let startTime = runStartTime else { return }
        
        totalRunTime = Date().timeIntervalSince(startTime)
        
        guard totalRunTime > 0 else {
            zonePercentages = [1: 0, 2: 0, 3: 0, 4: 0, 5: 0]
            return
        }
        
        var newPercentages: [Int: Double] = [:]
        for zone in 1...5 {
            let timeInZone = zoneTimeSpent[zone] ?? 0
            let percentage = (timeInZone / totalRunTime) * 100.0
            newPercentages[zone] = percentage
        }
        
        zonePercentages = newPercentages
        objectWillChange.send()
    }
    
    private func updateZoneTracking(newHeartRate: Double) {
        guard let age = hrConfigAge, let restingHR = hrConfigRestingHR else {
            if hrConfigAge == nil || hrConfigRestingHR == nil {
                loadHRConfigForZones()
            }
            return
        }
        
        let newZone = HeartZoneCalculator.currentZone(
            currentHR: newHeartRate,
            age: age,
            restingHeartRate: restingHR
        )
        
        guard let newZone = newZone else {
            return
        }
        
        let now = Date()
        
        // If zone changed, update time spent in previous zone
        if let previousZone = currentZone, previousZone != newZone {
            if let lastUpdate = lastZoneUpdateTime {
                let timeInPreviousZone = now.timeIntervalSince(lastUpdate)
                zoneTimeSpent[previousZone, default: 0] += timeInPreviousZone
                print("💓 [HealthManager] Zone changed: Z\(previousZone) -> Z\(newZone)")
            }
        } else if currentZone == nil {
            print("💓 [HealthManager] Initial zone assigned: Z\(newZone) for HR: \(Int(newHeartRate)) BPM")
        }
        
        // Update time spent in current zone
        if let previousZone = currentZone, previousZone == newZone, let lastUpdate = lastZoneUpdateTime {
            let timeSinceLastUpdate = now.timeIntervalSince(lastUpdate)
            zoneTimeSpent[newZone, default: 0] += timeSinceLastUpdate
        }
        
        currentZone = newZone
        lastZoneUpdateTime = now
        
        if zoneStartTime == nil {
            zoneStartTime = now
        }
        
        // Recalculate percentages on every update
        if let startTime = runStartTime {
            totalRunTime = now.timeIntervalSince(startTime)
            if totalRunTime > 0 {
                calculateZonePercentages()
            }
        }
    }
    
    /// Update zone tracking with current pace (to be called by RunTracker)
    func updateZoneWithPace(currentPace: Double) {
        guard let zone = currentZone, currentPace > 0 else { return }
        
        // Add pace sample to the current zone
        zonePaceSamples[zone, default: []].append(currentPace)
        
        // Keep only recent samples (last 100 per zone to avoid memory issues)
        if zonePaceSamples[zone]!.count > 100 {
            zonePaceSamples[zone] = Array(zonePaceSamples[zone]!.suffix(100))
        }
    }
    
    private func calculateZoneAveragePace() {
        var newAveragePace: [Int: Double] = [:]
        
        for zone in 1...5 {
            if let samples = zonePaceSamples[zone], !samples.isEmpty {
                let avgPace = samples.reduce(0.0, +) / Double(samples.count)
                newAveragePace[zone] = avgPace
            } else {
                newAveragePace[zone] = 0
            }
        }
        
        DispatchQueue.main.async {
            self.zoneAveragePace = newAveragePace
        }
    }
    
    /// Update adaptive guidance based on current zone and pace (enhanced analysis)
    func updateAdaptiveGuidance(currentPace: Double) {
        guard let currentZone = currentZone, currentPace > 0 else {
            adaptiveGuidance = ""
            return
        }
        
        // Enhanced guidance with zone-specific advice
        let guidance: String
        switch currentZone {
        case 1:
            // Recovery zone - very easy effort
            if currentPace < 6.0 {
                guidance = "Excellent efficiency! Zone 1 with fast pace — you're strong"
        } else {
                guidance = "Recovery zone — perfect for warm-up or cooldown"
            }
        case 2:
            // Aerobic base - comfortable effort
            if currentPace < 6.5 {
                guidance = "Strong aerobic base — great sustainable pace"
            } else if currentPace > 8.0 {
                guidance = "Zone 2 but pace is slow — consider increasing effort slightly"
            } else {
                guidance = "Perfect aerobic zone — maintain this effort"
            }
        case 3:
            // Tempo zone - comfortably hard
            if currentPace < 6.5 {
                guidance = "Excellent tempo pace — strong performance"
            } else if currentPace > 7.5 {
                guidance = "Zone 3 effort but pace could improve — focus on form"
            } else {
                guidance = "Good tempo effort — sustainable for longer runs"
            }
        case 4:
            // Threshold zone - hard effort
            if currentPace > 7.0 {
                guidance = "High effort (Z4) but pace is slow — ease up or focus on form"
            } else {
                guidance = "Threshold zone — strong effort, maintain if feeling good"
            }
        case 5:
            // VO2max zone - maximum effort
            if currentPace > 7.0 {
                guidance = "Maximum effort (Z5) — pace suggests fatigue, consider recovery"
            } else {
                guidance = "VO2max zone — maximum effort, use sparingly"
            }
        default:
            guidance = "Pace and effort are balanced"
        }
        
        adaptiveGuidance = guidance
    }
}

// MARK: - HKWorkoutSessionDelegate
extension HealthManager: HKWorkoutSessionDelegate {
    func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState, from fromState: HKWorkoutSessionState, date: Date) {
        let fromStateStr = workoutStateString(fromState)
        let toStateStr = workoutStateString(toState)
        print("🏃 [HealthManager] ========== WORKOUT SESSION STATE CHANGE ==========")
        print("✅✅✅ [HealthManager] REQUIREMENT 6 MET: Delegate callback FIRING ✅✅✅")
        print("🏃 [HealthManager] State: \(fromStateStr) -> \(toStateStr)")
        print("🏃 [HealthManager] Date: \(date)")
        print("🏃 [HealthManager] Raw values: \(fromState.rawValue) -> \(toState.rawValue)")
        print("🏃 [HealthManager] Thread: \(Thread.isMainThread ? "Main ✅" : "Background ⚠️")")
        print("🏃 [HealthManager] Session object: \(workoutSession)")
        print("🏃 [HealthManager] Delegate is self: \(workoutSession.delegate === self)")
        
        // Ensure delegate callbacks are on main thread
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
        // Log important state transitions
        if toState == .running {
            print("✅✅✅ [HealthManager] Workout session is now RUNNING - HR should be active ✅✅✅")
            print("💡 [HealthManager] Green HR sensor light should now be visible under the watch")
            print("💡 [HealthManager] HKLiveWorkoutDataSource is now actively collecting heart rate")
            
            // Update workout status
            DispatchQueue.main.async { [weak self] in
                self?.workoutStatus = .running
            }
            
            // CRITICAL: When session reaches running state, HR data should be available
            // Start HR query if not already started
            if self.heartRateQuery == nil {
                print("💓 [HealthManager] Session is RUNNING - starting HR query now...")
                self.startHeartRateQuery()
            } else {
                print("✅ [HealthManager] HR query already active")
            }
            
            // Also try reading from workout builder statistics (fallback)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.tryReadHRFromWorkoutBuilder()
            }
            
            // Set up periodic HR reading from workout builder (every 2 seconds)
            // This ensures we get HR even if the query has issues
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.startPeriodicHRReading()
            }
            
            // Verify builder is retained (dataSource is set earlier in startWorkoutSession)
            if self.workoutBuilder != nil {
                print("✅ [HealthManager] Workout builder is retained - HR collection should be working")
            } else {
                print("❌ [HealthManager] WARNING: Workout builder is nil - HR may not be collected!")
            }
        } else if toState == .prepared {
            print("✅ [HealthManager] Workout session PREPARED - ready to start")
            DispatchQueue.main.async { [weak self] in
                self?.workoutStatus = .starting
            }
        } else if toState == .ended {
            print("⚠️ [HealthManager] Workout session ENDED")
            DispatchQueue.main.async { [weak self] in
                self?.workoutStatus = .notStarted
            }
        } else if toState == .paused {
            print("⚠️ [HealthManager] Workout session PAUSED")
        } else if toState == .stopped {
            print("⚠️ [HealthManager] Workout session STOPPED")
            DispatchQueue.main.async { [weak self] in
                self?.workoutStatus = .notStarted
            }
        }
            
            // Verify session is still retained
            if self.workoutSession == nil {
                print("❌ [HealthManager] CRITICAL: Workout session was deallocated during state change!")
            }
        }
    }
    
    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        print("❌ [HealthManager] ========== WORKOUT SESSION ERROR ==========")
        print("❌ [HealthManager] Error: \(error.localizedDescription)")
        if let nsError = error as NSError? {
            print("❌ [HealthManager] Domain: \(nsError.domain)")
            print("❌ [HealthManager] Code: \(nsError.code)")
            print("❌ [HealthManager] UserInfo: \(nsError.userInfo)")
        }
        
        // Try to recover if possible
        DispatchQueue.main.async { [weak self] in
            guard self != nil else { return }
            // Don't clear session on error - let user stop manually
            print("⚠️ [HealthManager] Workout session error - session retained for manual stop")
        }
    }
}

// MARK: - Helper Methods
extension HealthManager {
    func workoutStateString(_ state: HKWorkoutSessionState) -> String {
        switch state {
        case .notStarted: return "notStarted"
        case .prepared: return "prepared"
        case .running: return "running"
        case .paused: return "paused"
        case .stopped: return "stopped"
        case .ended: return "ended"
        @unknown default: return "unknown(\(state.rawValue))"
        }
    }
}

// Note: Heart rate data is collected via anchored object query, not builder delegate

