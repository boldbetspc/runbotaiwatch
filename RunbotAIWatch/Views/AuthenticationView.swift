import SwiftUI
import HealthKit

struct AuthenticationView: View {
    @EnvironmentObject var authManager: AuthenticationManager
    @EnvironmentObject var runTracker: RunTracker
    @EnvironmentObject var voiceManager: VoiceManager
    @EnvironmentObject var supabaseManager: SupabaseManager
    @EnvironmentObject var healthManager: HealthManager
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
                
                // STEP 1: Request HealthKit authorization FIRST (before location)
                // Always request on login to ensure dialog shows (even if previously denied, user can change in Settings)
                print("💓 [AuthView] STEP 1: Requesting HealthKit authorization on login...")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    // Request authorization - this will show dialog if notDetermined, or do nothing if denied/authorized
                    healthManager.requestHealthDataAccess()
                    print("✅ [AuthView] HealthKit authorization request submitted")
                    
                    // Check status after request
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        let workoutType = HKObjectType.workoutType()
                        let heartRateType = HKQuantityType.quantityType(forIdentifier: .heartRate)!
                        let healthStore = HKHealthStore()
                        let workoutStatus = healthStore.authorizationStatus(for: workoutType)
                        let hrStatus = healthStore.authorizationStatus(for: heartRateType)
                        
                        print("💓 [AuthView] HealthKit status after request:")
                        print("   - Workout: \(workoutStatus.rawValue)")
                        print("   - HR: \(hrStatus.rawValue)")
                        
                        // Check if authorization was granted
                        if workoutStatus == .sharingAuthorized && hrStatus == .sharingAuthorized {
                            print("✅ [AuthView] HealthKit authorization GRANTED")
                        } else if workoutStatus == .notDetermined || hrStatus == .notDetermined {
                            print("⚠️ [AuthView] HealthKit authorization still notDetermined - dialog may not have shown")
                            print("💡 [AuthView] Check: Xcode > Signing & Capabilities > HealthKit entitlement enabled")
                        } else {
                            print("❌ [AuthView] HealthKit authorization DENIED - user must enable in Settings")
                        }
                        
                        // STEP 2: Request location permission AFTER HealthKit (with delay to avoid overlap)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            print("📍 [AuthView] STEP 2: Requesting location permission...")
                            runTracker.requestLocationPermission()
                            print("✅ [AuthView] Location permission request submitted")
                        }
                    }
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
        .environmentObject(HealthManager())
}
