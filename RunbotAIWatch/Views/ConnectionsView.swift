import SwiftUI
import Network
import HealthKit

struct ConnectionsView: View {
    @EnvironmentObject var healthManager: HealthManager
    @ObservedObject var networkMonitor: NetworkMonitor
    
    @State private var isRefreshingNetwork = false
    @State private var isRefreshingWorkout = false
    
    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Header
                Text("CONNECTIONS")
                    .font(.system(size: 10, weight: .black, design: .rounded))
                    .tracking(2)
                    .foregroundStyle(LinearGradient(colors: [.rbAccent, .rbSecondary], startPoint: .leading, endPoint: .trailing))
                    .padding(.top, 6)
                
                ScrollView {
                    VStack(spacing: 12) {
                        // Network Connection Section
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Network Connection")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.cyan)
                                Spacer()
                                Button(action: refreshNetworkConnection) {
                                    HStack(spacing: 4) {
                                        if isRefreshingNetwork {
                                            ProgressView()
                                                .scaleEffect(0.7)
                                                .tint(.white)
                                        } else {
                                            Image(systemName: "arrow.clockwise")
                                                .font(.system(size: 9))
                                        }
                                        Text(isRefreshingNetwork ? "Refreshing..." : "Refresh")
                                            .font(.system(size: 9, weight: .medium))
                                    }
                                    .foregroundColor(.cyan)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.cyan.opacity(0.2))
                                    .cornerRadius(6)
                                }
                            }
                            
                            NetworkConnectionCard(networkMonitor: networkMonitor)
                        }
                        .padding(10)
                        .background(Color.black.opacity(0.5))
                        .cornerRadius(8)
                        
                        // Workout Connection Section
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Workout Connection")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.cyan)
                                Spacer()
                                Button(action: refreshWorkoutConnection) {
                                    HStack(spacing: 4) {
                                        if isRefreshingWorkout {
                                            ProgressView()
                                                .scaleEffect(0.7)
                                                .tint(.white)
                                        } else {
                                            Image(systemName: "arrow.clockwise")
                                                .font(.system(size: 9))
                                        }
                                        Text(isRefreshingWorkout ? "Refreshing..." : "Refresh")
                                            .font(.system(size: 9, weight: .medium))
                                    }
                                    .foregroundColor(.cyan)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.cyan.opacity(0.2))
                                    .cornerRadius(6)
                                }
                            }
                            
                            WorkoutConnectionCard(healthManager: healthManager)
                        }
                        .padding(10)
                        .background(Color.black.opacity(0.5))
                        .cornerRadius(8)
                    }
                    .padding(.vertical, 8)
                }
            }
        }
    }
    
    private func refreshNetworkConnection() {
        isRefreshingNetwork = true
        print("🔄 [ConnectionsView] Refreshing network connection...")
        
        // Force network monitor to re-check connection
        networkMonitor.refreshConnection()
        
        // Simulate refresh delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            isRefreshingNetwork = false
        }
    }
    
    private func refreshWorkoutConnection() {
        isRefreshingWorkout = true
        print("🔄 [ConnectionsView] Refreshing workout connection...")
        
        #if targetEnvironment(simulator)
        print("⚠️ [ConnectionsView] Running on SIMULATOR - HealthKit has limitations")
        print("⚠️ [ConnectionsView] To test HealthKit properly:")
        print("   1. Use a real Apple Watch device, OR")
        print("   2. Reset simulator: Device > Erase All Content and Settings")
        #endif
        
        // First check current status
        healthManager.checkAuthorizationStatus()
        
        // If not authorized, request authorization
        if !healthManager.isAuthorized {
            print("💓 [ConnectionsView] Not authorized - requesting HealthKit access...")
            healthManager.requestHealthDataAccess()
            
            // Re-check status after delay to allow for authorization dialog
            // Longer delay on simulator as dialogs may be delayed
            #if targetEnvironment(simulator)
            let delay: TimeInterval = 3.0
            #else
            let delay: TimeInterval = 2.0
            #endif
            
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                healthManager.checkAuthorizationStatus()
                isRefreshingWorkout = false
                print("✅ [ConnectionsView] Workout connection refresh complete")
            }
        } else {
            // Already authorized, just refresh status
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                healthManager.checkAuthorizationStatus()
                isRefreshingWorkout = false
                print("✅ [ConnectionsView] Workout connection refresh complete (already authorized)")
            }
        }
    }
}

// MARK: - Network Connection Card
struct NetworkConnectionCard: View {
    @ObservedObject var networkMonitor: NetworkMonitor
    
    var body: some View {
        HStack(spacing: 8) {
            // Status indicator
            Circle()
                .fill(networkMonitor.isConnected ? Color.rbSuccess : Color.rbError)
                .frame(width: 10, height: 10)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(networkMonitor.isConnected ? "Connected" : "Disconnected")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(networkMonitor.isConnected ? .rbSuccess : .rbError)
                
                Text(networkMonitor.connectionType.displayText)
                    .font(.system(size: 10, weight: .regular))
                    .foregroundColor(.white.opacity(0.7))
                
                if !networkMonitor.isConnected {
                    Text("Trying to reconnect...")
                        .font(.system(size: 9, weight: .regular))
                        .foregroundColor(.white.opacity(0.5))
                }
            }
            
            Spacer()
            
            // Connection type icon
            Image(systemName: connectionIcon)
                .font(.system(size: 14))
                .foregroundColor(networkMonitor.isConnected ? .cyan.opacity(0.8) : .white.opacity(0.3))
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(networkMonitor.isConnected ? Color.rbSuccess.opacity(0.15) : Color.rbError.opacity(0.15))
        )
    }
    
    private var connectionIcon: String {
        switch networkMonitor.connectionType {
        case .watchCellular:
            return "antenna.radiowaves.left.and.right"
        case .iphonePaired:
            return "iphone"
        case .none:
            return "wifi.slash"
        }
    }
}

// MARK: - Workout Connection Card
struct WorkoutConnectionCard: View {
    @ObservedObject var healthManager: HealthManager
    
    var body: some View {
        HStack(spacing: 8) {
            // Status indicator
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(statusText)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(statusColor)
                
                Text(statusDetail)
                    .font(.system(size: 10, weight: .regular))
                    .foregroundColor(.white.opacity(0.7))
                
                if !healthManager.isAuthorized {
                    Text("Tap Refresh to request access")
                        .font(.system(size: 9, weight: .regular))
                        .foregroundColor(.white.opacity(0.5))
                }
            }
            
            Spacer()
            
            // Workout icon
            Image(systemName: statusIcon)
                .font(.system(size: 14))
                .foregroundColor(statusColor.opacity(0.8))
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(statusColor.opacity(0.15))
        )
    }
    
    private var statusColor: Color {
        if healthManager.isAuthorized {
            switch healthManager.workoutStatus {
            case .running:
                return .rbSuccess
            case .starting:
                return .rbWarning
            case .error(_):
                return .rbError
            case .notStarted:
                return .gray
            }
        } else {
            return .rbError
        }
    }
    
    private var statusText: String {
        if healthManager.isAuthorized {
            switch healthManager.workoutStatus {
            case .running:
                return "Workout Active"
            case .starting:
                return "Starting..."
            case .error(let msg):
                return "Error: \(msg)"
            case .notStarted:
                return "Ready"
            }
        } else if healthManager.workoutAuthorized && !healthManager.heartRateAuthorized {
            return "Partial Authorization"
        } else if !healthManager.workoutAuthorized && healthManager.heartRateAuthorized {
            return "Partial Authorization"
        } else {
            return "Not Authorized"
        }
    }
    
    private var statusDetail: String {
        if healthManager.isAuthorized {
            switch healthManager.workoutStatus {
            case .running:
                return "HealthKit session running"
            case .starting:
                return "Initializing workout..."
            case .error(let msg):
                return msg
            case .notStarted:
                return "Authorized - ready to start"
            }
        } else if healthManager.workoutAuthorized && !healthManager.heartRateAuthorized {
            return "Workout ✅ | Heart Rate ❌ - Enable in Settings > Privacy & Security > Health"
        } else if !healthManager.workoutAuthorized && healthManager.heartRateAuthorized {
            return "Workout ❌ | Heart Rate ✅ - Enable in Settings > Privacy & Security > Health"
        } else {
            return "HealthKit access required"
        }
    }
    
    private var statusIcon: String {
        if healthManager.isAuthorized {
            switch healthManager.workoutStatus {
            case .running:
                return "checkmark.circle.fill"
            case .starting:
                return "hourglass"
            case .error(_):
                return "exclamationmark.triangle.fill"
            case .notStarted:
                return "heart.circle.fill"
            }
        } else {
            return "lock.circle.fill"
        }
    }
}

#Preview {
    ConnectionsView(networkMonitor: NetworkMonitor())
        .environmentObject(HealthManager())
}

