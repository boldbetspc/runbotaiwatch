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
    private let intervalDistanceMeters: Double = 1000.0 // create interval every 1km
    private var lastIntervalEndDistance: Double = 0.0 // Track cumulative distance for 1km intervals
    var supabaseManager: SupabaseManager?
    var healthManager: HealthManager?
    
    // Pace history for energy signature graph (stores last 60 data points, ~1 per second)
    @Published var paceHistory: [Double] = []
    private let maxPaceHistorySize = 60 // Store last 60 seconds of pace data
    
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
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation // Most accurate for running
        // Distance filter: only update when moved at least 3 meters (reduces noise while maintaining accuracy)
        locationManager.distanceFilter = 3 // 3 meters for precise tracking
        locationManager.activityType = .fitness
        locationManager.allowsBackgroundLocationUpdates = false // Not needed for watchOS
        // Note: pausesLocationUpdatesAutomatically is not available on watchOS
        
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
        print("🏃 [RunTracker] ========== STARTING RUN ==========")
        print("🏃 [RunTracker] Thread: \(Thread.isMainThread ? "Main" : "Background")")
        print("🏃 [RunTracker] Mode: \(mode)")
        print("🏃 [RunTracker] Already running: \(isRunning)")
        
        guard !isRunning else {
            print("⚠️ [RunTracker] Already running - ignoring start request")
            return
        }
        
        var newSession = RunSession(
            id: UUID().uuidString,
            userId: "",
            startTime: Date()
        )
        newSession.mode = mode
        newSession.shadowRunData = shadowData
        newSession.shadowReferenceRunId = shadowData?.prModel.runId
        
        print("🏃 [RunTracker] Created new session:")
        print("   - ID: \(newSession.id)")
        print("   - Start time: \(newSession.startTime)")
        print("   - Mode: \(mode)")
        
        currentSession = newSession
        isRunning = true
        totalDistance = 0.0
        caloriesEstimate = 0.0
        totalElevation = 0.0
        maxSpeed = 0.0
        minSpeed = Double.infinity
        previousLocations = []
        intervalBuffer = []
        lastIntervalEndDistance = 0.0 // Reset interval tracking
        paceHistory = [] // Reset pace history for new run
        
        print("🏃 [RunTracker] Starting location manager...")
        locationManager.startUpdatingLocation()
        print("✅ [RunTracker] Location manager started")
        
        // CRITICAL: Start HealthManager for real-time HR via HKWorkoutSession
        // Pass run ID and SupabaseManager for periodic HR saves
        print("🏃 [RunTracker] Starting HealthManager HR monitoring...")
        print("   - HealthManager: \(healthManager != nil ? "available" : "nil")")
        print("   - SupabaseManager: \(supabaseManager != nil ? "available" : "nil")")
        
        healthManager?.startHeartRateMonitoring(
            runId: newSession.id,
            supabaseManager: supabaseManager
        )
        print("✅ [RunTracker] HealthManager startHeartRateMonitoring called")
        
        // Notify iOS that workout started
        if let sessionId = currentSession?.id {
            print("🏃 [RunTracker] Notifying iOS of workout start...")
            WatchConnectivityManager.shared.sendWorkoutStarted(runId: sessionId)
        }
        
        // Log run start for debugging
        print("🏃 [RunTracker] Run cache refresh will happen in AICoachManager")
        
        print("✅ [RunTracker] Run started with ID: \(newSession.id)")
        print("🏃 [RunTracker] Starting stats update timer...")
        startStatsUpdateTimer()
        print("🏃 [RunTracker] Performing initial stats update...")
        updateStats()
        print("✅ [RunTracker] ========== RUN START COMPLETE ==========")
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
        
        // Use HealthKit workout distance if available (most accurate)
        let finalDistanceMeters: Double
        if let workoutDistance = healthManager?.workoutDistance, workoutDistance > 0 {
            finalDistanceMeters = workoutDistance
            totalDistance = workoutDistance
        } else {
            finalDistanceMeters = totalDistance
        }
        
        let distanceKm = finalDistanceMeters / 1000.0
        let elapsedSeconds = Date().timeIntervalSince(session.startTime)
        let elapsedHours = elapsedSeconds / 3600.0
        let avgSpeed = elapsedHours > 0 ? distanceKm / elapsedHours : 0.0
        
        // Average pace: total time (minutes) / total distance (km) = min/km
        let averagePace = distanceKm > 0 ? elapsedSeconds / 60.0 / distanceKm : 0.0
        let caloriesEstimate = distanceKm * caloriesBurnedPerKm
        
        // Calculate final current pace from last 30 seconds (same improved logic as updateStats)
        let currentPace: Double = {
            guard previousLocations.count >= 2 else { return averagePace }
            
            let cutoffTime = Date().addingTimeInterval(-30)
            let recentLocations = previousLocations.filter { 
                $0.timestamp >= cutoffTime && 
                $0.horizontalAccuracy > 0 && 
                $0.horizontalAccuracy < 15 &&
                abs($0.timestamp.timeIntervalSinceNow) < 3.0
            }
            
            guard recentLocations.count >= 3 else { return averagePace }
            
            var segmentPaces: [Double] = []
            var totalDistance30s: Double = 0.0
            
            for i in 1..<recentLocations.count {
                let prev = recentLocations[i-1]
                let curr = recentLocations[i]
                
                let segmentDistance = haversineDistance(from: prev.coordinate, to: curr.coordinate)
                let segmentTime = abs(curr.timestamp.timeIntervalSince(prev.timestamp))
                
                if segmentDistance > 2.0 && segmentTime > 0 && segmentTime < 5.0 {
                    totalDistance30s += segmentDistance
                    let segmentDistanceKm = segmentDistance / 1000.0
                    if segmentDistanceKm > 0 && segmentTime > 0 {
                        let segmentPace = segmentTime / 60.0 / segmentDistanceKm
                        if segmentPace >= 2.0 && segmentPace <= 20.0 {
                            segmentPaces.append(segmentPace)
                        }
                    }
                }
            }
            
            guard totalDistance30s >= 15.0 && segmentPaces.count >= 2 else { return averagePace }
            
            // Use weighted average for smoother pace
            if segmentPaces.count >= 3 {
                var weightedSum: Double = 0.0
                var totalWeight: Double = 0.0
                for (index, pace) in segmentPaces.enumerated() {
                    let weight = pow(1.2, Double(segmentPaces.count - index))
                    weightedSum += pace * weight
                    totalWeight += weight
                }
                return weightedSum / totalWeight
            } else {
                return segmentPaces.reduce(0.0, +) / Double(segmentPaces.count)
            }
        }()
        
        // Update session with final values
        session.distance = finalDistanceMeters
        session.pace = averagePace // Average pace: total time / total distance
        session.avgSpeed = avgSpeed
        session.calories = caloriesEstimate
        session.elevation = totalElevation
        session.maxSpeed = maxSpeed > 0 ? maxSpeed * 3.6 : 0.0
        session.minSpeed = minSpeed != Double.infinity ? minSpeed * 3.6 : 0.0
        session.duration = elapsedSeconds
        session.endTime = Date()
        session.isCompleted = true
        
        // Shadow comparison removed (train mode removed)
        // Keeping this check for backward compatibility with existing data
        if session.shadowRunData != nil {
            updateShadowComparison(
                for: &session,
                currentPace: currentPace > 0 ? currentPace : averagePace,
                averagePace: averagePace,
                elapsedSeconds: elapsedSeconds
            )
        }
        
        currentSession = session
        
        // Update pace history for energy signature graph
        let finalPace = currentPace > 0 ? currentPace : averagePace
        if finalPace > 0 {
            paceHistory.append(finalPace)
            if paceHistory.count > maxPaceHistorySize {
                paceHistory.removeFirst()
            }
        }
        
        // Create final stats update
        statsUpdate = RunningStatsUpdate(
            distance: finalDistanceMeters,
            pace: currentPace > 0 ? currentPace : averagePace,
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
        print("   Average Pace: \(String(format: "%.2f", averagePace)) min/km")
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
        guard isRunning, var session = currentSession else {
            return
        }
        
        for newLocation in locations {
            // CRITICAL: Strict GPS filtering for maximum accuracy
            // 1. Accuracy check: GPS should be < 15m (excellent GPS is 3-8m)
            guard newLocation.horizontalAccuracy > 0 && newLocation.horizontalAccuracy < 15 else {
                continue
            }
            
            // 2. Age check: Ignore stale locations (> 3 seconds old)
            let locationAge = abs(newLocation.timestamp.timeIntervalSinceNow)
            guard locationAge < 3.0 else {
                continue
            }
            
            // 3. Vertical accuracy check: Ignore if vertical accuracy is too poor (> 20m)
            // This helps filter out bad GPS readings
            guard newLocation.verticalAccuracy <= 0 || newLocation.verticalAccuracy < 20 else {
                continue
            }
            
            // 4. Speed validation: Use GPS speed if available and reasonable
            let gpsSpeed = max(newLocation.speed, 0)
            let isMoving = gpsSpeed > 0.3 // 0.3 m/s = 1.08 km/h (very slow movement threshold)
            
            // Add location to workout route (HealthKit uses its own filtering)
            healthManager?.addLocationToWorkout(newLocation)
            
            // Store location for pace calculation
            let locationPoint = LocationPoint(location: newLocation)
            session.locations.append(locationPoint)
            
            // Only calculate distance if we have a previous location
            if let lastLocation = previousLocations.last {
                // Calculate distance using Haversine (most accurate for short distances)
                let distance = haversineDistance(from: lastLocation.coordinate, to: newLocation.coordinate)
                
                // Calculate time difference
                let timeDiff = abs(newLocation.timestamp.timeIntervalSince(lastLocation.timestamp))
                
                // CRITICAL: Only add distance if movement is validated
                // 1. Must be moving (GPS speed > 0.3 m/s), OR
                // 2. Distance is significant (> 5m) AND time difference is reasonable
                let isValidMovement = isMoving || (distance > 5.0 && timeDiff > 0 && timeDiff < 10.0)
                
                if isValidMovement && distance > 0 {
                    // Additional validation: Check if calculated speed matches GPS speed
                    let calculatedSpeed = timeDiff > 0 ? distance / timeDiff : 0
                    let speedDifference = abs(calculatedSpeed - gpsSpeed)
                    
                    // If GPS speed is available and calculated speed differs significantly, be cautious
                    // Allow up to 2 m/s difference (accounts for GPS inaccuracy)
                    if gpsSpeed > 0 && speedDifference > 2.0 && distance < 10.0 {
                        // Skip this segment if speeds don't match and distance is small (likely GPS noise)
                        print("⚠️ [RunTracker] Speed mismatch - skipping: GPS=\(gpsSpeed)m/s, Calc=\(calculatedSpeed)m/s, Dist=\(distance)m")
                    } else {
                        totalDistance += distance
                        
                        // Update speed tracking (use GPS speed when available, otherwise calculated)
                        let effectiveSpeed = gpsSpeed > 0 ? gpsSpeed : calculatedSpeed
                        if effectiveSpeed > 0 {
                            maxSpeed = max(maxSpeed, effectiveSpeed)
                            minSpeed = min(minSpeed, effectiveSpeed)
                        }
                        
                        // Track elevation change (only when moving)
                        if isMoving {
                            let elevationChange = newLocation.altitude - lastLocation.altitude
                            if elevationChange > 0 && newLocation.verticalAccuracy > 0 && newLocation.verticalAccuracy < 15 {
                                totalElevation += elevationChange
                            }
                        }
                        
                        // Build 1km interval buffer
                        intervalBuffer.append(newLocation)
                        trimIntervalBufferIfNeeded()
                        
                        // Create interval when 1km is complete
                        let distanceSinceLastInterval = totalDistance - lastIntervalEndDistance
                        if distanceSinceLastInterval >= intervalDistanceMeters {
                            createIntervalIfPossible(in: &session)
                            lastIntervalEndDistance = totalDistance
                            intervalBuffer.removeAll(keepingCapacity: true)
                        }
                    }
                }
            }
            
            // Always add to previousLocations for pace calculation (even if not moving)
            previousLocations.append(newLocation)
            
            // Keep only last 5 minutes of locations for pace calculation
            let fiveMinutesAgo = Date().addingTimeInterval(-300)
            previousLocations = previousLocations.filter { $0.timestamp >= fiveMinutesAgo }
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
        // HealthKit workout distance is filtered and smoothed by Apple
        let distanceMeters: Double
        if let workoutDistance = healthManager?.workoutDistance, workoutDistance > 0 {
            distanceMeters = workoutDistance
            // Sync our calculated distance to HealthKit (for consistency)
            totalDistance = workoutDistance
        } else {
            // Fallback: Use our filtered CoreLocation distance
            distanceMeters = totalDistance
        }
        
        // Calculate distance in km
        let distanceKm = distanceMeters / 1000.0
        
        // Calculate elapsed time
        let elapsedSeconds = Date().timeIntervalSince(session.startTime)
        
        // Calculate average pace: total time (minutes) / total distance (km) = min/km
        let averagePace = distanceKm > 0 ? elapsedSeconds / 60.0 / distanceKm : 0.0
        
        // Calculate average speed (km/h) - for reference
        let elapsedHours = elapsedSeconds / 3600.0
        let avgSpeed = elapsedHours > 0 ? distanceKm / elapsedHours : 0.0

        // Calculate current pace from last 30 seconds of location data
        // Uses weighted average of recent segments for smoother, more accurate pace
        let currentPace: Double = {
            guard previousLocations.count >= 2 else { return 0.0 }
            
            // Get locations from last 30 seconds with strict filtering
            let cutoffTime = Date().addingTimeInterval(-30)
            let recentLocations = previousLocations.filter { 
                $0.timestamp >= cutoffTime && 
                $0.horizontalAccuracy > 0 && 
                $0.horizontalAccuracy < 15 && // Only excellent GPS readings
                abs($0.timestamp.timeIntervalSinceNow) < 3.0 // Not stale
            }
            
            guard recentLocations.count >= 3 else { return 0.0 } // Need at least 3 points
            
            // Calculate distance and time for each segment
            var segmentPaces: [Double] = []
            var totalDistance30s: Double = 0.0
            var totalTime30s: Double = 0.0
            
            for i in 1..<recentLocations.count {
                let prev = recentLocations[i-1]
                let curr = recentLocations[i]
                
                let segmentDistance = haversineDistance(
                    from: prev.coordinate,
                    to: curr.coordinate
                )
                
                let segmentTime = abs(curr.timestamp.timeIntervalSince(prev.timestamp))
                
                // Only count valid segments: > 2m distance, reasonable time
                if segmentDistance > 2.0 && segmentTime > 0 && segmentTime < 5.0 {
                    totalDistance30s += segmentDistance
                    totalTime30s += segmentTime
                    
                    // Calculate pace for this segment
                    let segmentDistanceKm = segmentDistance / 1000.0
                    if segmentDistanceKm > 0 && segmentTime > 0 {
                        let segmentPace = segmentTime / 60.0 / segmentDistanceKm
                        // Only include reasonable paces (2-20 min/km)
                        if segmentPace >= 2.0 && segmentPace <= 20.0 {
                            segmentPaces.append(segmentPace)
                        }
                    }
                }
            }
            
            // Need at least 15m of movement in 30s to calculate pace
            guard totalDistance30s >= 15.0 && segmentPaces.count >= 2 else { return 0.0 }
            
            // Use weighted average: give more weight to recent segments
            // This provides smoother, more responsive pace
            if segmentPaces.count >= 3 {
                // Weighted average: recent segments have more weight
                var weightedSum: Double = 0.0
                var totalWeight: Double = 0.0
                
                for (index, pace) in segmentPaces.enumerated() {
                    // More recent segments get higher weight (exponential decay)
                    let weight = pow(1.2, Double(segmentPaces.count - index))
                    weightedSum += pace * weight
                    totalWeight += weight
                }
                
                let weightedPace = weightedSum / totalWeight
                return weightedPace
            } else {
                // Simple average if not enough segments
                let avgPace = segmentPaces.reduce(0.0, +) / Double(segmentPaces.count)
                return avgPace
            }
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
        session.pace = averagePace // Average pace: total time / total distance
        session.avgSpeed = avgSpeed
        session.calories = caloriesEstimate
        session.elevation = totalElevation
        session.maxSpeed = maxSpeed > 0 ? maxSpeed * 3.6 : 0.0 // Convert m/s to km/h
        session.minSpeed = minSpeed != Double.infinity ? minSpeed * 3.6 : 0.0
        session.duration = elapsedSeconds
        updateShadowComparison(
            for: &session,
            currentPace: currentPace > 0 ? currentPace : averagePace,
            averagePace: averagePace,
            elapsedSeconds: elapsedSeconds
        )
        
        currentSession = session
        
        // Update pace history for energy signature graph
        let displayPace = currentPace > 0 ? currentPace : averagePace
        if displayPace > 0 {
            paceHistory.append(displayPace)
            // Keep only last maxPaceHistorySize entries
            if paceHistory.count > maxPaceHistorySize {
                paceHistory.removeFirst()
            }
        }
        
        // Create stats update for UI
        // Note: pace field shows current pace, average pace is in session.pace
        statsUpdate = RunningStatsUpdate(
            distance: distanceMeters,
            pace: currentPace > 0 ? currentPace : averagePace, // Show current pace if available, else average
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
    /// Calculate distance using Haversine formula (most accurate for short distances)
    /// Uses Earth's radius at current latitude for better accuracy
    private func haversineDistance(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double {
        // Earth's radius varies by latitude - use average radius for running distances
        let R = 6371000.0 // meters (mean Earth radius)
        
        // Convert to radians
        let lat1 = from.latitude * .pi / 180.0
        let lat2 = to.latitude * .pi / 180.0
        let dLat = (to.latitude - from.latitude) * .pi / 180.0
        let dLon = (to.longitude - from.longitude) * .pi / 180.0
        
        // Haversine formula
        let a = sin(dLat/2.0) * sin(dLat/2.0) +
                cos(lat1) * cos(lat2) *
                sin(dLon/2.0) * sin(dLon/2.0)
        let c = 2.0 * atan2(sqrt(a), sqrt(1.0 - a))
        
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
        
        // Calculate ACTUAL distance traveled in this interval buffer (not fixed 1000m)
        // This is the real distance the runner covered, which may be slightly more or less than 1km
        let actualDistanceMeters = computeBufferedDistance()
        guard actualDistanceMeters > 50.0 else {
            print("⚠️ [RunTracker] Interval buffer distance too small: \(String(format: "%.1f", actualDistanceMeters))m - skipping")
            return
        }
        
        // Calculate actual time taken to cover this distance
        let dt = max(end.timestamp.timeIntervalSince(start.timestamp), 0.001)
        
        // Calculate pace in min/km: (duration in seconds / 60) / (distance in km)
        // Formula: pace (min/km) = (time in seconds) / 60 / (distance in km)
        // Example: 278 seconds for 1.0km = (278 / 60) / 1.0 = 4.633 min/km = 4:38 min/km
        let paceMinPerKm: Double = {
            guard actualDistanceMeters > 0 && dt > 0 else { 
                print("⚠️ [RunTracker] Invalid interval data: distance=\(actualDistanceMeters)m, dt=\(dt)s")
                return 0.0 
            }
            let distanceKm = actualDistanceMeters / 1000.0
            let timeMinutes = dt / 60.0
            let pace = timeMinutes / distanceKm
            
            // CRITICAL VALIDATION: Reject unrealistic paces (likely GPS errors or incomplete intervals)
            // Normal running pace is 3-20 min/km (3:00 to 20:00 per km)
            // If pace is outside this range, it's almost certainly wrong data
            guard pace >= 2.0 && pace <= 25.0 else {
                print("❌ [RunTracker] REJECTING unrealistic pace: \(String(format: "%.2f", pace)) min/km")
                print("   ❌ Duration: \(String(format: "%.1f", dt))s, Distance: \(String(format: "%.1f", actualDistanceMeters))m")
                print("   ❌ This interval will be skipped - GPS error or incomplete data")
                return 0.0 // Return 0 to skip this interval
            }
            
            // Additional validation: Check if duration is realistic for 1km
            // A 1km interval should take at least 2 minutes (120 seconds) for most runners
            // If it's less than 60 seconds, it's definitely wrong
            if dt < 60.0 && actualDistanceMeters >= 900.0 {
                print("⚠️ [RunTracker] WARNING: Very short duration for 1km: \(String(format: "%.1f", dt))s")
                print("   ⚠️ Calculated pace: \(String(format: "%.2f", pace)) min/km - may be GPS error")
                print("   ⚠️ Using calculated value but verify GPS accuracy")
            }
            
            print("✅ [RunTracker] Valid pace calculated: \(String(format: "%.2f", pace)) min/km (\(String(format: "%d:%02d", Int(pace), Int((pace - Double(Int(pace))) * 60))) min/km)")
            
            return pace
        }()
        
        // Skip interval if pace is invalid (0.0)
        guard paceMinPerKm > 0 else {
            print("⚠️ [RunTracker] Skipping interval creation due to invalid pace")
            return
        }
        
        // Format pace for logging: convert to MM:SS format
        let paceMins = Int(paceMinPerKm)
        let paceSecs = Int((paceMinPerKm - Double(paceMins)) * 60)
        let paceFormatted = String(format: "%d:%02d", paceMins, paceSecs)
        
        print("📊 [RunTracker] Creating interval #\(session.intervals.count + 1):")
        print("   - Actual distance: \(String(format: "%.1f", actualDistanceMeters))m")
        print("   - Duration: \(String(format: "%.1f", dt))s (\(String(format: "%d:%02d", Int(dt)/60, Int(dt)%60)))")
        print("   - Calculated pace: \(String(format: "%.3f", paceMinPerKm)) min/km = \(paceFormatted) min/km")
        
        var intervals = session.intervals
        let idx = intervals.count
        let interval = RunInterval(
            id: UUID().uuidString,
            runId: session.id,
            index: idx,
            startTime: start.timestamp,
            endTime: end.timestamp,
            distanceMeters: actualDistanceMeters, // Use actual distance, not fixed 1000m
            durationSeconds: dt,
            paceMinPerKm: paceMinPerKm
        )
        intervals.append(interval)
        session.intervals = intervals
        // fire-and-forget save
        if let sb = supabaseManager, sb.isInitialized {
            let userId = getUserId()
            Task {
                _ = await sb.saveRunIntervals([interval], userId: userId, healthManager: healthManager)
            }
        }
    }
}
