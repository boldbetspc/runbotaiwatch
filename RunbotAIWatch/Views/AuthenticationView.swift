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
    @State private var pin = ""
    @State private var setupPIN = ""
    @State private var confirmPIN = ""
    
    var body: some View {
        // Show PIN login if enabled, otherwise show email/password
        if authManager.usePINLogin {
            pinLoginView
        } else if authManager.showPINSetup {
            pinSetupView
        } else {
            emailPasswordView
        }
    }
    
    // MARK: - PIN Login View
    private var pinLoginView: some View {
        VStack(spacing: 20) {
            Text("Enter PIN")
                .font(.headline)
                .foregroundColor(.white)
                .padding(.top, 20)
            
            // PIN dots
            HStack(spacing: 12) {
                ForEach(0..<4) { index in
                    Circle()
                        .fill(index < pin.count ? Color.cyan : Color.gray.opacity(0.3))
                        .frame(width: 12, height: 12)
                }
            }
            .padding(.vertical, 10)
            
            // Number pad
            VStack(spacing: 8) {
                ForEach(0..<3) { row in
                    HStack(spacing: 8) {
                        ForEach(1..<4) { col in
                            let number = row * 3 + col
                            Button(action: {
                                if pin.count < 4 {
                                    pin.append(String(number))
                                    #if canImport(WatchKit)
                                    WKInterfaceDevice.current().play(.click)
                                    #endif
                                    
                                    // Auto-submit when 4 digits entered
                                    if pin.count == 4 {
                                        Task {
                                            try? await Task.sleep(nanoseconds: 200_000_000) // 0.2s delay
                                            authManager.loginWithPIN(pin)
                                            pin = ""
                                        }
                                    }
                                }
                            }) {
                                Text("\(number)")
                                    .font(.title2)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.white)
                                    .frame(width: 44, height: 44)
                                    .background(Color.cyan.opacity(0.2))
                                    .cornerRadius(8)
                            }
                        }
                    }
                }
                
                // Bottom row: Delete, 0, Use Email
                HStack(spacing: 8) {
                    Button(action: {
                        if !pin.isEmpty {
                            pin.removeLast()
                            #if canImport(WatchKit)
                            WKInterfaceDevice.current().play(.click)
                            #endif
                        }
                    }) {
                        Image(systemName: "delete.left")
                            .font(.title3)
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .background(Color.gray.opacity(0.3))
                            .cornerRadius(8)
                    }
                    
                    Button(action: {
                        if pin.count < 4 {
                            pin.append("0")
                            #if canImport(WatchKit)
                            WKInterfaceDevice.current().play(.click)
                            #endif
                            
                            if pin.count == 4 {
                                Task {
                                    try? await Task.sleep(nanoseconds: 200_000_000)
                                    authManager.loginWithPIN(pin)
                                    pin = ""
                                }
                            }
                        }
                    }) {
                        Text("0")
                            .font(.title2)
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .background(Color.cyan.opacity(0.2))
                            .cornerRadius(8)
                    }
                    
                    Button(action: {
                        authManager.disablePIN()
                    }) {
                        Image(systemName: "envelope")
                            .font(.title3)
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .background(Color.orange.opacity(0.3))
                            .cornerRadius(8)
                    }
                }
            }
            .padding(.horizontal)
            
            if let error = authManager.errorMessage {
                Text(error)
                    .font(.caption2)
                    .foregroundColor(.red)
                    .padding(.horizontal)
            }
            
            Spacer()
        }
        .padding()
    }
    
    // MARK: - PIN Setup View
    private var pinSetupView: some View {
        VStack(spacing: 16) {
            Text("Setup PIN")
                    .font(.headline)
                    .foregroundColor(.white)
                .padding(.top, 20)
            
            Text("Create a 4-digit PIN for quick login")
                .font(.caption)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
            
            // PIN dots for setup
            HStack(spacing: 12) {
                ForEach(0..<4) { index in
                    Circle()
                        .fill(index < setupPIN.count ? Color.cyan : Color.gray.opacity(0.3))
                        .frame(width: 12, height: 12)
                }
            }
            .padding(.vertical, 8)
            
            if !setupPIN.isEmpty && setupPIN.count == 4 {
                Text("Confirm PIN")
                    .font(.caption)
                    .foregroundColor(.gray)
                
                HStack(spacing: 12) {
                    ForEach(0..<4) { index in
                        Circle()
                            .fill(index < confirmPIN.count ? Color.green : Color.gray.opacity(0.3))
                            .frame(width: 12, height: 12)
                    }
                }
                .padding(.bottom, 8)
            }
            
            // Number pad for setup
            VStack(spacing: 8) {
                ForEach(0..<3) { row in
                    HStack(spacing: 8) {
                        ForEach(1..<4) { col in
                            let number = row * 3 + col
                            Button(action: {
                                handlePINSetupInput(String(number))
                            }) {
                                Text("\(number)")
                                    .font(.title3)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.white)
                                    .frame(width: 44, height: 44)
                                    .background(Color.cyan.opacity(0.2))
                                    .cornerRadius(8)
                            }
                        }
                    }
                }
                
                HStack(spacing: 8) {
                    Button(action: {
                        if confirmPIN.count > 0 {
                            confirmPIN.removeLast()
                        } else if setupPIN.count > 0 {
                            setupPIN.removeLast()
                        }
                        #if canImport(WatchKit)
                        WKInterfaceDevice.current().play(.click)
                        #endif
                    }) {
                        Image(systemName: "delete.left")
                            .font(.title3)
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .background(Color.gray.opacity(0.3))
                            .cornerRadius(8)
                    }
                    
                    Button(action: {
                        handlePINSetupInput("0")
                    }) {
                        Text("0")
                            .font(.title3)
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .background(Color.cyan.opacity(0.2))
                            .cornerRadius(8)
                    }
                    
                    Button(action: {
                        // Skip PIN setup
                        authManager.showPINSetup = false
                    }) {
                        Text("Skip")
                            .font(.caption2)
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .background(Color.gray.opacity(0.3))
                            .cornerRadius(8)
                    }
                }
            }
            .padding(.horizontal)
            
            Spacer()
        }
        .padding()
    }
    
    private func handlePINSetupInput(_ digit: String) {
        #if canImport(WatchKit)
        WKInterfaceDevice.current().play(.click)
        #endif
        
        if setupPIN.count < 4 {
            setupPIN.append(digit)
        } else if confirmPIN.count < 4 {
            confirmPIN.append(digit)
            
            // Check if PINs match when confirm is complete
            if confirmPIN.count == 4 {
                Task {
                    try? await Task.sleep(nanoseconds: 300_000_000) // 0.3s delay
                    if setupPIN == confirmPIN {
                        if authManager.setupPIN(setupPIN) {
                            authManager.showPINSetup = false
                            setupPIN = ""
                            confirmPIN = ""
                        }
                    } else {
                        // PINs don't match
                        #if canImport(WatchKit)
                        WKInterfaceDevice.current().play(.failure)
                        #endif
                        setupPIN = ""
                        confirmPIN = ""
                    }
                }
            }
        }
    }
    
    // MARK: - Email/Password View
    private var emailPasswordView: some View {
        ScrollView {
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
        }
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
                    voiceManager.requestMicrophonePermission()
                    print("📍🎤 [AuthView] Requested location and microphone permissions")
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
