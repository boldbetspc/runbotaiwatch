import Foundation
import SwiftUI
import Combine

/// SessionCleanupManager: Kills all AI sessions cleanly
/// Simple kill switch - no recovery, just clean shutdown
class SessionCleanupManager: ObservableObject {
    static let shared = SessionCleanupManager()
    
    private init() {
        print("🛡️ [SessionCleanup] Initialized")
    }
    
    // MARK: - Kill All Sessions
    
    /// Kill all AI sessions immediately - no recovery
    func killAllSessions() {
        print("🚨 [SessionCleanup] Killing all AI sessions...")
        
        // 1. Cancel all network requests
        URLSession.shared.getAllTasks { tasks in
            tasks.forEach { $0.cancel() }
            print("🛑 [SessionCleanup] Cancelled \(tasks.count) network tasks")
        }
        
        // 2. Stop voice
        NotificationCenter.default.post(name: NSNotification.Name("EmergencyStopAll"), object: nil)
        
        // 3. Clear caches
        URLCache.shared.removeAllCachedResponses()
        
        print("✅ [SessionCleanup] All sessions killed")
    }
}

