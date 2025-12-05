import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var userPreferences: UserPreferences
    @EnvironmentObject var supabaseManager: SupabaseManager
    @EnvironmentObject var authManager: AuthenticationManager
    
    @State private var showSaveSuccess = false
    @State private var isSaving = false
    
    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Header
                HStack {
                    Text("Settings")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                    Spacer()
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.gray)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                
                Divider()
                    .background(Color.cyan.opacity(0.2))
                
                ScrollView {
                    VStack(spacing: 12) {
                        // Coach Personality
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Coach")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.cyan)
                            
                            VStack(spacing: 6) {
                                ForEach(CoachPersonality.allCases, id: \.self) { personality in
                                    PersonalityButton(
                                        title: personality.rawValue,
                                        isSelected: userPreferences.settings.coachPersonality == personality,
                                        action: {
                                            userPreferences.updatePersonality(personality)
                                        }
                                    )
                                }
                            }
                        }
                        .padding(10)
                        .background(Color.black.opacity(0.5))
                        .cornerRadius(8)
                        
                        // Coach Energy - Vertical Layout
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Energy")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.cyan)
                            
                            VStack(spacing: 6) {
                                ForEach(CoachEnergy.allCases, id: \.self) { energy in
                                    EnergyButton(
                                        title: energy.rawValue,
                                        isSelected: userPreferences.settings.coachEnergy == energy,
                                        action: {
                                            userPreferences.updateEnergy(energy)
                                        }
                                    )
                                }
                            }
                        }
                        .padding(10)
                        .background(Color.black.opacity(0.5))
                        .cornerRadius(8)
                        
                        // Voice Selection
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Voice")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.cyan)
                            
                            VStack(spacing: 6) {
                                ForEach(VoiceOption.allCases, id: \.self) { voice in
                                    VoiceButton(
                                        title: voice.rawValue,
                                        isSelected: userPreferences.settings.voiceOption == voice,
                                        action: {
                                            userPreferences.updateVoice(voice)
                                        }
                                    )
                                }
                            }
                        }
                        .padding(10)
                        .background(Color.black.opacity(0.5))
                        .cornerRadius(8)
                        
                        // Feedback Frequency - Vertical Layout
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Feedback")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.cyan)
                            
                            VStack(spacing: 6) {
                                ForEach([1, 2, 5, 10], id: \.self) { frequency in
                                    FrequencyButton(
                                        title: frequency == 1 ? "1 km" : "\(frequency) km",
                                        isSelected: userPreferences.settings.feedbackFrequency == frequency,
                                        action: {
                                            userPreferences.updateFeedbackFrequency(frequency)
                                        }
                                    )
                                }
                            }
                        }
                        .padding(10)
                        .background(Color.black.opacity(0.5))
                        .cornerRadius(8)
                        
                        // Save Button
                        Button(action: savePreferences) {
                            HStack(spacing: 6) {
                                if isSaving {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                        .tint(.white)
                                } else {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 10, weight: .bold))
                                }
                                Text(isSaving ? "Saving..." : "Save")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(
                                LinearGradient(
                                    gradient: Gradient(colors: [Color(red: 0.1, green: 0.6, blue: 0.3), Color(red: 0.05, green: 0.5, blue: 0.2)]),
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .foregroundColor(.white)
                            .cornerRadius(8)
                            .disabled(isSaving)
                        }
                        .padding(.horizontal, 10)
                        .padding(.top, 4)
                        
                        // Success Message
                        if showSaveSuccess {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 10))
                                    .foregroundColor(.green)
                                Text("Saved successfully")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(.green)
                            }
                            .padding(8)
                            .background(Color.green.opacity(0.2))
                            .cornerRadius(6)
                            .padding(.horizontal, 10)
                            .transition(.opacity)
                        }
                        
                        // Logout Button
                        Button(action: logout) {
                            HStack(spacing: 6) {
                                Image(systemName: "door.left.hand.open")
                                    .font(.system(size: 10, weight: .semibold))
                                Text("Logout")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(
                                LinearGradient(
                                    gradient: Gradient(colors: [Color(red: 0.7, green: 0.2, blue: 0.2), Color(red: 0.6, green: 0.1, blue: 0.1)]),
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .foregroundColor(.white)
                            .cornerRadius(8)
                            .shadow(color: Color.red.opacity(0.4), radius: 4, y: 2)
                        }
                        .padding(.horizontal, 10)
                        .padding(.bottom, 12)
                    }
                    .padding(.vertical, 8)
                }
            }
        }
    }
    
    private func savePreferences() {
        isSaving = true
        guard let userId = authManager.currentUser?.id else {
            isSaving = false
            return
        }
        
        Task {
            let success = await supabaseManager.saveUserPreferences(userPreferences.settings, userId: userId)
            
            await MainActor.run {
                isSaving = false
                if success {
                    showSaveSuccess = true
                    print("✅ [SettingsView] Preferences saved successfully")
                    
                    // Hide success message after 2 seconds
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        withAnimation {
                            showSaveSuccess = false
                        }
                    }
                } else {
                    print("❌ [SettingsView] Failed to save preferences")
                }
            }
        }
    }
    
    private func logout() {
        print("🔴 [SettingsView] Logout button tapped")
        authManager.logout()
    }
}

// MARK: - Personality Button
struct PersonalityButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 9))
                    .foregroundColor(.cyan)
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white)
                Spacer()
            }
            .padding(8)
            .background(isSelected ? Color.cyan.opacity(0.2) : Color.black.opacity(0.3))
            .cornerRadius(6)
        }
    }
}

// MARK: - Energy Button
struct EnergyButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 9))
                    .foregroundColor(.orange)
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.orange)
                }
            }
            .padding(8)
            .background(isSelected ? Color.orange.opacity(0.2) : Color.black.opacity(0.3))
            .cornerRadius(6)
        }
    }
}

// MARK: - Voice Button
struct VoiceButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "speaker.wave.2")
                    .font(.system(size: 9))
                    .foregroundColor(.cyan)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white)
                    Text(title.contains("Apple") ? "System" : "OpenAI")
                        .font(.system(size: 8, weight: .regular))
                        .foregroundColor(.gray)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9))
                        .foregroundColor(.cyan)
                }
            }
            .padding(8)
            .background(isSelected ? Color.cyan.opacity(0.2) : Color.black.opacity(0.3))
            .cornerRadius(6)
        }
    }
}

// MARK: - Frequency Button
struct FrequencyButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "metronome")
                    .font(.system(size: 9))
                    .foregroundColor(.cyan)
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.green)
                }
            }
            .padding(8)
            .background(isSelected ? Color.green.opacity(0.2) : Color.black.opacity(0.3))
            .cornerRadius(6)
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(UserPreferences())
        .environmentObject(SupabaseManager())
        .environmentObject(AuthenticationManager())
}
