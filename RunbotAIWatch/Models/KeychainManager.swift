import Foundation
import Security

/// KeychainManager: Secure storage for PIN and sensitive data
/// Uses iOS/watchOS Keychain for encryption at rest
class KeychainManager {
    static let shared = KeychainManager()
    
    private init() {}
    
    // MARK: - Keychain Keys
    private enum KeychainKey {
        static let pin = "com.runbotai.watchapp.pin"
        static let pinEnabled = "com.runbotai.watchapp.pinEnabled"
        static let pinUserId = "com.runbotai.watchapp.pinUserId" // Store user ID with PIN
    }
    
    // MARK: - PIN Management
    
    /// Save PIN securely to Keychain (only digits 1-9 allowed, no 0)
    /// Also stores the user ID to make PIN user-specific
    func savePIN(_ pin: String, userId: String? = nil) -> Bool {
        guard pin.count >= 4, pin.count <= 6, pin.allSatisfy({ $0.isNumber && $0 != "0" }) else {
            print("❌ [Keychain] Invalid PIN format - must be 4-6 digits (1-9 only, no 0)")
            return false
        }
        
        // Convert PIN to Data
        guard let data = pin.data(using: .utf8) else {
            return false
        }
        
        // Delete any existing PIN first
        deletePIN()
        
        // Save new PIN
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: KeychainKey.pin,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        
        let status = SecItemAdd(query as CFDictionary, nil)
        
        if status == errSecSuccess {
            print("✅ [Keychain] PIN saved successfully")
            // Store user ID with PIN to make it user-specific
            if let userId = userId {
                UserDefaults.standard.set(userId, forKey: KeychainKey.pinUserId)
                print("✅ [Keychain] PIN associated with user ID: \(userId)")
            }
            UserDefaults.standard.set(true, forKey: KeychainKey.pinEnabled)
            return true
        } else {
            print("❌ [Keychain] Failed to save PIN: \(status)")
            return false
        }
    }
    
    /// Retrieve PIN from Keychain
    func getPIN() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: KeychainKey.pin,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        if status == errSecSuccess,
           let data = result as? Data,
           let pin = String(data: data, encoding: .utf8) {
            return pin
        }
        
        return nil
    }
    
    /// Validate PIN against stored value
    func validatePIN(_ enteredPIN: String) -> Bool {
        guard let storedPIN = getPIN() else {
            print("⚠️ [Keychain] No PIN stored")
            return false
        }
        
        let isValid = enteredPIN == storedPIN
        print(isValid ? "✅ [Keychain] PIN validated" : "❌ [Keychain] Invalid PIN")
        return isValid
    }
    
    /// Delete PIN from Keychain
    func deletePIN() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: KeychainKey.pin
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        
        if status == errSecSuccess || status == errSecItemNotFound {
            print("✅ [Keychain] PIN deleted")
            UserDefaults.standard.set(false, forKey: KeychainKey.pinEnabled)
            UserDefaults.standard.removeObject(forKey: KeychainKey.pinUserId)
        }
    }
    
    /// Check if PIN is enabled for the current user
    /// Returns true only if PIN exists AND belongs to the specified user
    func isPINEnabled(forUserId userId: String? = nil) -> Bool {
        // First check if PIN flag is set
        guard UserDefaults.standard.bool(forKey: KeychainKey.pinEnabled) else {
            return false
        }
        
        // If user ID provided, verify PIN belongs to this user
        if let userId = userId {
            let pinUserId = UserDefaults.standard.string(forKey: KeychainKey.pinUserId)
            if pinUserId != userId {
                print("⚠️ [Keychain] PIN exists but belongs to different user (stored: \(pinUserId ?? "none"), current: \(userId))")
                // Clear stale PIN data
                deletePIN()
                return false
            }
        }
        
        // Also verify PIN actually exists in Keychain
        return getPIN() != nil
    }
    
    /// Get the user ID associated with the PIN
    func getPINUserId() -> String? {
        return UserDefaults.standard.string(forKey: KeychainKey.pinUserId)
    }
    
    // MARK: - Generic Keychain Operations
    
    /// Save any string securely
    func save(_ value: String, forKey key: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        
        // Delete existing
        delete(forKey: key)
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }
    
    /// Retrieve any string
    func get(forKey key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        if status == errSecSuccess,
           let data = result as? Data,
           let value = String(data: data, encoding: .utf8) {
            return value
        }
        
        return nil
    }
    
    /// Delete any value
    func delete(forKey key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]
        
        SecItemDelete(query as CFDictionary)
    }
}

