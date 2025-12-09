import Foundation
import CoreLocation
import Combine

class RunTracker: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var isRunning = false
    @Published var currentSession: RunSession?
    @Published var statsUpdate: RunningStatsUpdate?
    @Published var locationError: String?
    
    private let locationManager = CLLocationManager()
    private var previousLocations: [CLLocation] = []
    private var totalDistance: Double = 0.0
    private var caloriesEstimate: Double = 0.0
    private var totalElevation: Double = 0.0
    private var maxSpeed: Double = 0.0
    private var minSpeed: Double = Double.infinity
    private var updateTimer: Timer?
    private var intervalBuffer: [CLLocation] = []
    private let intervalDistanceMeters: Double = 10.0 // create interval every ~10m for current pace
    var supabaseManager: SupabaseManager?
    var healthManager: HealthManager?
    
    // Configuration
    let runnerWeight: Double = 70.0 // kg, typical runner weight
    let caloriesBurnedPerKm: Double = 65.0 // kcal per km
    
    override init() {
        super.init()
        setupLocationManager()
    }
    
    private func setupLocationManager() {
        locationManager.delegate = self
        // Best accuracy for outdoor running - uses GPS, cellular, and Bluetooth beacons
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        // Small distance filter for real-time updates during running
        locationManager.distanceFilter = 3 // 3 meters for very accurate tracking
        locationManager.activityType = .fitness
        // Allow deferred updates for better battery efficiency while maintaining accuracy
        locationManager.allowsBackgroundLocationUpdates = false // Not needed for watchOS
        
        // Request location permission
        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        }
    }

    // Expose explicit permission request to call right after login
    func requestLocationPermission() {
        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        }
    }
    
    // MARK: - Run Control
    
    func startRun(mode: RunMode = .run, shadowData: ShadowRunData? = nil) {
        guard !isRunning else { return }
        
        var newSession = RunSession(
            id: UUID().uuidString,
            userId: "",
            startTime: Date()
        )
        newSession.mode = mode
        newSession.shadowRunData = shadowData
        newSession.shadowReferenceRunId = shadowData?.prModel.runId
        
        currentSession = newSession
        isRunning = true
        totalDistance = 0.0
        caloriesEstimate = 0.0
        totalElevation = 0.0
        maxSpeed = 0.0
        minSpeed = Double.infinity
        previousLocations = []
        intervalBuffer = []
        
        locationManager.startUpdatingLocation()
        
        // CRITICAL: Start HealthManager for real-time HR via HKWorkoutSession
        // Pass run ID and SupabaseManager for periodic HR saves
        healthManager?.startHeartRateMonitoring(
            runId: newSession.id,
            supabaseManager: supabaseManager
        )
        
        // Notify iOS that workout started
        if let sessionId = currentSession?.id {
            WatchConnectivityManager.shared.sendWorkoutStarted(runId: sessionId)
        }
        
        // Log run start for debugging
        print("🏃 [RunTracker] Run cache refresh will happen in AICoachManager")
        
        print("🏃 [RunTracker] Run started with ID: \(newSession.id)")
        startStatsUpdateTimer()
        updateStats()
    }
    
    /// Force final stats update before stopping (bypasses isRunning check)
    /// CRITICAL: Called right before stopRun() to capture absolute latest stats
    func forceFinalStatsUpdate() {
        print("📊 [RunTracker] Forcing final stats update to capture latest data...")
        
        // Do one final update even if isRunning will be false soon
        // This ensures we capture the absolute latest distance, pace, HR, etc.
        guard var session = currentSession else {
            print("⚠️ [RunTracker] No session to update")
            return
        }
        
        // Calculate final stats
        let distanceKm = totalDistance / 1000.0
        let elapsedSeconds = Date().timeIntervalSince(session.startTime)
        let elapsedHours = elapsedSeconds / 3600.0
        let avgSpeed = elapsedHours > 0 ? distanceKm / elapsedHours : 0.0
        let pace = distanceKm > 0 ? elapsedSeconds / 60.0 / distanceKm : 0.0
        let caloriesEstimate = distanceKm * caloriesBurnedPerKm
        
        // Calculate final current pace from last 30 seconds
        let currentPace: Double = {
            guard previousLocations.count >= 2 else { return pace }
            let cutoffTime = Date().addingTimeInterval(-30)
            let recentLocations = previousLocations.filter { $0.timestamp >= cutoffTime }
            guard recentLocations.count >= 2 else { return pace }
            
            var totalDistance30s: Double = 0.0
            for i in 1..<recentLocations.count {
                totalDistance30s += haversineDistance(
                    from: recentLocations[i-1].coordinate,
                    to: recentLocations[i].coordinate
                )
            }
            guard totalDistance30s >= 1 else { return pace }
            
            let timeInterval = recentLocations.last!.timestamp.timeIntervalSince(recentLocations.first!.timestamp)
            guard timeInterval > 0 else { return pace }
            
            let metersPerSecond = totalDistance30s / timeInterval
            let kmPerMin = (metersPerSecond * 3.6) / 60.0
            guard kmPerMin > 0 else { return pace }
            return 1.0 / kmPerMin
        }()
        
        // Update session with final values
        session.distance = totalDistance
        session.pace = pace
        session.avgSpeed = avgSpeed
        session.calories = caloriesEstimate
        session.elevation = totalElevation
        session.maxSpeed = maxSpeed > 0 ? maxSpeed * 3.6 : 0.0
        session.minSpeed = minSpeed != Double.infinity ? minSpeed * 3.6 : 0.0
        session.duration = elapsedSeconds
        session.endTime = Date()  // Set end time now
        session.isCompleted = true
        
        // Update shadow comparison if in train mode
        if session.shadowRunData != nil {
            updateShadowComparison(
                for: &session,
                currentPace: currentPace > 0 ? currentPace : pace,
                averagePace: pace,
                elapsedSeconds: elapsedSeconds
            )
        }
        
        currentSession = session
        
        // Create final stats update
        statsUpdate = RunningStatsUpdate(
            distance: totalDistance,
            pace: currentPace > 0 ? currentPace : pace,
            avgSpeed: avgSpeed,
            calories: caloriesEstimate,
            elevation: totalElevation,
            maxSpeed: session.maxSpeed,
            minSpeed: session.minSpeed,
            currentLocation: previousLocations.last
        )
        
        print("✅ [RunTracker] Final stats updated:")
        print("   Distance: \(String(format: "%.2f", distanceKm))km")
        print("   Duration: \(String(format: "%.1f", elapsedSeconds))s")
        print("   Pace: \(String(format: "%.2f", pace)) min/km")
        print("   Current Pace: \(String(format: "%.2f", currentPace)) min/km")
        print("   Calories: \(Int(caloriesEstimate))")
    }
    
    func stopRun() {
        guard isRunning else { return }
        
        isRunning = false
        locationManager.stopUpdatingLocation()
        updateTimer?.invalidate()
        
        // Stop HealthManager HR monitoring
        healthManager?.stopHeartRateMonitoring()
        
        // Ensure session has endTime set (should already be set by forceFinalStatsUpdate)
        if var session = currentSession {
            if session.endTime == nil {
                session.endTime = Date()
            }
            session.isCompleted = true
            currentSession = session
            
            // Notify iOS that workout ended with stats
            if let stats = statsUpdate {
                let statsDict: [String: Any] = [
                    "distance": stats.distance,
                    "duration": session.duration,
                    "pace": stats.pace,
                    "calories": stats.calories
                ]
                WatchConnectivityManager.shared.sendWorkoutEnded(stats: statsDict)
            }
        }
        
        print("✅ [RunTracker] Run stopped - session preserved with final stats")
    }
    
    // MARK: - Location Delegate
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard isRunning, var session = currentSession else { return }
        
        for newLocation in locations {
            // Ensure location accuracy is good for outdoor running
            // Accept locations with accuracy better than 50m (GPS typically 5-10m, cellular 50-100m)
            guard newLocation.horizontalAccuracy > 0 && newLocation.horizontalAccuracy < 50 else {
                print("⚠️ [RunTracker] Location accuracy too low: \(newLocation.horizontalAccuracy)m")
                continue
            }
            
            // Add location to workout route (for HealthKit workout) - this uses GPS from watch/iPhone
            healthManager?.addLocationToWorkout(newLocation)
            
            // Store location
            let locationPoint = LocationPoint(location: newLocation)
            session.locations.append(locationPoint)
            
            // Calculate distance from previous location (fallback if workout distance not available)
            if let lastLocation = previousLocations.last {
                let distance = haversineDistance(from: lastLocation.coordinate, to: newLocation.coordinate)
                totalDistance += distance
                
                // Update speed tracking
                let speed = newLocation.speed
                if speed > 0 {
                    maxSpeed = max(maxSpeed, speed)
                    minSpeed = min(minSpeed, speed)
                }
                
                // Track elevation change
                let elevationChange = newLocation.altitude - lastLocation.altitude
                if elevationChange > 0 {
                    totalElevation += elevationChange
                }
                // Build 10m interval buffer and emit intervals
                intervalBuffer.append(newLocation)
                trimIntervalBufferIfNeeded()
                if computeBufferedDistance() >= intervalDistanceMeters {
                    createIntervalIfPossible(in: &session)
                    intervalBuffer.removeAll(keepingCapacity: true)
                }
            }
            
            previousLocations.append(newLocation)
        }
        
        updateStats()
        currentSession = session
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        locationError = error.localizedDescription
    }
    
    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        switch status {
        case .authorizedWhenInUse, .authorizedAlways:
            locationManager.startUpdatingLocation()
        case .denied, .restricted:
            locationError = "Location permission denied"
        default:
            break
        }
    }
    
    // MARK: - Stats Calculation
    
    private func updateStats() {
        guard var session = currentSession, isRunning else { return }
        
        // PRIORITY: Use workout distance from HealthKit (most accurate - uses GPS from watch/iPhone)
        // FALLBACK: Use CoreLocation distance if HealthKit not available
        let distanceMeters: Double
        if let workoutDistance = healthManager?.workoutDistance, workoutDistance > 0 {
            // HealthKit workout distance is most accurate - uses GPS from watch or iPhone
            distanceMeters = workoutDistance
            totalDistance = workoutDistance // Sync for consistency
        } else {
            // Fallback to CoreLocation distance calculation
            distanceMeters = totalDistance
        }
        
        // Calculate distance in km
        let distanceKm = distanceMeters / 1000.0
        
        // Calculate elapsed time
        let elapsedSeconds = Date().timeIntervalSince(session.startTime)
        let elapsedHours = elapsedSeconds / 3600.0
        
        // Calculate average speed (km/h)
        let avgSpeed = elapsedHours > 0 ? distanceKm / elapsedHours : 0.0
        
        // Calculate average pace (minutes per km)
        let pace = distanceKm > 0 ? elapsedSeconds / 60.0 / distanceKm : 0.0

        // Calculate current pace from last 30 seconds of location data
        let currentPace: Double = {
            guard previousLocations.count >= 2 else { return 0.0 }
            
            // Get locations from last 30 seconds
            let cutoffTime = Date().addingTimeInterval(-30)
            let recentLocations = previousLocations.filter { $0.timestamp >= cutoffTime }
            
            guard recentLocations.count >= 2 else {
                // Fallback to interval buffer if not enough recent data
                guard intervalBuffer.count >= 2 else { return 0.0 }
                let d = computeBufferedDistance()
                guard d >= 1 else { return 0.0 }
                let start = intervalBuffer.first!.timestamp
                let end = intervalBuffer.last!.timestamp
                let dt = end.timeIntervalSince(start)
                guard dt > 0 else { return 0.0 }
                let metersPerSecond = d / dt
                let kmPerMin = (metersPerSecond * 3.6) / 60.0
                guard kmPerMin > 0 else { return 0.0 }
                return 1.0 / kmPerMin
            }
            
            // Calculate distance using Haversine formula for last 30s
            var totalDistance30s: Double = 0.0
            for i in 1..<recentLocations.count {
                totalDistance30s += haversineDistance(
                    from: recentLocations[i-1].coordinate,
                    to: recentLocations[i].coordinate
                )
            }
            
            guard totalDistance30s >= 1 else { return 0.0 }
            
            let startTime = recentLocations.first!.timestamp
            let endTime = recentLocations.last!.timestamp
            let timeInterval = endTime.timeIntervalSince(startTime)
            
            guard timeInterval > 0 else { return 0.0 }
            
            // Calculate pace: min per km
            let metersPerSecond = totalDistance30s / timeInterval
            let kmPerMin = (metersPerSecond * 3.6) / 60.0 // Convert m/s to km/min
            guard kmPerMin > 0 else { return 0.0 }
            
            return 1.0 / kmPerMin // min per km
        }()
        
        // Estimate calories burned
        caloriesEstimate = distanceKm * caloriesBurnedPerKm
        
        // Update HealthManager with current pace for zone-pace correlation and adaptive guidance
        if currentPace > 0 {
            healthManager?.updateZoneWithPace(currentPace: currentPace)
            healthManager?.updateAdaptiveGuidance(currentPace: currentPace)
        }
        
        // Update session - use workout distance if available (more accurate), otherwise use CoreLocation
        if let workoutDistance = healthManager?.workoutDistance, workoutDistance > 0 {
            session.distance = workoutDistance
        } else {
            session.distance = totalDistance
        }
        session.pace = pace
        session.avgSpeed = avgSpeed
        session.calories = caloriesEstimate
        session.elevation = totalElevation
        session.maxSpeed = maxSpeed > 0 ? maxSpeed * 3.6 : 0.0 // Convert m/s to km/h
        session.minSpeed = minSpeed != Double.infinity ? minSpeed * 3.6 : 0.0
        session.duration = elapsedSeconds
        updateShadowComparison(
            for: &session,
            currentPace: currentPace > 0 ? currentPace : pace,
            averagePace: pace,
            elapsedSeconds: elapsedSeconds
        )
        
        currentSession = session
        
        // Create stats update for UI
        statsUpdate = RunningStatsUpdate(
            distance: totalDistance,
            pace: currentPace > 0 ? currentPace : pace,
            avgSpeed: avgSpeed,
            calories: caloriesEstimate,
            elevation: totalElevation,
            maxSpeed: session.maxSpeed,
            minSpeed: session.minSpeed,
            currentLocation: previousLocations.last
        )
        
        // Update adaptive guidance in HealthManager
        if let currentPaceValue = statsUpdate?.pace, currentPaceValue > 0 {
            healthManager?.updateAdaptiveGuidance(currentPace: currentPaceValue)
        }
    }
    
    private func updateShadowComparison(
        for session: inout RunSession,
        currentPace: Double,
        averagePace: Double,
        elapsedSeconds: Double
    ) {
        guard var shadowData = session.shadowRunData else { return }
        let totalDistance = shadowData.prModel.distanceMeters
        guard totalDistance > 0 else { return }
        
        // Distance progress (0-1)
        let progress = min(max(session.distance / totalDistance, 0.0), 1.0)
        let totalDurationSeconds = Double(max(shadowData.prModel.durationSeconds, 1))
        let expectedTime = totalDurationSeconds * progress
        shadowData.timeDifference = elapsedSeconds - expectedTime
        
        // Pace difference using current km interval when available
        let distanceKm = session.distance / 1000.0
        let currentKmIndex = max(0, Int(distanceKm.rounded(.down)))
        shadowData.currentKm = currentKmIndex
        
        let shadowPace = shadowData.intervals.first(where: { $0.kilometer == currentKmIndex })?.pacePerKm
            ?? shadowData.prModel.averagePaceMinPerKm
        let activePace = currentPace > 0 ? currentPace : averagePace
        if activePace.isFinite && shadowPace.isFinite {
            shadowData.paceDifference = activePace - shadowPace
        }
        
        session.shadowRunData = shadowData
    }
    
    private func startStatsUpdateTimer() {
        updateTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.updateStats()
            // Continuously save/update run to Supabase every 2s
            if let session = self.currentSession, let sb = self.supabaseManager, sb.isInitialized {
                let userId = self.getUserId()
                Task {
                    _ = await sb.updateRunActivity(session, userId: userId, healthManager: self.healthManager)
                }
            }
        }
    }
    
    private func getUserId() -> String {
        if let data = UserDefaults.standard.data(forKey: "currentUser"),
           let user = try? JSONDecoder().decode(User.self, from: data) {
            return user.id
        }
        return "watch_user"
    }
    
    // MARK: - Public Access
    
    func getCurrentStats() -> RunningStatsUpdate? {
        return statsUpdate
    }
    
    func resetSession() {
        currentSession = nil
        isRunning = false
        totalDistance = 0.0
        caloriesEstimate = 0.0
        totalElevation = 0.0
        maxSpeed = 0.0
        minSpeed = Double.infinity
        previousLocations = []
        statsUpdate = nil
    }
}

// MARK: - Helpers
extension RunTracker {
    private func haversineDistance(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double {
        let R = 6371000.0 // meters
        let lat1 = from.latitude * .pi / 180
        let lat2 = to.latitude * .pi / 180
        let dLat = (to.latitude - from.latitude) * .pi / 180
        let dLon = (to.longitude - from.longitude) * .pi / 180
        let a = sin(dLat/2) * sin(dLat/2) + cos(lat1) * cos(lat2) * sin(dLon/2) * sin(dLon/2)
        let c = 2 * atan2(sqrt(a), sqrt(1-a))
        return R * c
    }

    private func computeBufferedDistance() -> Double {
        guard intervalBuffer.count >= 2 else { return 0 }
        var d: Double = 0
        for i in 1..<intervalBuffer.count {
            d += haversineDistance(from: intervalBuffer[i-1].coordinate, to: intervalBuffer[i].coordinate)
        }
        return d
    }

    private func trimIntervalBufferIfNeeded() {
        guard intervalBuffer.count > 2 else { return }
        // keep last ~30 seconds worth of points (safety)
        let cutoff = Date().addingTimeInterval(-30)
        intervalBuffer = intervalBuffer.filter { $0.timestamp >= cutoff }
    }

    private func createIntervalIfPossible(in session: inout RunSession) {
        guard intervalBuffer.count >= 2 else { return }
        let start = intervalBuffer.first!
        let end = intervalBuffer.last!
        let d = computeBufferedDistance()
        let dt = max(end.timestamp.timeIntervalSince(start.timestamp), 0.001)
        let paceMinPerKm: Double = {
            let mps = d / dt
            let kmPerMin = (mps * 3.6) / 60.0
            return kmPerMin > 0 ? 1.0 / kmPerMin : 0.0
        }()
        var intervals = session.intervals
        let idx = intervals.count
        let interval = RunInterval(
            id: UUID().uuidString,
            runId: session.id,
            index: idx,
            startTime: start.timestamp,
            endTime: end.timestamp,
            distanceMeters: d,
            durationSeconds: dt,
            paceMinPerKm: paceMinPerKm
        )
        intervals.append(interval)
        session.intervals = intervals
        // fire-and-forget save
        if let sb = supabaseManager, sb.isInitialized {
            let userId = getUserId()
            Task {
                _ = await sb.saveRunIntervals([interval], userId: userId)
            }
        }
    }
}
