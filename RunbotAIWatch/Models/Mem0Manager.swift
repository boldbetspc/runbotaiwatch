import Foundation
import Network
import Combine

// MARK: - WatchOS Mem0 Manager
/// Optimized Mem0 integration for watchOS with caching, batching, and offline support
/// 
/// **Network Connectivity Priority:**
/// 1. Apple Watch Cellular (if available)
/// 2. iPhone Connection via Bluetooth (automatic fallback)
/// 
/// watchOS automatically handles connection priority - no WiFi required.
final class Mem0Manager: ObservableObject {
    static let shared = Mem0Manager()
    
    // MARK: - Published State
    @Published var isOnline = true
    
    // MARK: - Configuration
    private let supabaseURL: String
    private let supabaseKey: String
    
    // Cache settings - optimized for battery
    private let cacheTTL: TimeInterval = 600 // 10 minutes (vs 5 min iOS)
    private var cache: [String: CacheEntry] = [:]
    
    // Batch writing settings
    private let batchFlushInterval: TimeInterval = 30 // 30 seconds (vs 10s iOS)
    private let maxBatchSize = 3 // Smaller for watch
    private var writeQueue: [QueuedWrite] = []
    private var flushTimer: Timer?
    
    // Network monitoring
    private let networkMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "mem0.network.monitor")
    
    // MARK: - Types
    
    private struct CacheEntry {
        let results: [String]
        let timestamp: Date
    }
    
    private struct QueuedWrite: Codable {
        let userId: String
        let text: String
        let category: String
        let metadata: [String: String]
        let timestamp: Date
    }
    
    // MARK: - Initialization
    
    private init() {
        if let config = ConfigLoader.loadConfig() {
            self.supabaseURL = (config["SUPABASE_URL"] as? String) ?? ""
            self.supabaseKey = (config["SUPABASE_ANON_KEY"] as? String) ?? ""
        } else {
            self.supabaseURL = ""
            self.supabaseKey = ""
        }
        
        setupNetworkMonitoring()
        loadOfflineQueue()
        startBatchFlushTimer()
    }
    
    deinit {
        flushTimer?.invalidate()
        networkMonitor.cancel()
    }
    
    // MARK: - Public API
    
    /// Search Mem0 for relevant memories
    func search(
        userId: String,
        query: String,
        category: String? = nil,
        limit: Int = 5
    ) async -> [String] {
        // Check cache first
        let cacheKey = "\(userId):\(query.hashValue):\(category ?? "")"
        if let cached = getCachedResult(key: cacheKey) {
            print("📦 [Mem0] Cache hit for: \(query.prefix(30))...")
            return cached
        }
        
        // Fetch from API
        guard isOnline else {
            print("📴 [Mem0] Offline - returning empty results")
            return []
        }
        
        let results = await fetchFromAPI(
            userId: userId,
            query: query,
            category: category,
            limit: limit
        )
        
        // Cache results
        cacheResult(key: cacheKey, results: results)
        
        return results
    }
    
    /// Add memory to Mem0 (batched for efficiency)
    func add(
        userId: String,
        text: String,
        category: String,
        metadata: [String: String] = [:]
    ) {
        var enrichedMetadata = metadata
        enrichedMetadata["platform"] = "watchOS"
        enrichedMetadata["timestamp"] = ISO8601DateFormatter().string(from: Date())
        
        let write = QueuedWrite(
            userId: userId,
            text: text,
            category: category,
            metadata: enrichedMetadata,
            timestamp: Date()
        )
        
        writeQueue.append(write)
        saveOfflineQueue()
        
        // Flush immediately if queue is full
        if writeQueue.count >= maxBatchSize {
            Task { await flushWriteQueue() }
        }
        
        // Invalidate related cache entries
        invalidateCache(userId: userId, category: category)
        
        print("📝 [Mem0] Queued write: \(category) (queue size: \(writeQueue.count))")
    }
    
    /// Force flush all queued writes
    func flushNow() async {
        await flushWriteQueue()
    }
    
    // MARK: - Network Monitoring
    
    private func setupNetworkMonitoring() {
        // Efficient: Only check online/offline status, not connection type
        // URLSession automatically prioritizes watch cellular, then iPhone connection
        // No need to check on each call - system handles it optimally
        networkMonitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                let wasOffline = !(self?.isOnline ?? true)
                let isConnected = path.status == .satisfied
                self?.isOnline = isConnected
                
                // Only log on state change to avoid spam
                if wasOffline && isConnected {
                    print("🌐 [Mem0] Network restored - flushing offline queue")
                    Task { await self?.flushWriteQueue() }
                } else if !wasOffline && !isConnected {
                    print("📴 [Mem0] Network lost - writes will queue")
                }
            }
        }
        networkMonitor.start(queue: monitorQueue)
        
        // URLSession automatically uses best available connection:
        // 1. Watch Cellular (if available)
        // 2. iPhone Connection via Bluetooth (automatic fallback)
        // No per-call checking needed - system handles efficiently
    }
    
    // MARK: - Caching
    
    private func getCachedResult(key: String) -> [String]? {
        guard let entry = cache[key] else { return nil }
        
        // Check TTL
        if Date().timeIntervalSince(entry.timestamp) > cacheTTL {
            cache.removeValue(forKey: key)
            return nil
        }
        
        return entry.results
    }
    
    private func cacheResult(key: String, results: [String]) {
        cache[key] = CacheEntry(results: results, timestamp: Date())
    }
    
    private func invalidateCache(userId: String, category: String) {
        // Remove all cache entries for this user/category
        cache = cache.filter { key, _ in
            !key.hasPrefix(userId) || !key.contains(category)
        }
    }
    
    // MARK: - Batch Writing
    
    private func startBatchFlushTimer() {
        flushTimer?.invalidate()
        flushTimer = Timer.scheduledTimer(withTimeInterval: batchFlushInterval, repeats: true) { [weak self] _ in
            Task { await self?.flushWriteQueue() }
        }
    }
    
    private func flushWriteQueue() async {
        guard !writeQueue.isEmpty else { return }
        guard isOnline else {
            print("📴 [Mem0] Offline - writes remain queued (\(writeQueue.count) items)")
            return
        }
        
        let itemsToFlush = writeQueue
        writeQueue.removeAll()
        saveOfflineQueue()
        
        print("📤 [Mem0] Flushing \(itemsToFlush.count) queued writes...")
        
        for write in itemsToFlush {
            let success = await writeToAPI(
                userId: write.userId,
                text: write.text,
                category: write.category,
                metadata: write.metadata
            )
            
            if !success {
                // Re-queue failed writes
                writeQueue.append(write)
            }
        }
        
        if !writeQueue.isEmpty {
            saveOfflineQueue()
            print("⚠️ [Mem0] \(writeQueue.count) writes failed, re-queued")
        } else {
            print("✅ [Mem0] All writes flushed successfully")
        }
    }
    
    // MARK: - Offline Queue Persistence
    
    private func saveOfflineQueue() {
        if let data = try? JSONEncoder().encode(writeQueue) {
            UserDefaults.standard.set(data, forKey: "mem0_offline_queue")
        }
    }
    
    private func loadOfflineQueue() {
        if let data = UserDefaults.standard.data(forKey: "mem0_offline_queue"),
           let queue = try? JSONDecoder().decode([QueuedWrite].self, from: data) {
            writeQueue = queue
            print("📂 [Mem0] Loaded \(queue.count) offline queued writes")
        }
    }
    
    // MARK: - API Calls
    
    /// Fetch from Mem0 via Supabase edge function (shared with iOS app)
    /// Edge function uses MEM0_API_KEY from Supabase secrets
    /// URLSession automatically uses best connection: watch cellular → iPhone connection
    private func fetchFromAPI(
        userId: String,
        query: String,
        category: String?,
        limit: Int
    ) async -> [String] {
        guard !supabaseURL.isEmpty else {
            print("❌ [Mem0] Supabase URL not configured")
            return []
        }
        
        let proxyURL = "\(supabaseURL)/functions/v1/mem0-proxy"
        guard let url = URL(string: proxyURL) else {
            print("❌ [Mem0] Invalid edge function URL")
            return []
        }
        
        print("📦 [Mem0] ========== SEARCHING MEM0 ==========")
        print("📦 [Mem0] Using Supabase edge function: mem0-proxy (shared with iOS)")
        print("📦 [Mem0] URL: \(url)")
        print("📦 [Mem0] Query: \(query.prefix(50))...")
        print("📦 [Mem0] User ID: \(userId)")
        print("📦 [Mem0] Note: Edge function uses MEM0_API_KEY from Supabase secrets")
        
        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(supabaseKey, forHTTPHeaderField: "apikey")
            request.setValue(getAuthToken(), forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 10 // Shorter timeout for watch
            
            var body: [String: Any] = [
                "action": "search",
                "user_id": userId,
                "query": query,
                "limit": limit
            ]
            if let category = category {
                body["category"] = category
            }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            
            print("📦 [Mem0] Sending search request to edge function...")
            let startTime = Date()
            let (data, response) = try await URLSession.shared.data(for: request)
            let duration = Date().timeIntervalSince(startTime)
            
            print("📦 [Mem0] Response received in \(String(format: "%.2f", duration)) seconds")
            
            if let http = response as? HTTPURLResponse {
                print("📦 [Mem0] HTTP Status Code: \(http.statusCode)")
                if http.statusCode == 200 {
                    // Edge function may return either format:
                    // 1. Array directly: [{...}, {...}]
                    // 2. Object with results: {"results": [{...}, {...}]}
                    
                    // First try to parse as JSON
                    do {
                        let jsonObject = try JSONSerialization.jsonObject(with: data)
                        
                        // Try direct array format first
                        if let jsonArray = jsonObject as? [[String: Any]] {
                            let memories = jsonArray.compactMap { $0["memory"] as? String }
                            print("📦 [Mem0] ✅✅✅ Mem0 search SUCCESS - found \(memories.count) memories ✅✅✅")
                            return memories
                        }
                        
                        // Try wrapped in results object
                        if let json = jsonObject as? [String: Any],
                           let results = json["results"] as? [[String: Any]] {
                            let memories = results.compactMap { $0["memory"] as? String }
                            print("📦 [Mem0] ✅✅✅ Mem0 search SUCCESS - found \(memories.count) memories ✅✅✅")
                            return memories
                        }
                        
                        // If we got here, format is unexpected
                        print("❌ [Mem0] Unexpected response format. JSON type: \(type(of: jsonObject))")
                        if let jsonDict = jsonObject as? [String: Any] {
                            print("❌ [Mem0] Response keys: \(Array(jsonDict.keys))")
                        }
                    } catch {
                        print("❌ [Mem0] JSON parsing error: \(error.localizedDescription)")
                    }
                    
                    // If we reach here, parsing failed
                    let errorBody = String(data: data, encoding: .utf8) ?? "Unknown"
                    print("❌ [Mem0] Search failed - Status: \(http.statusCode)")
                    print("❌ [Mem0] Response preview: \(errorBody.prefix(200))")
                } else {
                    let errorBody = String(data: data, encoding: .utf8) ?? "Unknown"
                    print("❌ [Mem0] Search failed - Status: \(http.statusCode), Error: \(errorBody)")
                }
            }
        } catch {
            print("❌ [Mem0] Search error: \(error.localizedDescription)")
        }
        
        return []
    }
    
    /// Write to Mem0 via Supabase edge function (shared with iOS app)
    /// Edge function uses MEM0_API_KEY from Supabase secrets
    /// URLSession automatically uses best connection: watch cellular → iPhone connection
    private func writeToAPI(
        userId: String,
        text: String,
        category: String,
        metadata: [String: String]
    ) async -> Bool {
        guard !supabaseURL.isEmpty else {
            print("❌ [Mem0] Supabase URL not configured")
            return false
        }
        
        let proxyURL = "\(supabaseURL)/functions/v1/mem0-proxy"
        guard let url = URL(string: proxyURL) else {
            print("❌ [Mem0] Invalid edge function URL")
            return false
        }
        
        print("📝 [Mem0] ========== WRITING TO MEM0 ==========")
        print("📝 [Mem0] Using Supabase edge function: mem0-proxy (shared with iOS)")
        print("📝 [Mem0] URL: \(url)")
        print("📝 [Mem0] Category: \(category)")
        print("📝 [Mem0] Text length: \(text.count) characters")
        print("📝 [Mem0] Note: Edge function uses MEM0_API_KEY from Supabase secrets")
        
        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(supabaseKey, forHTTPHeaderField: "apikey")
            request.setValue(getAuthToken(), forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 15
            
            // Edge function expects: action, user_id, data (not text), and optional metadata
            // Edge function transforms this to Mem0 API format: { messages: [{ role: "user", content: data }], user_id }
            var requestMetadata = metadata
            requestMetadata["category"] = category // Include category in metadata
            requestMetadata["platform"] = "watchOS"
            requestMetadata["timestamp"] = ISO8601DateFormatter().string(from: Date())
            
            let body: [String: Any] = [
                "action": "add",
                "user_id": userId,
                "data": text, // Edge function expects "data" not "text"
                "metadata": requestMetadata
            ]
            print("📝 [Mem0] Request body format:")
            print("   - action: add")
            print("   - user_id: \(userId)")
            print("   - data: \(text.count) characters")
            print("   - metadata: \(requestMetadata)")
            
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            
            print("📝 [Mem0] Sending write request to edge function...")
            let startTime = Date()
            let (data, response) = try await URLSession.shared.data(for: request)
            let duration = Date().timeIntervalSince(startTime)
            
            print("📝 [Mem0] Response received in \(String(format: "%.2f", duration)) seconds")
            
            if let http = response as? HTTPURLResponse {
                print("📝 [Mem0] HTTP Status Code: \(http.statusCode)")
                if http.statusCode == 200 {
                    print("📝 [Mem0] ✅✅✅ Mem0 write SUCCESS ✅✅✅")
                    return true
                } else {
                    let errorBody = String(data: data, encoding: .utf8) ?? "Unknown"
                    print("❌ [Mem0] Write failed - Status: \(http.statusCode), Error: \(errorBody)")
                }
            }
        } catch {
            print("❌ [Mem0] Write error: \(error.localizedDescription)")
        }
        
        return false
    }
    
    // MARK: - Helpers
    
    private func getAuthToken() -> String {
        if let token = UserDefaults.standard.string(forKey: "sessionToken") {
            return "Bearer \(token)"
        }
        return "Bearer \(supabaseKey)"
    }
    
    // MARK: - Legacy Compatibility
    
    /// Legacy method for backward compatibility
    func fetchInsights(for userId: String) async -> String {
        let results = await search(
            userId: userId,
            query: "running performance, pacing patterns, fatigue moments",
            category: "RUNNING_DATA",
            limit: 5
        )
        return results.joined(separator: "\n")
    }
}
