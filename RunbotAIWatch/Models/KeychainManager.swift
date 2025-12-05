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
    }
    
    // MARK: - PIN Management
    
    /// Save PIN securely to Keychain
    func savePIN(_ pin: String) -> Bool {
        guard pin.count >= 4, pin.count <= 6, pin.allSatisfy({ $0.isNumber }) else {
            print("❌ [Keychain] Invalid PIN format")
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
        }
    }
    
    /// Check if PIN is enabled
    func isPINEnabled() -> Bool {
        return UserDefaults.standard.bool(forKey: KeychainKey.pinEnabled)
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

