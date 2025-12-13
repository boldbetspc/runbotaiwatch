import SwiftUI
import Combine
import ImageIO
import Network
#if canImport(WatchKit)
import WatchKit
#endif
#if canImport(UIKit)
import UIKit
#endif

// MARK: - 🎨 Color Theme (Blue-Purple)
extension Color {
    static let rbAccent = Color(red: 0.0, green: 0.78, blue: 1.0)
    static let rbSecondary = Color(red: 0.55, green: 0.36, blue: 0.96)
    static let rbSuccess = Color(red: 0.2, green: 0.9, blue: 0.4)
    static let rbWarning = Color(red: 1.0, green: 0.6, blue: 0.0)
    static let rbError = Color(red: 0.95, green: 0.3, blue: 0.35)
}

// MARK: - 🎬 GIF Image View (for AI Coach) - Enhanced for watchOS
struct GIFImage: View {
    let name: String
    let isAnimating: Bool
    
    @State private var currentFrame: UIImage?
    @State private var frameIndex: Int = 0
    @State private var frames: [UIImage] = []
    @State private var durations: [Double] = []
    @State private var animationTask: Task<Void, Never>?
    @State private var shouldAnimate: Bool = false
    
    var body: some View {
        Group {
            if let image = currentFrame {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                // Fallback to static image
                Image("ai_coach")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
        .onAppear {
            print("🎬 [GIF] Loading GIF: \(name), isAnimating: \(isAnimating)")
            loadGIF()
            shouldAnimate = isAnimating
            if isAnimating {
                startAnimation()
            }
        }
        .onChange(of: isAnimating) { oldValue, newValue in
            print("🎬 [GIF] Animation state changed: \(newValue) (was: \(shouldAnimate))")
            shouldAnimate = newValue
            if newValue {
                print("▶️ [GIF] onChange: Starting animation immediately")
                startAnimation()
            } else {
                print("⏹️ [GIF] onChange: Stopping animation immediately")
                stopAnimation()
            }
        }
        .onDisappear {
            stopAnimation()
        }
    }
    
    private func loadGIF() {
        guard let url = Bundle.main.url(forResource: name, withExtension: "gif") else {
            print("❌ [GIF] File not found: \(name).gif")
            return
        }
        
        guard let data = try? Data(contentsOf: url) else {
            print("❌ [GIF] Failed to load data from: \(url)")
            return
        }
        
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            print("❌ [GIF] Failed to create image source")
            return
        }
        
        let count = CGImageSourceGetCount(source)
        print("🎬 [GIF] Found \(count) frames")
        
        var loadedFrames: [UIImage] = []
        var loadedDurations: [Double] = []
        
        for i in 0..<count {
            guard let cgImage = CGImageSourceCreateImageAtIndex(source, i, nil) else { continue }
            loadedFrames.append(UIImage(cgImage: cgImage))
            
            // Get frame duration
            var delay: Double = 0.1 // Default
            if let properties = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [String: Any],
               let gifProps = properties[kCGImagePropertyGIFDictionary as String] as? [String: Any] {
                if let unclampedDelay = gifProps[kCGImagePropertyGIFUnclampedDelayTime as String] as? Double {
                    delay = unclampedDelay
                } else if let delayTime = gifProps[kCGImagePropertyGIFDelayTime as String] as? Double {
                    delay = delayTime
                }
            }
            loadedDurations.append(max(delay, 0.05)) // Minimum 50ms
        }
        
        guard !loadedFrames.isEmpty else {
            print("❌ [GIF] No frames loaded")
            return
        }
        
        frames = loadedFrames
        durations = loadedDurations
        currentFrame = frames[0]
        shouldAnimate = isAnimating
        
        print("✅ [GIF] Loaded \(frames.count) frames, first frame set, isAnimating: \(isAnimating)")
        
        if isAnimating {
            print("▶️ [GIF] onAppear: Starting animation (isAnimating=true)")
            startAnimation()
        } else {
            print("⏸️ [GIF] onAppear: Not starting animation (isAnimating=false)")
        }
    }
    
    private func startAnimation() {
        guard !frames.isEmpty, frames.count > 1 else {
            print("⚠️ [GIF] Cannot animate: \(frames.count) frames")
            return
        }
        
        guard shouldAnimate else {
            print("⚠️ [GIF] Animation requested but shouldAnimate is false")
            return
        }
        
        stopAnimation() // Stop any existing animation
        
        print("▶️ [GIF] Starting animation with \(frames.count) frames, shouldAnimate: \(shouldAnimate)")
        
        // Reset to first frame
        frameIndex = 0
        currentFrame = frames[0]
        
        animationTask = Task { @MainActor in
            while !Task.isCancelled {
                // Check if still animating using state variable
                guard shouldAnimate else {
                    print("⏸️ [GIF] Animation stopped (shouldAnimate = false)")
                    break
                }
                
                let duration = durations.indices.contains(frameIndex) ? durations[frameIndex] : 0.1
                
                // Wait for frame duration
                try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                
                guard !Task.isCancelled && shouldAnimate else { 
                    print("⏸️ [GIF] Animation cancelled or shouldAnimate changed")
                    break 
                }
                
                // Advance to next frame
                frameIndex = (frameIndex + 1) % frames.count
                currentFrame = frames[frameIndex]
                
                // Debug every 10 frames
                if frameIndex % 10 == 0 {
                    print("🎬 [GIF] Frame \(frameIndex)/\(frames.count), shouldAnimate: \(shouldAnimate)")
                }
            }
            print("✅ [GIF] Animation task completed")
        }
    }
    
    private func stopAnimation() {
        print("⏹️ [GIF] Stopping animation")
        animationTask?.cancel()
        animationTask = nil
        frameIndex = 0
        if !frames.isEmpty {
            currentFrame = frames[0]
        }
    }
}

fileprivate enum HapticEvent {
    case click
    case success
}

fileprivate func playHaptic(_ event: HapticEvent) {
#if canImport(WatchKit)
    let device = WKInterfaceDevice.current()
    switch event {
    case .click:
        device.play(.click)
    case .success:
        device.play(.success)
    }
#elseif canImport(UIKit)
    switch event {
    case .click:
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.prepare()
        generator.impactOccurred(intensity: 0.7)
    case .success:
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.success)
    }
#endif
}
struct MainRunbotView: View {
    @EnvironmentObject var runTracker: RunTracker
    @EnvironmentObject var authManager: AuthenticationManager
    @EnvironmentObject var userPreferences: UserPreferences
    @EnvironmentObject var supabaseManager: SupabaseManager
    @EnvironmentObject var healthManager: HealthManager
    @StateObject private var aiCoach = AICoachManager()
    @StateObject private var voiceManager = VoiceManager()
    @StateObject private var networkMonitor = NetworkMonitor()
    
    @State private var carouselSelection: CarouselPage = .startStop
    @State private var wavePhase: Double = 0
    @State private var isRunning = false
    @State private var lastCoachingKm = 0
    @State private var didTriggerInitialCoaching = false
    @State private var showSaveSuccess = false
    @State private var saveMessage = ""
    @State private var feedbackTextDisplayUntil: Date? = nil // Track when to show feedback text (2 min after voice finishes)
    // Train mode removed - only run mode supported
    private let runMode: RunMode = .run
    
    private enum CarouselPage: Int, Hashable {
        case startStop
        case aiCoach          // AI Coach FIRST after start
        case runStats         // Combined stats
        case heartZone
        case heartZoneChart   // New page for pie chart
        case energyPulse      // ECG-style pace visualization
        case splitIntervals   // Split intervals timeline
        case connections      // Network & Workout connections
        case settings
    }
    
    private var carouselPages: [CarouselPage] {
        [.startStop, .aiCoach, .runStats, .heartZone, .heartZoneChart, .energyPulse, .splitIntervals, .connections, .settings]
    }
    
    var body: some View {
        ZStack {
            LinearGradient(
                gradient: Gradient(colors: [Color.black, Color(red: 0.05, green: 0.05, blue: 0.15)]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
                .ignoresSafeArea()
            
            // Main Carousel - Full Screen
            TabView(selection: $carouselSelection) {
                ForEach(carouselPages, id: \.self) { page in
                    pageView(for: page)
                        .tag(page)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
            
            // Success message overlay
            if showSaveSuccess {
                VStack {
                    Spacer()
                    Text(saveMessage)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.green.opacity(0.9))
                        .cornerRadius(8)
                        .shadow(radius: 4)
                        .padding(.bottom, 20)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                .ignoresSafeArea()
            }
        }
        .onChange(of: supabaseManager.tokenExpired) { oldValue, expired in
            if expired {
                print("🔴 [MainRunbotView] Token expired - logging out user")
                authManager.logout()
                supabaseManager.tokenExpired = false // Reset flag
            }
        }
        .onAppear {
            startWaveAnimation()
            // Wire Supabase manager to RunTracker for continuous saves
            runTracker.supabaseManager = supabaseManager
            
            // Initialize Supabase session if user is authenticated
            if authManager.isAuthenticated, let userId = authManager.currentUser?.id {
                print("🔵 User authenticated, initializing Supabase session")
                supabaseManager.initializeSession(for: userId)
            }
            // Train mode and PR model loading removed
        }
        .onChange(of: authManager.isAuthenticated) { oldValue, isAuth in
            if isAuth, let userId = authManager.currentUser?.id {
                print("🔵 User logged in, initializing Supabase session")
                supabaseManager.initializeSession(for: userId)
            }
        }
        // Train mode removed - no mode changes
        // Trigger scheduled coaching on first stats update and distance milestones
        // Enhanced with RAG-driven closed-loop performance analysis
        .onReceive(runTracker.$statsUpdate.compactMap { $0 }) { stats in
            // Kickoff once at run start when stats first arrive
            if isRunning && !didTriggerInitialCoaching {
                // Refresh preferences from Supabase to ensure latest language is used
                let userId = authManager.currentUser?.id ?? "watch_user"
                Task {
                    await userPreferences.refreshFromSupabase(supabaseManager: supabaseManager, userId: userId)
                    
                    await MainActor.run {
                        // Train mode removed - always use run mode
                        aiCoach.startScheduledCoaching(
                            for: stats,
                            with: userPreferences.settings,
                            voiceManager: voiceManager,
                            runSessionId: runTracker.currentSession?.id,
                            isTrainMode: false,
                            shadowData: nil,
                            healthManager: healthManager,
                            intervals: runTracker.currentSession?.intervals ?? [],
                            runStartTime: runTracker.currentSession?.startTime
                        )
                        didTriggerInitialCoaching = true
                    }
                }
            }
            let km = Int(stats.distance / 1000.0)
            let freq = userPreferences.settings.feedbackFrequency
            if freq > 0, km > lastCoachingKm, km % freq == 0 {
                // Refresh preferences from Supabase to ensure latest language is used for interval coaching
                let userId = authManager.currentUser?.id ?? "watch_user"
                Task {
                    await userPreferences.refreshFromSupabase(supabaseManager: supabaseManager, userId: userId)
                    
                    await MainActor.run {
                        // Train mode removed - always use run mode
                        // RAG-enhanced interval coaching with full performance analysis
                        aiCoach.startScheduledCoaching(
                            for: stats,
                            with: userPreferences.settings,
                            voiceManager: voiceManager,
                            runSessionId: runTracker.currentSession?.id,
                            isTrainMode: false,
                            shadowData: nil,
                            healthManager: healthManager,
                            intervals: runTracker.currentSession?.intervals ?? [],
                            runStartTime: runTracker.currentSession?.startTime
                        )
                        lastCoachingKm = km
                    }
                }
            }
        }
    }
    
    @ViewBuilder
    private func pageView(for page: CarouselPage) -> some View {
        switch page {
        case .startStop:
            startStopPage()
        case .aiCoach:
            aiCoachPageWithGIF()
        case .runStats:
            combinedStatsPage()
        case .heartZone:
            heartZonePage()
        case .heartZoneChart:
            heartZoneChartPage()
        case .energyPulse:
            energyPulseViewPage()
        case .splitIntervals:
            splitIntervalsPage()
        case .connections:
            ConnectionsView(networkMonitor: networkMonitor)
                .environmentObject(healthManager)
        case .settings:
            settingsPage()
        }
    }
    
    // MARK: - Page 0: Start/Stop Button with Mode Selector
    @ViewBuilder
    private func startStopPage() -> some View {
        ZStack {
        VStack(spacing: 16) {
            Spacer()
            
            VStack(spacing: 12) {
                Text(isRunning ? "Running" : "Ready to Run?")
                    .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white)
                
                    if !isRunning {
                    // Workout Status Indicator
                    workoutStatusIndicator()
                    } else {
                        Text("Tap to Stop")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(.gray)
                    }
            }
            
                    Spacer()
            
                // FAB Start/Stop Button - Clean circle only
                Button(action: {
                    if isRunning {
                        stopRun()
                    } else {
                        // Start run - all functionality consolidated here
                        print("🟢🟢🟢 [MainRunbotView] ========== START RUN TAPPED ==========")
                        print("🟢 [MainRunbotView] Thread: \(Thread.isMainThread ? "Main" : "Background")")
                        print("🟢 [MainRunbotView] HealthManager: available")
                        print("🟢 [MainRunbotView] RunTracker: available")
                        
                        // Reset all state for new run (clear previous run data)
                        didTriggerInitialCoaching = false
                        lastCoachingKm = 0
                        
                        // Start run tracker (creates session, starts location, starts HR monitoring)
                        // This resets intervals, distance, etc. internally
                        runTracker.startRun(mode: .run, shadowData: nil)
                        
                        // Set running state
                        isRunning = true
                        
                        // Clear any previous coaching feedback
                        aiCoach.stopCoaching()
                        voiceManager.stopSpeaking()
                        
                        print("🟢 [MainRunbotView] Run started, isRunning = true")
                        
                        // Log run UUID
                        if let session = runTracker.currentSession {
                            print("🆔 [MainRunbotView] Run started with UUID: \(session.id)")
                            
                            // Initial save to database to create the run_activities record
                            let userId = authManager.currentUser?.id ?? "watch_user"
                            Task {
                                print("💾 [MainRunbotView] Creating initial run_activities record: \(session.id)")
                                let success = await supabaseManager.saveRunActivity(session, userId: userId, healthManager: healthManager)
                                print(success ? "✅ [MainRunbotView] Initial run record created" : "❌ [MainRunbotView] Failed to create initial run record")
                            }
                        }
                        
                        // Kick off an initial AI coaching prompt shortly after start
                        let stats = runTracker.getCurrentStats() ?? RunningStatsUpdate(
                            distance: 0,
                            pace: 0,
                            avgSpeed: 0,
                            calories: 0,
                            elevation: 0,
                            maxSpeed: 0,
                            minSpeed: 0,
                            currentLocation: nil
                        )
                        didTriggerInitialCoaching = true
                        
                        // Refresh preferences from Supabase before starting coaching to ensure latest language/preferences
                        let userId = authManager.currentUser?.id ?? "watch_user"
                        Task {
                            await userPreferences.refreshFromSupabase(supabaseManager: supabaseManager, userId: userId)
                            
                            await MainActor.run {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                                    // START-OF-RUN COACHING (personalized welcome)
                                    // This also initializes RAG cache with preferences, language, Mem0 for the entire run
                                    // NOW INCLUDES RAG PERFORMANCE ANALYSIS + ADAPTIVE COACH RAG
                                    // Preferences are refreshed from Supabase to ensure latest language is used
                                    aiCoach.startOfRunCoaching(
                                        for: stats,
                                        with: userPreferences.settings,
                                        voiceManager: voiceManager,
                                        runSessionId: runTracker.currentSession?.id,
                                        runnerName: userPreferences.runnerName,
                                        healthManager: healthManager,
                                        runStartTime: runTracker.currentSession?.startTime
                                    )
                                }
                            }
                        }
                        
                        // Note: Interval coaching is triggered by distance milestones
                        // See onReceive(runTracker.$statsUpdate) below (every N km based on feedbackFrequency)
                        
                        print("🟢🟢🟢 [MainRunbotView] ========== START RUN COMPLETE ==========")
                    }
                }) {
                        Circle()
                            .fill(
                                LinearGradient(
                                gradient: Gradient(colors: isRunning ?
                                    [Color(red: 0.8, green: 0.2, blue: 0.2), Color(red: 0.7, green: 0.1, blue: 0.1)] :
                                        [Color(red: 0.2, green: 0.8, blue: 0.4), Color(red: 0.1, green: 0.7, blue: 0.3)]),
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                        .frame(width: 80, height: 80)
                        .overlay(
                            Image(systemName: isRunning ? "stop.fill" : "play.fill")
                                .font(.system(size: 32, weight: .bold))
                                .foregroundColor(.white)
                        )
                        .shadow(color: isRunning ? Color.red.opacity(0.6) : Color.green.opacity(0.6), radius: 15, y: 5)
                }
                
                Spacer()
            }
        }
    }
    
    // MARK: - Page 1: AI Coach with Feedback Text Below
    @ViewBuilder
    private func aiCoachingFeedbackPage() -> some View {
        VStack(spacing: 8) {
				// Voice wave animation (only when actually speaking)
				if voiceManager.isSpeaking {
					VoiceWaveView(isActive: voiceManager.isSpeaking, phase: wavePhase)
                    .frame(height: 50)
                    .padding(.top, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                Spacer().frame(height: 8)
                }
                
            // AI Coach Image with pulsing rings - clean, no background
                ZStack {
                    if aiCoach.isCoaching || voiceManager.isSpeaking {
                        PulsingRings(isActive: true)
                        .frame(width: 120, height: 120)
                            .transition(.scale(scale: 0.9).combined(with: .opacity))
                    }
                
                ZStack {
                    // Black background to replace white with transparent effect
                    Circle()
                        .fill(Color.black)
                        .frame(width: 80, height: 80)
                    
                Image("ai_coach")
                    .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 80, height: 80)
                        .blendMode(.screen) // Makes white transparent, keeps colors
                        .clipShape(Circle())
                }
                .shadow(color: Color.cyan.opacity(0.7), radius: 10)
                .offset(y: (aiCoach.isCoaching || voiceManager.isSpeaking) ? sin(wavePhase * 0.12) * 3 : 0)
                .rotationEffect(.degrees((voiceManager.isSpeaking ? sin(wavePhase * 0.3) * 1.5 : 0)))
                .scaleEffect((aiCoach.isCoaching || voiceManager.isSpeaking) ? 1.15 : 1.0)
                    .animation(
                            (aiCoach.isCoaching || voiceManager.isSpeaking) ?
                                Animation.easeInOut(duration: 0.55).repeatForever(autoreverses: true) :
                            Animation.easeInOut(duration: 0.3),
                            value: aiCoach.isCoaching || voiceManager.isSpeaking
                    )
            }
            .padding(.vertical, 8)
            
            // Coaching feedback text below - scrollable
            ScrollView {
                Text(aiCoach.currentFeedback.isEmpty ? "AI coaching will appear here..." : aiCoach.currentFeedback)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(.white.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 6)
    }
    
    // MARK: - 🤖 AI Coach Page with GIF (Next-Gen)
    @ViewBuilder
    private func aiCoachPageWithGIF() -> some View {
        // Use @ObservedObject to ensure updates
        let isSpeaking = voiceManager.isSpeaking
        let isActive = aiCoach.isCoaching || isSpeaking
        let feedbackText = aiCoach.currentFeedback
        
        ZStack {
            // Background glow when active
            if isActive {
                RadialGradient(
                    colors: [Color.rbSecondary.opacity(0.2), Color.clear],
                    center: .center,
                    startRadius: 30,
                    endRadius: 120
                )
                .ignoresSafeArea()
            }
            
                VStack(spacing: 6) {
                // Voice wave animation (only when actually speaking)
                if isSpeaking {
                    VoiceWaveView(isActive: isSpeaking, phase: wavePhase)
                        .frame(height: 40)
                        .padding(.top, 6)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    } else {
                    Spacer().frame(height: 6)
                }
                
                // GIF Avatar with elegant pulsating animation
                ZStack {
                    // Single elegant pulsating glow (smooth and refined)
                    if isSpeaking {
                            Circle()
                            .fill(
                                RadialGradient(
                                    colors: [
                                        Color.rbAccent.opacity(0.5),
                                        Color.rbSecondary.opacity(0.3),
                                        Color.clear
                                    ],
                                    center: .center,
                                    startRadius: 40,
                                    endRadius: 65
                                )
                            )
                            .frame(width: 130, height: 130)
                            .scaleEffect(1.0 + sin(wavePhase * 0.1) * 0.2)
                            .opacity(0.5 + sin(wavePhase * 0.12) * 0.3)
                            .blur(radius: 8)
                    }
                    
                    // AI Coach GIF
                    ZStack {
                        // Background circle
                        Circle()
                            .fill(Color.black)
                            .frame(width: 90, height: 90)
                        
                        // GIF animation (plays ONLY when speaking)
                        GIFImage(name: "ai_coach", isAnimating: isSpeaking)
                            .frame(width: 90, height: 90)
                            .clipShape(Circle())
                            .blendMode(.screen)
                    }
                    .shadow(color: isSpeaking ? .rbAccent.opacity(0.4) : .clear, radius: 12)
                }
                .padding(.top, 4)
                .onChange(of: isSpeaking) { oldValue, speaking in
                    print("🎤 [AI Coach Page] Speaking state changed: \(speaking)")
                    if speaking {
                        print("▶️ [AI Coach] Starting GIF animation and voice wave")
                        // Clear feedback text timer when speaking starts
                        feedbackTextDisplayUntil = nil
                    } else {
                        print("⏹️ [AI Coach] Stopping GIF animation and voice wave")
                        // When voice finishes, show text for 2 minutes
                        if !aiCoach.currentFeedback.isEmpty {
                            feedbackTextDisplayUntil = Date().addingTimeInterval(120.0) // 2 minutes
                            print("📝 [AI Coach] Will show feedback text until: \(feedbackTextDisplayUntil?.description ?? "nil")")
                        }
                    }
                }
                
                // Speaking indicator
                if isSpeaking {
                    HStack(spacing: 4) {
                        ForEach(0..<5, id: \.self) { i in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(LinearGradient(colors: [.rbAccent, .rbSecondary], startPoint: .bottom, endPoint: .top))
                                .frame(width: 3, height: 6 + sin(wavePhase * 0.25 + Double(i) * 0.6) * 5)
                        }
                        Text("Speaking")
                        .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.rbAccent)
                    }
                    .padding(.top, 4)
                } else if isActive {
                    Text("AI Coach Active")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.rbSecondary)
                        .padding(.top, 4)
                }
                
                // Feedback text (show for 2 minutes after voice finishes, then show icon)
                if let displayUntil = feedbackTextDisplayUntil, Date() < displayUntil, !feedbackText.isEmpty {
                    // Show feedback text for 2 minutes after voice finishes
                    ScrollView {
                        Text(feedbackText)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.9))
                            .multilineTextAlignment(.center)
                            .lineSpacing(3)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                    }
                    .frame(maxHeight: .infinity)
                    .transition(.opacity)
                } else if feedbackText.isEmpty {
                    // No feedback yet
                    ScrollView {
                        Text(isRunning ? "Waiting for feedback..." : "Start a run for AI coaching")
                            .font(.system(size: 11, weight: .regular))
                            .foregroundColor(.white.opacity(0.4))
                            .multilineTextAlignment(.center)
                            .lineSpacing(3)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                    }
                    .frame(maxHeight: .infinity)
                } else {
                    // 2 minutes passed, show icon instead of text
                    Spacer()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - 📊 Combined Stats Page
    @ViewBuilder
    private func combinedStatsPage() -> some View {
        let distance = runTracker.statsUpdate?.distance ?? 0
        let duration = runTracker.currentSession?.duration ?? 0
        let currentPace = runTracker.statsUpdate?.pace ?? 0
        let avgPace = paceFromAvgSpeed(runTracker.statsUpdate?.avgSpeed ?? 0)
        let targetPace = userPreferences.settings.targetPaceMinPerKm
        let currentPaceClr = paceStatusColor(currentPace, target: targetPace)
        let avgPaceClr = paceStatusColor(avgPace, target: targetPace)
        
        // Calculate pace difference for dynamic effects
        let paceDiff = currentPace > 0 && avgPace > 0 ? currentPace - avgPace : 0
        let isFaster = paceDiff < -0.1
        let isSlower = paceDiff > 0.1
        
        VStack(spacing: 4) {
            // Beautiful Dual Pace Visualization with Enhanced Circles
            HStack(spacing: 8) {
                // Current Pace - Left (Beautiful Circle with min/km label)
                ZStack {
                    // Outer glow ring with animated pulse
                    Circle()
                        .stroke(
                            LinearGradient(
                                colors: [
                                    currentPaceClr.opacity(0.6),
                                    currentPaceClr.opacity(0.3),
                                    currentPaceClr.opacity(0.6)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 3
                        )
                        .frame(width: 92, height: 92)
                        .shadow(color: currentPaceClr.opacity(0.5), radius: 6)
                    
                    // Middle ring with gradient
                    Circle()
                        .stroke(
                            LinearGradient(
                                colors: [
                                    currentPaceClr.opacity(0.4),
                                    currentPaceClr.opacity(0.2)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 2
                        )
                        .frame(width: 86, height: 86)
                    
                    // Inner background circle with color-coded gradient based on target pace deviation
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    paceCircleBackgroundColor(currentPace, target: targetPace),
                                    paceCircleBackgroundColor(currentPace, target: targetPace).opacity(0.6),
                                    paceCircleBackgroundColor(currentPace, target: targetPace).opacity(0.3)
                                ],
                                center: .center,
                                startRadius: 0,
                                endRadius: 43
                            )
                        )
                        .frame(width: 80, height: 80)
                    
                    // Content
                    VStack(spacing: 1) {
                        Text(formatPace(currentPace))
                            .font(.system(size: 28, weight: .black, design: .rounded))
                            .foregroundColor(.white)
                            .shadow(color: .black.opacity(0.8), radius: 3, x: 0, y: 1)
                        
                        Text("min/km")
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .foregroundColor(currentPaceClr.opacity(0.9))
                            .tracking(0.3)
                        
                        Text("RT")
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .foregroundColor(.white.opacity(0.7))
                            .tracking(0.5)
                    }
                }
                .frame(width: 92, height: 92)
                
                // Average Pace - Right (Beautiful Circle with min/km label)
                ZStack {
                    // Outer glow ring with animated pulse
                    Circle()
                        .stroke(
                            LinearGradient(
                                colors: [
                                    avgPaceClr.opacity(0.6),
                                    avgPaceClr.opacity(0.3),
                                    avgPaceClr.opacity(0.6)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 3
                        )
                        .frame(width: 92, height: 92)
                        .shadow(color: avgPaceClr.opacity(0.5), radius: 6)
                    
                    // Middle ring with gradient
                    Circle()
                        .stroke(
                            LinearGradient(
                                colors: [
                                    avgPaceClr.opacity(0.4),
                                    avgPaceClr.opacity(0.2)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 2
                        )
                        .frame(width: 86, height: 86)
                    
                    // Inner background circle with color-coded gradient based on target pace deviation
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    paceCircleBackgroundColor(avgPace, target: targetPace),
                                    paceCircleBackgroundColor(avgPace, target: targetPace).opacity(0.6),
                                    paceCircleBackgroundColor(avgPace, target: targetPace).opacity(0.3)
                                ],
                                center: .center,
                                startRadius: 0,
                                endRadius: 43
                            )
                        )
                        .frame(width: 80, height: 80)
                    
                    // Content
                    VStack(spacing: 1) {
                        Text(formatPace(avgPace))
                            .font(.system(size: 28, weight: .black, design: .rounded))
                            .foregroundColor(.white)
                            .shadow(color: .black.opacity(0.8), radius: 3, x: 0, y: 1)
                        
                        Text("min/km")
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .foregroundColor(avgPaceClr.opacity(0.9))
                            .tracking(0.3)
                        
                        Text("AVG")
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .foregroundColor(.white.opacity(0.7))
                            .tracking(0.5)
                    }
                }
                .frame(width: 92, height: 92)
            }
            .padding(.top, 6)
            .padding(.horizontal, 4)
            
            // Pace Comparison Indicator
            if currentPace > 0 && avgPace > 0 {
                HStack(spacing: 4) {
                    if isFaster {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.rbSuccess)
                        Text("Faster")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.rbSuccess)
                    } else if isSlower {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.rbWarning)
                        Text("Slower")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.rbWarning)
                    } else {
                        Image(systemName: "equal.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.rbAccent)
                        Text("Steady")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.rbAccent)
                    }
                }
                .padding(.vertical, 2)
            }
            
            // Distance | Time row (compact)
            HStack(spacing: 0) {
                VStack(spacing: 1) {
                    Text(formatDistanceKm(distance))
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    Text("KM")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.rbAccent)
                }
                .frame(maxWidth: .infinity)
                
                Rectangle()
                    .fill(LinearGradient(colors: [.rbAccent.opacity(0.1), .rbSecondary.opacity(0.3), .rbAccent.opacity(0.1)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 1, height: 24)
                
                VStack(spacing: 1) {
                    Text(formatElapsedMinutes(duration))
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    Text("MIN")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.rbSecondary)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.top, 4)
            
            // Target Pace (compact at bottom)
            HStack(spacing: 4) {
                Image(systemName: "target")
                    .font(.system(size: 12))
                    .foregroundColor(.rbWarning.opacity(0.7))
                Text("Target:")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white.opacity(0.6))
                Text(formatPace(targetPace))
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                    .foregroundColor(.rbWarning)
            }
            .padding(.top, 2)
            .padding(.bottom, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private func paceStatusColor(_ pace: Double, target: Double) -> Color {
        guard pace > 0, target > 0 else { return .rbAccent }
        let deviation = ((pace - target) / target) * 100
        if abs(deviation) <= 5 { return .rbSuccess }
        else if deviation < -5 { return .rbAccent }
        else if deviation <= 10 { return .rbWarning }
        else { return .rbError }
    }
    
    // Calculate background color for pace circle based on % deviation from target
    private func paceCircleBackgroundColor(_ pace: Double, target: Double) -> Color {
        guard pace > 0, target > 0 else { return Color.green.opacity(0.2) }
        
        // Calculate % deviation: negative means faster, positive means slower
        let deviation = ((pace - target) / target) * 100
        
        if deviation <= 0 {
            // Faster than or equal to target pace
            if deviation <= -20 {
                // Faster by >20% = brighter green
                return Color.green.opacity(0.35)
            } else {
                // Faster or equal = green
                return Color.green.opacity(0.25)
            }
        } else {
            // Slower than target pace
            if deviation > 10 {
                // Slower by >10% = red
                return Color.red.opacity(0.25)
            } else {
                // Slower by <=10% = yellow
                return Color.yellow.opacity(0.25)
            }
        }
    }
    
    private func formatElapsed(_ seconds: TimeInterval) -> String {
        let totalMinutes = Int(seconds / 60)
        return String(format: "%02d:%02d", totalMinutes, Int(seconds.truncatingRemainder(dividingBy: 60)))
    }
    
    private func formatElapsedMinutes(_ seconds: TimeInterval) -> String {
        let totalMinutes = Int(seconds / 60)
        return "\(totalMinutes) min"
    }
    
    private func formatDistanceKm(_ meters: Double) -> String {
        let km = meters / 1000.0
        if km >= 100 {
            return String(format: "%.1f", km)
        } else if km >= 10 {
            return String(format: "%.2f", km)
        } else {
            return String(format: "%.2f", km)
        }
    }
    
    // MARK: - ❤️ Heart Zone Page
    @ViewBuilder
    private func heartZonePage() -> some View {
        // Force refresh by observing published properties
        let _ = healthManager.currentHeartRate
        let _ = healthManager.currentZone
        let _ = healthManager.zonePercentages
        let _ = healthManager.adaptiveGuidance
        
        VStack(spacing: 6) {
            Text("Heart Zones")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.rbAccent)
                .padding(.top, 8)
            
            // HR Data Status Indicator
            hrStatusIndicator()
                .padding(.top, 2)
            
            if isRunning {
                let currentHR = healthManager.currentHeartRate
                let currentZone = healthManager.currentZone
                let _ = healthManager.zonePercentages
                let adaptiveGuidance = healthManager.adaptiveGuidance
                
                // Beautiful Heart Rate Display (No Circle)
                VStack(spacing: 8) {
                    // Heart icon with pulsing animation
                        Image(systemName: "heart.fill")
                        .font(.system(size: 24))
                            .foregroundColor(currentZone != nil ? HeartZoneCalculator.zoneColor(for: currentZone!) : .rbError)
                        .scaleEffect(1.0 + sin(wavePhase * 0.2) * 0.15)
                        .shadow(color: (currentZone != nil ? HeartZoneCalculator.zoneColor(for: currentZone!) : .rbError).opacity(0.6), radius: 8)
                        
                    // Large HR value (reduced size for more space for heart zone)
                        if let hr = currentHR {
                            Text("\(Int(hr))")
                            .font(.system(size: 42, weight: .black, design: .rounded))
                            .foregroundColor(.white)
                            .shadow(color: .white.opacity(0.3), radius: 4)
                    } else {
                        Text("--")
                            .font(.system(size: 42, weight: .black, design: .rounded))
                                .foregroundColor(.white.opacity(0.5))
                        }
                        
                    // BPM label (reduced size)
                        Text("BPM")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundColor(.white.opacity(0.6))
                    }
                .padding(.vertical, 12)
                    
                // Beautiful Color-Coded Zone Badge
                if let zone = currentZone {
                    HStack(spacing: 8) {
                        // Zone color indicator
                        RoundedRectangle(cornerRadius: 4)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        HeartZoneCalculator.zoneColor(for: zone),
                                        HeartZoneCalculator.zoneColor(for: zone).opacity(0.7)
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: 6, height: 32)
                            .shadow(color: HeartZoneCalculator.zoneColor(for: zone).opacity(0.5), radius: 4)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("ZONE \(zone)")
                                .font(.system(size: 14, weight: .black, design: .rounded))
                                .foregroundColor(HeartZoneCalculator.zoneColor(for: zone))
                            
                            Text(HeartZoneCalculator.zoneName(for: zone))
                                .font(.system(size: 18, weight: .bold, design: .rounded))
                                .foregroundColor(.white)
                        }
                        
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.white.opacity(0.08))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(
                                        LinearGradient(
                                            colors: [
                                                HeartZoneCalculator.zoneColor(for: zone).opacity(0.4),
                                                HeartZoneCalculator.zoneColor(for: zone).opacity(0.1)
                                            ],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        ),
                                        lineWidth: 1.5
                                    )
                            )
                    )
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill(HeartZoneCalculator.zoneColor(for: zone).opacity(0.15))
                    )
                    .padding(.top, 2)
                }
                
                // Adaptive Guidance (KEY FEATURE!)
                if !adaptiveGuidance.isEmpty {
                    Text(adaptiveGuidance)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.rbAccent)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.rbAccent.opacity(0.1))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.rbAccent.opacity(0.3), lineWidth: 1)
                                )
                        )
                        .padding(.top, 2)
                }
                
                // Show HR status if no data
                if currentHR == nil {
                    VStack(spacing: 4) {
                    Text("Waiting for heart rate...")
                        .font(.system(size: 8))
                        .foregroundColor(.white.opacity(0.3))
                        
                        // Show HR status error if applicable
                        if case .error(let msg) = healthManager.hrDataStatus {
                            Text("Error: \(msg)")
                                .font(.system(size: 7))
                                .foregroundColor(.red)
                                .multilineTextAlignment(.center)
                        }
                    }
                        .padding(.top, 2)
                }
                
            } else {
                    Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 32))
                    .foregroundColor(.rbSecondary.opacity(0.4))
                Text("Start running to track")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.3))
                    
                    // Show HR status when not running
                    hrStatusIndicator()
                        .padding(.top, 4)
                }
                    Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            // Real-time refresh every 2 seconds for heart rate display
            Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
                // Force UI refresh
                let _ = healthManager.currentHeartRate
                let _ = healthManager.currentZone
            }
        }
    }
    
    // MARK: - ❤️ Heart Zone Chart Page (Pie Chart)
    @State private var chartRefreshTimer: Timer?
    
    private func heartZoneChartPage() -> some View {
        // Force refresh by observing published properties
        let _ = healthManager.zonePercentages
        let _ = healthManager.currentZone
        let _ = healthManager.currentHeartRate
        
        // Calculate pie chart data (must be outside ViewBuilder)
        let zonePercentages = healthManager.zonePercentages
        let zones = [1, 2, 3, 4, 5]
        let total = zonePercentages.values.reduce(0.0, +)
        var angles: [(zone: Int, start: Double, end: Double)] = []
        var currentStart: Double = -90
        for zone in zones {
            let percentage = zonePercentages[zone] ?? 0.0
            if percentage > 0 && total > 0 {
                let angle = (percentage / total) * 360.0
                angles.append((zone: zone, start: currentStart, end: currentStart + angle))
                currentStart += angle
            }
        }
        
        return VStack(spacing: 6) {
            // Elegant header with gradient
            Text("ZONE TIME")
                .font(.system(size: 16, weight: .black, design: .rounded))
                .tracking(1.5)
                .foregroundStyle(LinearGradient(colors: [.rbAccent, .rbSecondary], startPoint: .leading, endPoint: .trailing))
                .padding(.top, 6)
            
            if isRunning {
                // Show chart if we have data, or show "collecting data" message
                if !zonePercentages.isEmpty && !angles.isEmpty && total > 0 {
                // Beautiful Donut Chart with % on Segments (reduced size)
                ZStack {
                    // Outer glow ring
                    Circle()
                        .stroke(
                            LinearGradient(
                                colors: [.rbAccent.opacity(0.3), .rbSecondary.opacity(0.2)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 2
                        )
                        .frame(width: 120, height: 120)
                        .blur(radius: 2)
                    
                    // Pie segments with gradient fills and percentage labels
                    ForEach(angles, id: \.zone) { angleData in
                        let percentage = zonePercentages[angleData.zone] ?? 0.0
                        let midAngle = angleData.start + (angleData.end - angleData.start) / 2.0
                        let labelRadius: CGFloat = 32 // Position label on segment (reduced for smaller chart)
                        let labelX = 60 + CGFloat(cos(midAngle * .pi / 180.0)) * labelRadius
                        let labelY = 60 + CGFloat(sin(midAngle * .pi / 180.0)) * labelRadius
                        
                        ZStack {
                            // Segment path
                            Path { path in
                                path.move(to: CGPoint(x: 60, y: 60))
                                path.addArc(
                                    center: CGPoint(x: 60, y: 60),
                                    radius: 52, // Reduced radius for smaller chart
                                    startAngle: Angle(degrees: angleData.start),
                                    endAngle: Angle(degrees: angleData.end),
                                    clockwise: false
                                )
                                path.closeSubpath()
                            }
                            .fill(
                                LinearGradient(
                                    colors: [
                                        HeartZoneCalculator.zoneColor(for: angleData.zone),
                                        HeartZoneCalculator.zoneColor(for: angleData.zone).opacity(0.7)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .shadow(color: HeartZoneCalculator.zoneColor(for: angleData.zone).opacity(0.5), radius: 4, x: 0, y: 2)
                            
                            // Large percentage label on segment
                            if percentage >= 5.0 { // Only show if segment is large enough
                                Text(String(format: "%.0f%%", percentage))
                                    .font(.system(size: 18, weight: .black, design: .rounded)) // Reduced font size
                                    .foregroundColor(.white)
                                    .shadow(color: .black.opacity(0.8), radius: 3, x: 1, y: 1)
                                    .shadow(color: HeartZoneCalculator.zoneColor(for: angleData.zone).opacity(0.5), radius: 2)
                                    .position(x: labelX, y: labelY)
                            }
                        }
                    }
                    
                    // Center donut hole with gradient
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [Color.black.opacity(0.95), Color.black],
                                center: .center,
                                startRadius: 5,
                                endRadius: 28 // Reduced for smaller chart
                            )
                        )
                        .frame(width: 56, height: 56) // Reduced center hole
                    
                    // Center current zone indicator
                    VStack(spacing: 2) {
                        if let currentZone = healthManager.currentZone {
                            Text("Z\(currentZone)")
                                .font(.system(size: 20, weight: .black, design: .rounded)) // Reduced font
                                .foregroundColor(HeartZoneCalculator.zoneColor(for: currentZone))
                                .shadow(color: HeartZoneCalculator.zoneColor(for: currentZone).opacity(0.5), radius: 4)
        } else {
                            Text("—")
                                .font(.system(size: 18, weight: .bold)) // Reduced font
                                .foregroundColor(.white.opacity(0.5))
                        }
                    }
                }
                .frame(width: 120, height: 120) // Reduced chart size
                .padding(.vertical, 8)
                
                // Zone Legend (small, compact)
                HStack(spacing: 8) {
                    ForEach([1, 2, 3, 4, 5], id: \.self) { zone in
                        if let percentage = zonePercentages[zone], percentage > 0 {
                            HStack(spacing: 3) {
                                Circle()
                                    .fill(HeartZoneCalculator.zoneColor(for: zone))
                                    .frame(width: 6, height: 6)
                                Text("Z\(zone)")
                                    .font(.system(size: 8, weight: .semibold))
                                    .foregroundColor(.white.opacity(0.7))
                            }
                        }
                    }
                }
                .padding(.top, 4)
                } else {
                    // Data is being collected - show loading state
                Spacer()
                    VStack(spacing: 8) {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .rbAccent))
                            .scaleEffect(1.2)
                        
                        Text("Collecting zone data...")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.5))
                        
                        if let hr = healthManager.currentHeartRate {
                            Text("\(Int(hr)) BPM")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.rbAccent)
                        }
                    }
                    Spacer()
                }
            } else {
                Spacer()
                Image(systemName: "chart.pie.fill")
                    .font(.system(size: 32))
                    .foregroundColor(.rbSecondary.opacity(0.4))
                Text("Start running to see zones")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.3))
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            // Real-time refresh every 5 seconds (matches HealthManager update interval)
            chartRefreshTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
                // Force UI refresh by accessing published properties
                let _ = healthManager.zonePercentages
                let _ = healthManager.currentZone
            }
        }
        .onDisappear {
            chartRefreshTimer?.invalidate()
            chartRefreshTimer = nil
        }
    }
    
    // Train mode visualization removed - only run mode now
    
    // MARK: - ⚡ Energy Pulse View (ECG-style pace) - Next-Gen
    @ViewBuilder
    private func energyPulseViewPage() -> some View {
        if isRunning {
            VStack(spacing: 4) {
                // Header - compact
                Text("ENERGY")
                    .font(.system(size: 17, weight: .black, design: .rounded))
                    .tracking(2)
                    .foregroundStyle(LinearGradient(colors: [.rbAccent, .rbSecondary], startPoint: .leading, endPoint: .trailing))
                    .padding(.top, 4)
                
                // Waveform visualization - takes most of the space
                    EnhancedEnergyWaveform(
                        paceHistory: runTracker.paceHistory,
                        currentPace: runTracker.statsUpdate?.pace ?? 0,
                        targetPace: userPreferences.settings.targetPaceMinPerKm,
                    phase: wavePhase
                )
                .frame(height: 110)
                .padding(.horizontal, 4)
                .padding(.vertical, 6)
                
                // Compact stats row - minimal space
                HStack(spacing: 8) {
                    VStack(spacing: 0) {
                                Text("PACE")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.white.opacity(0.5))
                                Text(formatPace(runTracker.statsUpdate?.pace ?? 0))
                            .font(.system(size: 18, weight: .bold, design: .monospaced))
                            .foregroundColor(.rbAccent)
                    }
                    
                    VStack(spacing: 0) {
                        Text("DIST")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.white.opacity(0.5))
                        Text(String(format: "%.2f", (runTracker.statsUpdate?.distance ?? 0) / 1000.0))
                            .font(.system(size: 16, weight: .bold, design: .monospaced))
                            .foregroundColor(.rbSecondary)
                    }
                    
                    VStack(spacing: 0) {
                                Text("TIME")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.white.opacity(0.5))
                                Text(formatElapsed(runTracker.currentSession?.duration ?? 0))
                            .font(.system(size: 16, weight: .bold, design: .monospaced))
                            .foregroundColor(.white.opacity(0.7))
                    }
                }
                .padding(.bottom, 4)
                
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // Placeholder
            VStack(spacing: 12) {
                Spacer()
                ZStack {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [Color.rbAccent.opacity(0.2), Color.clear],
                                center: .center,
                                startRadius: 10,
                                endRadius: 40
                            )
                        )
                        .frame(width: 80, height: 80)
                    
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 32))
                        .foregroundColor(.rbAccent.opacity(0.5))
                }
                Text("Energy Pulse")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white.opacity(0.5))
                Text("Start running to see\npace energy waveform")
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.3))
                    .multilineTextAlignment(.center)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    
    // MARK: - Split Intervals Page
    @ViewBuilder
    private func splitIntervalsPage() -> some View {
        // Only show intervals that have been completed (i.e., intervals that exist in the array)
        // Intervals are only added to the array when a full 1km is completed
        let allIntervals = runTracker.currentSession?.intervals ?? []
        let currentDistance = runTracker.statsUpdate?.distance ?? 0.0 // Current distance in meters
        
        // Filter: only show intervals that are actually complete
        // - Interval must have valid data (distance >= 900m, positive pace and duration)
        // - Interval must be within the current distance (don't show future intervals)
        // - Intervals are created when 1km is complete, so any valid interval is complete
        // - Only show intervals that have realistic pace values (pace > 0 and <= 30 min/km)
        let completeIntervals = allIntervals.filter { interval in
            let intervalEndDistance = Double(interval.index + 1) * 1000.0 // km index + 1 = end distance in meters
            return interval.distanceMeters >= 900.0 && // Interval is actually ~1km (allow some tolerance)
                   interval.paceMinPerKm > 0 && // Valid pace (must be positive)
                   interval.paceMinPerKm <= 30.0 && // Reasonable max pace (30 min/km for walking/slow jog)
                   interval.durationSeconds > 0 && // Valid duration
                   intervalEndDistance <= currentDistance + 50.0 // Don't show intervals beyond current distance (50m tolerance)
        }
        let targetPace = userPreferences.settings.targetPaceMinPerKm
        
        VStack(spacing: 6) {
            // Header with title and live pace (matching iOS)
            HStack {
                Text("Split Timeline")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                
                Spacer()
                
                // Live pace indicator
                if isRunning, let currentPace = runTracker.statsUpdate?.pace, currentPace > 0 {
                    HStack(spacing: 3) {
                        Circle()
                            .fill(Color.rbAccent)
                            .frame(width: 6, height: 6)
                        Text("\(formatPace(currentPace)) /km")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(.rbAccent)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
            
            if isRunning && !completeIntervals.isEmpty {
                ScrollView {
                    VStack(spacing: 8) {
                        // Show all complete intervals in chronological order (KM 1, KM 2, KM 3...)
                        ForEach(completeIntervals, id: \.id) { interval in
                            SplitIntervalBar(
                                interval: interval,
                                targetPace: targetPace,
                                isLast: interval.id == completeIntervals.last?.id
                            )
                        }
                        
                        // Average of all complete intervals
                        if completeIntervals.count > 0 {
                            let avgPace = completeIntervals.map { $0.paceMinPerKm }.reduce(0, +) / Double(completeIntervals.count)
                            SplitIntervalBar(
                                interval: RunInterval(
                                    id: "average",
                                    runId: runTracker.currentSession?.id ?? "",
                                    index: -1,
                                    startTime: Date(),
                                    endTime: Date(),
                                    distanceMeters: Double(completeIntervals.count) * 1000.0,
                                    durationSeconds: completeIntervals.map { $0.durationSeconds }.reduce(0, +),
                                    paceMinPerKm: avgPace
                                ),
                                targetPace: targetPace,
                                isAverage: true
                            )
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
            } else {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "chart.bar.fill")
                        .font(.system(size: 32))
                        .foregroundColor(.rbSecondary.opacity(0.4))
                    Text("Split Intervals")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white.opacity(0.5))
                    Text(isRunning ? (completeIntervals.isEmpty ? "Complete 1km to see splits" : "\(completeIntervals.count) km completed") : "Start running to see splits")
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.3))
                        .multilineTextAlignment(.center)
                }
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    
    // MARK: - Stats Pages (Scrollable)
    enum StatType {
        case distanceAndTime
        case paces
    }
    
    @ViewBuilder
    private func statsPage(statType: StatType) -> some View {
        VStack(spacing: 6) {
            Text("Running Stats")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.cyan)
                .padding(.top, 8)
            
            ScrollView {
                VStack(spacing: 10) {
                    switch statType {
                    case .distanceAndTime:
                        HStack(spacing: 8) {
                            StatTile(
                                title: "Distance",
                                value: formatDistanceKm(runTracker.statsUpdate?.distance ?? 0),
                                unit: "km",
                                icon: "location.fill"
                            )
                            
                            StatTile(
                                title: "Time",
                                value: formatElapsed(runTracker.currentSession?.duration ?? 0),
                                unit: "min",
                                icon: "clock.fill"
                            )
                        }
                        
                    case .paces:
                        PaceDialView(
                            currentPace: runTracker.statsUpdate?.pace ?? 0,
                            avgPace: paceFromAvgSpeed(runTracker.statsUpdate?.avgSpeed ?? 0),
                            targetPace: userPreferences.settings.targetPaceMinPerKm
                        )
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 4)
    }
    
    // MARK: - Helper Functions
    private func formatPaceFromDecimal(_ paceMinutesPerKm: Double) -> String {
        if paceMinutesPerKm <= 0 || !paceMinutesPerKm.isFinite { return "--:--" }
        let mins = Int(paceMinutesPerKm)
        let secs = Int((paceMinutesPerKm - Double(mins)) * 60)
        return String(format: "%d:%02d", mins, secs)
    }
    
    private func formatPace(_ paceMinutesPerKm: Double) -> String {
        if paceMinutesPerKm <= 0 || !paceMinutesPerKm.isFinite { return "--:--" }
        let mins = Int(paceMinutesPerKm)
        let secs = Int((paceMinutesPerKm - Double(mins)) * 60)
        return String(format: "%d:%02d", mins, secs)
    }
    
    private func paceFromAvgSpeed(_ avgSpeedKmh: Double) -> Double {
        guard avgSpeedKmh > 0 else { return 0 }
        // Convert km/h to min/km: 60 / speed
        return 60.0 / avgSpeedKmh
    }
    
    // MARK: - ⚙️ Settings Page (Elegant Watch UI)
    @ViewBuilder
    private func settingsPage() -> some View {
            ScrollView {
            VStack(spacing: 14) {
                // Header
                Text("SETTINGS")
                    .font(.system(size: 10, weight: .black, design: .rounded))
                    .tracking(2)
                    .foregroundStyle(LinearGradient(colors: [.rbAccent, .rbSecondary], startPoint: .leading, endPoint: .trailing))
                    .padding(.top, 6)
                
                // Voice AI Model
                SettingsSection(title: "VOICE AI", icon: "waveform.circle.fill", color: .rbAccent) {
                    ForEach(VoiceAIModel.allCases, id: \.self) { model in
                        SettingsRow(
                            title: model.displayName,
                            isSelected: userPreferences.settings.voiceAIModel == model,
                            color: .rbAccent
                        ) {
                            userPreferences.updateVoiceAIModel(model)
                        }
                    }
                }
                
                // Energy Level
                SettingsSection(title: "ENERGY", icon: "bolt.fill", color: .rbWarning) {
                    ForEach(CoachEnergy.allCases, id: \.self) { energy in
                        SettingsRow(
                            title: energy.rawValue,
                            isSelected: userPreferences.settings.coachEnergy == energy,
                            color: .rbWarning
                        ) {
                            userPreferences.updateEnergy(energy)
                        }
                    }
                }
                
                // Language
                SettingsSection(title: "LANGUAGE", icon: "globe", color: .rbSecondary) {
                    // Show popular languages first, rest in picker
                    let popularLangs: [SupportedLanguage] = [.english, .spanish, .french, .german, .italian, .portuguese]
                    
                    ForEach(popularLangs, id: \.self) { lang in
                        SettingsRow(
                            title: lang.displayName,
                            isSelected: userPreferences.settings.language == lang,
                            color: .rbSecondary
                        ) {
                            userPreferences.updateLanguage(lang)
                        }
                    }
                    
                    // More languages
                    NavigationLink(destination: AllLanguagesView(userPreferences: userPreferences)) {
                        HStack {
                            Text("More Languages...")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.white.opacity(0.6))
                                        Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10))
                                .foregroundColor(.rbSecondary.opacity(0.5))
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
                        }
                    }
                    
                    // Feedback Frequency
                SettingsSection(title: "FEEDBACK", icon: "message.fill", color: .rbWarning) {
                    HStack(spacing: 6) {
                        ForEach([1, 2, 5], id: \.self) { freq in
                                Button(action: { userPreferences.updateFeedbackFrequency(freq) }) {
                                Text("\(freq)km")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(userPreferences.settings.feedbackFrequency == freq ? .black : .white.opacity(0.7))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(userPreferences.settings.feedbackFrequency == freq ? Color.rbWarning : Color.white.opacity(0.1))
                                    )
                                }
                            .buttonStyle(.plain)
                            }
                        }
                    }
                    
                    // Target Pace
                SettingsSection(title: "TARGET PACE", icon: "speedometer", color: .rbSuccess) {
                        VStack(spacing: 6) {
                        // First row: 4.5, 5.0, 5.5, 6.0
                        HStack(spacing: 6) {
                            ForEach([4.5, 5.0, 5.5, 6.0], id: \.self) { pace in
                                Button(action: { userPreferences.updateTargetPace(pace) }) {
                                    Text(formatPaceFromDecimal(pace))
                                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                                        .foregroundColor(abs(userPreferences.settings.targetPaceMinPerKm - pace) < 0.01 ? .black : .white.opacity(0.7))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 6)
                                        .background(
                                            RoundedRectangle(cornerRadius: 6)
                                                .fill(abs(userPreferences.settings.targetPaceMinPerKm - pace) < 0.01 ? Color.rbSuccess : Color.white.opacity(0.1))
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        // Second row: 6.5, 7.0, 7.5, 8.0
                        HStack(spacing: 6) {
                            ForEach([6.5, 7.0, 7.5, 8.0], id: \.self) { pace in
                                Button(action: { userPreferences.updateTargetPace(pace) }) {
                                    Text(formatPaceFromDecimal(pace))
                                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                                        .foregroundColor(abs(userPreferences.settings.targetPaceMinPerKm - pace) < 0.01 ? .black : .white.opacity(0.7))
                                    .frame(maxWidth: .infinity)
                                        .padding(.vertical, 6)
                                    .background(
                                            RoundedRectangle(cornerRadius: 6)
                                                .fill(abs(userPreferences.settings.targetPaceMinPerKm - pace) < 0.01 ? Color.rbSuccess : Color.white.opacity(0.1))
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                
                // Save Button
                Button(action: saveWatchSettings) {
                    HStack(spacing: 6) {
                        Image(systemName: "icloud.and.arrow.up")
                            .font(.system(size: 12, weight: .bold))
                        Text("Save to Cloud")
                            .font(.system(size: 12, weight: .bold))
                        }
                        .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                        .background(
                        LinearGradient(colors: [.rbAccent, .rbSecondary], startPoint: .leading, endPoint: .trailing)
                        )
                        .foregroundColor(.white)
                        .cornerRadius(10)
                    }
                .buttonStyle(.plain)
                
                // Logout
                Button(action: logout) {
                    HStack(spacing: 6) {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                            .font(.system(size: 11))
                        Text("Logout")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundColor(.rbError.opacity(0.8))
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private func saveWatchSettings() {
        guard let userId = authManager.currentUser?.id else { return }
        Task {
            let success = await supabaseManager.saveWatchPreferences(userPreferences.settings, userId: userId)
            await MainActor.run {
                saveMessage = success ? "✅ Saved!" : "⚠️ Failed"
                showSaveSuccess = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    showSaveSuccess = false
                }
            }
        }
    }
    
    private func startWaveAnimation() {
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            withAnimation(.linear(duration: 0.05)) {
                wavePhase += 1
            }
        }
    }
    
    // Train mode and PR model loading removed - only run mode now
    
    // startRun() function removed - all functionality now directly in start button action
    
    private func stopRun() {
        print("🔴 [MainRunbotView] Stop Run tapped")
        
        // CRITICAL: Force final stats update BEFORE stopping to capture latest data
        print("📊 [MainRunbotView] Forcing final stats update to capture latest running data...")
        runTracker.forceFinalStatsUpdate()
        
        // GUARDRAIL 1: Stop all ongoing coaching/voice immediately
        aiCoach.stopCoaching()
        voiceManager.stopSpeaking()
        print("✅ [MainRunbotView] Ongoing AI sessions terminated")
        
        // CRITICAL: Capture session and stats AFTER final update, BEFORE stopping tracker
        // This ensures we have the absolute latest distance, pace, HR, etc.
        let sessionSnapshot = runTracker.currentSession
        let statsSnapshot = runTracker.getCurrentStats()
        
        // Log captured data for verification
        if let session = sessionSnapshot {
            print("📊 [MainRunbotView] Captured session snapshot:")
            print("   Distance: \(String(format: "%.2f", session.distance / 1000.0))km")
            print("   Duration: \(String(format: "%.1f", session.duration))s")
            print("   Pace: \(String(format: "%.2f", session.pace)) min/km")
            print("   Calories: \(Int(session.calories))")
        }
        if let stats = statsSnapshot {
            print("📊 [MainRunbotView] Captured stats snapshot:")
            print("   Distance: \(String(format: "%.2f", stats.distance / 1000.0))km")
            print("   Pace: \(String(format: "%.2f", stats.pace)) min/km")
            print("   Calories: \(Int(stats.calories))")
        }
        
        // NOW stop the tracker (this sets isRunning = false, stops location updates)
        runTracker.stopRun()
        isRunning = false
        
        // END-OF-RUN SUMMARY (personalized performance review)
        // CRITICAL: End feedback uses captured snapshot (latest stats preserved)
        // GUARDRAIL: End feedback has 40-second auto-timeout (voice AI cutoff)
        if let session = sessionSnapshot, let stats = statsSnapshot {
            print("🏁 [MainRunbotView] Triggering end-of-run feedback with latest stats:")
            print("   Distance: \(String(format: "%.2f", stats.distance / 1000.0))km")
            print("   Pace: \(String(format: "%.2f", stats.pace)) min/km")
            print("   Duration: \(String(format: "%.1f", session.duration))s")
            print("   Calories: \(Int(stats.calories))")
            print("🏁 [MainRunbotView] End feedback will auto-terminate after 40s (voice AI cutoff)")
            
            // Final save to Supabase - all three tables (save first, then trigger feedback)
            let userId = authManager.currentUser?.id ?? "watch_user"
            Task {
                print("💾 [MainRunbotView] Saving run to Supabase - run_activities, run_hr, run_intervals")
                
                // 1. Save/Update run_activities (UPSERT)
                let runSuccess = await supabaseManager.saveRunActivity(
                    session,
                    userId: userId,
                    healthManager: healthManager
                )
                print(runSuccess ? "✅ [MainRunbotView] run_activities saved" : "❌ [MainRunbotView] run_activities save failed")
                
                // 2. Save run_hr (UPSERT)
                let hrSuccess = await supabaseManager.saveRunHR(session.id, healthManager: healthManager)
                print(hrSuccess ? "✅ [MainRunbotView] run_hr saved" : "⚠️ [MainRunbotView] run_hr save skipped (no HR data)")
                
                // 3. Save run_intervals (batch UPSERT)
                if !session.intervals.isEmpty {
                    let intervalsSuccess = await supabaseManager.saveRunIntervals(session.intervals, userId: userId, healthManager: healthManager)
                    print(intervalsSuccess ? "✅ [MainRunbotView] run_intervals saved (\(session.intervals.count) intervals)" : "❌ [MainRunbotView] run_intervals save failed")
                } else {
                    print("⚠️ [MainRunbotView] No intervals to save")
                }
                
                await MainActor.run {
                    if runSuccess {
                        saveMessage = "✅ Run saved successfully!"
                        showSaveSuccess = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                            withAnimation {
                                showSaveSuccess = false
                            }
                        }
                    } else {
                        saveMessage = "⚠️ Run save failed"
                        showSaveSuccess = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                            withAnimation {
                                showSaveSuccess = false
                            }
                        }
                    }
                }
                
                // After saving, trigger end-of-run feedback immediately
                print("🏁 [MainRunbotView] Run data saved - starting end-of-run feedback")
                aiCoach.endOfRunCoaching(
                    for: stats,
                    session: session,
                    with: userPreferences.settings,
                    voiceManager: voiceManager,
                    healthManager: healthManager
                )
                
                // Stop HealthKit workout after end-of-run feedback finishes (40 seconds max)
                // Use a completion callback to detect when feedback is complete
                DispatchQueue.main.asyncAfter(deadline: .now() + 45.0) {
                    print("🛑 [MainRunbotView] Stopping HealthKit workout after end-of-run feedback")
                    healthManager.stopHeartRateMonitoring()
                    print("✅ [MainRunbotView] HealthKit workout stopped")
                }
            }
        }
    }
    
    private func logout() {
        print("🔴 [MainRunbotView] Logout tapped")
        
        // Auto-terminate coaching on logout
        if isRunning {
            stopRun()
        } else {
            aiCoach.stopCoaching()
            voiceManager.stopSpeaking()
        }
        
        authManager.logout()
    }
    
    // Train mode removed - createShadowRunData no longer needed
    
    private func savePreferencesToSupabase() {
        let userId = authManager.currentUser?.id ?? "watch_user"
        Task {
            let success = await supabaseManager.saveUserPreferences(userPreferences.settings, userId: userId)
            if success {
                print("✅ Preferences saved to Supabase")
            } else {
                print("❌ Failed to save preferences")
            }
        }
    }
    
    // MARK: - Workout Status Indicator
    @ViewBuilder
    private func workoutStatusIndicator() -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: workoutStatusIcon)
                    .font(.system(size: 10))
                    .foregroundColor(healthManager.workoutStatus.color)
                Text(healthManager.workoutStatus.displayText)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(healthManager.workoutStatus.color)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(healthManager.workoutStatus.color.opacity(0.15))
            )
        }
    }
    
    private var workoutStatusIcon: String {
        switch healthManager.workoutStatus {
        case .notStarted: return "circle"
        case .starting: return "hourglass"
        case .running: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }
    
    // MARK: - HR Status Indicator (for HR page)
    @ViewBuilder
    private func hrStatusIndicator() -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: hrStatusIcon)
                    .font(.system(size: 10))
                    .foregroundColor(healthManager.hrDataStatus.color)
                Text(healthManager.hrDataStatus.displayText)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(healthManager.hrDataStatus.color)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(healthManager.hrDataStatus.color.opacity(0.15))
            )
        }
    }
    
    private var hrStatusIcon: String {
        switch healthManager.hrDataStatus {
        case .noData: return "heart.slash"
        case .collecting: return "heart.fill"
        case .active: return "heart.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }
}

// MARK: - Pulsing Rings Bubble
struct PulsingRings: View {
	let isActive: Bool
	@State private var animate = false
	
	var body: some View {
		ZStack {
			Circle()
				.stroke(Color.cyan.opacity(0.25), lineWidth: 2)
				.scaleEffect(animate ? 1.6 : 0.8)
				.opacity(animate ? 0.0 : 0.6)
			Circle()
				.stroke(Color.cyan.opacity(0.18), lineWidth: 2)
				.scaleEffect(animate ? 2.0 : 0.8)
				.opacity(animate ? 0.0 : 0.4)
			Circle()
				.stroke(Color.cyan.opacity(0.12), lineWidth: 2)
				.scaleEffect(animate ? 2.4 : 0.8)
				.opacity(animate ? 0.0 : 0.3)
		}
		.animation(isActive ? .easeOut(duration: 1.4).repeatForever(autoreverses: false) : .default, value: animate)
		.onAppear {
			if isActive { animate = true }
		}
		.onChange(of: isActive) { _, newValue in
			animate = newValue
		}
	}
}

// MARK: - Voice Wave (Sine) Visualization
struct VoiceWaveView: View {
	let isActive: Bool
	let phase: Double
	@State private var amplitude: CGFloat = 0.0
	@State private var timerTick: Int = 0

	var body: some View {
		ZStack {
			SineWave(phase: CGFloat(phase * 0.12), amplitude: amplitude, frequency: 1.6)
				.stroke(LinearGradient(
					gradient: Gradient(colors: [Color.cyan.opacity(0.0), Color.cyan.opacity(0.9), Color.cyan.opacity(0.0)]),
					startPoint: .leading,
					endPoint: .trailing
				), lineWidth: 3)
				.blur(radius: 0.5)
			SineWave(phase: CGFloat(phase * 0.12 + .pi/3), amplitude: amplitude * 0.7, frequency: 1.6)
				.stroke(Color.cyan.opacity(0.5), lineWidth: 2)
			SineWave(phase: CGFloat(phase * 0.12 + .pi*2/3), amplitude: amplitude * 0.45, frequency: 1.6)
				.stroke(Color.cyan.opacity(0.25), lineWidth: 2)
		}
		.onAppear { if isActive { startAmplitude() } }
		.onChange(of: isActive) { _, active in
			if active { startAmplitude() } else { amplitude = 0 }
		}
		.onChange(of: timerTick) { _, _ in
			// jitter amplitude a bit to feel reactive
			guard isActive else { return }
			withAnimation(.easeInOut(duration: 0.12)) {
				amplitude = CGFloat.random(in: 10...22)
			}
		}
	}

	private func startAmplitude() {
		amplitude = 16
		// Drive small random fluctuations to mimic syllable energy
		Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { timer in
			if !isActive { timer.invalidate(); return }
			timerTick += 1
		}
	}
}

struct SineWave: Shape {
	var phase: CGFloat
	var amplitude: CGFloat
	var frequency: CGFloat

	var animatableData: AnimatablePair<CGFloat, CGFloat> {
		get { AnimatablePair(phase, amplitude) }
		set {
			phase = newValue.first
			amplitude = newValue.second
		}
	}

	func path(in rect: CGRect) -> Path {
		var path = Path()
		let midY = rect.midY
		let width = rect.width
		let twoPi = CGFloat.pi * 2
		let step: CGFloat = 1
		var x: CGFloat = 0
		var first = true
		while x <= width {
			let relative = x / width
			let angle = relative * twoPi * frequency + phase
			let y = midY + sin(angle) * amplitude
			if first {
				path.move(to: CGPoint(x: x, y: y))
				first = false
			} else {
				path.addLine(to: CGPoint(x: x, y: y))
			}
			x += step
		}
		return path
    }
}

// MARK: - Coaching Feedback Card
struct CoachingFeedbackCard: View {
    let title: String
    let message: String
    let icon: String
    
    var body: some View {
        ZStack {
            // Green/Blue gradient background on dark
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(
                            LinearGradient(
                                gradient: Gradient(colors: [Color.green.opacity(0.4), Color.cyan.opacity(0.4)]),
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                )
            
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(
                            LinearGradient(
                                gradient: Gradient(colors: [Color.green, Color.cyan]),
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                    
                    Text(title)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(
                            LinearGradient(
                                gradient: Gradient(colors: [Color.green, Color.cyan]),
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                    
                    Spacer()
                }
                
                Text(message)
                    .font(.system(size: 9, weight: .regular))
                    .foregroundColor(.white.opacity(0.8))
                    .lineLimit(2)
            }
            .padding(10)
        }
        .frame(minHeight: 65)
    }
}

// MARK: - Stat Tile Component
struct StatTile: View {
    let title: String
    let value: String
    let unit: String
    let icon: String
    
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(0.85))
                .overlay(
                    LinearGradient(
                        gradient: Gradient(colors: [Color.black.opacity(0.8), Color(red: 0.05, green: 0.1, blue: 0.2)]),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.cyan.opacity(0.3), lineWidth: 1)
                )
            
            VStack(alignment: .center, spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.cyan)
                
                Text(title)
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundColor(.gray)
                
                HStack(spacing: 2) {
                    Text(value)
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundColor(.cyan)
                    
                    Text(unit)
                        .font(.system(size: 6, weight: .semibold))
                        .foregroundColor(.gray)
                }
            }
            .padding(8)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 100)
    }
}

// MARK: - Dynamic Pace View (Combined Current + Average Pace)
struct DynamicPaceView: View {
    let currentPace: Double
    let avgPace: Double
    let targetPace: Double
    
    var body: some View {
        VStack(spacing: 8) {
            // Current Pace (Large, Dynamic Color)
            VStack(spacing: 4) {
                Text("CURRENT PACE")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.gray)
                
                Text(formatPace(currentPace))
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundColor(paceColor(for: currentPace, target: targetPace))
                    .shadow(color: paceColor(for: currentPace, target: targetPace).opacity(0.5), radius: 6)
                
                Text("min/km")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(.gray)
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.black.opacity(0.6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(paceColor(for: currentPace, target: targetPace).opacity(0.4), lineWidth: 2)
                    )
            )
            
            // Average Pace (Smaller, Dynamic Color)
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 12))
                    .foregroundColor(paceColor(for: avgPace, target: targetPace))
                
                Text("AVG:")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.gray)
                
                Text(formatPace(avgPace))
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundColor(paceColor(for: avgPace, target: targetPace))
                
                Text("min/km")
                    .font(.system(size: 8))
                    .foregroundColor(.gray)
                
                Spacer()
                
                // Target indicator
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Target")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundColor(.gray)
                    Text(formatPace(targetPace))
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.cyan.opacity(0.7))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(paceColor(for: avgPace, target: targetPace).opacity(0.3), lineWidth: 1)
                    )
            )
        }
        .padding(.horizontal, 6)
    }
    
    private func paceColor(for pace: Double, target: Double) -> Color {
        guard pace > 0, target > 0 else { return .cyan }
        let deviation = abs(pace - target) / target
        
        if deviation <= 0.05 {
            // Within 5% => Green (on target)
            return .green
        } else if pace < target * 0.9 {
            // >10% faster => Darker Green
            return Color(red: 0, green: 0.6, blue: 0)
        } else if pace > target * 1.1 {
            // >10% slower => Red
            return .red
        } else if pace < target {
            // 5-10% faster => Light green
            return Color(red: 0.2, green: 0.8, blue: 0.2)
        } else {
            // 5-10% slower => Orange
            return .orange
        }
    }
    
    private func formatPace(_ paceMinutesPerKm: Double) -> String {
        if paceMinutesPerKm <= 0 || !paceMinutesPerKm.isFinite { return "--:--" }
        let mins = Int(paceMinutesPerKm)
        let secs = Int((paceMinutesPerKm - Double(mins)) * 60)
        return String(format: "%d:%02d", mins, secs)
    }
}

// MARK: - Beaming Pulse Component (Tron-style)
struct BeamingPulse: View {
    let color: Color
    let isActive: Bool
    @State private var animate = false
    
    var body: some View {
        ZStack {
            // Outer pulse rings
            Circle()
                .stroke(color.opacity(0.3), lineWidth: 2)
                .scaleEffect(animate ? 1.8 : 0.8)
                .opacity(animate ? 0.0 : 0.8)
            
            Circle()
                .stroke(color.opacity(0.2), lineWidth: 2)
                .scaleEffect(animate ? 2.2 : 0.8)
                .opacity(animate ? 0.0 : 0.6)
            
            // Center glow
            Circle()
                .fill(
                    RadialGradient(
                        gradient: Gradient(colors: [color, color.opacity(0.3), .clear]),
                        center: .center,
                        startRadius: 0,
                        endRadius: 20
                    )
                )
                .frame(width: 30, height: 30)
                .scaleEffect(animate ? 1.2 : 1.0)
        }
        .animation(isActive ? .easeOut(duration: 1.2).repeatForever(autoreverses: false) : .default, value: animate)
        .onAppear {
            if isActive { animate = true }
        }
        .onChange(of: isActive) { oldValue, newValue in
            animate = newValue
        }
    }
}

// MARK: - Energy Waveform (ECG-style)
struct EnergyWaveform: View {
    let pace: Double
    let phase: Double
    
    var body: some View {
        Canvas { context, size in
            let width = size.width
            let height = size.height
            let midY = height / 2
            
            // Calculate amplitude based on pace (faster pace = taller peaks)
            let amplitude: CGFloat = {
                if pace <= 0 { return 15 }
                // Normalize pace: 3 min/km (very fast) = 50pt, 8 min/km (slow) = 15pt
                let normalizedPace = max(3, min(8, pace))
                return CGFloat(50 - (normalizedPace - 3) * 7)
            }()
            
            // Draw ECG-style waveform with multiple layers for stellar effect
            var path = Path()
            let step: CGFloat = 1.5 // Smoother with smaller step
            var x: CGFloat = 0
            var first = true
            
            while x <= width {
                let relative = x / width
                let angle = relative * .pi * 4 + CGFloat(phase * 0.05)
                
                // ECG-style sharp peaks with more dynamic variation
                var y = midY
                let sine = sin(angle)
                let cosine = cos(angle * 0.5) // Secondary wave for complexity
                
                if sine > 0.7 {
                    // Sharp upward spike with secondary wave modulation
                    let spike = CGFloat(pow(sine, 2.5))
                    y = midY - amplitude * spike * (1.0 + cosine * 0.2)
                } else if sine < -0.7 {
                    // Small downward dip
                    y = midY + amplitude * 0.25 * CGFloat(abs(sine))
                } else {
                    // Baseline with subtle wave
                    y = midY + CGFloat(cosine) * 2
                }
                
                if first {
                    path.move(to: CGPoint(x: x, y: y))
                    first = false
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
                x += step
            }
            
            // Multi-layer glow effect for stellar appearance
            // Outer glow (widest, most transparent)
            context.stroke(
                path,
                with: .color(Color.rbSecondary.opacity(0.2)),
                style: StrokeStyle(lineWidth: 12, lineCap: .round, lineJoin: .round)
            )
            
            // Middle glow (medium)
            context.stroke(
                path,
                with: .color(Color.rbAccent.opacity(0.3)),
                style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round)
            )
            
            // Inner glow (bright)
            context.stroke(
                path,
                with: .color(Color.rbAccent.opacity(0.6)),
                style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round)
            )
            
            // Core line (brightest, most visible)
            context.stroke(
                path,
                with: .color(Color.rbAccent),
                style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
            )
            
            // Add pulsing particles at peaks
            x = 0
            while x <= width {
                let relative = x / width
                let angle = relative * .pi * 4 + CGFloat(phase * 0.05)
                let sine = sin(angle)
                
                if sine > 0.85 {
                    let y = midY - amplitude * CGFloat(pow(sine, 2.5))
                    // Draw small glowing dots at peaks
                    let particleSize: CGFloat = 3 + sin(phase * 0.1 + x * 0.1) * 1.5
                    context.fill(
                        Path(ellipseIn: CGRect(x: x - particleSize/2, y: y - particleSize/2, width: particleSize, height: particleSize)),
                        with: .color(Color.rbAccent.opacity(0.8))
                    )
                }
                x += step * 3 // Check every 3rd point for particles
            }
            
            // Subtle baseline
            let baselinePath = Path { p in
                p.move(to: CGPoint(x: 0, y: midY))
                p.addLine(to: CGPoint(x: width, y: midY))
            }
            context.stroke(baselinePath, with: .color(Color.rbAccent.opacity(0.15)), lineWidth: 0.5)
        }
    }
}

// MARK: - Enhanced Energy Waveform with Dynamic Axis
struct EnhancedEnergyWaveform: View {
    let paceHistory: [Double]
    let currentPace: Double
    let targetPace: Double
    let phase: Double
    
    var body: some View {
        Canvas { context, size in
            let width = size.width
            let height = size.height
            
            // Use real pace history if available, otherwise use current pace
            let dataPoints = paceHistory.isEmpty ? [currentPace] : paceHistory
            guard !dataPoints.isEmpty, dataPoints.allSatisfy({ $0 > 0 }) else {
                // Draw placeholder if no data
                let placeholderText = "No pace data"
                context.draw(Text(placeholderText).foregroundColor(.gray), at: CGPoint(x: width/2, y: height/2))
                return
            }
            
            // Calculate dynamic axis bounds based on actual data
            let minPace = dataPoints.min() ?? targetPace
            let maxPace = dataPoints.max() ?? targetPace
            let paceRange = max(maxPace - minPace, 1.0) // Ensure at least 1.0 range
            
            // Add padding to axis (10% on each side)
            let axisMin = max(0, minPace - paceRange * 0.1)
            let axisMax = maxPace + paceRange * 0.1
            
            // Calculate Y position for a given pace value
            let paceToY = { (pace: Double) -> CGFloat in
                guard axisMax > axisMin else { return height / 2 }
                let normalized = (pace - axisMin) / (axisMax - axisMin)
                // Invert: lower pace (faster) = higher Y, higher pace (slower) = lower Y
                return height - (CGFloat(normalized) * height * 0.8) - height * 0.1
            }
            
            // Draw dynamic axis labels
            let axisLabels = [
                axisMin,
                axisMin + (axisMax - axisMin) * 0.25,
                axisMin + (axisMax - axisMin) * 0.5,
                axisMin + (axisMax - axisMin) * 0.75,
                axisMax
            ]
            
            // Draw grid lines and labels
            for (_, labelPace) in axisLabels.enumerated() {
                let y = paceToY(labelPace)
                let gridPath = Path { path in
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: width, y: y))
                }
                context.stroke(gridPath, with: .color(Color.white.opacity(0.1)), lineWidth: 0.5)
                
                // Draw label with larger font for readability
                let labelText = String(format: "%.1f", labelPace)
                let text = Text(labelText).font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundColor(.white.opacity(0.6))
                context.draw(text, at: CGPoint(x: width - 30, y: y))
            }
            
            // Draw target pace line
            let targetY = paceToY(targetPace)
            let targetPath = Path { path in
                path.move(to: CGPoint(x: 0, y: targetY))
                path.addLine(to: CGPoint(x: width, y: targetY))
            }
            context.stroke(targetPath, with: .color(Color.rbWarning.opacity(0.5)), lineWidth: 1)
            
            // Draw pace line from history
            guard dataPoints.count > 1 else { return }
            
            var path = Path()
            let stepX = width / CGFloat(dataPoints.count - 1)
            var first = true
            
            for (index, pace) in dataPoints.enumerated() {
                let x = CGFloat(index) * stepX
                let y = paceToY(pace)
                
                if first {
                    path.move(to: CGPoint(x: x, y: y))
                    first = false
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }
            
            // Determine line color based on pace vs target
            let avgPace = dataPoints.reduce(0, +) / Double(dataPoints.count)
            let deviation = ((avgPace - targetPace) / targetPace) * 100
            let lineColor: Color = {
                if abs(deviation) <= 5 { return .rbSuccess }
                else if deviation < -10 { return .rbAccent } // Fast
                else if deviation < -5 { return Color(red: 0.0, green: 0.7, blue: 1.0) } // Slightly fast
                else if deviation <= 10 { return .rbWarning } // Slightly slow
                else { return .rbError } // Slow
            }()
            
            // Multi-layer glow effect
            context.stroke(path, with: .color(lineColor.opacity(0.2)), style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
            context.stroke(path, with: .color(lineColor.opacity(0.4)), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            context.stroke(path, with: .color(lineColor.opacity(0.7)), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            context.stroke(path, with: .color(lineColor), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            
            // Draw gradient fill under the line
            var fillPath = path
            fillPath.addLine(to: CGPoint(x: width, y: height))
            fillPath.addLine(to: CGPoint(x: 0, y: height))
            fillPath.closeSubpath()
            
            let gradient = Gradient(colors: [lineColor.opacity(0.3), lineColor.opacity(0.0)])
            context.fill(fillPath, with: .linearGradient(gradient, startPoint: CGPoint(x: width/2, y: 0), endPoint: CGPoint(x: width/2, y: height)))
            
            // Draw current pace indicator (pulsing dot at end)
            if let lastPace = dataPoints.last {
                let lastX = width - 5
                let lastY = paceToY(lastPace)
                
                // Pulsing effect
                let pulseSize = 6 + sin(phase * 0.2) * 2
                let pulsePath = Path(ellipseIn: CGRect(x: lastX - pulseSize/2, y: lastY - pulseSize/2, width: pulseSize, height: pulseSize))
                context.fill(pulsePath, with: .color(lineColor.opacity(0.5)))
                context.fill(Path(ellipseIn: CGRect(x: lastX - 3, y: lastY - 3, width: 6, height: 6)), with: .color(lineColor))
            }
        }
    }
}

// MARK: - Pace Dial (Circular Activity Ring Style)
struct PaceDialView: View {
    let currentPace: Double
    let avgPace: Double
    let targetPace: Double
    
    @State private var animatedProgress: CGFloat = 0.0
    @State private var lastPaceState: PaceState = .onPace
    
    enum PaceState {
        case faster, onPace, slightlySlow, tooSlow
    }
    
    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                // Background circle
                Circle()
                    .stroke(Color.white.opacity(0.1), lineWidth: 12)
                    .frame(width: 140, height: 140)
                
                // Colored progress ring
                Circle()
                    .trim(from: 0, to: animatedProgress)
                    .stroke(
                        ringColor,
                        style: StrokeStyle(lineWidth: 12, lineCap: .round)
                    )
                    .frame(width: 140, height: 140)
                    .rotationEffect(.degrees(-90))
                    .shadow(color: ringColor.opacity(0.6), radius: 8)
                    .animation(.easeInOut(duration: 0.5), value: animatedProgress)
                    .animation(.easeInOut(duration: 0.3), value: ringColor)
                
                // Center content
                VStack(spacing: 4) {
                    // Current pace - large
                    Text(formatPace(currentPace))
                        .font(.system(size: 28, weight: .bold, design: .monospaced))
                        .foregroundColor(ringColor)
                    
                    Text("min/km")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.gray)
                    
                    Divider()
                        .frame(width: 60)
                        .background(Color.gray.opacity(0.3))
                        .padding(.vertical, 2)
                    
                    // Average pace - smaller
                    HStack(spacing: 4) {
                        Text("Avg")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.gray)
                        Text(formatPace(avgPace))
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white.opacity(0.8))
                    }
                }
            }
            
            // Target indicator
            HStack(spacing: 4) {
                Image(systemName: "target")
                    .font(.system(size: 9))
                    .foregroundColor(.cyan.opacity(0.6))
                Text("Target: \(formatPace(targetPace))")
                    .font(.system(size: 9, weight: .regular))
                    .foregroundColor(.cyan.opacity(0.6))
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 12)
        .onAppear {
            updateProgress()
        }
        .onChange(of: currentPace) { _, _ in
            updateProgress()
            checkPaceStateChange()
        }
    }
    
    private var ringColor: Color {
        guard currentPace > 0, targetPace > 0 else { return .cyan }
        
        let deviation = ((currentPace - targetPace) / targetPace) * 100
        
        if abs(deviation) <= 5 {
            return .green // On pace ±5%
        } else if deviation < -5 {
            return .cyan // Faster than target
        } else if deviation <= 10 {
            return .orange // Slightly slow 6-10%
        } else {
            return .red // Too slow >10%
        }
    }
    
    private var paceState: PaceState {
        guard currentPace > 0, targetPace > 0 else { return .onPace }
        
        let deviation = ((currentPace - targetPace) / targetPace) * 100
        
        if abs(deviation) <= 5 {
            return .onPace
        } else if deviation < -5 {
            return .faster
        } else if deviation <= 10 {
            return .slightlySlow
        } else {
            return .tooSlow
        }
    }
    
    private func updateProgress() {
        guard currentPace > 0, targetPace > 0 else {
            animatedProgress = 0.0
            return
        }
        
        // Calculate progress based on how close to target
        let deviation = abs(currentPace - targetPace) / targetPace
        
        // Progress: 1.0 = on target, decreases as deviation increases
        // Cap at 0.2 minimum for visibility
        let progress = max(0.2, min(1.0, 1.0 - deviation))
        
        withAnimation(.easeInOut(duration: 0.5)) {
            animatedProgress = progress
        }
    }
    
    private func checkPaceStateChange() {
        let newState = paceState
        if newState != lastPaceState {
            // Gentle haptic when crossing pace boundaries
            playHaptic(.click)
            lastPaceState = newState
        }
    }
    
    private func formatPace(_ paceMinutesPerKm: Double) -> String {
        if paceMinutesPerKm <= 0 || !paceMinutesPerKm.isFinite { return "--:--" }
        let mins = Int(paceMinutesPerKm)
        let secs = Int((paceMinutesPerKm - Double(mins)) * 60)
        return String(format: "%d:%02d", mins, secs)
    }
}

// MARK: - Train Mode Race View Component
struct TrainModeRaceView: View {
    let currentDistance: Double
    let startTime: Date
    let shadowData: ShadowRunData
    let currentPace: Double
    
    @State private var animationTime: TimeInterval = 0
    @State private var displayedUserProgress: Double = 0
    @State private var previousOvertakingState: Bool = false
    
    var body: some View {
        let totalDistance = max(shadowData.prModel.distanceMeters, 1)
        let targetUserProgress = progressForDistance(currentDistance)
        let shadowCurrentPace = shadowData.prModel.averagePaceMinPerKm
        let timeDifference = shadowData.timeDifference
        
        return TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            raceTimelineContent(
                timeline: timeline,
                totalDistance: totalDistance,
                targetUserProgress: targetUserProgress,
                shadowCurrentPace: shadowCurrentPace,
                timeDifference: timeDifference
            )
        }
        .onAppear {
            displayedUserProgress = targetUserProgress
        }
        .onChange(of: currentDistance) { _, newDistance in
            let newProgress = progressForDistance(newDistance)
            withAnimation(.easeInOut(duration: 0.4)) {
                displayedUserProgress = newProgress
            }
        }
    }
    
    private func formatTime(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60
        return String(format: "%d:%02d:%02d", hours, minutes, secs)
    }
    
    private func formatPace(_ paceMinutesPerKm: Double) -> String {
        if paceMinutesPerKm <= 0 || !paceMinutesPerKm.isFinite { return "--:--" }
        let mins = Int(paceMinutesPerKm)
        let secs = Int((paceMinutesPerKm - Double(mins)) * 60)
        return String(format: "%d:%02d", mins, secs)
    }
    
    private func progressForDistance(_ distance: Double) -> Double {
        let total = shadowData.prModel.distanceMeters
        guard total > 0 else { return 0 }
        return min(max(distance / total, 0.0), 1.0)
    }
    
    private func progressForTime(_ date: Date) -> Double {
        let totalDuration = Double(max(shadowData.prModel.durationSeconds, 1))
        let elapsed = max(0, date.timeIntervalSince(startTime))
        return min(max(elapsed / totalDuration, 0.0), 1.0)
    }

    @ViewBuilder
    private func raceTimelineContent(
        timeline: TimelineViewDefaultContext,
        totalDistance: Double,
        targetUserProgress: Double,
        shadowCurrentPace: Double,
        timeDifference: Double
    ) -> some View {
        let shadowProgress = progressForTime(timeline.date)
        let userProgress = displayedUserProgress
        let userDistanceMeters = userProgress * totalDistance
        let shadowExpectedDistance = shadowProgress * totalDistance
        let distanceDiffMeters = userDistanceMeters - shadowExpectedDistance
        let isCurrentlyOvertaking = abs(distanceDiffMeters) < 10.0
        let isOverlapping = abs(userProgress - shadowProgress) < 0.02

        ZStack {
            TronGridBackground(animationTime: animationTime)

            TronRacingLanes(
                userProgress: userProgress,
                shadowProgress: shadowProgress,
                distanceDiffMeters: distanceDiffMeters,
                currentPace: currentPace,
                animationTime: animationTime,
                startTime: startTime,
                totalDistance: totalDistance
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            raceStatsOverlay(
                distanceDiffMeters: distanceDiffMeters,
                totalDistance: totalDistance,
                shadowCurrentPace: shadowCurrentPace,
                timeDifference: timeDifference
            )

            if isOverlapping {
                Rectangle()
                    .fill(
                        RadialGradient(
                            colors: [Color.white.opacity(0.4), Color.clear],
                            center: .center,
                            startRadius: 0,
                            endRadius: 100
                        )
                    )
                    .ignoresSafeArea()
                    .onAppear {
                        playHaptic(.click)
                    }
            }
        }
        .onAppear {
            animationTime = timeline.date.timeIntervalSince1970
            displayedUserProgress = targetUserProgress
        }
        .onChange(of: timeline.date) { _, newDate in
            animationTime = newDate.timeIntervalSince1970
        }
        .onChange(of: isCurrentlyOvertaking) { _, newValue in
            handleOvertakingChange(newValue)
        }
    }

    @ViewBuilder
    private func raceStatsOverlay(
        distanceDiffMeters: Double,
        totalDistance: Double,
        shadowCurrentPace: Double,
        timeDifference: Double
    ) -> some View {
        VStack {
            Spacer()

            VStack(spacing: 1) {
                distanceDifferenceRow(distanceDiffMeters: distanceDiffMeters, timeDifference: timeDifference)
                statsSummaryRow(
                    totalDistance: totalDistance,
                    shadowCurrentPace: shadowCurrentPace
                )
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.black.opacity(0.85))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.purple.opacity(0.3), lineWidth: 0.5)
                    )
            )
            .padding(.horizontal, 3)
            .padding(.bottom, 1)
        }
        .edgesIgnoringSafeArea(.bottom)
    }

    @ViewBuilder
    private func distanceDifferenceRow(distanceDiffMeters: Double, timeDifference: Double) -> some View {
        HStack(spacing: 4) {
            if distanceDiffMeters > 10 {
                Text(String(format: "↑ %.0fm AHEAD", distanceDiffMeters))
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
            } else if distanceDiffMeters < -10 {
                Text(String(format: "↓ %.0fm BEHIND", abs(distanceDiffMeters)))
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundColor(Color(red: 1.0, green: 0.58, blue: 0.0))
            } else {
                Text("EVEN")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundColor(.green)
            }

            Text("•")
                .font(.system(size: 6))
                .foregroundColor(.white.opacity(0.3))

            Text(shadowData.prModel.name)
                .font(.system(size: 6, weight: .medium, design: .rounded))
                .foregroundColor(.white.opacity(0.7))
                .lineLimit(1)
        }

        if timeDifference.isFinite && timeDifference != 0 {
            HStack(spacing: 4) {
                Image(systemName: timeDifference < 0 ? "timer" : "hourglass")
                    .font(.system(size: 6, weight: .bold))
                Text(
                    String(
                        format: "%@%.1fs",
                        timeDifference < 0 ? "AHEAD " : "BEHIND ",
                        abs(timeDifference)
                    )
                )
                .font(.system(size: 6, weight: .semibold, design: .rounded))
                .foregroundColor(timeDifference < 0 ? .green : .orange)
            }
        }
    }

    @ViewBuilder
    private func statsSummaryRow(
        totalDistance: Double,
        shadowCurrentPace: Double
    ) -> some View {
        HStack(spacing: 6) {
            HStack(spacing: 2) {
                Text("You")
                    .font(.system(size: 6, weight: .semibold, design: .rounded))
                Text(String(format: "%.0fm", currentDistance))
                    .font(.system(size: 7, weight: .bold, design: .rounded))
                Text(formatPace(currentPace))
                    .font(.system(size: 6, weight: .medium, design: .rounded))
            }
            .foregroundColor(.white)

            Text("|")
                .foregroundColor(.white.opacity(0.3))

            HStack(spacing: 2) {
                Text("PR")
                    .font(.system(size: 6, weight: .semibold, design: .rounded))
                Text(formatPace(shadowCurrentPace))
                    .font(.system(size: 7, weight: .bold, design: .rounded))
            }
            .foregroundColor(Color(red: 1.0, green: 0.58, blue: 0.0))

            Text("|")
                .foregroundColor(.white.opacity(0.3))

            Text(String(format: "%.1f km", totalDistance / 1000.0))
                .font(.system(size: 6, weight: .medium, design: .rounded))
                .foregroundColor(.white.opacity(0.7))
        }
    }

    private func handleOvertakingChange(_ newValue: Bool) {
        if newValue != previousOvertakingState {
            playHaptic(.success)
            previousOvertakingState = newValue
        }
    }
}

// MARK: - Tron Grid Background
struct TronGridBackground: View {
    let animationTime: TimeInterval
    
    var body: some View {
        ZStack {
            // Darker gradient for less distraction
            LinearGradient(
                colors: [Color.black, Color(red: 0.01, green: 0.02, blue: 0.05)],
                startPoint: .top,
                endPoint: .bottom
            )
            
            // Subtle scrolling grid lines
            Canvas { context, size in
                let spacing: CGFloat = 30
                let gridColor = Color.cyan.opacity(0.04)
                
                // Horizontal scroll offset
                let scrollOffset = CGFloat(animationTime * 20).truncatingRemainder(dividingBy: spacing)
                
                // Vertical lines (scrolling horizontally)
                var x: CGFloat = -scrollOffset
                while x <= size.width {
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(path, with: .color(gridColor), lineWidth: 0.3)
                    x += spacing
                }
                
                // Horizontal lines (static, more subtle)
                for i in stride(from: 0, through: size.height, by: spacing * 1.5) {
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: i))
                    path.addLine(to: CGPoint(x: size.width, y: i))
                    context.stroke(path, with: .color(gridColor.opacity(0.5)), lineWidth: 0.3)
                }
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - Tron Racing Lanes
struct TronRacingLanes: View {
    let userProgress: Double
    let shadowProgress: Double
    let distanceDiffMeters: Double
    let currentPace: Double
    let animationTime: TimeInterval
    let startTime: Date
    let totalDistance: Double
    
    var body: some View {
        GeometryReader { geometry in
            let _ = geometry.size.width
            let _ = geometry.size.height
            
            Canvas { context, size in
                let laneHeight: CGFloat = 6 // Beam thickness (slimmer for clarity)
                
                // Direction changes every 3 minutes (180 seconds)
                let elapsedTime = Date().timeIntervalSince(startTime)
                let threeMinuteInterval = Int(elapsedTime / 180) // 180 seconds = 3 minutes
                
                // Rotation: 0° (horizontal), 90° (vertical down), 180° (horizontal back), 270° (vertical up)
                let rotationAngles: [Double] = [0, 90, 180, 270]
                let rotationAngle = rotationAngles[threeMinuteInterval % rotationAngles.count]
                
                // Calculate actual distances traveled (in meters)
                let userDistanceMeters = userProgress * totalDistance // User's actual distance
                let shadowDistanceMeters = shadowProgress * totalDistance // Shadow's actual distance
                
                // Screen bounds
                let startX: CGFloat = 20
                let endX = size.width - 20
                let screenWidth = endX - startX
                
                // Scale factor: map meters to pixels with looping
                let visibleRangeMeters: CGFloat = 500.0
                let metersPerPixel = visibleRangeMeters / screenWidth
                
                // LOOPING: When reaching right edge, reset to left (infinite orbit illusion)
                let userScreenDistance = (userDistanceMeters / metersPerPixel).truncatingRemainder(dividingBy: screenWidth)
                let shadowScreenDistance = (shadowDistanceMeters / metersPerPixel).truncatingRemainder(dividingBy: screenWidth)
                
                // Position based on looped distance
                let userX = startX + userScreenDistance
                let shadowX = startX + shadowScreenDistance
                
                // Calculate relative positions for interaction effects
                let distanceDiff = abs(userDistanceMeters - shadowDistanceMeters)
                let isOvertaking = distanceDiff < 10.0 // Within 10m = overtaking zone
                
                // Trail fade effect near edges for smooth looping
                let fadeZone: CGFloat = 30
                let userNearEnd = userX > (endX - fadeZone)
                let shadowNearEnd = shadowX > (endX - fadeZone)
                
                // Trails start from left edge
                let userTrailStartX = startX
                let shadowTrailStartX = startX
                
                let userLaneY = size.height * 0.38
                let shadowLaneY = size.height * 0.55
                
                let userColor = Color.white // You = White
                let shadowColor = Color(red: 1.0, green: 0.58, blue: 0.0) // Shadow PR = Neon Orange
                
                let isUserLeading = userProgress > shadowProgress
                
                // Dynamic track curve for visual flow (sine wave based on time)
                let curveAmplitude: CGFloat = 15
                let curveFrequency = elapsedTime * 0.5
                let trackCurve = sin(curveFrequency) * curveAmplitude
                
                // Apply rotation transformation with slight tilt for dynamic feel
                context.translateBy(x: size.width / 2, y: size.height / 2)
                context.rotate(by: Angle(degrees: rotationAngle + trackCurve * 0.5))
                context.translateBy(x: -size.width / 2, y: -size.height / 2)
                
                // Draw continuous TRON beams with dynamic effects
                drawTronRaceBeam(
                    context: context,
                    y: userLaneY,
                    currentX: userX,
                    color: userColor,
                    startX: userTrailStartX,
                    endX: endX,
                    beamHeight: laneHeight,
                    animationTime: animationTime,
                    isLeading: isUserLeading,
                    isOvertaking: isOvertaking,
                    isFading: userNearEnd,
                    label: "YOU"
                )
                
                drawTronRaceBeam(
                    context: context,
                    y: shadowLaneY,
                    currentX: shadowX,
                    color: shadowColor,
                    startX: shadowTrailStartX,
                    endX: endX,
                    beamHeight: laneHeight,
                    animationTime: animationTime,
                    isLeading: !isUserLeading,
                    isOvertaking: isOvertaking,
                    isFading: shadowNearEnd,
                    label: "PR"
                )
            }
        }
    }
    
    private func drawTronRaceBeam(
        context: GraphicsContext,
        y: CGFloat,
        currentX: CGFloat,
        color: Color,
        startX: CGFloat,
        endX: CGFloat,
        beamHeight: CGFloat,
        animationTime: TimeInterval,
        isLeading: Bool,
        isOvertaking: Bool,
        isFading: Bool,
        label: String
    ) {
        let halfHeight = beamHeight / 2
        
        // Dynamic opacity based on state
        let baseOpacity: Double = isFading ? 0.3 : 1.0 // Fade when near edge for looping
        let overtakeBoost: Double = isOvertaking ? 0.3 : 0.0 // Extra glow when overtaking
        
        // Draw CONTINUOUS glowing trail from start to current position
        let trailWidth = max(currentX - startX, 2)
        let beamTrail = RoundedRectangle(cornerRadius: beamHeight * 0.5)
        let trailRect = CGRect(
            x: startX,
            y: y - halfHeight,
            width: trailWidth,
            height: beamHeight
        )
        
        // Outer glow layer - pulsing when overtaking
        let outerGlow = isOvertaking ? 5 : 3
        context.fill(
            beamTrail.path(in: CGRect(
                x: trailRect.origin.x - CGFloat(outerGlow),
                y: trailRect.origin.y - CGFloat(outerGlow),
                width: trailRect.width + CGFloat(outerGlow * 2),
                height: trailRect.height + CGFloat(outerGlow * 2)
            )),
            with: .color(color.opacity((0.35 + overtakeBoost) * baseOpacity))
        )
        
        // Middle glow layer (brighter when overtaking)
        context.fill(
            beamTrail.path(in: CGRect(
                x: trailRect.origin.x - 1.5,
                y: trailRect.origin.y - 1.5,
                width: trailRect.width + 3,
                height: trailRect.height + 3
            )),
            with: .color(color.opacity((0.65 + overtakeBoost) * baseOpacity))
        )
        
        // Main bright beam - flicker when behind
        let flickerEffect = !isLeading && !isOvertaking ? sin(animationTime * 3) * 0.1 : 0.0
        context.fill(
            beamTrail.path(in: trailRect),
            with: .color(color.opacity((0.95 + flickerEffect) * baseOpacity))
        )
        
        // Inner bright core
        context.fill(
            beamTrail.path(in: CGRect(
                x: trailRect.origin.x,
                y: trailRect.origin.y + halfHeight * 0.35,
                width: trailRect.width,
                height: beamHeight * 0.3
            )),
            with: .color(.white.opacity((0.5 + overtakeBoost) * baseOpacity))
        )
        
        // Light cycle at current position (compact glowing disk)
        let cycleSize: CGFloat = 16 // Smaller for watch
        let cycleIntensity: Double = 1.0
        
        // Reduced glow rings around light cycle (fewer, smaller)
        for i in 0..<4 {
            let glowSize = cycleSize + CGFloat(i) * 5
            let glowOpacity = (0.7 - CGFloat(i) * 0.15) * cycleIntensity
            let glowPath = Path { path in
                path.addEllipse(in: CGRect(
                    x: currentX - glowSize/2,
                    y: y - glowSize/2,
                    width: glowSize,
                    height: glowSize
                ))
            }
            context.fill(glowPath, with: .color(color.opacity(glowOpacity)))
        }
        
        // Outer ring of light cycle (thinner)
        let outerRingSize = cycleSize * 1.15
        let outerRing = Path { path in
            path.addEllipse(in: CGRect(
                x: currentX - outerRingSize/2,
                y: y - outerRingSize/2,
                width: outerRingSize,
                height: outerRingSize
            ))
        }
        context.stroke(outerRing, with: .color(color.opacity(0.7)), lineWidth: 1.5)
        
        // Main light cycle disk
        let cyclePath = Path { path in
            path.addEllipse(in: CGRect(
                x: currentX - cycleSize/2,
                y: y - cycleSize/2,
                width: cycleSize,
                height: cycleSize
            ))
        }
        context.fill(cyclePath, with: .color(color))
        
        // Bright white center (hot spot)
        let hotCenterSize = cycleSize * 0.5
        let hotCenter = Path { path in
            path.addEllipse(in: CGRect(
                x: currentX - hotCenterSize/2,
                y: y - hotCenterSize/2,
                width: hotCenterSize,
                height: hotCenterSize
            ))
        }
        context.fill(hotCenter, with: .color(.white.opacity(0.95)))
    }
}

// MARK: - Curved Race Arc Component (Legacy)
struct CurvedRaceArc: View {
    let progress: Double
    let color: Color
    let isTop: Bool
    
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let _ = geometry.size.height
            let arcRadius = width * 0.9
            
            Canvas { context, size in
                // Draw the arc path
                let arcPath = createArcPath(width: size.width, height: size.height, radius: arcRadius)
                
                // Draw the arc with glow
                context.stroke(
                    arcPath,
                    with: .color(color.opacity(0.3)),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round)
                )
                
                // Draw glow effect
                context.stroke(
                    arcPath,
                    with: .color(color.opacity(0.1)),
                    style: StrokeStyle(lineWidth: 8, lineCap: .round)
                )
                
                // Calculate pulse position
                let pulsePosition = getPulsePosition(
                    progress: progress,
                    width: size.width,
                    height: size.height,
                    radius: arcRadius
                )
                
                // Draw trailing fade
                drawTrail(context: context, position: pulsePosition, color: color)
                
                // Draw the moving pulse dot
                let pulsePath = Path { path in
                    path.addEllipse(in: CGRect(
                        x: pulsePosition.x - 6,
                        y: pulsePosition.y - 6,
                        width: 12,
                        height: 12
                    ))
                }
                
                // Bright core
                context.fill(pulsePath, with: .color(color))
                
                // Outer glow
                context.fill(
                    Path { path in
                        path.addEllipse(in: CGRect(
                            x: pulsePosition.x - 10,
                            y: pulsePosition.y - 10,
                            width: 20,
                            height: 20
                        ))
                    },
                    with: .color(color.opacity(0.5))
                )
            }
        }
    }
    
    private func createArcPath(width: CGFloat, height: CGFloat, radius: CGFloat) -> Path {
        Path { path in
            let midX = width / 2
            let startAngle: Angle = .degrees(200)
            let endAngle: Angle = .degrees(340)
            
            if isTop {
                path.addArc(
                    center: CGPoint(x: midX, y: -radius + height),
                    radius: radius,
                    startAngle: startAngle,
                    endAngle: endAngle,
                    clockwise: false
                )
            } else {
                path.addArc(
                    center: CGPoint(x: midX, y: radius),
                    radius: radius,
                    startAngle: .degrees(20),
                    endAngle: .degrees(160),
                    clockwise: false
                )
            }
        }
    }
    
    private func getPulsePosition(progress: Double, width: CGFloat, height: CGFloat, radius: CGFloat) -> CGPoint {
        let midX = width / 2
        let clampedProgress = min(max(progress, 0.0), 1.0)
        
        if isTop {
            // Top arc: 200° to 340° (140° range)
            let startAngle: CGFloat = 200 * .pi / 180
            let angleRange: CGFloat = 140 * .pi / 180
            let angle = startAngle + angleRange * CGFloat(clampedProgress)
            
            let centerY = -radius + height
            let x = midX + radius * cos(angle)
            let y = centerY + radius * sin(angle)
            return CGPoint(x: x, y: y)
        } else {
            // Bottom arc: 20° to 160° (140° range)
            let startAngle: CGFloat = 20 * .pi / 180
            let angleRange: CGFloat = 140 * .pi / 180
            let angle = startAngle + angleRange * CGFloat(clampedProgress)
            
            let centerY = radius
            let x = midX + radius * cos(angle)
            let y = centerY + radius * sin(angle)
            return CGPoint(x: x, y: y)
        }
    }
    
    private func drawTrail(context: GraphicsContext, position: CGPoint, color: Color) {
        // Draw a fading trail behind the pulse
        for i in 0..<5 {
            let offset = CGFloat(i) * 4
            let opacity = 0.3 * (1.0 - CGFloat(i) / 5.0)
            let trailPath = Path { path in
                path.addEllipse(in: CGRect(
                    x: position.x - 3 - offset,
                    y: position.y - 3,
                    width: 6,
                    height: 6
                ))
            }
            context.fill(trailPath, with: .color(color.opacity(opacity)))
        }
    }
}

// MARK: - Split Interval Bar Component (iOS-style)
struct SplitIntervalBar: View {
    let interval: RunInterval
    let targetPace: Double
    var isLast: Bool = false
    var isAverage: Bool = false
    
    var body: some View {
        let pace = interval.paceMinPerKm
        let deviation = targetPace > 0 ? ((pace - targetPace) / targetPace) * 100 : 0
        
        // Color coding matching iOS: Green (faster), Yellow (steady), Red (slower)
        let (barColor, statusText, statusIcon): (Color, String, String) = {
            if abs(deviation) <= 5 {
                return (.rbWarning, "Steady", "equal.circle.fill") // Yellow for steady (iOS uses yellow)
            } else if deviation < -5 {
                return (.rbSuccess, "Faster", "arrow.up.circle.fill") // Green for faster
            } else {
                return (.rbError, "Slower", "arrow.down.circle.fill") // Red for slower
            }
        }()
        
        // Format duration as MM:SS
        let durationMinutes = Int(interval.durationSeconds) / 60
        let durationSeconds = Int(interval.durationSeconds) % 60
        let durationString = String(format: "%d:%02d", durationMinutes, durationSeconds)
        
        VStack(alignment: .leading, spacing: 3) {
            // Interval label at top
            Text(isAverage ? "AVG" : "KM \(interval.index + 1)")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(.white.opacity(0.8))
            
            // Main content area
            VStack(alignment: .leading, spacing: 3) {
                // Horizontal bar with pace displayed inside
                // Bar length directly represents pace in min/km: faster pace (lower min/km) = shorter bar, slower pace (higher min/km) = longer bar
                GeometryReader { geometry in
                    let barWidth = geometry.size.width
                    
                    // Pace range for visualization: 3-12 min/km maps to bar width
                    // Example: 5:00 min/km (fast) = shorter bar, 8:00 min/km (slow) = longer bar
                    let minPaceRange: Double = 3.0  // Fastest expected pace (3:00 min/km)
                    let maxPaceRange: Double = 12.0 // Slowest expected pace (12:00 min/km)
                    
                    // Clamp pace to valid range and normalize to 0-1
                    // This ensures bar length is proportional to pace value in min/km
                    let clampedPace = min(max(pace, minPaceRange), maxPaceRange)
                    let normalizedPace = (clampedPace - minPaceRange) / (maxPaceRange - minPaceRange)
                    let barLength = max(barWidth * CGFloat(normalizedPace), 70) // Minimum 70pt to fit pace text comfortably
                    
                    ZStack(alignment: .leading) {
                        // Background bar (full width, subtle)
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.white.opacity(0.08))
                            .frame(width: barWidth, height: 24)
                        
                        // Colored pace bar
                        RoundedRectangle(cornerRadius: 6)
                            .fill(barColor)
                            .frame(width: barLength, height: 24)
                        
                        // Pace text inside bar (white text)
                        HStack {
                            Text("\(formatPace(pace)) /km")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(.white)
                                .padding(.leading, 8)
                            Spacer()
                        }
                        .frame(width: barLength, height: 24)
                    }
                }
                .frame(height: 24)
                
                // Duration with clock icon and status on same row
                HStack {
                    HStack(spacing: 3) {
                        Image(systemName: "clock")
                            .font(.system(size: 8))
                            .foregroundColor(.white.opacity(0.6))
                        Text(durationString)
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white.opacity(0.7))
                    }
                    
                    Spacer()
                    
                    // Status indicator on right
                    HStack(spacing: 3) {
                        Image(systemName: statusIcon)
                            .font(.system(size: 10))
                            .foregroundColor(barColor)
                        Text(statusText)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(barColor)
                    }
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(barColor.opacity(0.2), lineWidth: 1)
                )
        )
    }
    
    private func formatPace(_ paceMinutesPerKm: Double) -> String {
        if paceMinutesPerKm <= 0 || !paceMinutesPerKm.isFinite { return "--:--" }
        let mins = Int(paceMinutesPerKm)
        let secs = Int((paceMinutesPerKm - Double(mins)) * 60)
        return String(format: "%d:%02d", mins, secs)
    }
}

// MARK: - Network Monitor
class NetworkMonitor: ObservableObject {
    @Published var isConnected = false
    @Published var connectionType: ConnectionType = .none
    
    enum ConnectionType {
        case none
        case watchCellular
        case iphonePaired
        
        var displayText: String {
            switch self {
            case .none: return "No Connection"
            case .watchCellular: return "Watch Cellular"
            case .iphonePaired: return "iPhone Paired"
            }
        }
    }
    
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "NetworkMonitor")
    private let watchConnectivity = WatchConnectivityManager.shared
    private var startupRetryTimer: Timer?
    private var startupRetryCount = 0
    private let maxStartupRetries = 10 // Retry up to 10 times (20 seconds total)
    
    init() {
        startMonitoring()
        startStartupRetry()
    }
    
    private func startMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                guard let self = self else { return }
                
                let isConnected = path.status == .satisfied
                self.isConnected = isConnected
                
                if isConnected {
                    // PRIORITY 1: Check if watch has cellular capability (watch cellular)
                    if path.usesInterfaceType(.cellular) {
                        self.connectionType = .watchCellular
                        print("🌐 [NetworkMonitor] ✅ Connected via Watch Cellular (Priority 1)")
                    }
                    // PRIORITY 2: If no watch cellular, try iPhone Bluetooth internet
                    else if self.watchConnectivity.isReachable {
                        // iPhone is paired and reachable via Bluetooth
                        self.connectionType = .iphonePaired
                        print("🌐 [NetworkMonitor] ✅ Connected via iPhone Bluetooth Internet (Priority 2)")
                    }
                    // PRIORITY 3: WiFi (if available on watch)
                    else if path.usesInterfaceType(.wifi) {
                        self.connectionType = .watchCellular // Treat WiFi as watch's own connection
                        print("🌐 [NetworkMonitor] ✅ Connected via WiFi")
                    }
                    // FALLBACK: Connected but unknown type - try iPhone
                    else {
                        // Check if iPhone is reachable even if path doesn't show it
                        if self.watchConnectivity.isReachable {
                            self.connectionType = .iphonePaired
                            print("🌐 [NetworkMonitor] ✅ Connected via iPhone (fallback check)")
                        } else {
                            // Unknown connection type
                            self.connectionType = .iphonePaired // Default assumption
                            print("🌐 [NetworkMonitor] ⚠️ Connected (unknown type, defaulting to iPhone)")
                        }
                    }
                    
                    print("✅ [NetworkMonitor] Connection established")
                    // Stop startup retry once connected
                    self.stopStartupRetry()
                } else {
                    // Not connected - check iPhone as fallback
                    self.connectionType = .none
                    if self.watchConnectivity.isReachable {
                        self.isConnected = true
                        self.connectionType = .iphonePaired
                        print("🌐 [NetworkMonitor] ✅ Connected via iPhone Bluetooth (fallback check)")
                        self.stopStartupRetry()
                    } else {
                        print("❌ [NetworkMonitor] No connection available - will retry during startup")
                    }
                }
            }
        }
        
        monitor.start(queue: queue)
    }
    
    /// Force refresh connection check (only called when user hits refresh button)
    func refreshConnection() {
        print("🔄 [NetworkMonitor] Manual refresh requested")
        
        // Check current path status
        let currentPath = monitor.currentPath
        let pathConnected = currentPath.status == .satisfied
        
        // PRIORITY 1: Check watch cellular first
        if pathConnected && currentPath.usesInterfaceType(.cellular) {
            self.isConnected = true
            self.connectionType = .watchCellular
            print("🌐 [NetworkMonitor] ✅ Refreshed: Watch Cellular")
            return
        }
        
        // PRIORITY 2: Check iPhone Bluetooth internet
        if watchConnectivity.isReachable {
            self.isConnected = true
            self.connectionType = .iphonePaired
            print("🌐 [NetworkMonitor] ✅ Refreshed: iPhone Bluetooth Internet")
            return
        }
        
        // PRIORITY 3: Check WiFi
        if pathConnected && currentPath.usesInterfaceType(.wifi) {
            self.isConnected = true
            self.connectionType = .watchCellular
            print("🌐 [NetworkMonitor] ✅ Refreshed: WiFi")
            return
        }
        
        // No connection available
        if pathConnected {
            // Connected but unknown type
            self.isConnected = true
            self.connectionType = .iphonePaired // Default assumption
            print("🌐 [NetworkMonitor] ⚠️ Refreshed: Connected (unknown type)")
        } else {
            self.isConnected = false
            self.connectionType = .none
            print("❌ [NetworkMonitor] Refreshed: No connection")
        }
    }
    
    /// Startup retry logic - only retries during app startup, not continuously
    private func startStartupRetry() {
        stopStartupRetry()
        startupRetryCount = 0
        
        print("🔄 [NetworkMonitor] Starting startup connection retry...")
        startupRetryTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            
            // Stop if already connected
            if self.isConnected {
                print("✅ [NetworkMonitor] Connected - stopping startup retry")
                self.stopStartupRetry()
                return
            }
            
            // Stop if max retries reached
            self.startupRetryCount += 1
            if self.startupRetryCount >= self.maxStartupRetries {
                print("⏹️ [NetworkMonitor] Max startup retries reached - stopping")
                self.stopStartupRetry()
                return
            }
            
            print("🔄 [NetworkMonitor] Startup retry \(self.startupRetryCount)/\(self.maxStartupRetries) - checking connection...")
            
            // PRIORITY 1: Check watch cellular
            let currentPath = self.monitor.currentPath
            if currentPath.status == .satisfied && currentPath.usesInterfaceType(.cellular) {
                self.isConnected = true
                self.connectionType = .watchCellular
                print("🌐 [NetworkMonitor] ✅ Connected via Watch Cellular (startup retry)")
                self.stopStartupRetry()
                return
            }
            
            // PRIORITY 2: Check iPhone Bluetooth
            if self.watchConnectivity.isReachable {
                self.isConnected = true
                self.connectionType = .iphonePaired
                print("🌐 [NetworkMonitor] ✅ Connected via iPhone Bluetooth (startup retry)")
                self.stopStartupRetry()
                return
            }
            
            // PRIORITY 3: Check WiFi
            if currentPath.status == .satisfied && currentPath.usesInterfaceType(.wifi) {
                self.isConnected = true
                self.connectionType = .watchCellular
                print("🌐 [NetworkMonitor] ✅ Connected via WiFi (startup retry)")
                self.stopStartupRetry()
                return
            }
        }
    }
    
    private func stopStartupRetry() {
        startupRetryTimer?.invalidate()
        startupRetryTimer = nil
    }
    
    deinit {
        stopStartupRetry()
        monitor.cancel()
    }
}

// MARK: - Workout Status Row
struct WorkoutStatusRow: View {
    @ObservedObject var healthManager: HealthManager
    let isRunning: Bool
    
    var body: some View {
        HStack(spacing: 8) {
            // Status indicator
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(statusText)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(statusColor)
                
                Text(statusDetail)
                    .font(.system(size: 9, weight: .regular))
                    .foregroundColor(.white.opacity(0.6))
            }
            
            Spacer()
            
            // Workout icon
            Image(systemName: statusIcon)
                .font(.system(size: 12))
                .foregroundColor(statusColor.opacity(0.7))
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(statusColor.opacity(0.1))
        )
    }
    
    private var statusColor: Color {
        if isRunning {
            switch healthManager.workoutStatus {
            case .running: return .rbSuccess
            case .starting: return .rbWarning
            case .error(_): return .rbError
            case .notStarted: return .rbError
            }
        } else {
            return .gray
        }
    }
    
    private var statusText: String {
        if isRunning {
            switch healthManager.workoutStatus {
            case .running: return "Workout Active"
            case .starting: return "Starting..."
            case .error(let msg): return "Error: \(msg)"
            case .notStarted: return "Not Started"
            }
        } else {
            return "Not Running"
        }
    }
    
    private var statusDetail: String {
        if isRunning {
            switch healthManager.workoutStatus {
            case .running: return "HealthKit session running"
            case .starting: return "Initializing workout..."
            case .error(let msg): return msg
            case .notStarted: return "Workout not started"
            }
        } else {
            return "Tap start to begin"
        }
    }
    
    private var statusIcon: String {
        if isRunning {
            switch healthManager.workoutStatus {
            case .running: return "checkmark.circle.fill"
            case .starting: return "hourglass"
            case .error(_): return "exclamationmark.triangle.fill"
            case .notStarted: return "xmark.circle.fill"
            }
        } else {
            return "circle"
        }
    }
}

// MARK: - Network Status Row
struct NetworkStatusRow: View {
    @ObservedObject var networkMonitor: NetworkMonitor
    
    var body: some View {
        HStack(spacing: 8) {
            // Status indicator
            Circle()
                .fill(networkMonitor.isConnected ? Color.rbSuccess : Color.rbError)
                .frame(width: 8, height: 8)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(networkMonitor.isConnected ? "Connected" : "Disconnected")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(networkMonitor.isConnected ? .rbSuccess : .rbError)
                
                Text(networkMonitor.connectionType.displayText)
                    .font(.system(size: 9, weight: .regular))
                    .foregroundColor(.white.opacity(0.6))
            }
            
            Spacer()
            
            // Connection type icon
            Image(systemName: networkMonitor.connectionType == .watchCellular ? "antenna.radiowaves.left.and.right" : "iphone")
                .font(.system(size: 12))
                .foregroundColor(networkMonitor.isConnected ? .rbAccent.opacity(0.7) : .white.opacity(0.3))
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(networkMonitor.isConnected ? Color.rbSuccess.opacity(0.1) : Color.rbError.opacity(0.1))
        )
    }
}

// MARK: - ⚙️ Settings Helper Views

struct SettingsSection<Content: View>: View {
    let title: String
    let icon: String
    let color: Color
    @ViewBuilder let content: Content
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(color)
                Text(title)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white.opacity(0.5))
            }
            
            content
        }
    }
}

struct SettingsRow: View {
    let title: String
    let isSelected: Bool
    let color: Color
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle()
                    .fill(isSelected ? color : Color.white.opacity(0.15))
                    .frame(width: 8, height: 8)
                    .overlay(
                        Circle()
                            .stroke(color.opacity(0.3), lineWidth: 1)
                    )
                
                Text(title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? .white : .white.opacity(0.6))
                
                Spacer()
                
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(color)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? color.opacity(0.15) : Color.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isSelected ? color.opacity(0.3) : Color.clear, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

struct AllLanguagesView: View {
    @ObservedObject var userPreferences: UserPreferences
    
    var body: some View {
        ScrollView {
            VStack(spacing: 4) {
                ForEach(SupportedLanguage.allCases, id: \.self) { lang in
                    Button(action: { userPreferences.updateLanguage(lang) }) {
                        HStack {
                            Text(lang.displayName)
                                .font(.system(size: 12, weight: userPreferences.settings.language == lang ? .semibold : .regular))
                                .foregroundColor(userPreferences.settings.language == lang ? .white : .white.opacity(0.7))
                            Spacer()
                            if userPreferences.settings.language == lang {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.rbSecondary)
                            }
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(userPreferences.settings.language == lang ? Color.rbSecondary.opacity(0.15) : Color.white.opacity(0.05))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
        }
        .navigationTitle("Language")
    }
}

#Preview {
    MainRunbotView()
        .environmentObject(RunTracker())
        .environmentObject(AuthenticationManager())
        .environmentObject(UserPreferences())
        .environmentObject(SupabaseManager())
}


#Preview {
    MainRunbotView()
        .environmentObject(RunTracker())
        .environmentObject(AuthenticationManager())
        .environmentObject(UserPreferences())
        .environmentObject(SupabaseManager())
}
