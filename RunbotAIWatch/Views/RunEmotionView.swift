import SwiftUI

// MARK: - Run Emotion View
// Next-gen watch UI: animated glowing mood orb, radial gradient background,
// glassmorphism track card, pulsing ring, biofeedback badge.
struct RunEmotionView: View {
    @ObservedObject var moodController: SpotifyMoodController
    @ObservedObject var spotifyManager: SpotifyManager
    @ObservedObject var appleMusicManager: AppleMusicManager

    @State private var orbPhase: Double = 0
    @State private var ringRotation: Double = 0
    @State private var pulseScale: CGFloat = 1.0
    @State private var glowOpacity: Double = 0.5
    @State private var animTimer: Timer?

    private var mood: SpotifyMoodController.Mood { moodController.currentMood }

    private var isPlaying: Bool {
        RunEmotionMusicSource.current == .spotify ? spotifyManager.isPlaying : appleMusicManager.isPlaying
    }

    private var currentTrackName: String {
        RunEmotionMusicSource.current == .spotify ? spotifyManager.currentTrackName : appleMusicManager.currentTrackName
    }

    private var currentTrackArtist: String {
        RunEmotionMusicSource.current == .spotify ? spotifyManager.currentTrackArtist : appleMusicManager.currentTrackArtist
    }

    private var isConnected: Bool {
        RunEmotionMusicSource.current == .spotify ? spotifyManager.isConnected : appleMusicManager.isConnected
    }

    var body: some View {
        ZStack {
            backgroundLayer
            
            VStack(spacing: 0) {
                Spacer(minLength: 4)
                moodOrbSection
                Spacer(minLength: 6)
                trackCard
                Spacer(minLength: 4)
            }
        }
        .onAppear { startAnimations() }
        .onDisappear { stopAnimations() }
    }

    // MARK: - Background

    private var backgroundLayer: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            RadialGradient(
                gradient: Gradient(colors: [
                    mood.color.opacity(0.45),
                    mood.color.opacity(0.18),
                    Color.black
                ]),
                center: .center,
                startRadius: 10,
                endRadius: 130
            )
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 1.8), value: mood)

            // Ambient glow burst that breathes
            Circle()
                .fill(
                    RadialGradient(
                        colors: [mood.color.opacity(glowOpacity * 0.35), .clear],
                        center: .center,
                        startRadius: 5,
                        endRadius: 100
                    )
                )
                .frame(width: 200, height: 200)
                .animation(.easeInOut(duration: 1.8), value: mood)
        }
    }

    // MARK: - Mood Orb + Ring

    private var moodOrbSection: some View {
        ZStack {
            // Outer rotating ring
            Circle()
                .stroke(
                    AngularGradient(
                        gradient: Gradient(colors: [
                            mood.color.opacity(0.8),
                            mood.color.opacity(0.15),
                            mood.color.opacity(0.5),
                            mood.color.opacity(0.05),
                            mood.color.opacity(0.8)
                        ]),
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                )
                .frame(width: 90, height: 90)
                .rotationEffect(.degrees(ringRotation))
                .animation(.easeInOut(duration: 1.8), value: mood)

            // Glowing orb
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            mood.color.opacity(0.9),
                            mood.color.opacity(0.5),
                            mood.color.opacity(0.15)
                        ],
                        center: .center,
                        startRadius: 4,
                        endRadius: 36
                    )
                )
                .frame(width: 68, height: 68)
                .scaleEffect(pulseScale)
                .shadow(color: mood.color.opacity(0.7), radius: 18)
                .animation(.easeInOut(duration: 1.8), value: mood)

            // Mood icon
            VStack(spacing: 2) {
                Image(systemName: moodIcon)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 2)
            }
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 2) {
                Text(mood.rawValue.uppercased())
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.white, mood.color],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .shadow(color: mood.color.opacity(0.6), radius: 6)

                Text(moodController.bpmRange)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.55))
            }
            .offset(y: 38)
        }
        .padding(.bottom, 30)
    }

    // MARK: - Track Card (glassmorphism)

    private var trackCard: some View {
        Group {
            if isPlaying && !currentTrackName.isEmpty {
                playingCard
            } else if !isConnected {
                disconnectedCard
            } else {
                waitingCard
            }
        }
        .padding(.horizontal, 14)
    }

    private var playingCard: some View {
        HStack(spacing: 10) {
            // Mini animated bars
            HStack(spacing: 2) {
                ForEach(0..<3, id: \.self) { i in
                    let h = barHeight(index: i)
                    RoundedRectangle(cornerRadius: 1)
                        .fill(mood.color)
                        .frame(width: 3, height: h)
                        .animation(.easeInOut(duration: 0.3), value: h)
                }
            }
            .frame(width: 14, height: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(currentTrackName)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if !currentTrackArtist.isEmpty {
                    Text(currentTrackArtist)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.55))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            if moodController.currentTrackScore != 0 {
                biofeedbackBadge
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(glassBackground)
    }

    private var disconnectedCard: some View {
        HStack(spacing: 8) {
            Image(systemName: "music.note.slash")
                .font(.system(size: 16))
                .foregroundColor(.white.opacity(0.5))
            Text("\(RunEmotionMusicSource.current.displayName) not connected")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.5))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(glassBackground)
    }

    private var waitingCard: some View {
        HStack(spacing: 8) {
            Image(systemName: "headphones")
                .font(.system(size: 16))
                .foregroundColor(.white.opacity(0.45))
            Text("Waiting for music...")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.5))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(glassBackground)
    }

    private var glassBackground: some View {
        RoundedRectangle(cornerRadius: 14)
            .fill(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(
                        LinearGradient(
                            colors: [
                                mood.color.opacity(0.4),
                                .white.opacity(0.08),
                                mood.color.opacity(0.15)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.8
                    )
            )
    }

    // MARK: - Biofeedback Badge

    private var biofeedbackBadge: some View {
        let positive = moodController.currentTrackScore > 0
        return HStack(spacing: 3) {
            Image(systemName: positive ? "chevron.up" : "chevron.down")
                .font(.system(size: 8, weight: .heavy))
            Text("\(positive ? "+" : "")\(moodController.currentTrackScore)")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
        }
        .foregroundColor(positive ? .green : .red)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill((positive ? Color.green : Color.red).opacity(0.18))
        )
    }

    // MARK: - Mini Bars (playing indicator)

    private func barHeight(index: Int) -> CGFloat {
        guard isPlaying else { return 4 }
        let phase = orbPhase
        let offsets: [Double] = [0.0, 0.6, 1.2]
        let val = sin(phase * 0.12 + offsets[index]) * 0.5 + 0.5
        return max(4, CGFloat(val) * 16)
    }

    // MARK: - Mood Icon

    private var moodIcon: String {
        switch mood {
        case .calmFocus: return "leaf.fill"
        case .flow: return "wind"
        case .push: return "flame.fill"
        case .restraint: return "tortoise.fill"
        }
    }

    // MARK: - Animations

    private func startAnimations() {
        animTimer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { _ in
            orbPhase += 1
            ringRotation += 0.6

            let breathe = sin(orbPhase * 0.03) * 0.08 + 1.0
            pulseScale = CGFloat(breathe)
            glowOpacity = sin(orbPhase * 0.025) * 0.2 + 0.5
        }
    }

    private func stopAnimations() {
        animTimer?.invalidate()
        animTimer = nil
    }
}
