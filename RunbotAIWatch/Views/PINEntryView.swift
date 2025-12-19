import SwiftUI

struct PINEntryView: View {
    @EnvironmentObject var authManager: AuthenticationManager
    @State private var pin: String = ""
    @State private var confirmPin: String = ""
    @State private var isConfirming = false
    @State private var errorMessage: String?
    @State private var showSkip = false
    
    var isSetupMode: Bool
    
    init(isSetupMode: Bool = false) {
        self.isSetupMode = isSetupMode
    }
    
    var body: some View {
        VStack(spacing: 6) {
            // Title (smaller)
            Text(isSetupMode ? "Set Up PIN" : "Enter PIN")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
                .padding(.top, 4)
            
            // Instructions (smaller, optional - can be removed for compactness)
            if isSetupMode {
                Text("4-6 digits")
                    .font(.system(size: 9))
                    .foregroundColor(.gray.opacity(0.7))
            }
            
            // PIN Display (dots) - smaller
            pinDisplayView
            
            // Confirmation prompt (smaller)
            if isSetupMode && isConfirming {
                Text("Confirm")
                    .font(.system(size: 9))
                    .foregroundColor(.gray.opacity(0.7))
            }
            
            // Error message (smaller)
            if let error = errorMessage {
                Text(error)
                    .font(.system(size: 8))
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                    .lineLimit(2)
            }
            
            // Number pad (smaller buttons)
            VStack(spacing: 4) {
                ForEach(0..<3) { row in
                    HStack(spacing: 4) {
                        ForEach(1..<4) { col in
                            let number = row * 3 + col
                            NumberButton(number: number) {
                                handleNumberTap(number)
                            }
                        }
                    }
                }
                
                // Bottom row: 0 and backspace (smaller)
                HStack(spacing: 4) {
                    NumberButton(number: 0) {
                        handleNumberTap(0)
                    }
                    Button(action: {
                        if isConfirming {
                            if !confirmPin.isEmpty {
                                confirmPin.removeLast()
                            } else {
                                isConfirming = false
                            }
                        } else {
                            if !pin.isEmpty {
                                pin.removeLast()
                            }
                        }
                        errorMessage = nil
                    }) {
                        Image(systemName: "delete.left")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white)
                            .frame(width: 45, height: 38)
                            .background(Color.gray.opacity(0.3))
                            .cornerRadius(6)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)
            
            // Skip button (smaller, appears after delay)
            if showSkip {
                Button(action: {
                    if isSetupMode {
                        authManager.skipPINSetup()
                    } else {
                        authManager.skipPINEntry()
                    }
                }) {
                    Text("Skip")
                        .font(.system(size: 10))
                        .foregroundColor(.gray.opacity(0.7))
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .onAppear {
            // Show skip button after a delay (both setup and entry modes)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                showSkip = true
            }
        }
        .onChange(of: pin) { oldValue, newValue in
            // In setup mode, move to confirmation when first PIN is complete
            if isSetupMode && !isConfirming && newValue.count >= 4 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    startConfirmation()
                }
            }
        }
        .onChange(of: confirmPin) { oldValue, newValue in
            // Auto-validate when confirmation PIN is complete
            if isSetupMode && isConfirming && newValue.count >= 4 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    validatePIN()
                }
            }
        }
    }
    
    private func handleNumberTap(_ number: Int) {
        if isConfirming {
            guard confirmPin.count < 6 else { return }
            confirmPin.append(String(number))
            errorMessage = nil
            
            // Auto-validate when confirmation PIN is complete
            if confirmPin.count >= 4 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    validatePIN()
                }
            }
        } else {
            guard pin.count < 6 else { return }
            pin.append(String(number))
            errorMessage = nil
            
            // Auto-submit in entry mode when 4+ digits
            if !isSetupMode && pin.count >= 4 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    validatePIN()
                }
            }
        }
    }
    
    private func startConfirmation() {
        isConfirming = true
        confirmPin = ""
        errorMessage = nil
    }
    
    private func validatePIN() {
        if isSetupMode {
            if !isConfirming {
                // First PIN entry - move to confirmation
                startConfirmation()
                return
            } else {
                // Confirming PIN
                if pin == confirmPin {
                    let success = authManager.setupPIN(pin)
                    if success {
                        // Success - view will dismiss automatically
                        return
                    } else {
                        errorMessage = "Failed to save PIN. Please try again."
                        resetPIN()
                    }
                } else {
                    errorMessage = "PINs don't match. Please try again."
                    resetPIN()
                }
            }
        } else {
            // Entry mode - validate against stored PIN
            let success = authManager.validatePIN(pin)
            if success {
                // Success - view will dismiss automatically
                return
            } else {
                errorMessage = "Incorrect PIN. Please try again."
                pin = ""
            }
        }
    }
    
    private func resetPIN() {
        pin = ""
        confirmPin = ""
        isConfirming = false
    }
    
    private var pinDisplayView: some View {
        let displayPin = isConfirming ? confirmPin : pin
        let pinLength = max(4, displayPin.count)
        
        return HStack(spacing: 6) {
            ForEach(0..<pinLength, id: \.self) { index in
                let isFilled = index < displayPin.count
                Circle()
                    .fill(isFilled ? Color.cyan : Color.gray.opacity(0.3))
                    .frame(width: 10, height: 10)
            }
        }
        .padding(.vertical, 4)
    }
}

// Number button component (smaller for watch)
struct NumberButton: View {
    let number: Int
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Text("\(number)")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 45, height: 38)
                .background(Color.gray.opacity(0.3))
                .cornerRadius(6)
        }
    }
}

#Preview {
    PINEntryView(isSetupMode: true)
        .environmentObject(AuthenticationManager())
}

