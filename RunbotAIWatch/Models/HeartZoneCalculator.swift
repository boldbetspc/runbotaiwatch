import Foundation

// MARK: - Heart Zone Calculator
class HeartZoneCalculator {
    
    // MARK: - Zone Calculation (Karvonen Method)
    
    /// Calculate heart rate zone using Karvonen Method
    /// - Parameters:
    ///   - currentHR: Current heart rate in BPM
    ///   - age: User's age
    ///   - restingHeartRate: User's resting heart rate in BPM
    /// - Returns: Zone number (1-5) or nil if calculation not possible
    static func currentZone(currentHR: Double, age: Int?, restingHeartRate: Int?) -> Int? {
        guard let age = age, let restingHR = restingHeartRate else {
            print("⚠️ [HeartZone] Cannot calculate zone - missing age or resting HR")
            return nil
        }
        
        // Karvonen Method
        let maxHR = 220 - age
        let hrr = maxHR - restingHR // Heart Rate Reserve
        
        // Zone thresholds (as percentages of HRR)
        let restingHRDouble = Double(restingHR)
        let hrrDouble = Double(hrr)
        let z1Min = restingHRDouble + (hrrDouble * 0.50) // 50% of HRR
        let z1Max = restingHRDouble + (hrrDouble * 0.60) // 60% of HRR
        let z2Max = restingHRDouble + (hrrDouble * 0.70) // 70% of HRR
        let z3Max = restingHRDouble + (hrrDouble * 0.80) // 80% of HRR
        let z4Max = restingHRDouble + (hrrDouble * 0.90) // 90% of HRR
        let z5Max = restingHRDouble + hrrDouble           // 100% of HRR
        
        // Determine current zone
        if currentHR < z1Min {
            return 1 // Below Z1, but still Z1
        } else if currentHR <= z1Max {
            return 1 // Zone 1: 50-60%
        } else if currentHR <= z2Max {
            return 2 // Zone 2: 60-70%
        } else if currentHR <= z3Max {
            return 3 // Zone 3: 70-80%
        } else if currentHR <= z4Max {
            return 4 // Zone 4: 80-90%
        } else if currentHR <= z5Max {
            return 5 // Zone 5: 90-100%
        } else {
            return 5 // Above Z5, but still Z5
        }
    }
    
    /// Get zone name from zone number
    static func zoneName(for zone: Int) -> String {
        switch zone {
        case 1: return "Recovery"
        case 2: return "Easy"
        case 3: return "Aerobic"
        case 4: return "Threshold"
        case 5: return "Maximum"
        default: return "Unknown"
        }
    }
    
    /// Get zone color for UI
    static func zoneColor(for zone: Int) -> Color {
        switch zone {
        case 1: return Color.gray      // Z1: Recovery
        case 2: return Color.blue       // Z2: Easy
        case 3: return Color.green      // Z3: Aerobic
        case 4: return Color.orange     // Z4: Threshold
        case 5: return Color.red        // Z5: Maximum
        default: return Color.gray
        }
    }
}

import SwiftUI




