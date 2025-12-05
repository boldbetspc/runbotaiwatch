import Foundation
import HealthKit
import Combine
import SwiftUI

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
    private var workoutSession: HKWorkoutSession?
    private var workoutBuilder: HKWorkoutBuilder?
    private var workoutConfiguration: HKWorkoutConfiguration?
    
    private var heartRateQuery: HKQuery?
    private var heartRateSamples: [HKQuantitySample] = []
    
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
    
    override init() {
        super.init()
        print("💓 [HealthManager] Initializing...")
        // Don't request authorization in init - wait for explicit call
    }
    
    func requestHealthDataAccess() {
        print("💓 [HealthManager] Requesting health data access...")
        
        guard HKHealthStore.isHealthDataAvailable() else {
            print("⚠️ [HealthManager] Health data is not available on this device")
            isAuthorized = false
            return
        }
        
        // Check if HealthKit entitlement is available (graceful handling)
        #if os(watchOS)
        // On watchOS, check if we can actually use HealthKit
        do {
            let _ = try healthStore.authorizationStatus(for: HKObjectType.workoutType())
        } catch {
            print("⚠️ [HealthManager] HealthKit entitlement may be missing: \(error.localizedDescription)")
            print("⚠️ [HealthManager] Continuing without HealthKit - app will work without heart rate")
            isAuthorized = false
            return
        }
        #endif
        
        guard let heartRateType = HKQuantityType.quantityType(forIdentifier: .heartRate) else {
            print("❌ [HealthManager] Could not create heart rate type")
            isAuthorized = false
            return
        }
        
        let workoutType = HKObjectType.workoutType()
        
        let typesToRead: Set<HKObjectType> = [heartRateType, workoutType]
        let typesToWrite: Set<HKSampleType> = [workoutType]
        
        healthStore.requestAuthorization(toShare: typesToWrite, read: typesToRead) { [weak self] success, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isAuthorized = success
                if let error = error {
                    let errorMsg = error.localizedDescription
                    print("⚠️ [HealthManager] Health data authorization error: \(errorMsg)")
                    // Don't crash - just mark as not authorized
                    if errorMsg.contains("entitlement") {
                        print("⚠️ [HealthManager] HealthKit entitlement missing - app will continue without heart rate data")
                    }
                } else {
                    print("✅ [HealthManager] Health data authorized: \(success)")
                }
            }
        }
    }
    
    // MARK: - CRITICAL: HKWorkoutSession for watchOS Real-Time HR
    
    func startHeartRateMonitoring(runId: String? = nil, supabaseManager: SupabaseManager? = nil) {
        print("💓 [HealthManager] ========== Starting heart rate monitoring ==========")
        
        // Store run ID and Supabase manager for periodic saves
        self.currentRunId = runId
        self.supabaseManager = supabaseManager
        
        guard HKHealthStore.isHealthDataAvailable() else {
            print("⚠️ [HealthManager] HealthKit not available - continuing without heart rate")
            isAuthorized = false
            return
        }
        
        if !isAuthorized {
            print("⚠️ [HealthManager] Cannot start - not authorized, requesting access...")
            requestHealthDataAccess()
            // Check again after requesting
            if !isAuthorized {
                print("⚠️ [HealthManager] HealthKit not authorized - app will continue without heart rate data")
                return
            }
        }
        
        // Reset zone tracking when starting
        resetZoneTracking()
        runStartTime = Date()
        
        // Load HR config for zone calculation
        loadHRConfigForZones()
        
        // Start periodic zone percentage updates
        startZoneUpdateTimer()
        
        // Start periodic HR data saves to Supabase (every 30 seconds)
        startHRSaveTimer()
        
        // CRITICAL: Start HKWorkoutSession for real-time HR on watchOS
        startWorkoutSession()
        
        print("💓 [HealthManager] ========== Heart rate monitoring started ==========")
    }
    
    private func startWorkoutSession() {
        print("🏃 [HealthManager] ========== Starting HKWorkoutSession ==========")
        
        // Check if HealthKit is available and authorized
        guard HKHealthStore.isHealthDataAvailable() else {
            print("⚠️ [HealthManager] HealthKit not available - continuing without workout session")
            return
        }
        
        guard isAuthorized else {
            print("⚠️ [HealthManager] Not authorized for HealthKit - continuing without workout session")
            return
        }
        
        // Create workout configuration
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .running
        configuration.locationType = .outdoor
        
        workoutConfiguration = configuration
        
        do {
            // CRITICAL: Create HKWorkoutSession - this enables real-time HR on watchOS
            let session = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
            workoutSession = session
            
            // Create workout builder with live data source
            guard let builder = session.associatedWorkoutBuilder() as? HKLiveWorkoutBuilder else {
                print("⚠️ [HealthManager] Could not create workout builder - continuing without HR")
                return
            }
            
            let dataSource = HKLiveWorkoutDataSource(healthStore: healthStore, workoutConfiguration: configuration)
            builder.dataSource = dataSource
            workoutBuilder = builder
            
            // Set session delegate
            session.delegate = self
            
            // Start the workout session - CRITICAL for real-time HR
            let startDate = runStartTime ?? Date()
            session.startActivity(with: startDate)
            builder.beginCollection(withStart: startDate) { [weak self] success, error in
                DispatchQueue.main.async {
                    if let error = error {
                        let errorMsg = error.localizedDescription
                        print("⚠️ [HealthManager] Failed to begin workout collection: \(errorMsg)")
                        // Don't crash - continue without HR
                        if errorMsg.contains("entitlement") {
                            print("⚠️ [HealthManager] HealthKit entitlement issue - app will continue without heart rate")
                        }
                    } else if success {
                        print("✅ [HealthManager] HKWorkoutSession started - real-time HR active")
                        self?.startHeartRateQuery()
                    } else {
                        print("⚠️ [HealthManager] Workout collection did not start - continuing without HR")
                    }
                }
            }
        } catch {
            let errorMsg = error.localizedDescription
            print("⚠️ [HealthManager] Failed to create HKWorkoutSession: \(errorMsg)")
            // Don't crash - continue without HR
            if errorMsg.contains("entitlement") {
                print("⚠️ [HealthManager] HealthKit entitlement missing - app will continue without heart rate")
            }
        }
    }
    
    private func startHeartRateQuery() {
        // Stop existing query if any
        if let existingQuery = heartRateQuery {
            healthStore.stop(existingQuery)
            heartRateQuery = nil
        }
        
        let heartRateType = HKQuantityType.quantityType(forIdentifier: .heartRate)!
        
        // Anchored query for real-time push updates
        let query = HKAnchoredObjectQuery(
            type: heartRateType,
            predicate: nil, // No filter - get all new samples
            anchor: nil,
            limit: HKObjectQueryNoLimit
        ) { [weak self] query, samples, deletedObjects, anchor, error in
            if let error = error {
                print("❌ [HealthManager] Anchored query error: \(error.localizedDescription)")
                return
            }
            
            guard let samples = samples as? [HKQuantitySample], !samples.isEmpty else {
                return
            }
            
            guard let self = self else { return }
            
            // Get the most recent sample
            if let newestSample = samples.max(by: { $0.endDate < $1.endDate }) {
                let hr = newestSample.quantity.doubleValue(for: HKUnit(from: "count/min"))
                print("💓 [HealthManager] ✅ HR Update: \(Int(hr)) BPM")
                
                DispatchQueue.main.async {
                    self.updateHeartRate(heartRate: hr)
                }
            }
        }
        
        // Update handler for real-time updates
        query.updateHandler = { [weak self] query, samples, deletedObjects, anchor, error in
            if let error = error {
                print("❌ [HealthManager] Anchored query update error: \(error.localizedDescription)")
                return
            }
            
            guard let samples = samples as? [HKQuantitySample], !samples.isEmpty else {
                return
            }
            
            guard let self = self else { return }
            
            // Get the most recent sample
            if let newestSample = samples.max(by: { $0.endDate < $1.endDate }) {
                let hr = newestSample.quantity.doubleValue(for: HKUnit(from: "count/min"))
                print("💓 [HealthManager] ✅ HR Update: \(Int(hr)) BPM")
                
                DispatchQueue.main.async {
                    self.updateHeartRate(heartRate: hr)
                }
            }
        }
        
        heartRateQuery = query
        healthStore.execute(query)
        print("💓 [HealthManager] Heart rate query started - real-time HR stream active")
    }
    
    private func updateHeartRate(heartRate: Double) {
        currentHeartRate = heartRate
        
        // Send HR update to iOS via WatchConnectivity
        WatchConnectivityManager.shared.sendHeartRateUpdate(heartRate)
        
        // Update zone tracking
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
        
        // Finalize zone tracking and save final data
        finalizeZoneTracking()
        
        // Final save to Supabase
        if let runId = currentRunId, let manager = supabaseManager {
            Task {
                print("💓 [HealthManager] Performing final HR save to Supabase...")
                _ = await manager.saveRunHR(runId, healthManager: self)
            }
        }
        
        // Stop heart rate query
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
        guard let session = workoutSession else {
            return
        }
        
        let endDate = Date()
        
        // End the workout session
        session.end()
        
        // End collection
        let builder = session.associatedWorkoutBuilder()
        builder.endCollection(withEnd: endDate) { success, error in
            if let error = error {
                print("❌ [HealthManager] Failed to end workout collection: \(error.localizedDescription)")
            } else {
                print("✅ [HealthManager] Workout collection ended")
            }
        }
        
        workoutSession = nil
        workoutBuilder = nil
        workoutConfiguration = nil
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
        
        zoneUpdateTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            guard let self = self, self.runStartTime != nil else { return }
            self.calculateZonePercentages()
            self.calculateZoneAveragePace()
        }
        
        if let timer = zoneUpdateTimer {
            RunLoop.current.add(timer, forMode: .common)
        }
    }
    
    private func stopZoneUpdateTimer() {
        zoneUpdateTimer?.invalidate()
        zoneUpdateTimer = nil
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
    
    /// Update adaptive guidance based on current zone and pace
    func updateAdaptiveGuidance(currentPace: Double) {
        guard let currentZone = currentZone, currentPace > 0 else {
            adaptiveGuidance = ""
            return
        }
        
        // Simple guidance rules
        if (currentZone == 4 || currentZone == 5) && currentPace > 7.0 {
            adaptiveGuidance = "High effort for low pace — ease up"
        } else if (currentZone == 1 || currentZone == 2) && currentPace < 6.0 {
            adaptiveGuidance = "Great efficiency — strong pace"
        } else {
            adaptiveGuidance = "Pace and effort are balanced"
        }
    }
}

// MARK: - HKWorkoutSessionDelegate
extension HealthManager: HKWorkoutSessionDelegate {
    func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState, from fromState: HKWorkoutSessionState, date: Date) {
        print("🏃 [HealthManager] Workout session state changed: \(fromState.rawValue) -> \(toState.rawValue)")
    }
    
    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        print("❌ [HealthManager] Workout session error: \(error.localizedDescription)")
    }
}

// Note: Heart rate data is collected via anchored object query, not builder delegate

