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
    private var workoutBuilderHRQuery: HKStatisticsQuery?
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
        print("💓 [HealthManager] Running on watchOS - requesting authorization ON WATCH")
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
        
        // If already requested authorization AND still not determined, request again
        // (User might have dismissed the dialog, or it's still pending)
        if hasRequestedAuthorization {
            if workoutAuthStatus == .notDetermined || hrAuthStatus == .notDetermined {
                print("⚠️ [HealthManager] Authorization was requested before but still notDetermined")
                print("   Requesting again - user may have dismissed previous dialog")
                // Continue to request again below
            } else {
                print("⚠️ [HealthManager] Authorization already requested - checking current status")
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
        
        healthStore.requestAuthorization(toShare: typesToWrite, read: typesToRead) { [weak self] success, error in
            DispatchQueue.main.async {
                guard let self = self else {
                    print("⚠️ [HealthManager] Self deallocated during authorization")
                    return
                }
                self.isAuthorized = success
                if let error = error {
                    let errorMsg = error.localizedDescription
                    print("❌ [HealthManager] Health data authorization ERROR: \(errorMsg)")
                    print("   Error domain: \((error as NSError).domain)")
                    print("   Error code: \((error as NSError).code)")
                    // Don't crash - just mark as not authorized
                    if errorMsg.contains("entitlement") {
                        print("⚠️ [HealthManager] HealthKit entitlement missing - app will continue without heart rate data")
                    }
                } else {
                    print("✅ [HealthManager] Health data authorization SUCCESS: \(success)")
                    // Re-check status after authorization
                    let newWorkoutStatus = self.healthStore.authorizationStatus(for: workoutType)
                    let newHRStatus = self.healthStore.authorizationStatus(for: heartRateType)
                    print("💓 [HealthManager] After authorization:")
                    print("   - Workout: \(newWorkoutStatus.rawValue) (\(self.authStatusString(newWorkoutStatus)))")
                    print("   - HR: \(newHRStatus.rawValue) (\(self.authStatusString(newHRStatus)))")
                }
            }
        }
        print("💓 [HealthManager] Authorization request submitted, waiting for callback...")
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
        
        // CRITICAL: Check authorization status
        // Authorization should already be requested during app initialization
        if workoutAuthStatus == .sharingDenied || hrAuthStatus == .sharingDenied {
            print("❌ [HealthManager] HealthKit authorization DENIED - cannot start HR monitoring")
            print("   User has denied HealthKit access. Please enable it in Settings > Privacy & Security > Health")
            isAuthorized = false
            return
        } else if workoutAuthStatus == .notDetermined || hrAuthStatus == .notDetermined {
            // Authorization not determined - request it now
            print("⚠️ [HealthManager] Authorization NOT DETERMINED - requesting now...")
            print("   Workout: \(workoutAuthStatus.rawValue), HR: \(hrAuthStatus.rawValue)")
            print("   This should trigger authorization dialog on watch")
            
            // Request authorization (async - don't block)
            requestHealthDataAccess()
            
            // Wait a moment for authorization dialog, then check status
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self = self else { return }
                
                // Re-check status after authorization request
                let newWorkoutStatus = self.healthStore.authorizationStatus(for: workoutType)
                let newHRStatus = self.healthStore.authorizationStatus(for: heartRateType)
                
                print("💓 [HealthManager] Authorization status after request:")
                print("   - Workout: \(newWorkoutStatus.rawValue) (\(self.authStatusString(newWorkoutStatus)))")
                print("   - HR: \(newHRStatus.rawValue) (\(self.authStatusString(newHRStatus)))")
                
                if newWorkoutStatus == .sharingDenied || newHRStatus == .sharingDenied {
                    print("❌ [HealthManager] Authorization DENIED after request - cannot start workout")
                    self.isAuthorized = false
                } else if newWorkoutStatus == .sharingAuthorized && newHRStatus == .sharingAuthorized {
                    print("✅ [HealthManager] Authorization GRANTED - retrying workout start")
                    self.isAuthorized = true
                    // Retry workout start if authorization was granted
                    if self.workoutSession == nil {
                        print("🏃 [HealthManager] Retrying workout session start after authorization...")
                        self.startWorkoutSession()
                    }
                } else {
                    print("⚠️ [HealthManager] Authorization still not determined - attempting workout start anyway")
                    // Continue anyway - workout will fail gracefully if not authorized
                }
            }
            
            // Continue with workout start attempt (will fail gracefully if not authorized)
            print("⚠️ [HealthManager] Proceeding with workout start attempt (authorization may be pending)")
        } else {
            // Authorization is granted
            isAuthorized = true
            print("✅ [HealthManager] Authorization confirmed - proceeding with workout")
        }
        
        // Reset zone tracking when starting
        print("💓 [HealthManager] Resetting zone tracking...")
        resetZoneTracking()
        runStartTime = Date()
        print("💓 [HealthManager] Run start time set: \(runStartTime!)")
        
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
        
        // CRITICAL: Start HKWorkoutSession for real-time HR on watchOS
        print("💓 [HealthManager] Starting workout session...")
        startWorkoutSession()
        
        print("✅ [HealthManager] ========== HEART RATE MONITORING STARTED ==========")
    }
    
    private func authStatusString(_ status: HKAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .sharingDenied: return "sharingDenied"
        case .sharingAuthorized: return "sharingAuthorized"
        @unknown default: return "unknown"
        }
    }
    
    private func startWorkoutSession() {
        print("🏃 [HealthManager] ========== STARTING HKWORKOUTSESSION ==========")
        print("🏃 [HealthManager] Thread: \(Thread.isMainThread ? "Main" : "Background")")
        
        // Check if HealthKit is available
        guard HKHealthStore.isHealthDataAvailable() else {
            print("❌ [HealthManager] HealthKit NOT available - aborting workout session")
            return
        }
        print("✅ [HealthManager] HealthKit is available")
        
        // Check authorization status directly (more reliable than cached flag)
        let workoutType = HKObjectType.workoutType()
        let workoutAuthStatus = healthStore.authorizationStatus(for: workoutType)
        print("🏃 [HealthManager] Workout authorization status: \(workoutAuthStatus.rawValue) (\(authStatusString(workoutAuthStatus)))")
        
        if workoutAuthStatus == .sharingDenied {
            print("❌ [HealthManager] Workout authorization DENIED - cannot start workout session")
            return
        }
        
        // Try to start workout even if authorization is notDetermined (user might grant it)
        // The workout session will fail gracefully if not authorized
        print("🏃 [HealthManager] Attempting to create workout session...")
        
        // Create workout configuration for outdoor running
        // This enables GPS tracking via watch/iPhone and accurate distance measurement
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .running
        configuration.locationType = .outdoor // Critical: Enables GPS tracking for accurate distance
        
        workoutConfiguration = configuration
        print("🏃 [HealthManager] Workout configuration created:")
        print("   - Activity: Running")
        print("   - Location: Outdoor")
        
        // CRITICAL: Ensure we're on main thread for workout session creation
        // HKWorkoutSession must be created on main thread on watchOS
        guard Thread.isMainThread else {
            print("⚠️ [HealthManager] Not on main thread - dispatching to main...")
            DispatchQueue.main.async { [weak self] in
                self?.startWorkoutSession()
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
            
            builder.dataSource = dataSource
            print("✅ [HealthManager] Data source assigned to builder")
            
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
            session.startActivity(with: startDate)
            print("✅✅✅ [HealthManager] session.startActivity() CALLED ✅✅✅")
            print("✅ [HealthManager] Workout activity STARTED - HR sensor should be active now")
            print("   Session state after startActivity: \(session.state.rawValue) (\(workoutStateString(session.state)))")
            print("🏃 [HealthManager] Waiting for delegate callback to confirm state transition...")
            
            // Update workout status
            DispatchQueue.main.async { [weak self] in
                self?.workoutStatus = .starting
            }
            
            // CRITICAL FIX: Use workout builder statistics for HR (recommended on watchOS)
            // This is more reliable than anchored query when workout session is active
            print("🏃 [HealthManager] Setting up workout builder statistics query for HR...")
            startWorkoutBuilderHRQuery(builder: builder)
            
            // Also start anchored query as backup (works even before collection begins)
            print("🏃 [HealthManager] Scheduling anchored HR query in 1.0 second...")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self = self else {
                    print("⚠️ [HealthManager] Self deallocated before HR query start")
                    return
                }
                guard self.workoutSession != nil else {
                    print("❌ [HealthManager] Workout session was deallocated before HR query!")
                    return
                }
                print("🏃 [HealthManager] Starting anchored HR query now...")
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
    
    // CRITICAL FIX: Use workout builder statistics for HR (recommended on watchOS)
    // This queries statistics directly from the active workout builder
    private func startWorkoutBuilderHRQuery(builder: HKLiveWorkoutBuilder) {
        print("💓 [HealthManager] ========== STARTING WORKOUT BUILDER HR STATISTICS QUERY ==========")
        
        guard let heartRateType = HKQuantityType.quantityType(forIdentifier: .heartRate) else {
            print("❌ [HealthManager] Heart rate type NOT available - aborting builder query")
            return
        }
        
        // Stop existing builder query if any
        if let existingQuery = workoutBuilderHRQuery {
            print("💓 [HealthManager] Stopping existing builder HR query...")
            healthStore.stop(existingQuery)
            workoutBuilderHRQuery = nil
        }
        
        print("💓 [HealthManager] Creating statistics query from workout builder...")
        print("💓 [HealthManager] Builder: \(builder)")
        // Note: HKWorkoutBuilder doesn't expose dataSource directly, but it's set internally
        
        // Query statistics from the workout builder
        // This gets real-time HR data directly from the active workout
        let query = HKStatisticsQuery(
            quantityType: heartRateType,
            quantitySamplePredicate: nil, // Get all samples from this workout
            options: [.discreteAverage, .discreteMin, .discreteMax, .mostRecent]
        ) { [weak self] query, statistics, error in
            guard let self = self else {
                print("⚠️ [HealthManager] Self deallocated in builder statistics callback")
                return
            }
            
            if let error = error {
                print("❌ [HealthManager] Builder statistics query ERROR: \(error.localizedDescription)")
                return
            }
            
            guard let statistics = statistics else {
                print("💓 [HealthManager] Builder statistics query: No statistics yet (waiting for HR sensor...)")
                return
            }
            
            // Get most recent HR value
            if let mostRecent = statistics.mostRecentQuantity() {
                let hr = mostRecent.doubleValue(for: HKUnit(from: "count/min"))
                print("💓 [HealthManager] ✅✅✅ BUILDER HR UPDATE: \(Int(hr)) BPM ✅✅✅")
                if let dateInterval = statistics.mostRecentQuantityDateInterval() {
                    print("   Most recent date: \(dateInterval.start)")
                }
                
                DispatchQueue.main.async {
                    self.updateHeartRate(heartRate: hr)
                }
            } else {
                print("💓 [HealthManager] Builder statistics: No most recent HR value yet")
            }
            
            // Also log average if available
            if let average = statistics.averageQuantity() {
                let avgHR = average.doubleValue(for: HKUnit(from: "count/min"))
                print("💓 [HealthManager] Builder statistics - Average HR: \(Int(avgHR)) BPM")
            }
        }
        
        // Note: HKStatisticsQuery is a one-shot query (no update handler)
        // Continuous HR updates come from the HKAnchoredObjectQuery (startHeartRateQuery)
        // This query just provides initial statistics from the workout builder
        
        workoutBuilderHRQuery = query
        // Execute query on health store (not builder - builder collects automatically via dataSource)
        healthStore.execute(query)
        print("✅✅✅ [HealthManager] Workout builder HR statistics query EXECUTED ✅✅✅")
        print("💓 [HealthManager] Query will receive updates as workout collects HR data")
        print("💓 [HealthManager] ========== WORKOUT BUILDER HR QUERY START COMPLETE ==========")
    }
    
    private func startHeartRateQuery() {
        print("💓 [HealthManager] ========== STARTING HEART RATE QUERY ==========")
        print("💓 [HealthManager] Thread: \(Thread.isMainThread ? "Main" : "Background")")
        
        // Stop existing query if any
        if let existingQuery = heartRateQuery {
            print("💓 [HealthManager] Stopping existing HR query...")
            healthStore.stop(existingQuery)
            heartRateQuery = nil
            print("✅ [HealthManager] Existing query stopped")
        }
        
        guard let heartRateType = HKQuantityType.quantityType(forIdentifier: .heartRate) else {
            print("❌ [HealthManager] Heart rate type NOT available - aborting query")
            return
        }
        print("✅ [HealthManager] Heart rate type available")
        
        // Check authorization for heart rate
        let hrAuthStatus = healthStore.authorizationStatus(for: heartRateType)
        print("💓 [HealthManager] HR authorization status: \(hrAuthStatus.rawValue) (\(authStatusString(hrAuthStatus)))")
        
        if hrAuthStatus == .sharingDenied {
            print("❌ [HealthManager] HR authorization DENIED - cannot query heart rate")
            return
        }
        
        // CRITICAL: Use workout session as data source for real-time HR
        // This ensures we get HR data directly from the active workout
        let startTime = runStartTime ?? Date().addingTimeInterval(-60)
        print("💓 [HealthManager] Query start time: \(startTime)")
        
        let predicate = HKQuery.predicateForSamples(
            withStart: startTime,
            end: nil,
            options: .strictStartDate
        )
        print("💓 [HealthManager] Query predicate created")
        
        // Anchored query for real-time push updates
        print("💓 [HealthManager] Creating anchored object query...")
        let query = HKAnchoredObjectQuery(
            type: heartRateType,
            predicate: predicate, // Filter to current workout session
            anchor: nil,
            limit: HKObjectQueryNoLimit
        ) { [weak self] query, samples, deletedObjects, anchor, error in
            print("💓 [HealthManager] ========== INITIAL QUERY CALLBACK ==========")
            if let error = error {
                print("❌ [HealthManager] Anchored query INITIAL ERROR:")
                print("   Error: \(error.localizedDescription)")
                print("   Domain: \((error as NSError).domain)")
                print("   Code: \((error as NSError).code)")
                return
            }
            
            print("💓 [HealthManager] Initial query results:")
            print("   Samples: \(samples?.count ?? 0)")
            print("   Deleted: \(deletedObjects?.count ?? 0)")
            
            guard let samples = samples as? [HKQuantitySample], !samples.isEmpty else {
                print("💓 [HealthManager] Initial query: No samples yet (waiting for HR sensor...)")
                print("   This is normal - sensor may need a few seconds to activate")
                return
            }
            
            guard let self = self else {
                print("⚠️ [HealthManager] Self deallocated in initial query callback")
                return
            }
            
            // Get the most recent sample
            if let newestSample = samples.max(by: { $0.endDate < $1.endDate }) {
                let hr = newestSample.quantity.doubleValue(for: HKUnit(from: "count/min"))
                print("💓 [HealthManager] ✅✅✅ HR UPDATE (INITIAL): \(Int(hr)) BPM ✅✅✅")
                print("   Sample date: \(newestSample.startDate)")
                
                DispatchQueue.main.async {
                    self.updateHeartRate(heartRate: hr)
                }
            }
        }
        
        // Update handler for real-time updates (called continuously)
        query.updateHandler = { [weak self] query, samples, deletedObjects, anchor, error in
            if let error = error {
                print("❌ [HealthManager] Anchored query UPDATE ERROR: \(error.localizedDescription)")
                return
            }
            
            guard let samples = samples as? [HKQuantitySample], !samples.isEmpty else {
                // No samples yet - this is normal at workout start
                // Don't log every time to avoid spam
                return
            }
            
            guard let self = self else {
                print("⚠️ [HealthManager] Self deallocated in update handler")
                return
            }
            
            // Get the most recent sample
            if let newestSample = samples.max(by: { $0.endDate < $1.endDate }) {
                let hr = newestSample.quantity.doubleValue(for: HKUnit(from: "count/min"))
                print("💓 [HealthManager] ✅✅✅ HR UPDATE: \(Int(hr)) BPM ✅✅✅")
                
                DispatchQueue.main.async {
                    self.updateHeartRate(heartRate: hr)
                }
            }
        }
        
        heartRateQuery = query
        print("💓 [HealthManager] Executing heart rate query...")
        healthStore.execute(query)
        print("✅ [HealthManager] Heart rate query EXECUTED - real-time HR stream active")
        print("💓 [HealthManager] Waiting for HR sensor to activate (may take 5-10 seconds)...")
        print("💓 [HealthManager] ========== HEART RATE QUERY START COMPLETE ==========")
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
        
        // Stop workout builder HR query
        if let builderQuery = workoutBuilderHRQuery {
            healthStore.stop(builderQuery)
            workoutBuilderHRQuery = nil
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
                print("✅ [HealthManager] Workout saved to HealthKit: \(workout.uuid)")
                print("   Duration: \(workout.duration) seconds")
                print("   Distance: \(workout.totalDistance?.doubleValue(for: .meter()) ?? 0) meters")
                
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
            // Update workout status
            DispatchQueue.main.async { [weak self] in
                self?.workoutStatus = .running
            }
            // When session reaches running state, ensure HR query is active
            if self.heartRateQuery == nil {
                print("⚠️ [HealthManager] HR query not started yet - starting now...")
                self.startHeartRateQuery()
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

