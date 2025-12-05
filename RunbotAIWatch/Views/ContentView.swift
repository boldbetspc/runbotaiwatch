import SwiftUI

struct ContentView: View {
    @EnvironmentObject var authManager: AuthenticationManager
    @EnvironmentObject var runTracker: RunTracker
    
    var body: some View {
        ZStack {
            if authManager.isAuthenticated {
                MainRunbotView()
            } else {
                AuthenticationView()
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AuthenticationManager())
        .environmentObject(RunTracker())
}
