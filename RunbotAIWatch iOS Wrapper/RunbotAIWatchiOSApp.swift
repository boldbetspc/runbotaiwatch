import SwiftUI

@main
struct RunbotAIWatchiOSApp: App {
    var body: some Scene {
        WindowGroup {
            // Minimal iOS wrapper - this app is only used for TestFlight distribution
            // The actual functionality is in the watchOS app
            VStack {
                Image(systemName: "applewatch")
                    .font(.system(size: 60))
                    .foregroundColor(.blue)
                Text("RunbotAI Watch")
                    .font(.title)
                    .fontWeight(.bold)
                    .padding(.top)
                Text("This app is a wrapper for the Apple Watch app.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                    .padding(.top, 8)
                Text("Install the watch app from the Watch app on your iPhone.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                    .padding(.top, 4)
            }
            .padding()
        }
    }
}

