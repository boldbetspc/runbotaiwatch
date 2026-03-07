import Foundation
import Combine

// MARK: - Config Loader
struct ConfigLoader {
    static func loadConfig() -> [String: Any]? {
        print("⚙️ [Config] Loading Config.plist...")
        
        // Try Bundle.main first
        if let configPath = Bundle.main.path(forResource: "Config", ofType: "plist") {
            print("⚙️ [Config] Found at: \(configPath)")
            if let config = NSDictionary(contentsOfFile: configPath) as? [String: Any] {
                print("⚙️ [Config] ✅ Loaded successfully")
                return config
            }
        }
        
        print("⚙️ [Config] ❌ Config.plist not found in bundle!")
        
        // List bundle contents for debugging
        if let resourcePath = Bundle.main.resourcePath {
            print("⚙️ [Config] Bundle resources:")
            if let contents = try? FileManager.default.contentsOfDirectory(atPath: resourcePath) {
                for item in contents.prefix(10) {
                    print("  - \(item)")
                }
            }
        }
        
        return nil
    }
}

// MARK: - Supabase Manager
// 
// IMPORTANT: This watchOS app uses ONLY existing Supabase tables from the iOS app.
// NO new tables, NO edge functions, NO schema changes.
// 
// Tables used (all existing):
// - run_activities: Read/write (same schema as iOS)
// - run_intervals: Write (same schema as iOS)
// - user_preferences: Read/write (same schema as iOS)
// - pr_models: Read (same schema as iOS)
// - user_health_config: Read-only (optional, gracefully handles if missing)
// - coaching_sessions: Write (same schema as iOS)
//
// All operations are safe and won't interfere with iOS app data.
class SupabaseManager: ObservableObject {
    @Published var isInitialized = false
    @Published var currentUserId: String?
    @Published var tokenExpired = false // Flag to trigger re-authentication
    
    private let session = URLSession.shared
    private let baseURL: String
    private let anonKey: String
    private var sessionToken: String?
    
    init() {
        if let config = ConfigLoader.loadConfig(),
           let url = config["SUPABASE_URL"] as? String,
           let key = config["SUPABASE_ANON_KEY"] as? String {
            self.baseURL = url
            self.anonKey = key
            self.isInitialized = true
        } else {
            self.baseURL = ""
            self.anonKey = ""
            self.isInitialized = false
        }
    }
    
    private func handleTokenExpiration() {
        print("🔐 [SupabaseManager] Token expired - clearing session")
        self.sessionToken = nil
        self.currentUserId = nil
        self.tokenExpired = true
        
        // Clear stored credentials
        UserDefaults.standard.removeObject(forKey: "currentUser")
        UserDefaults.standard.removeObject(forKey: "sessionToken")
    }
    
    func initializeSession(for userId: String) {
        self.currentUserId = userId
        self.sessionToken = UserDefaults.standard.string(forKey: "sessionToken")
        print("🔐 [SupabaseManager] Session initialized")
        print("🔐 User ID: \(userId)")
        print("🔐 Token present: \(sessionToken != nil)")
        if let token = sessionToken {
            print("🔐 Token (first 20 chars): \(String(token.prefix(20)))...")
        }
    }
    
    private func getAuthHeader() -> String {
        if let token = sessionToken {
            return "Bearer \(token)"
        }
        print("⚠️ [Supabase] WARNING: Using anonymous key (not authenticated!)")
        return "Bearer \(anonKey)"
    }
    
    private func handleAPIResponse(_ response: HTTPURLResponse, data: Data) -> Bool {
        // Check for token expiration (401 Unauthorized)
        if response.statusCode == 401 {
            print("🔐 [Supabase] Token expired (401) - marking for re-authentication")
            handleTokenExpiration()
            return false
        }
        
        // Check for other errors
        if response.statusCode >= 400 {
            let errorString = String(data: data, encoding: .utf8) ?? "Unknown error"
            print("❌ [Supabase] API error \(response.statusCode): \(errorString.prefix(200))")
            return false
        }
        
        return true
    }
    
    // MARK: - Run Activities (Saves to run_activities table)
    
    func saveRunActivity(_ runData: RunSession, userId: String, healthManager: HealthManager? = nil) async -> Bool {
        guard isInitialized else {
            print("❌ Supabase not initialized")
            return false
        }
        
        // Skip save if duration is 0 or negative (violates database constraint)
        if runData.duration <= 0 {
            print("⚠️ [Supabase] Skipping save - duration is 0 or negative (violates constraint)")
            return false
        }
        
        do {
            let formatter = ISO8601DateFormatter()
            let _: Any = runData.endTime.map { formatter.string(from: $0) } ?? NSNull()
            
            // Get start/end coordinates from locations
            let startLat = runData.locations.first?.latitude
            let startLng = runData.locations.first?.longitude
            let endLat = runData.locations.last?.latitude
            let endLng = runData.locations.last?.longitude
            
            // Get heart rate data from HealthManager if available
            let avgHR = healthManager?.averageHeartRate.map { Int($0) }
            let maxHR = healthManager?.maxHeartRate.map { Int($0) }
            
            // Generate run name (train mode removed - always "Run")
            let runName = "Run"
            
            // NOTE: average_pace_minutes_per_km is a GENERATED COLUMN - don't send it
            var runPayload: [String: Any] = [
                "id": runData.id,
                "user_id": userId,
                "name": runName,
                "duration_s": Int(runData.duration),
                "distance_meters": runData.distance,
                "calories": Int(runData.calories),
                "elevation_gain_meters": runData.elevation,
                "start_time": formatter.string(from: runData.startTime),
                "mode": runData.mode.rawValue,
                "activity_date": formatter.string(from: runData.startTime),
                "device_connected": "Apple Watch",
                "is_pr_shadow": false, // Train mode removed
                "created_at": formatter.string(from: runData.startTime),
                "updated_at": formatter.string(from: Date())
            ]
            
            // Add optional fields
            if let endTime = runData.endTime {
                runPayload["end_time"] = formatter.string(from: endTime)
            }
            if let startLat = startLat, let startLng = startLng {
                runPayload["start_lat"] = startLat
                runPayload["start_lng"] = startLng
            }
            if let endLat = endLat, let endLng = endLng {
                runPayload["end_lat"] = endLat
                runPayload["end_lng"] = endLng
            }
            if let avgHR = avgHR {
                runPayload["average_heart_rate"] = avgHR
            }
            if let maxHR = maxHR {
                runPayload["max_heart_rate"] = maxHR
            }
            if let referenceId = runData.shadowReferenceRunId {
                runPayload["shadow_reference_run_id"] = referenceId
            }
            
            print("💾 [Supabase] Saving run activity: \(runData.id), mode: \(runData.mode.rawValue), distance: \(runData.distance)m")
            
            // Use UPSERT: POST with resolution=merge-duplicates (updates if exists, inserts if not)
            let url = URL(string: "\(baseURL)/rest/v1/run_activities")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue(anonKey, forHTTPHeaderField: "apikey")
            request.setValue(getAuthHeader(), forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
            // UPSERT: if run with same ID exists, update it; otherwise insert
            request.setValue("resolution=merge-duplicates", forHTTPHeaderField: "Prefer")
            request.httpBody = try JSONSerialization.data(withJSONObject: runPayload)
            
            let (data, response) = try await session.data(for: request)
            
            if let httpResponse = response as? HTTPURLResponse {
                print("📤 [Supabase] Save response status: \(httpResponse.statusCode)")
                
                if httpResponse.statusCode == 200 || httpResponse.statusCode == 201 {
                    print("✅ [Supabase] Run activity saved/updated in Supabase")
                    return true
                } else if handleAPIResponse(httpResponse, data: data) {
                    // Handled by helper (token expiration, etc.)
                    return false
                } else {
                    let errorString = String(data: data, encoding: .utf8) ?? "Unknown error"
                    print("❌ [Supabase] Save failed with status \(httpResponse.statusCode): \(errorString)")
                }
            }
        } catch {
            print("❌ [Supabase] Error saving run activity: \(error.localizedDescription)")
        }
        return false
    }
    
    // MARK: - Update Run Activity (continuous updates during run)
    func updateRunActivity(_ runData: RunSession, userId: String, healthManager: HealthManager? = nil) async -> Bool {
        guard isInitialized else { return false }
        
        do {
            let formatter = ISO8601DateFormatter()
            let endTimeString: Any = runData.endTime.map { formatter.string(from: $0) } ?? NSNull()
            
            // Get end coordinates
            let endLat = runData.locations.last?.latitude
            let endLng = runData.locations.last?.longitude
            
            // Get heart rate data
            let avgHR = healthManager?.averageHeartRate.map { Int($0) }
            let maxHR = healthManager?.maxHeartRate.map { Int($0) }
            
            // NOTE: average_pace_minutes_per_km is a GENERATED COLUMN - don't send it
            var runPayload: [String: Any] = [
                "user_id": userId,
                "duration_s": Int(runData.duration),
                "distance_meters": runData.distance,
                "calories": Int(runData.calories),
                "elevation_gain_meters": runData.elevation,
                "end_time": endTimeString,
                "mode": runData.mode.rawValue,
                "updated_at": formatter.string(from: Date())
            ]
            
            if let endLat = endLat, let endLng = endLng {
                runPayload["end_lat"] = endLat
                runPayload["end_lng"] = endLng
            }
            if let avgHR = avgHR {
                runPayload["average_heart_rate"] = avgHR
            }
            if let maxHR = maxHR {
                runPayload["max_heart_rate"] = maxHR
            }
            if let referenceId = runData.shadowReferenceRunId {
                runPayload["shadow_reference_run_id"] = referenceId
            }
            
            // SAFE: Updates only the specific run by ID (UUID) - won't affect iOS app's runs
            // Each app generates unique UUIDs, so no conflicts possible
            let url = URL(string: "\(baseURL)/rest/v1/run_activities?id=eq.\(runData.id)")!
            var request = URLRequest(url: url)
            request.httpMethod = "PATCH"
            request.setValue(anonKey, forHTTPHeaderField: "apikey")
            request.setValue(getAuthHeader(), forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
            request.httpBody = try JSONSerialization.data(withJSONObject: runPayload)
            
            let (_, response) = try await session.data(for: request)
            
            if let httpResponse = response as? HTTPURLResponse,
               (httpResponse.statusCode == 200 || httpResponse.statusCode == 204) {
                print("✅ [Supabase] Run activity updated (id: \(runData.id))")
                return true
            } else {
                // If PATCH fails (row doesn't exist), fall back to INSERT
                // This is safe - UUID ensures no conflicts with iOS app
                return await saveRunActivity(runData, userId: userId, healthManager: healthManager)
            }
        } catch {
            print("❌ [Supabase] Error updating run activity: \(error.localizedDescription)")
        }
        return false
    }
    
    // MARK: - Run Intervals (batch save)
    func saveRunIntervals(_ intervals: [RunInterval], userId: String) async -> Bool {
        guard isInitialized, !intervals.isEmpty else { return false }
        
        do {
            var payloads: [[String: Any]] = []
            for interval in intervals {
                // NOTE: pace_per_km is a GENERATED COLUMN - don't send it
                let payload: [String: Any] = [
                    "id": interval.id,
                    "run_id": interval.runId,
                    "user_id": userId,
                    "kilometer": interval.index,
                    "duration_s": interval.durationSeconds,
                    "time_recorded": ISO8601DateFormatter().string(from: interval.endTime),
                    "created_at": ISO8601DateFormatter().string(from: Date())
                ]
                payloads.append(payload)
            }
            
            let url = URL(string: "\(baseURL)/rest/v1/run_intervals")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue(anonKey, forHTTPHeaderField: "apikey")
            request.setValue(getAuthHeader(), forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
            // Upsert: if row with same id exists, update it
            request.setValue("resolution=merge-duplicates", forHTTPHeaderField: "Prefer")
            request.httpBody = try JSONSerialization.data(withJSONObject: payloads)
            
            let (_, response) = try await session.data(for: request)
            
            if let httpResponse = response as? HTTPURLResponse,
               (httpResponse.statusCode == 200 || httpResponse.statusCode == 201) {
                print("✅ \(intervals.count) run interval(s) saved to Supabase")
                return true
            }
        } catch {
            print("❌ Error saving run intervals: \(error)")
        }
        return false
    }
    
    // MARK: - Run Heart Rate Data (Saves to run_hr table)
    func saveRunHR(_ runId: String, healthManager: HealthManager) async -> Bool {
        guard isInitialized else {
            print("❌ [Supabase] Not initialized for run_hr save")
            return false
        }
        
        // Only save if we have heart rate data
        guard let currentHR = healthManager.currentHeartRate.map({ Int($0) }),
              let avgHR = healthManager.averageHeartRate.map({ Int($0) }) else {
            print("⚠️ [Supabase] No heart rate data available - skipping run_hr save")
            return false
        }
        
        do {
            let formatter = ISO8601DateFormatter()
            let maxHR = healthManager.maxHeartRate.map { Int($0) }
            let currentZone = healthManager.currentZone.map { String($0) }
            let zonePercentages = healthManager.zonePercentages
            
            // First, try to get existing run_hr record for this run_id
            var hrPayload: [String: Any] = [
                "run_id": runId,
                "current_hr": currentHR,
                "average_hr": avgHR,
                "current_zone": currentZone ?? NSNull(),
                "updated_at": formatter.string(from: Date())
            ]
            
            // Only add created_at if this is a new record (will be set by DB if not provided)
            // For UPSERT, we don't send id - let DB handle it
            
            if let maxHR = maxHR {
                hrPayload["max_hr"] = maxHR
            }
            
            // Add zone percentages
            if let z1pct = zonePercentages[1] {
                hrPayload["z1pct"] = z1pct
                hrPayload["z1p"] = z1pct
            }
            if let z2pct = zonePercentages[2] {
                hrPayload["z2pct"] = z2pct
                hrPayload["z2p"] = z2pct
            }
            if let z3pct = zonePercentages[3] {
                hrPayload["z3pct"] = z3pct
                hrPayload["z3p"] = z3pct
            }
            if let z4pct = zonePercentages[4] {
                hrPayload["z4pct"] = z4pct
                hrPayload["z4p"] = z4pct
            }
            if let z5pct = zonePercentages[5] {
                hrPayload["z5pct"] = z5pct
                hrPayload["z5p"] = z5pct
            }
            
            // Add zone-wise average pace (if table supports these columns)
            // These will be silently ignored if columns don't exist
            let zoneAvgPace = healthManager.zoneAveragePace
            if let z1pace = zoneAvgPace[1], z1pace > 0 {
                hrPayload["z1_avg_pace"] = z1pace
            }
            if let z2pace = zoneAvgPace[2], z2pace > 0 {
                hrPayload["z2_avg_pace"] = z2pace
            }
            if let z3pace = zoneAvgPace[3], z3pace > 0 {
                hrPayload["z3_avg_pace"] = z3pace
            }
            if let z4pace = zoneAvgPace[4], z4pace > 0 {
                hrPayload["z4_avg_pace"] = z4pace
            }
            if let z5pace = zoneAvgPace[5], z5pace > 0 {
                hrPayload["z5_avg_pace"] = z5pace
            }
            
            print("💓 [Supabase] Saving run_hr data for run: \(runId)")
            print("💓 [Supabase] Zone %: Z1=\(String(format: "%.1f", zonePercentages[1] ?? 0))% Z2=\(String(format: "%.1f", zonePercentages[2] ?? 0))% Z3=\(String(format: "%.1f", zonePercentages[3] ?? 0))% Z4=\(String(format: "%.1f", zonePercentages[4] ?? 0))% Z5=\(String(format: "%.1f", zonePercentages[5] ?? 0))%")
            
            // Try PATCH first (update existing record for this run_id)
            let patchUrl = URL(string: "\(baseURL)/rest/v1/run_hr?run_id=eq.\(runId)")!
            var patchRequest = URLRequest(url: patchUrl)
            patchRequest.httpMethod = "PATCH"
            patchRequest.setValue(anonKey, forHTTPHeaderField: "apikey")
            patchRequest.setValue(getAuthHeader(), forHTTPHeaderField: "Authorization")
            patchRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            patchRequest.setValue("return=representation", forHTTPHeaderField: "Prefer") // Get updated rows to verify
            patchRequest.httpBody = try JSONSerialization.data(withJSONObject: hrPayload)
            
            let (patchData, patchResponse) = try await session.data(for: patchRequest)
            
            if let httpResponse = patchResponse as? HTTPURLResponse {
                print("💓 [Supabase] PATCH response status: \(httpResponse.statusCode)")
                if httpResponse.statusCode == 200 || httpResponse.statusCode == 204 {
                    // Verify rows were actually updated (not empty array)
                    if let responseStr = String(data: patchData, encoding: .utf8),
                       responseStr != "[]" && !responseStr.isEmpty {
                        print("✅ [Supabase] Run HR data updated successfully")
                        return true
                    } else {
                        print("⚠️ [Supabase] PATCH returned empty - no existing record, trying INSERT...")
                    }
                }
            }
            
            // PATCH didn't update anything (no existing record), so INSERT new one
            var insertPayload = hrPayload
            insertPayload["id"] = UUID().uuidString
            insertPayload["created_at"] = formatter.string(from: Date())
            
            let insertUrl = URL(string: "\(baseURL)/rest/v1/run_hr")!
            var insertRequest = URLRequest(url: insertUrl)
            insertRequest.httpMethod = "POST"
            insertRequest.setValue(anonKey, forHTTPHeaderField: "apikey")
            insertRequest.setValue(getAuthHeader(), forHTTPHeaderField: "Authorization")
            insertRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            insertRequest.setValue("return=minimal", forHTTPHeaderField: "Prefer")
            insertRequest.httpBody = try JSONSerialization.data(withJSONObject: insertPayload)
            
            let (insertData, insertResponse) = try await session.data(for: insertRequest)
            
            if let httpResponse = insertResponse as? HTTPURLResponse {
                print("💓 [Supabase] INSERT response status: \(httpResponse.statusCode)")
                if httpResponse.statusCode == 200 || httpResponse.statusCode == 201 {
                    print("✅ [Supabase] Run HR data inserted successfully")
                    return true
                } else {
                    if handleAPIResponse(httpResponse, data: insertData) {
                        return false
                    } else {
                        let errorString = String(data: insertData, encoding: .utf8) ?? "Unknown error"
                        print("❌ [Supabase] run_hr save failed: \(errorString)")
                    }
                }
            }
        } catch {
            print("❌ [Supabase] Error saving run_hr: \(error.localizedDescription)")
        }
        return false
    }
    
    // MARK: - User Preferences (Reads/writes to user_preferences table)
    
    func loadUserPreferences(userId: String) async -> UserPreferences.Settings? {
        guard isInitialized else { return nil }
        
        do {
            let url = URL(string: "\(baseURL)/rest/v1/user_preferences?user_id=eq.\(userId)")!
            var request = URLRequest(url: url)
            request.setValue(anonKey, forHTTPHeaderField: "apikey")
            request.setValue(getAuthHeader(), forHTTPHeaderField: "Authorization")
            
            let (data, response) = try await session.data(for: request)
            
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                if let jsonArray = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                   let first = jsonArray.first {
                    return parseUserPreferences(from: first)
                }
            }
        } catch {
            print("❌ Error loading user preferences: \(error)")
        }
        
        return nil
    }
    
    func saveUserPreferences(_ settings: UserPreferences.Settings, userId: String) async -> Bool {
        guard isInitialized else { return false }
        
        do {
            let prefsPayload: [String: Any] = [
                "user_id": userId,
                "voice_mode": settings.coachPersonality.rawValue,
                "voice_energy": settings.coachEnergy.rawValue,
                "voice_ai_model": settings.voiceAIModel.rawValue,
                "feedback_frequency": settings.feedbackFrequency,
                "target_pace": settings.targetPaceMinPerKm,
                "language": settings.language.rawValue,
                "updated_at": ISO8601DateFormatter().string(from: Date())
            ]
            
            // Try PATCH first (update existing)
            let patchUrl = URL(string: "\(baseURL)/rest/v1/user_preferences?user_id=eq.\(userId)")!
            var patchRequest = URLRequest(url: patchUrl)
            patchRequest.httpMethod = "PATCH"
            patchRequest.setValue(anonKey, forHTTPHeaderField: "apikey")
            patchRequest.setValue(getAuthHeader(), forHTTPHeaderField: "Authorization")
            patchRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            patchRequest.httpBody = try JSONSerialization.data(withJSONObject: prefsPayload)
            
            let (_, patchResponse) = try await session.data(for: patchRequest)
            
            if let httpResponse = patchResponse as? HTTPURLResponse,
               (httpResponse.statusCode == 200 || httpResponse.statusCode == 204) {
                print("✅ User preferences updated")
                return true
            }
            
            // If PATCH didn't work, try INSERT
            var postPayload = prefsPayload
            postPayload["id"] = UUID().uuidString
            postPayload["created_at"] = ISO8601DateFormatter().string(from: Date())
            
            let postUrl = URL(string: "\(baseURL)/rest/v1/user_preferences")!
            var postRequest = URLRequest(url: postUrl)
            postRequest.httpMethod = "POST"
            postRequest.setValue(anonKey, forHTTPHeaderField: "apikey")
            postRequest.setValue(getAuthHeader(), forHTTPHeaderField: "Authorization")
            postRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            postRequest.httpBody = try JSONSerialization.data(withJSONObject: postPayload)
            
            let (_, postResponse) = try await session.data(for: postRequest)
            
            if let httpResponse = postResponse as? HTTPURLResponse,
               (httpResponse.statusCode == 200 || httpResponse.statusCode == 201) {
                print("✅ User preferences saved")
                return true
            }
        } catch {
            print("❌ Error saving user preferences: \(error)")
        }
        
        return false
    }
    
    /// Save only watch-specific preferences (selective update)
    /// Only updates: voice_ai_model, language, feedback_frequency, target_pace, voice_energy, coach_personality, target_distance
    func saveWatchPreferences(_ settings: UserPreferences.Settings, userId: String) async -> Bool {
        guard isInitialized else { 
            print("❌ [Supabase] Not initialized for watch prefs save")
            return false 
        }
        
        do {
            // ONLY update watch-relevant fields that exist in the table
            // Table structure: id, user_id, voice_mode (required), race_type (required), 
            // voice_ai_model, language, feedback_frequency, target_pace, voice_energy, 
            // feedback_mode, user_name, heart_rate_source, milestone_alerts, feedback_frequency_custom
            // NOTE: target_distance and custom_distance_km do NOT exist in the table - removed
            var watchPrefsPayload: [String: Any] = [
                "user_id": userId,
                "voice_mode": settings.coachPersonality.rawValue, // Required field: voice_mode
                "voice_ai_model": settings.voiceAIModel.rawValue,
                "language": settings.language.rawValue,
                "feedback_frequency": settings.feedbackFrequency,
                "target_pace": settings.targetPaceMinPerKm,
                "voice_energy": settings.coachEnergy.rawValue,
                "updated_at": ISO8601DateFormatter().string(from: Date())
            ]
            
            print("⌚ [Supabase] Saving watch preferences for user: \(userId)")
            print("⌚ [Supabase] Payload: \(watchPrefsPayload)")
            
            // Try PATCH first (update existing record)
            let patchUrl = URL(string: "\(baseURL)/rest/v1/user_preferences?user_id=eq.\(userId)")!
            var patchRequest = URLRequest(url: patchUrl)
            patchRequest.httpMethod = "PATCH"
            patchRequest.setValue(anonKey, forHTTPHeaderField: "apikey")
            patchRequest.setValue(getAuthHeader(), forHTTPHeaderField: "Authorization")
            patchRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            patchRequest.setValue("return=representation", forHTTPHeaderField: "Prefer") // Get updated rows to verify
            patchRequest.httpBody = try JSONSerialization.data(withJSONObject: watchPrefsPayload)
            
            let (patchData, patchResponse) = try await session.data(for: patchRequest)
            
            if let httpResponse = patchResponse as? HTTPURLResponse {
                print("⌚ [Supabase] PATCH response status: \(httpResponse.statusCode)")
                if httpResponse.statusCode == 200 || httpResponse.statusCode == 204 {
                    // Verify rows were actually updated (not empty array)
                    if let responseStr = String(data: patchData, encoding: .utf8),
                       responseStr != "[]" && !responseStr.isEmpty {
                        print("✅ [Supabase] Watch preferences updated successfully")
                        return true
                    } else {
                        print("⚠️ [Supabase] PATCH returned empty - no existing record, trying INSERT...")
                    }
                }
            }
            
            // PATCH didn't update anything (no existing record), so INSERT new one
            // Map targetDistance to race_type for required field
            let raceType: String = {
                let distance = settings.targetDistance
                switch distance {
                case .casual: return "5K" // Default casual to 5K
                case .fiveK: return "5K"
                case .tenK: return "10K"
                case .halfMarathon: return "Half Marathon"
                case .marathon: return "Marathon"
                case .custom: return "5K" // Default for custom
                }
            }()
            
            var insertPayload = watchPrefsPayload
            insertPayload["id"] = UUID().uuidString
            insertPayload["race_type"] = raceType // Required field: race_type
            insertPayload["created_at"] = ISO8601DateFormatter().string(from: Date())
            
            let insertUrl = URL(string: "\(baseURL)/rest/v1/user_preferences")!
            var insertRequest = URLRequest(url: insertUrl)
            insertRequest.httpMethod = "POST"
            insertRequest.setValue(anonKey, forHTTPHeaderField: "apikey")
            insertRequest.setValue(getAuthHeader(), forHTTPHeaderField: "Authorization")
            insertRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            insertRequest.setValue("return=minimal", forHTTPHeaderField: "Prefer")
            insertRequest.httpBody = try JSONSerialization.data(withJSONObject: insertPayload)
            
            let (insertData, insertResponse) = try await session.data(for: insertRequest)
            
            if let httpResponse = insertResponse as? HTTPURLResponse {
                print("⌚ [Supabase] INSERT response status: \(httpResponse.statusCode)")
                if httpResponse.statusCode == 200 || httpResponse.statusCode == 201 {
                    print("✅ [Supabase] Watch preferences inserted successfully")
                    return true
                } else {
                    if handleAPIResponse(httpResponse, data: insertData) {
                        return false
                    } else {
                        let errorString = String(data: insertData, encoding: .utf8) ?? "Unknown error"
                        print("❌ [Supabase] Watch preferences save failed: \(errorString)")
                    }
                }
            }
        } catch {
            print("❌ [Supabase] Error saving watch preferences: \(error)")
        }
        
        return false
    }

    // MARK: - Run Aggregates (for coaching context)
    struct RunAggregates {
        let totalRuns: Int
        let avgDistanceKm: Double
        let avgPaceMinPerKm: Double
        let bestPaceMinPerKm: Double
    }
    
    struct LastRunStats {
        let distanceKm: Double
        let paceMinPerKm: Double
        let durationSeconds: Double
        let startTime: Date?
    }
    
    func fetchLastRun(userId: String) async -> LastRunStats? {
        guard isInitialized else { return nil }
        do {
            let url = URL(string: "\(baseURL)/rest/v1/run_activities?user_id=eq.\(userId)&select=distance_meters,average_pace_minutes_per_km,duration_s,start_time&order=start_time.desc&limit=1")!
            var request = URLRequest(url: url)
            request.setValue(anonKey, forHTTPHeaderField: "apikey")
            request.setValue(getAuthHeader(), forHTTPHeaderField: "Authorization")
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 200,
               let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
               let lastRun = list.first {
                let distanceMeters = lastRun["distance_meters"] as? Double ?? 0
                let pace = lastRun["average_pace_minutes_per_km"] as? Double ?? 0
                let duration = lastRun["duration_s"] as? Double ?? 0
                let startTimeStr = lastRun["start_time"] as? String
                let startTime = startTimeStr.flatMap { ISO8601DateFormatter().date(from: $0) }
                return LastRunStats(
                    distanceKm: distanceMeters / 1000.0,
                    paceMinPerKm: pace,
                    durationSeconds: duration,
                    startTime: startTime
                )
            }
        } catch {
            print("❌ Error fetching last run: \(error)")
        }
        return nil
    }
    
    func fetchRunAggregates(userId: String, limit: Int = 20) async -> RunAggregates? {
        guard isInitialized else { return nil }
        do {
            // Fetch recent runs minimal fields
            let url = URL(string: "\(baseURL)/rest/v1/run_activities?user_id=eq.\(userId)&select=distance_meters,average_pace_minutes_per_km&order=start_time.desc&limit=\(limit)")!
            var request = URLRequest(url: url)
            request.setValue(anonKey, forHTTPHeaderField: "apikey")
            request.setValue(getAuthHeader(), forHTTPHeaderField: "Authorization")
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 200,
               let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                let distances = list.compactMap { $0["distance_meters"] as? Double }
                let paces = list.compactMap { $0["average_pace_minutes_per_km"] as? Double }
                guard !distances.isEmpty, !paces.isEmpty else {
                    return RunAggregates(totalRuns: list.count, avgDistanceKm: 0, avgPaceMinPerKm: 0, bestPaceMinPerKm: 0)
                }
                let avgDistKm = distances.reduce(0, +) / Double(distances.count) / 1000.0
                let avgPace = paces.reduce(0, +) / Double(paces.count)
                let bestPace = paces.min() ?? 0
                return RunAggregates(totalRuns: list.count, avgDistanceKm: avgDistKm, avgPaceMinPerKm: avgPace, bestPaceMinPerKm: bestPace)
            }
        } catch {
            print("❌ Error fetching aggregates: \(error)")
        }
        return nil
    }

    // MARK: - Coaching Sessions persistence
    func saveCoachingSession(
        userId: String,
        runSessionId: String?,
        text: String,
        personality: String,
        energy: String,
        stats: RunningStatsUpdate,
        durationSeconds: Double
    ) async {
        guard isInitialized else { return }
        do {
            var payload: [String: Any] = [
                "id": UUID().uuidString,
                "user_id": userId,
                "timestamp": ISO8601DateFormatter().string(from: Date()),
                "feedback_text": text,
                "personality": personality,
                "energy": energy,
                "distance_m": stats.distance,
                "pace_min_per_km": stats.effectivePace,
                "calories": stats.calories,
                "elevation_m": stats.elevation,
                "duration_seconds": durationSeconds
            ]
            if let runId = runSessionId { payload["run_session_id"] = runId }
            
            let url = URL(string: "\(baseURL)/rest/v1/coaching_sessions")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue(anonKey, forHTTPHeaderField: "apikey")
            request.setValue(getAuthHeader(), forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            _ = try await session.data(for: request)
            print("✅ Coaching session saved to Supabase")
        } catch {
            print("❌ Error saving coaching session: \(error)")
        }
    }
    
    private func parseUserPreferences(from dict: [String: Any]) -> UserPreferences.Settings {
        let coachPersonalityStr = (dict["voice_mode"] as? String ?? "pacer").lowercased()
        let voiceStr = (dict["voice_ai_model"] as? String ?? "apple").lowercased()
        let energyStr = (dict["voice_energy"] as? String ?? "medium").lowercased()
        let feedbackFreq = dict["feedback_frequency"] as? Int ?? 5
        let targetPace = dict["target_pace_min_per_km"] as? Double ?? 7.0
        
        let personality = CoachPersonality(rawValue: coachPersonalityStr) ?? .pacer
        let voiceOption = VoiceOption(rawValue: voiceStr) ?? .samantha
        let energy = CoachEnergy(rawValue: energyStr) ?? .medium
        
        return UserPreferences.Settings(
            coachPersonality: personality,
            voiceOption: voiceOption,
            coachEnergy: energy,
            feedbackFrequency: feedbackFreq,
            targetPaceMinPerKm: targetPace
        )
    }
    
    // MARK: - PR Models (Shadow Runs)
    
    /// Fetch the active PR model for the user
    func fetchActivePRModel(userId: String) async -> PRModel? {
        guard isInitialized else {
            print("❌ Supabase not initialized for fetchActivePRModel")
            return nil
        }
        
        do {
            let url = URL(string: "\(baseURL)/rest/v1/pr_models?user_id=eq.\(userId)&is_active=eq.true&select=*")!
            var request = URLRequest(url: url)
            request.setValue(anonKey, forHTTPHeaderField: "apikey")
            request.setValue(getAuthHeader(), forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            
            print("🔍 Fetching PR models from: \(url.absoluteString)")
            print("🔍 Auth header: \(getAuthHeader().prefix(50))...")
            
            let (data, response) = try await session.data(for: request)
            
            if let httpResponse = response as? HTTPURLResponse {
                print("📥 fetchActivePRModel Response status: \(httpResponse.statusCode)")
                let jsonString = String(data: data, encoding: .utf8) ?? "Unable to decode"
                print("📦 Response data: \(jsonString)")
                
                if httpResponse.statusCode == 200 {
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    let prModels = try decoder.decode([PRModel].self, from: data)
                    print("✅ Decoded \(prModels.count) PR models")
                    if let first = prModels.first {
                        print("✅ Returning PR: \(first.name), Active: \(first.isActive)")
                    }
                    return prModels.first
                } else if httpResponse.statusCode == 401 {
                    print("❌ Authentication failed - 401 Unauthorized - JWT expired")
                    await MainActor.run {
                        handleTokenExpiration()
                    }
                } else if httpResponse.statusCode == 403 {
                    print("❌ Permission denied - 403 Forbidden (RLS policy issue?)")
                } else {
                    print("❌ HTTP error: \(httpResponse.statusCode)")
                }
            }
        } catch {
            print("❌ Error fetching active PR model: \(error)")
            if let decodingError = error as? DecodingError {
                print("❌ Decoding error details: \(decodingError)")
            }
        }
        
        return nil
    }
    
    /// Fetch all PR models for the user
    func fetchAllPRModels(userId: String) async -> [PRModel] {
        guard isInitialized else {
            print("❌ Supabase not initialized for fetchAllPRModels")
            return []
        }
        
        do {
            let url = URL(string: "\(baseURL)/rest/v1/pr_models?user_id=eq.\(userId)&order=created_at.desc&select=*")!
            var request = URLRequest(url: url)
            request.setValue(anonKey, forHTTPHeaderField: "apikey")
            request.setValue(getAuthHeader(), forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            
            print("🔍 Fetching ALL PR models from: \(url.absoluteString)")
            
            let (data, response) = try await session.data(for: request)
            
            if let httpResponse = response as? HTTPURLResponse {
                print("📥 fetchAllPRModels Response status: \(httpResponse.statusCode)")
                let jsonString = String(data: data, encoding: .utf8) ?? "Unable to decode"
                print("📦 All PR models data: \(jsonString)")
                
                if httpResponse.statusCode == 200 {
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    let models = try decoder.decode([PRModel].self, from: data)
                    print("✅ Decoded \(models.count) total PR models")
                    return models
                } else if httpResponse.statusCode == 401 {
                    print("❌ Authentication failed - 401 Unauthorized - JWT expired")
                    await MainActor.run {
                        handleTokenExpiration()
                    }
                } else {
                    print("❌ HTTP error: \(httpResponse.statusCode)")
                }
            }
        } catch {
            print("❌ Error fetching all PR models: \(error)")
            if let decodingError = error as? DecodingError {
                print("❌ Decoding error: \(decodingError)")
            }
        }
        
        return []
    }
    
    /// Fetch shadow run intervals for a specific run_id
    func fetchShadowIntervals(runId: String) async -> [ShadowInterval] {
        guard isInitialized else { return [] }
        
        do {
            let url = URL(string: "\(baseURL)/rest/v1/run_intervals?run_id=eq.\(runId)&order=kilometer.asc&select=*")!
            var request = URLRequest(url: url)
            request.setValue(anonKey, forHTTPHeaderField: "apikey")
            request.setValue(getAuthHeader(), forHTTPHeaderField: "Authorization")
            
            let (data, response) = try await session.data(for: request)
            
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                return try decoder.decode([ShadowInterval].self, from: data)
            }
        } catch {
            print("❌ Error fetching shadow intervals: \(error)")
        }
        
        return []
    }
    
    // MARK: - HR Config (Read-Only, Optional)
    
    struct HRConfig {
        let age: Int?
        let restingHeartRate: Int?
        let heartZoneMethod: String?
    }
    
    /// Load HR config for heart zone calculation
    /// SAFE: Read-only operation, uses existing table (if it exists)
    /// - Filters by user_id (safe isolation)
    /// - Gracefully handles missing table (returns nil, uses defaults)
    /// - NO writes, NO new tables, NO edge functions
    /// - This will NOT interfere with iOS app - it's a read-only query
    func loadHRConfig() async -> HRConfig? {
        guard isInitialized, let userId = currentUserId else {
            return nil
        }
        
        do {
            // SAFE: Read-only query, filtered by user_id - won't affect iOS app
            let url = URL(string: "\(baseURL)/rest/v1/user_health_config?user_id=eq.\(userId)&select=*")!
            var request = URLRequest(url: url)
            request.setValue(anonKey, forHTTPHeaderField: "apikey")
            request.setValue(getAuthHeader(), forHTTPHeaderField: "Authorization")
            
            let (data, response) = try await session.data(for: request)
            
            if let httpResponse = response as? HTTPURLResponse {
                // Gracefully handle missing table (404) or no data (200 with empty array)
                if httpResponse.statusCode == 404 {
                    // Table doesn't exist - this is OK, iOS app might not use it
                    print("ℹ️ [SupabaseManager] user_health_config table not found - using defaults")
                    return nil
                }
                
                if httpResponse.statusCode == 200 {
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                       let config = json.first {
                        let age = config["age"] as? Int
                        let restingHR = config["resting_heart_rate"] as? Int
                        let method = config["heart_zone_method"] as? String
                        return HRConfig(age: age, restingHeartRate: restingHR, heartZoneMethod: method)
                    }
                    // Empty result is OK - user hasn't set HR config yet
                    return nil
                }
            }
        } catch {
            // Gracefully handle errors - don't break the app if HR config isn't available
            print("ℹ️ [SupabaseManager] HR config not available (table may not exist): \(error.localizedDescription)")
        }
        
        return nil
    }
    
    // MARK: - Spotify Device Settings (device_settings table)
    
    func loadSpotifyDeviceSettings(userId: String) async -> SpotifyDeviceSettings? {
        guard isInitialized else { return nil }
        
        do {
            let url = URL(string: "\(baseURL)/rest/v1/device_settings?user_id=eq.\(userId)&select=spotify_enabled,spotify_master_playlist_id,target_heart_rate")!
            var request = URLRequest(url: url)
            request.setValue(anonKey, forHTTPHeaderField: "apikey")
            request.setValue(getAuthHeader(), forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 10
            
            let (data, response) = try await session.data(for: request)
            
            if let http = response as? HTTPURLResponse {
                if http.statusCode == 404 {
                    print("ℹ️ [Supabase] device_settings table not found")
                    return nil
                }
                if http.statusCode == 200,
                   let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                   let first = list.first {
                    return SpotifyDeviceSettings(
                        spotifyEnabled: first["spotify_enabled"] as? Bool ?? false,
                        masterPlaylistId: first["spotify_master_playlist_id"] as? String,
                        targetHeartRate: first["target_heart_rate"] as? Int
                    )
                }
            }
        } catch {
            print("ℹ️ [Supabase] Device settings not available: \(error.localizedDescription)")
        }
        return nil
    }
    
    func saveSpotifyDeviceSettings(userId: String, spotifyEnabled: Bool, masterPlaylistId: String?, targetHeartRate: Int?) async -> Bool {
        guard isInitialized else { return false }
        
        do {
            var payload: [String: Any] = [
                "user_id": userId,
                "spotify_enabled": spotifyEnabled,
                "updated_at": ISO8601DateFormatter().string(from: Date())
            ]
            if let pid = masterPlaylistId { payload["spotify_master_playlist_id"] = pid }
            if let thr = targetHeartRate { payload["target_heart_rate"] = thr }
            
            let patchUrl = URL(string: "\(baseURL)/rest/v1/device_settings?user_id=eq.\(userId)")!
            var patchRequest = URLRequest(url: patchUrl)
            patchRequest.httpMethod = "PATCH"
            patchRequest.setValue(anonKey, forHTTPHeaderField: "apikey")
            patchRequest.setValue(getAuthHeader(), forHTTPHeaderField: "Authorization")
            patchRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            patchRequest.setValue("return=representation", forHTTPHeaderField: "Prefer")
            patchRequest.httpBody = try JSONSerialization.data(withJSONObject: payload)
            
            let (patchData, patchResponse) = try await session.data(for: patchRequest)
            
            if let http = patchResponse as? HTTPURLResponse,
               (http.statusCode == 200 || http.statusCode == 204),
               let responseStr = String(data: patchData, encoding: .utf8),
               responseStr != "[]" && !responseStr.isEmpty {
                print("✅ [Supabase] Device settings updated")
                return true
            }
            
            payload["id"] = UUID().uuidString
            payload["created_at"] = ISO8601DateFormatter().string(from: Date())
            
            let postUrl = URL(string: "\(baseURL)/rest/v1/device_settings")!
            var postRequest = URLRequest(url: postUrl)
            postRequest.httpMethod = "POST"
            postRequest.setValue(anonKey, forHTTPHeaderField: "apikey")
            postRequest.setValue(getAuthHeader(), forHTTPHeaderField: "Authorization")
            postRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            postRequest.setValue("return=minimal", forHTTPHeaderField: "Prefer")
            postRequest.httpBody = try JSONSerialization.data(withJSONObject: payload)
            
            let (_, postResponse) = try await session.data(for: postRequest)
            if let http = postResponse as? HTTPURLResponse,
               http.statusCode == 200 || http.statusCode == 201 {
                print("✅ [Supabase] Device settings inserted")
                return true
            }
        } catch {
            print("❌ [Supabase] Device settings save error: \(error.localizedDescription)")
        }
        return false
    }
    
    struct SpotifyDeviceSettings {
        let spotifyEnabled: Bool
        let masterPlaylistId: String?
        let targetHeartRate: Int?
    }
    
    // MARK: - Track Scores (track_scores table)
    
    func loadTrackScores(userId: String) async -> [TrackScoreRecord] {
        guard isInitialized else { return [] }
        
        do {
            let url = URL(string: "\(baseURL)/rest/v1/track_scores?user_id=eq.\(userId)&select=track_uri,score,play_count,last_played_at")!
            var request = URLRequest(url: url)
            request.setValue(anonKey, forHTTPHeaderField: "apikey")
            request.setValue(getAuthHeader(), forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 15
            
            let (data, response) = try await session.data(for: request)
            
            if let http = response as? HTTPURLResponse {
                if http.statusCode == 404 {
                    print("ℹ️ [Supabase] track_scores table not found")
                    return []
                }
                if http.statusCode == 200,
                   let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                    return list.compactMap { item -> TrackScoreRecord? in
                        guard let uri = item["track_uri"] as? String else { return nil }
                        let score = item["score"] as? Int ?? 0
                        let playCount = item["play_count"] as? Int ?? 0
                        let lastPlayedStr = item["last_played_at"] as? String
                        let lastPlayed = lastPlayedStr.flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date()
                        return TrackScoreRecord(trackURI: uri, score: score, playCount: playCount, lastPlayedAt: lastPlayed)
                    }
                }
            }
        } catch {
            print("ℹ️ [Supabase] Track scores not available: \(error.localizedDescription)")
        }
        return []
    }
    
    func batchUpsertTrackScores(userId: String, scores: [TrackScoreRecord]) async -> Bool {
        guard isInitialized, !scores.isEmpty else { return false }
        
        do {
            let formatter = ISO8601DateFormatter()
            var payloads: [[String: Any]] = []
            
            for score in scores {
                let payload: [String: Any] = [
                    "user_id": userId,
                    "track_uri": score.trackURI,
                    "score": max(-5, min(5, score.score)),
                    "play_count": score.playCount,
                    "last_played_at": formatter.string(from: score.lastPlayedAt),
                    "updated_at": formatter.string(from: Date())
                ]
                payloads.append(payload)
            }
            
            let url = URL(string: "\(baseURL)/rest/v1/track_scores")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue(anonKey, forHTTPHeaderField: "apikey")
            request.setValue(getAuthHeader(), forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("return=minimal,resolution=merge-duplicates", forHTTPHeaderField: "Prefer")
            request.httpBody = try JSONSerialization.data(withJSONObject: payloads)
            request.timeoutInterval = 15
            
            let (_, response) = try await session.data(for: request)
            
            if let http = response as? HTTPURLResponse,
               http.statusCode == 200 || http.statusCode == 201 {
                print("✅ [Supabase] Batch upserted \(scores.count) track scores")
                return true
            }
        } catch {
            print("❌ [Supabase] Track scores upsert error: \(error.localizedDescription)")
        }
        return false
    }
    
    struct TrackScoreRecord {
        let trackURI: String
        let score: Int
        let playCount: Int
        let lastPlayedAt: Date
    }
}
