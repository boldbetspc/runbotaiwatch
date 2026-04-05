import SwiftUI

// MARK: - Devices Config View (Music Settings)
struct DevicesConfigView: View {
    @ObservedObject var spotifyManager: SpotifyManager
    @ObservedObject var appleMusicManager: AppleMusicManager
    @EnvironmentObject var supabaseManager: SupabaseManager
    @EnvironmentObject var authManager: AuthenticationManager

    @State private var musicSource: RunEmotionMusicSource = RunEmotionMusicSource.current
    @State private var isLoadingPlaylists = false
    @State private var isSaving = false
    @State private var showSaveSuccess = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 12) {
                    headerSection

                    Divider().background(Color.green.opacity(0.2))

                    musicSourcePicker

                    Divider().background(Color.green.opacity(0.2))

                    enableToggleSection

                    connectionStatusSection

                    connectActionSection

                    if activeConnected && runEmotionOnForSource {
                        playlistSection
                    }

                    saveSection
                }
                .padding(.vertical, 8)
            }
            .onAppear {
                spotifyManager.checkForPendingTokens()
                if spotifyManager.isConnected && spotifyManager.userPlaylists.isEmpty {
                    Task { await spotifyManager.loadUserPlaylists() }
                }
                if appleMusicManager.isConnected && appleMusicManager.userPlaylists.isEmpty {
                    Task { await appleMusicManager.loadUserPlaylists() }
                }
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack {
            Image(systemName: "music.note.list")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.green)
            Text("Music")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
    }

    // MARK: - Music Source Picker

    private var musicSourcePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Music source")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.gray)
            Picker("Source", selection: $musicSource) {
                Text("Spotify").tag(RunEmotionMusicSource.spotify)
                Text("Apple Music").tag(RunEmotionMusicSource.appleMusic)
            }
            .pickerStyle(.wheel)
            .frame(height: 52)
            .onChange(of: musicSource) { _, new in
                RunEmotionMusicSource.current = new
            }
        }
        .padding(.horizontal, 10)
    }

    // MARK: - Active Source Helpers

    private var activeConnected: Bool {
        switch musicSource {
        case .spotify: return spotifyManager.isConnected
        case .appleMusic: return appleMusicManager.isConnected
        }
    }

    private var runEmotionOnForSource: Bool {
        switch musicSource {
        case .spotify: return spotifyManager.spotifyEnabled
        case .appleMusic: return appleMusicManager.appleMusicEnabled
        }
    }

    // MARK: - Enable Toggle

    private var enableToggleSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Run Emotion")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
                Text("Mood-adaptive music")
                    .font(.system(size: 9))
                    .foregroundColor(.gray)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: {
                    switch musicSource {
                    case .spotify: return spotifyManager.spotifyEnabled
                    case .appleMusic: return appleMusicManager.appleMusicEnabled
                    }
                },
                set: { newValue in
                    switch musicSource {
                    case .spotify:
                        spotifyManager.spotifyEnabled = newValue
                        if !newValue { spotifyManager.disconnect() }
                    case .appleMusic:
                        appleMusicManager.appleMusicEnabled = newValue
                        if !newValue { appleMusicManager.disconnect() }
                    }
                }
            ))
                .labelsHidden()
                .tint(musicSource == .spotify ? .green : .pink)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.05))
        .cornerRadius(8)
        .padding(.horizontal, 10)
    }

    // MARK: - Connection Status

    private var connectionStatusSection: some View {
        let accent: Color = musicSource == .spotify
            ? (activeConnected ? .green : .orange)
            : (activeConnected ? .pink : .orange)

        return HStack(spacing: 6) {
            Circle()
                .fill(accent)
                .frame(width: 8, height: 8)

            Image(systemName: activeConnected ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 10))
                .foregroundColor(accent)

            Text(activeConnected ? "Connected" : "Disconnected")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(accent)

            Spacer()

            if musicSource == .spotify && !spotifyManager.activeDeviceName.isEmpty {
                Text(spotifyManager.activeDeviceName)
                    .font(.system(size: 9))
                    .foregroundColor(.gray)
                    .lineLimit(1)
            } else if musicSource == .appleMusic && !appleMusicManager.activeDeviceName.isEmpty {
                Text(appleMusicManager.activeDeviceName)
                    .font(.system(size: 9))
                    .foregroundColor(.gray)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(accent.opacity(0.1))
        )
        .padding(.horizontal, 10)
    }

    // MARK: - Connect / Disconnect

    private var connectActionSection: some View {
        VStack(spacing: 8) {
            switch musicSource {
            case .spotify:
                spotifyConnectContent
            case .appleMusic:
                appleMusicConnectContent
            }
        }
        .padding(.horizontal, 10)
    }

    @ViewBuilder
    private var spotifyConnectContent: some View {
        if spotifyManager.isConnected {
            Button(action: {
                spotifyManager.disconnect()
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "link.badge.plus")
                        .font(.system(size: 10))
                    Text("Disconnect")
                        .font(.system(size: 11, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color.red.opacity(0.3))
                .foregroundColor(.red)
                .cornerRadius(8)
            }

            Button(action: {
                Task { _ = await spotifyManager.discoverActiveDevice() }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 10))
                    Text("Find Device")
                        .font(.system(size: 10, weight: .medium))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(Color.cyan.opacity(0.2))
                .foregroundColor(.cyan)
                .cornerRadius(6)
            }
        } else {
            Button(action: {
                spotifyManager.authenticateViaPhone()
            }) {
                HStack(spacing: 6) {
                    if spotifyManager.isAuthenticating {
                        ProgressView()
                            .scaleEffect(0.6)
                            .tint(.white)
                    } else {
                        Image(systemName: "iphone.and.arrow.forward")
                            .font(.system(size: 10, weight: .bold))
                    }
                    Text(spotifyManager.isAuthenticating ? "Waiting for iPhone..." : "Connect on iPhone")
                        .font(.system(size: 11, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    LinearGradient(
                        colors: [Color.green.opacity(0.8), Color.green.opacity(0.6)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .foregroundColor(.white)
                .cornerRadius(8)
            }
            .disabled(spotifyManager.isAuthenticating)

            Button(action: {
                spotifyManager.authenticateWithWebAuth()
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "applewatch")
                        .font(.system(size: 10))
                    Text("Try on Watch")
                        .font(.system(size: 10, weight: .medium))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.1))
                .foregroundColor(.white.opacity(0.7))
                .cornerRadius(6)
            }
            .disabled(spotifyManager.isAuthenticating)

            if spotifyManager.isAuthenticating {
                Button(action: {
                    spotifyManager.cancelAuth()
                }) {
                    Text("Cancel")
                        .font(.system(size: 10, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(Color.red.opacity(0.2))
                        .foregroundColor(.red)
                        .cornerRadius(6)
                }
            }

            Text("Tap 'Connect on iPhone' — Spotify login opens in Safari on your iPhone. Once logged in the watch connects automatically.")
                .font(.system(size: 8))
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
        }

        if let error = spotifyManager.connectionError {
            Text(error)
                .font(.system(size: 9))
                .foregroundColor(.red)
                .multilineTextAlignment(.center)
        }
    }

    @ViewBuilder
    private var appleMusicConnectContent: some View {
        if appleMusicManager.isConnected {
            Button(action: {
                appleMusicManager.disconnect()
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "link.badge.plus")
                        .font(.system(size: 10))
                    Text("Disconnect")
                        .font(.system(size: 11, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color.red.opacity(0.3))
                .foregroundColor(.red)
                .cornerRadius(8)
            }
        } else {
            Button(action: {
                Task { await appleMusicManager.requestMusicAccess() }
            }) {
                HStack(spacing: 6) {
                    if appleMusicManager.isAuthenticating {
                        ProgressView()
                            .scaleEffect(0.6)
                            .tint(.white)
                    } else {
                        Image(systemName: "music.note")
                            .font(.system(size: 10, weight: .bold))
                    }
                    Text(appleMusicManager.isAuthenticating ? "Authorizing..." : "Connect Apple Music")
                        .font(.system(size: 11, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    LinearGradient(
                        colors: [Color.pink.opacity(0.8), Color.purple.opacity(0.6)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .foregroundColor(.white)
                .cornerRadius(8)
            }
            .disabled(appleMusicManager.isAuthenticating)

            Text("Grants MusicKit access to your Apple Music library on this watch.")
                .font(.system(size: 8))
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
        }

        if let error = appleMusicManager.connectionError {
            Text(error)
                .font(.system(size: 9))
                .foregroundColor(.red)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Playlist Selection

    private var playlistSection: some View {
        Group {
            switch musicSource {
            case .spotify: spotifyPlaylistSection
            case .appleMusic: appleMusicPlaylistSection
            }
        }
    }

    private var spotifyPlaylistSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Playlist")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.green)

                Spacer()

                Button(action: {
                    isLoadingPlaylists = true
                    Task {
                        await spotifyManager.loadUserPlaylists()
                        await MainActor.run { isLoadingPlaylists = false }
                    }
                }) {
                    if isLoadingPlaylists {
                        ProgressView()
                            .scaleEffect(0.6)
                            .tint(.green)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10))
                            .foregroundColor(.green)
                    }
                }
            }

            if !spotifyManager.masterPlaylistName.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "music.note")
                        .font(.system(size: 9))
                        .foregroundColor(.green)
                    Text(spotifyManager.masterPlaylistName)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                }
                .padding(.vertical, 2)
            }

            if spotifyManager.userPlaylists.isEmpty {
                Text("Tap refresh to load playlists")
                    .font(.system(size: 9))
                    .foregroundColor(.gray)
                    .padding(.vertical, 4)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(spotifyManager.userPlaylists) { playlist in
                            PlaylistRow(
                                playlist: playlist,
                                isSelected: spotifyManager.masterPlaylistId == playlist.id,
                                accentColor: .green,
                                onSelect: {
                                    spotifyManager.masterPlaylistId = playlist.id
                                    spotifyManager.masterPlaylistName = playlist.name
                                }
                            )
                        }
                    }
                }
                .frame(maxHeight: 120)
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.05))
        .cornerRadius(8)
        .padding(.horizontal, 10)
    }

    private var appleMusicPlaylistSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Playlist")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.pink)

                Spacer()

                Button(action: {
                    isLoadingPlaylists = true
                    Task {
                        await appleMusicManager.loadUserPlaylists()
                        await MainActor.run { isLoadingPlaylists = false }
                    }
                }) {
                    if isLoadingPlaylists {
                        ProgressView()
                            .scaleEffect(0.6)
                            .tint(.pink)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10))
                            .foregroundColor(.pink)
                    }
                }
            }

            if !appleMusicManager.masterPlaylistName.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "music.note")
                        .font(.system(size: 9))
                        .foregroundColor(.pink)
                    Text(appleMusicManager.masterPlaylistName)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                }
                .padding(.vertical, 2)
            }

            if appleMusicManager.userPlaylists.isEmpty {
                Text("Tap refresh to load playlists")
                    .font(.system(size: 9))
                    .foregroundColor(.gray)
                    .padding(.vertical, 4)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(appleMusicManager.userPlaylists) { playlist in
                            PlaylistRow(
                                playlist: playlist,
                                isSelected: appleMusicManager.masterPlaylistId == playlist.id,
                                accentColor: .pink,
                                onSelect: {
                                    appleMusicManager.masterPlaylistId = playlist.id
                                    appleMusicManager.masterPlaylistName = playlist.name
                                }
                            )
                        }
                    }
                }
                .frame(maxHeight: 120)
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.05))
        .cornerRadius(8)
        .padding(.horizontal, 10)
    }

    // MARK: - Save Section

    private var saveSection: some View {
        VStack(spacing: 6) {
            Button(action: saveSettings) {
                HStack(spacing: 6) {
                    if isSaving {
                        ProgressView()
                            .scaleEffect(0.7)
                            .tint(.white)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 10))
                    }
                    Text(isSaving ? "Saving..." : "Save")
                        .font(.system(size: 11, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color.green.opacity(0.7))
                .foregroundColor(.white)
                .cornerRadius(8)
            }
            .disabled(isSaving)

            if showSaveSuccess {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.green)
                    Text("Settings saved")
                        .font(.system(size: 9))
                        .foregroundColor(.green)
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 12)
    }

    // MARK: - Actions

    private func saveSettings() {
        guard let userId = authManager.currentUser?.id else { return }
        isSaving = true

        Task {
            let success = await supabaseManager.saveSpotifyDeviceSettings(
                userId: userId,
                spotifyEnabled: spotifyManager.spotifyEnabled,
                masterPlaylistId: spotifyManager.masterPlaylistId,
                targetHeartRate: nil
            )

            RunEmotionMusicSource.current = musicSource

            await MainActor.run {
                isSaving = false
                if success {
                    showSaveSuccess = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        withAnimation { showSaveSuccess = false }
                    }
                }
            }
        }
    }
}

// MARK: - Playlist Row

struct PlaylistRow: View {
    let playlist: SpotifyPlaylist
    let isSelected: Bool
    var accentColor: Color = .green
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 6) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 9))
                    .foregroundColor(isSelected ? accentColor : .gray)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        if playlist.isRunbot {
                            Image(systemName: "star.fill")
                                .font(.system(size: 7))
                                .foregroundColor(.yellow)
                        }
                        Text(playlist.name)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.white)
                            .lineLimit(1)
                    }
                    Text("\(playlist.trackCount) tracks")
                        .font(.system(size: 8))
                        .foregroundColor(.gray)
                }

                Spacer()
            }
            .padding(6)
            .background(isSelected ? accentColor.opacity(0.15) : Color.clear)
            .cornerRadius(6)
        }
    }
}
