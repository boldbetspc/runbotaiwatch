import SwiftUI

// MARK: - Devices Config View (Spotify Settings)
// Settings screen for Spotify: enable/disable toggle, connection status,
// Connect/Disconnect button, playlist picker, save to Supabase device_settings.
struct DevicesConfigView: View {
    @ObservedObject var spotifyManager: SpotifyManager
    @EnvironmentObject var supabaseManager: SupabaseManager
    @EnvironmentObject var authManager: AuthenticationManager
    
    @State private var isLoadingPlaylists = false
    @State private var isSaving = false
    @State private var showSaveSuccess = false
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            ScrollView {
                VStack(spacing: 12) {
                    // Header
                    headerSection
                    
                    Divider().background(Color.green.opacity(0.2))
                    
                    // Spotify Enable/Disable
                    enableToggleSection
                    
                    // Connection Status
                    connectionStatusSection
                    
                    // Connect / Disconnect
                    connectActionSection
                    
                    // Playlist Selection
                    if spotifyManager.isConnected && spotifyManager.spotifyEnabled {
                        playlistSection
                    }
                    
                    // Save Button
                    saveSection
                }
                .padding(.vertical, 8)
            }
            .onAppear {
                spotifyManager.checkForPendingTokens()
                if spotifyManager.isConnected && spotifyManager.userPlaylists.isEmpty {
                    Task { await spotifyManager.loadUserPlaylists() }
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
            Text("Spotify")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
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
                get: { spotifyManager.spotifyEnabled },
                set: { newValue in
                    spotifyManager.spotifyEnabled = newValue
                    if !newValue {
                        // Toggling off resets everything for a clean retry
                        spotifyManager.disconnect()
                    }
                }
            ))
                .labelsHidden()
                .tint(.green)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.05))
        .cornerRadius(8)
        .padding(.horizontal, 10)
    }
    
    // MARK: - Connection Status
    
    private var connectionStatusSection: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(spotifyManager.isConnected ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            
            Image(systemName: spotifyManager.isConnected ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 10))
                .foregroundColor(spotifyManager.isConnected ? .green : .orange)
            
            Text(spotifyManager.isConnected ? "Connected" : "Disconnected")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(spotifyManager.isConnected ? .green : .orange)
            
            Spacer()
            
            if !spotifyManager.activeDeviceName.isEmpty {
                Text(spotifyManager.activeDeviceName)
                    .font(.system(size: 9))
                    .foregroundColor(.gray)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(spotifyManager.isConnected ? Color.green.opacity(0.1) : Color.orange.opacity(0.1))
        )
        .padding(.horizontal, 10)
    }
    
    // MARK: - Connect / Disconnect
    
    private var connectActionSection: some View {
        VStack(spacing: 8) {
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
                // Primary: Connect via iPhone (avoids reCAPTCHA issues on watch browser)
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
                
                // Secondary: Try directly on watch
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
        .padding(.horizontal, 10)
    }
    
    // MARK: - Playlist Selection
    
    private var playlistSection: some View {
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
    let onSelect: () -> Void
    
    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 6) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 9))
                    .foregroundColor(isSelected ? .green : .gray)
                
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
            .background(isSelected ? Color.green.opacity(0.15) : Color.clear)
            .cornerRadius(6)
        }
    }
}

