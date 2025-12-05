import Foundation
import WatchConnectivity
import Combine

// MARK: - WatchConnectivity Manager for iOS <-> watchOS Sync
class WatchConnectivityManager: NSObject, ObservableObject {
    static let shared = WatchConnectivityManager()
    
    @Published var isReachable = false
    @Published var lastReceivedMessage: [String: Any]?
    
    private var session: WCSession?
    
    override init() {
        super.init()
        setupWatchConnectivity()
    }
    
    private func setupWatchConnectivity() {
        guard WCSession.isSupported() else {
            print("⚠️ [WatchConnectivity] WCSession not supported on this device")
            return
        }
        
        session = WCSession.default
        session?.delegate = self
        session?.activate()
        
        print("✅ [WatchConnectivity] Session activated")
    }
    
    // MARK: - Send Messages to iOS
    
    /// Send heart rate update to iOS
    func sendHeartRateUpdate(_ heartRate: Double) {
        guard let session = session, session.isReachable else {
            // Store for later if not reachable
            sendMessage(["hrUpdate": heartRate])
            return
        }
        
        sendMessage(["hrUpdate": heartRate])
    }
    
    /// Send workout started notification to iOS
    func sendWorkoutStarted(runId: String) {
        sendMessage([
            "command": "workoutStarted",
            "runId": runId,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ])
    }
    
    /// Send workout ended notification to iOS
    func sendWorkoutEnded(stats: [String: Any]) {
        var message: [String: Any] = [
            "command": "workoutEnded",
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
        message.merge(stats) { (_, new) in new }
        sendMessage(message)
    }
    
    private func sendMessage(_ message: [String: Any]) {
        guard let session = session else { return }
        
        if session.isReachable {
            session.sendMessage(message, replyHandler: nil) { error in
                print("❌ [WatchConnectivity] Failed to send message: \(error.localizedDescription)")
            }
        } else {
            // Use application context for background delivery
            try? session.updateApplicationContext(message)
        }
    }
    
    // MARK: - Receive Messages from iOS
    
    private func handleMessage(_ message: [String: Any]) {
        let command = message["command"] as? String
        
        print("📱 [WatchConnectivity] Received: \(command ?? "data sync")")
        
        switch command {
        case "startWorkout":
            NotificationCenter.default.post(
                name: NSNotification.Name("WatchConnectivityStartWorkout"),
                object: nil,
                userInfo: message
            )
            
        case "stopWorkout":
            NotificationCenter.default.post(
                name: NSNotification.Name("WatchConnectivityStopWorkout"),
                object: nil,
                userInfo: message
            )
            
        case "prShadow":
            NotificationCenter.default.post(
                name: NSNotification.Name("WatchConnectivityPRShadow"),
                object: nil,
                userInfo: message
            )
            
        case "syncPreferences":
            // iOS sending user preferences
            NotificationCenter.default.post(
                name: NSNotification.Name("WatchConnectivitySyncPreferences"),
                object: nil,
                userInfo: message
            )
            
        default:
            // Check for preference data in any message
            if message["coachPersonality"] != nil || message["targetPace"] != nil {
                NotificationCenter.default.post(
                    name: NSNotification.Name("WatchConnectivitySyncPreferences"),
                    object: nil,
                    userInfo: message
                )
            }
        }
    }
}

// MARK: - WCSessionDelegate
extension WatchConnectivityManager: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async {
            self.isReachable = (activationState == .activated && session.isReachable)
        }
        
        if let error = error {
            print("❌ [WatchConnectivity] Activation error: \(error.localizedDescription)")
        } else {
            print("✅ [WatchConnectivity] Session activated - State: \(activationState.rawValue), Reachable: \(session.isReachable)")
        }
    }
    
    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            self.isReachable = session.isReachable
        }
        print("📱 [WatchConnectivity] Reachability changed: \(session.isReachable)")
    }
    
    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        DispatchQueue.main.async {
            self.lastReceivedMessage = message
        }
        handleMessage(message)
    }
    
    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        DispatchQueue.main.async {
            self.lastReceivedMessage = message
        }
        handleMessage(message)
        replyHandler(["status": "received"])
    }
    
    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        DispatchQueue.main.async {
            self.lastReceivedMessage = applicationContext
        }
        handleMessage(applicationContext)
    }
    
}


