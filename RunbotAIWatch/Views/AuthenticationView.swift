import SwiftUI

struct AuthenticationView: View {
    @EnvironmentObject var authManager: AuthenticationManager
    @EnvironmentObject var runTracker: RunTracker
    @EnvironmentObject var voiceManager: VoiceManager
    @EnvironmentObject var supabaseManager: SupabaseManager
    @State private var email = ""
    @State private var password = ""
    @State private var name = ""
    @State private var isSignUp = false
    
    var body: some View {
        emailPasswordView
    }
    
    // MARK: - Email/Password View
    private var emailPasswordView: some View {
        VStack(spacing: 12) {
            // Title
            Text("Sign In")
                .font(.headline)
                .foregroundColor(.white)
                .padding(.top, 8)
            
            // Email Input
            TextField("Email", text: $email)
                .textContentType(.emailAddress)
                .padding(8)
                .background(Color.gray.opacity(0.2))
                .cornerRadius(8)
            
            // Password Input
            SecureField("Password", text: $password)
                .textContentType(.password)
                .padding(8)
                .background(Color.gray.opacity(0.2))
                .cornerRadius(8)
            
            // Auth Button
            Button(action: authAction) {
                HStack {
                    if authManager.isLoading {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .black))
                            .scaleEffect(0.8)
                    }
                    Text(authManager.isLoading ? "Signing In..." : "Sign In")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(canLogin ? Color.cyan : Color.gray)
                .foregroundColor(.black)
                .cornerRadius(10)
            }
            .disabled(!canLogin)
            .padding(.top, 8)
            
            // Error Message
            if let error = authManager.errorMessage {
                Text(error)
                    .font(.caption2)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 12)
        .background(Color.black.ignoresSafeArea())
        .onAppear {
            print("🔐 [AuthView] View appeared")
        }
    }
    
    private var canLogin: Bool {
        !authManager.isLoading && !email.isEmpty && !password.isEmpty
    }
    
    private func authAction() {
        print("🔐 [AuthView] Auth action triggered - isSignUp: \(isSignUp)")
        print("🔐 [AuthView] Email: \(email), Password length: \(password.count)")
        
        Task {
            if isSignUp {
                await authManager.signup(email: email, password: password, name: name)
            } else {
                await authManager.login(email: email, password: password)
            }
            
            print("🔐 [AuthView] Auth completed - isAuthenticated: \(authManager.isAuthenticated)")
            
            // Request permissions immediately after successful login
            if authManager.isAuthenticated {
                // Initialize Supabase session with authenticated user
                if let userId = authManager.currentUser?.id {
                    supabaseManager.initializeSession(for: userId)
                    print("✅ [AuthView] Supabase session initialized for user: \(userId)")
                }
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    runTracker.requestLocationPermission()
                    print("📍 [AuthView] Requested location permission")
                }
            }
        }
    }
}

#Preview {
    AuthenticationView()
        .environmentObject(AuthenticationManager())
        .environmentObject(RunTracker())
        .environmentObject(VoiceManager())
        .environmentObject(SupabaseManager())
}
