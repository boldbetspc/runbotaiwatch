import Foundation

/// Watch-side client for the shared Supabase `fatigue-score` Edge Function.
/// Intentionally isolated — not wired into AICoachManager / RAGPerformanceAnalyzer.
/// All failures return nil so the existing Watch coaching flow cannot regress.
enum FatigueScoreClient {

    // MARK: - Feature flag
    /// UserDefaults-backed toggle. Independent from the iOS toggle (Watch stores its own).
    /// Default OFF — user enables from Watch Settings or inherits from paired iPhone
    /// (iOS writes `fatigueScoreV2Enabled` to UserDefaults; Watch reads its own copy).
    static let featureFlagKey = "fatigueScoreV2Enabled"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: featureFlagKey)
    }

    // MARK: - Contract (mirrors supabase/functions/fatigue-score/index.ts v2.x)
    struct RunSnapshot: Encodable {
        let hr_drift_pct: Double?
        let pace_cv: Double?
        let current_run_km: Double?
        // v2 — richer in-run context for solid Mistral citations.
        let current_pace_min_per_km: Double?
        let target_pace_min_per_km: Double?
        let target_distance_km: Double?
        let avg_hr: Double?
        let current_hr: Double?
        let duration_seconds: Double?
    }

    struct CumulativeLoad: Encodable {
        let acr_ratio: Double?
        let monotony: Double?
        let days_since_rest: Int?
        let resting_hr_recent: Int?
        let prior_injury_areas: [String]?
        let recent_run_count_7d: Int?
        let acute_load: Double?
        let chronic_load: Double?
        let strain_days: Int?
        let sleep_hours: Double?
        let hrv_ms: Double?
    }

    struct MLPrediction: Encodable {
        let probability: Double
        let weight: Double?
        let source: String?
    }

    struct Request: Encodable {
        let language: String?
        let run: RunSnapshot
        let load: CumulativeLoad
        let notes: String?
        let ml_prediction: MLPrediction?
        let injury_ml_prediction: MLPrediction?
        // v2 — energy reserve depletion probability (0..1).
        let energy_ml_prediction: MLPrediction?
    }

    struct Response: Decodable {
        // ── Fatigue (legacy contract) ──
        let score: Int
        let tier: String
        let drivers: [String]
        let explanation: String
        let model: String
        let endpoint: String?
        let fusion: String?
        let rules_score: Int?
        let ml_probability: Double?
        let latency_ms: Int?
        let chain_steps: [String]?
        // ── Injury (additive — absent on older edge fn deploys) ──
        let injury_score: Int?
        let injury_tier: String?
        let injury_drivers: [String]?
        let injury_rules_score: Int?
        let injury_ml_probability: Double?
        let injury_fusion: String?
        let injury_explanation: String?
        // ── Energy Reserve (v2 additive) ──
        let energy_reserve_score: Int?            // 0..100, % remaining
        let energy_reserve_depletion_score: Int?  // 0..100, complement
        let energy_reserve_tier: String?          // strong | steady | guarded | low
        let energy_reserve_drivers: [String]?
        let energy_reserve_rules_score: Int?
        let energy_reserve_ml_probability: Double?
        let energy_reserve_fusion: String?
        let energy_reserve_explanation: String?
        // ── Shared ──
        let fatigue_explanation: String?
        let next_km_cue: String?
        let version: String?
    }

    // MARK: - Call
    static func fetchScore(
        request: Request,
        timeout: TimeInterval = 6.0
    ) async -> Response? {
        guard isEnabled else {
            print("⌚️🔥 FatigueScoreClient(Watch) → SKIP (flag OFF)")
            return nil
        }
        guard let config = ConfigLoader.loadConfig(),
              let supabaseURL = config["SUPABASE_URL"] as? String,
              let anonKey = config["SUPABASE_ANON_KEY"] as? String,
              !supabaseURL.isEmpty, !anonKey.isEmpty else {
            print("⌚️🔥 FatigueScoreClient(Watch) → SKIP (Config.plist missing SUPABASE_URL/ANON_KEY)")
            return nil
        }
        guard let url = URL(string: "\(supabaseURL)/functions/v1/fatigue-score") else {
            print("⌚️🔥 FatigueScoreClient(Watch) → SKIP (bad URL)")
            return nil
        }

        // Watch stores the user JWT in UserDefaults under "sessionToken"
        // (see AuthenticationManager.swift). Fall back to anon if absent.
        let token = UserDefaults.standard.string(forKey: "sessionToken") ?? anonKey

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = timeout

        do {
            req.httpBody = try JSONEncoder().encode(request)
        } catch {
            return nil
        }

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                print("⌚️🔥 FatigueScoreClient(Watch) → FAIL (no HTTP response)")
                return nil
            }
            guard http.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8)?.prefix(180) ?? ""
                print("⌚️🔥 FatigueScoreClient(Watch) → FAIL HTTP \(http.statusCode): \(body)")
                return nil
            }
            do {
                return try JSONDecoder().decode(Response.self, from: data)
            } catch {
                let body = String(data: data, encoding: .utf8)?.prefix(180) ?? ""
                print("⌚️🔥 FatigueScoreClient(Watch) → FAIL decode: \(error.localizedDescription) body=\(body)")
                return nil
            }
        } catch {
            print("⌚️🔥 FatigueScoreClient(Watch) → FAIL network: \(error.localizedDescription)")
            return nil
        }
    }
}
