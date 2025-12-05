import SwiftUI

/// Running View - Legacy view, kept for reference
/// Main running functionality is now in MainRunbotView
struct RunningView: View {
    @EnvironmentObject var runTracker: RunTracker
    @EnvironmentObject var voiceManager: VoiceManager
    @EnvironmentObject var aiCoachManager: AICoachManager
    @EnvironmentObject var userPreferences: UserPreferences
    @EnvironmentObject var supabaseManager: SupabaseManager
    @EnvironmentObject var authManager: AuthenticationManager
    
    @State private var carouselIndex = 1
    @State private var selectedStatIndex = 0
    @State private var wavePhase: Double = 0
    
    let statTitles = ["Distance", "Avg Pace", "Curr Pace", "Time", "Calories"]
    
    var body: some View {
        ZStack {
            LinearGradient(
                gradient: Gradient(colors: [Color.black, Color(red: 0.05, green: 0.05, blue: 0.15)]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Header
                HStack(spacing: 8) {
                    if aiCoachManager.isCoaching {
                        HStack(spacing: 4) {
                            Image(systemName: "brain.head.profile")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.cyan)
                                .scaleEffect(voiceManager.isSpeaking ? 1.2 : 1.0)
                                .animation(.easeInOut(duration: 0.3).repeatForever(autoreverses: true), value: voiceManager.isSpeaking)
                            Text("Coaching")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.orange)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.orange.opacity(0.2))
                        .cornerRadius(4)
                    } else {
                        HStack(spacing: 4) {
                            Image(systemName: "location.circle.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.green)
                            Text("Running")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(.green)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.green.opacity(0.2))
                        .cornerRadius(4)
                    }
                    
                    Spacer()
                    
                    // Page dots
                    HStack(spacing: 3) {
                        ForEach(0..<3, id: \.self) { index in
                            Circle()
                                .fill(index == carouselIndex ? Color.cyan : Color.gray.opacity(0.3))
                                .frame(width: 4, height: 4)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                
                Divider().background(Color.cyan.opacity(0.2))
                
                // Carousel
                TabView(selection: $carouselIndex) {
                    statsPage().tag(0)
                    coachPage().tag(1)
                    feedbackPage().tag(2)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(maxHeight: .infinity)
                
                // Stop Button
                Button(action: stopRun) {
                    HStack(spacing: 6) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 10, weight: .bold))
                        Text("Stop")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        LinearGradient(
                            colors: [Color(red: 0.9, green: 0.2, blue: 0.2), Color(red: 0.8, green: 0.1, blue: 0.1)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .foregroundColor(.white)
                    .cornerRadius(8)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
        }
        .onAppear { startWaveAnimation() }
    }
    
    // MARK: - Stats Page
    @ViewBuilder
    private func statsPage() -> some View {
        VStack(spacing: 12) {
            Text("Stats")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.cyan)
                .padding(.top, 12)
            
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.black.opacity(0.85))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.cyan.opacity(0.3), lineWidth: 1)
                    )
                
                VStack(spacing: 12) {
                    Text(statTitles[selectedStatIndex])
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.gray)
                    
                    HStack(spacing: 4) {
                        Text(getCurrentStatValue())
                            .font(.system(size: 36, weight: .bold, design: .monospaced))
                            .foregroundColor(.cyan)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        
                        Text(getCurrentStatUnit())
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.gray)
                            .padding(.top, 8)
                    }
                }
                .padding(12)
            }
            .frame(height: 110)
            
            // Stat selectors
            HStack(spacing: 4) {
                ForEach(0..<statTitles.count, id: \.self) { index in
                    Button(action: { selectedStatIndex = index }) {
                        Circle()
                            .fill(index == selectedStatIndex ? Color.cyan : Color.gray.opacity(0.3))
                            .frame(height: 6)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            
            Spacer()
        }
        .padding(.horizontal, 8)
    }
    
    // MARK: - Coach Page
    @ViewBuilder
    private func coachPage() -> some View {
        VStack(spacing: 16) {
            Spacer()
            
            ZStack {
                if aiCoachManager.isCoaching {
                    Circle()
                        .stroke(Color.cyan.opacity(0.3), lineWidth: 2)
                        .frame(width: 100, height: 100)
                        .scaleEffect(1.2)
                        .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: aiCoachManager.isCoaching)
                }
                
                Image(systemName: coachIcon)
                    .font(.system(size: 40, weight: .bold))
                    .foregroundColor(coachColor)
            }
            
            VStack(spacing: 4) {
                Text(aiCoachManager.isCoaching ? "AI Coach Active" : "Ready")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                
                Text(userPreferences.settings.coachPersonality.rawValue)
                    .font(.system(size: 10))
                    .foregroundColor(.gray)
            }
            
            Spacer()
        }
    }
    
    // MARK: - Feedback Page
    @ViewBuilder
    private func feedbackPage() -> some View {
        VStack(spacing: 12) {
            Text("Feedback")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.cyan)
                .padding(.top, 12)
            
            if !aiCoachManager.currentFeedback.isEmpty {
                ScrollView {
                    Text(aiCoachManager.currentFeedback)
                        .font(.system(size: 11))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .padding()
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "text.bubble")
                        .font(.system(size: 32))
                        .foregroundColor(.gray)
                    Text("Coaching will appear here")
                        .font(.system(size: 10))
                        .foregroundColor(.gray)
                }
                .frame(maxHeight: .infinity)
            }
            
            Spacer()
        }
        .padding(.horizontal, 8)
    }
    
    // MARK: - Helpers
    
    private var coachIcon: String {
        switch userPreferences.settings.coachPersonality {
        case .pacer: return "figure.run"
        case .strategist: return "brain.head.profile"
        case .finisher: return "flame.fill"
        }
    }
    
    private var coachColor: Color {
        switch userPreferences.settings.coachPersonality {
        case .pacer: return .cyan
        case .strategist: return .indigo
        case .finisher: return .orange
        }
    }
    
    private func startWaveAnimation() {
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            wavePhase += 1
        }
    }
    
    private func getCurrentStatValue() -> String {
        guard let session = runTracker.currentSession else { return "0.00" }
        switch selectedStatIndex {
        case 0: return session.formattedDistance
        case 1: return calculateAveragePace()
        case 2: return session.formattedPace
        case 3: return session.formattedDuration
        case 4: return String(format: "%.0f", session.calories)
        default: return "0.00"
        }
    }
    
    private func getCurrentStatUnit() -> String {
        switch selectedStatIndex {
        case 0: return "km"
        case 1, 2: return "min/km"
        case 3: return ""
        case 4: return "kcal"
        default: return ""
        }
    }
    
    private func calculateAveragePace() -> String {
        guard let session = runTracker.currentSession else { return "0:00" }
        let distanceKm = session.distance / 1000.0
        guard distanceKm > 0 else { return "0:00" }
        let avgPace = session.elapsedTime / 60.0 / distanceKm
        let mins = Int(avgPace)
        let secs = Int((avgPace - Double(mins)) * 60)
        return String(format: "%d:%02d", mins, secs)
    }
    
    private func stopRun() {
        aiCoachManager.stopCoaching()
        voiceManager.stopSpeaking()
        runTracker.stopRun()
        
        if let session = runTracker.currentSession,
           let userId = authManager.currentUser?.id {
            Task {
                _ = await supabaseManager.saveRunActivity(session, userId: userId)
            }
        }
        
        runTracker.resetSession()
    }
}

#Preview {
    RunningView()
        .environmentObject(RunTracker())
        .environmentObject(VoiceManager())
        .environmentObject(AICoachManager())
        .environmentObject(UserPreferences())
        .environmentObject(SupabaseManager())
        .environmentObject(AuthenticationManager())
}
