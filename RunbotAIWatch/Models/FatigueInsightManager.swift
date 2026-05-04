import Foundation
import Combine

/// Watch-side: publishes Mistral-explained FATIGUE · INJURY · ENERGY-RESERVE insights and
/// a shared next-km cue. Uses the same Supabase `fatigue-score` Edge Function (LangChain →
/// Mistral Small) as iOS.
///
/// Load context (ACR, acute/chronic, strain, sleep, HRV) is mirrored from the paired iPhone
/// via `recoveryLoadSnapshot` in WatchConnectivityManager → UserDefaults keys `recovery.*`.
///
/// Hard isolation:
///   • Never reads / writes AICoachManager state.
///   • Network/parse failures leave previously-published values intact.
///   • Feature-flag gated via `FatigueScoreClient.isEnabled`.
@MainActor
final class FatigueInsightManager: ObservableObject {

    // MARK: - Published — Fatigue
    @Published var tier: String? = nil
    @Published var fatigueExplanation: String? = nil

    // MARK: - Published — Injury
    @Published var injuryTier: String? = nil
    @Published var injuryExplanation: String? = nil

    // MARK: - Published — Energy Reserve (v2)
    @Published var energyReserveTier: String? = nil       // strong | steady | guarded | low
    @Published var energyReservePercent: Int? = nil       // 0..100
    @Published var energyReserveExplanation: String? = nil

    // MARK: - Published — shared cue + meta
    @Published var nextKmCue: String? = nil
    @Published var explanation: String? = nil             // legacy combined string
    @Published var isLoading: Bool = false
    @Published var lastUpdate: Date? = nil
    @Published var lastModel: String? = nil

    private let minIntervalBetweenCalls: TimeInterval = 12

    func refresh(
        fatigue: String,
        injury: String,
        hrDriftPercent: Double? = nil,
        paceCV: Double? = nil,
        currentRunKm: Double? = nil,
        currentPaceMinPerKm: Double? = nil,
        targetPaceMinPerKm: Double? = nil,
        targetDistanceKm: Double? = nil,
        avgHR: Double? = nil,
        currentHR: Double? = nil,
        durationSeconds: Double? = nil,
        bypassCooldown: Bool = false
    ) {
        guard FatigueScoreClient.isEnabled else {
            print("⌚️🔥 FatigueInsight.refresh(Watch) → SKIP (flag OFF)")
            return
        }
        let trimmedFatigue = fatigue.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedInjury = injury.trimmingCharacters(in: .whitespacesAndNewlines)

        let hasFatigueSignal = !trimmedFatigue.isEmpty && trimmedFatigue != "—"
        let hasInjurySignal  = !trimmedInjury.isEmpty  && trimmedInjury  != "—"
        let hasDriftSignal   = (hrDriftPercent ?? 0) >= 3.0
        let hasRunKm         = (currentRunKm ?? 0) >= 0.05
        let hasWeeklyLoad    = recoveryACRFromDefaults() != nil
            || UserDefaults.standard.object(forKey: "recovery.strain_days") != nil

        guard hasFatigueSignal || hasInjurySignal || hasDriftSignal || hasRunKm || hasWeeklyLoad else {
            print("⌚️🔥 FatigueInsight.refresh(Watch) → SKIP (no signals)")
            return
        }

        if !bypassCooldown,
           let last = lastUpdate,
           Date().timeIntervalSince(last) < minIntervalBetweenCalls {
            print("⌚️🔥 FatigueInsight.refresh(Watch) → SKIP (cooldown)")
            return
        }

        print("⌚️🔥 FatigueInsight.refresh(Watch) → DISPATCH (f=\(trimmedFatigue), i=\(trimmedInjury), drift=\(String(describing: hrDriftPercent)), km=\(currentRunKm ?? 0))")

        Task { [weak self] in
            await self?.fetch(
                fatigue: trimmedFatigue.isEmpty ? "—" : trimmedFatigue,
                injury: trimmedInjury.isEmpty ? "—" : trimmedInjury,
                hrDriftPercent: hrDriftPercent,
                paceCV: paceCV,
                currentRunKm: currentRunKm,
                currentPaceMinPerKm: currentPaceMinPerKm,
                targetPaceMinPerKm: targetPaceMinPerKm,
                targetDistanceKm: targetDistanceKm,
                avgHR: avgHR,
                currentHR: currentHR,
                durationSeconds: durationSeconds
            )
        }
    }

    func clear() {
        tier = nil
        fatigueExplanation = nil
        injuryTier = nil
        injuryExplanation = nil
        energyReserveTier = nil
        energyReservePercent = nil
        energyReserveExplanation = nil
        nextKmCue = nil
        explanation = nil
        isLoading = false
        lastUpdate = nil
        lastModel = nil
    }

    // MARK: - Fetch

    private func fetch(
        fatigue: String,
        injury: String,
        hrDriftPercent: Double?,
        paceCV: Double?,
        currentRunKm: Double?,
        currentPaceMinPerKm: Double?,
        targetPaceMinPerKm: Double?,
        targetDistanceKm: Double?,
        avgHR: Double?,
        currentHR: Double?,
        durationSeconds: Double?
    ) async {
        isLoading = true
        defer { isLoading = false }

        let load = loadFromRecoveryDefaults()
        let acr = load.acr_ratio

        var fatigueProb = probabilityFromFatigueText(fatigue)
        if let d = hrDriftPercent, d >= 5.0 { fatigueProb = min(0.9, max(fatigueProb, 0.35 + d / 200.0)) }
        if let d = hrDriftPercent, d < 0 { fatigueProb = max(0.05, fatigueProb * 0.9) }

        let injuryProb = injuryProbability(
            acr: acr,
            daysSinceRest: load.days_since_rest,
            strainDays: load.strain_days,
            hrDrift: hrDriftPercent,
            paceCV: paceCV,
            currentRunKm: currentRunKm,
            priorInjury: false,
            sleepHours: load.sleep_hours,
            injuryLabel: injury
        )

        let energyDepletionProb = energyDepletionProbability(
            currentRunKm: currentRunKm,
            targetDistanceKm: targetDistanceKm,
            currentPaceMinPerKm: currentPaceMinPerKm,
            targetPaceMinPerKm: targetPaceMinPerKm,
            paceCV: paceCV,
            hrDriftPercent: hrDriftPercent,
            currentHR: currentHR,
            avgHR: avgHR,
            acr: acr,
            strainDays: load.strain_days,
            daysSinceRest: load.days_since_rest,
            sleepHours: load.sleep_hours,
            fatigueLabel: fatigue
        )

        var notes = "Runbot(Watch) — fatigue: \(fatigue); injury: \(injury)"
        if let d = hrDriftPercent { notes += "; hr_drift: \(String(format: "%.1f", d))%" }
        if let c = paceCV { notes += "; pace_cv: \(String(format: "%.3f", c))" }
        if let km = currentRunKm { notes += "; run_km: \(String(format: "%.2f", km))" }
        if let a = acr { notes += "; acr: \(String(format: "%.2f", a))" }

        let req = FatigueScoreClient.Request(
            language: "en",
            run: .init(
                hr_drift_pct: hrDriftPercent,
                pace_cv: paceCV,
                current_run_km: currentRunKm,
                current_pace_min_per_km: currentPaceMinPerKm,
                target_pace_min_per_km: targetPaceMinPerKm,
                target_distance_km: targetDistanceKm,
                avg_hr: avgHR,
                current_hr: currentHR,
                duration_seconds: durationSeconds
            ),
            load: load,
            notes: notes,
            ml_prediction: .init(
                probability: fatigueProb,
                weight: 1.0,
                source: "runbot:watch_derived"
            ),
            injury_ml_prediction: .init(
                probability: injuryProb,
                weight: 0.6,
                source: "runbot:watch_injury_rules_v1"
            ),
            energy_ml_prediction: .init(
                probability: energyDepletionProb,
                weight: 0.5,
                source: "runbot:watch_energy_rules_v1"
            )
        )

        let started = Date()
        guard let resp = await FatigueScoreClient.fetchScore(request: req, timeout: 6) else {
            print("⌚️🔥 FatigueInsight.fetch(Watch) → FAIL (nil, \(Int(Date().timeIntervalSince(started) * 1000))ms)")
            return
        }
        print("⌚️🔥 FatigueInsight.fetch(Watch) → OK f=\(resp.tier) i=\(resp.injury_tier ?? "?") e=\(resp.energy_reserve_tier ?? "?") (\(resp.energy_reserve_score ?? -1)%)")
        self.tier = resp.tier
        self.fatigueExplanation = resp.fatigue_explanation ?? extractFirstLine(resp.explanation)
        self.injuryTier = resp.injury_tier
        self.injuryExplanation = resp.injury_explanation
        self.energyReserveTier = resp.energy_reserve_tier
        self.energyReservePercent = resp.energy_reserve_score
        self.energyReserveExplanation = resp.energy_reserve_explanation
        self.nextKmCue = resp.next_km_cue
        self.explanation = resp.explanation
        self.lastModel = resp.model
        self.lastUpdate = Date()
    }

    private func extractFirstLine(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.split(whereSeparator: \.isNewline).first.map(String.init)
    }

    // MARK: - Recovery defaults (from paired iPhone)

    private func loadFromRecoveryDefaults() -> FatigueScoreClient.CumulativeLoad {
        let d = UserDefaults.standard
        return FatigueScoreClient.CumulativeLoad(
            acr_ratio: recoveryACRFromDefaults(),
            monotony: nil,
            days_since_rest: intIfSet("recovery.days_since_rest"),
            resting_hr_recent: intIfSet("recovery.resting_hr_recent"),
            prior_injury_areas: nil,
            recent_run_count_7d: intIfSet("recovery.run_count_7d"),
            acute_load: optionalDoubleKey("recovery.acute_load"),
            chronic_load: optionalDoubleKey("recovery.chronic_load"),
            strain_days: intIfSet("recovery.strain_days"),
            sleep_hours: optionalDoubleKey("recovery.sleep_hours"),
            hrv_ms: optionalDoubleKey("recovery.hrv_ms")
        )
    }

    private func recoveryACRFromDefaults() -> Double? {
        optionalDoubleKey("recovery.acr_ratio")
    }

    private func optionalDoubleKey(_ key: String) -> Double? {
        let d = UserDefaults.standard
        guard d.object(forKey: key) != nil else { return nil }
        let v = d.double(forKey: key)
        return v
    }

    private func intIfSet(_ key: String) -> Int? {
        let d = UserDefaults.standard
        guard d.object(forKey: key) != nil else { return nil }
        return d.integer(forKey: key)
    }

    private func probabilityFromFatigueText(_ raw: String) -> Double {
        let s = raw.lowercased()
        if s.contains("critical") || s == "high" { return 0.80 }
        if s.contains("elevated") { return 0.60 }
        if s.contains("moderate") { return 0.45 }
        if s.contains("fresh") || s == "low" || s == "baseline" { return 0.15 }
        return 0.30
    }

    /// Rule-based injury-risk probability — aligned with iOS `FatigueInsightManager`.
    private func injuryProbability(
        acr: Double?,
        daysSinceRest: Int?,
        strainDays: Int?,
        hrDrift: Double?,
        paceCV: Double?,
        currentRunKm: Double?,
        priorInjury: Bool,
        sleepHours: Double?,
        injuryLabel: String
    ) -> Double {
        var z: Double = -1.8

        if let a = acr {
            if a > 1.5 { z += 1.4 }
            else if a > 1.3 { z += 0.9 }
            else if a < 0.8 { z += 0.4 }
        }
        if let d = daysSinceRest { z += max(0, Double(d - 4)) * 0.12 }
        if let s = strainDays { z += Double(s) * 0.18 }
        if let drift = hrDrift {
            if drift > 8 { z += 0.7 }
            else if drift > 5 { z += 0.35 }
        }
        if let cv = paceCV, cv > 0.1 { z += 0.5 }
        if let km = currentRunKm, km >= 10, let a = acr, a > 1.2 { z += 0.3 }
        if priorInjury { z += 0.35 }
        if let s = sleepHours, s < 6.0 { z += 0.25 }

        let il = injuryLabel.lowercased()
        if il.contains("high") || il.contains("severe") { z += 0.8 }
        else if il.contains("moderate") { z += 0.4 }

        let p = 1.0 / (1.0 + exp(-z))
        return min(0.95, max(0.05, p))
    }

    // MARK: - Energy depletion probability (mirrors iOS logic)
    //
    // Returns 0..1, where 1 = empty tank. Sent to the edge function as
    // `energy_ml_prediction.probability` so the server can fuse rules + this signal.
    private func energyDepletionProbability(
        currentRunKm: Double?,
        targetDistanceKm: Double?,
        currentPaceMinPerKm: Double?,
        targetPaceMinPerKm: Double?,
        paceCV: Double?,
        hrDriftPercent: Double?,
        currentHR: Double?,
        avgHR: Double?,
        acr: Double?,
        strainDays: Int?,
        daysSinceRest: Int?,
        sleepHours: Double?,
        fatigueLabel: String
    ) -> Double {
        var z: Double = -1.6

        if let target = targetDistanceKm, target > 0, let covered = currentRunKm {
            let frac = min(1.0, max(0, covered / target))
            z += frac * 2.4
        } else if let covered = currentRunKm {
            z += min(2.0, covered * 0.20)
        }

        if let d = hrDriftPercent {
            if d > 8 { z += 0.9 }
            else if d > 5 { z += 0.5 }
            else if d > 3 { z += 0.25 }
        }
        if let cur = currentHR, let avg = avgHR, avg > 0, cur - avg > 6 {
            z += 0.35
        }

        if let cur = currentPaceMinPerKm, let tgt = targetPaceMinPerKm, tgt > 0 {
            let ratio = cur / tgt
            if ratio > 1.10 { z += 0.55 }
            else if ratio > 1.05 { z += 0.30 }
        }
        if let cv = paceCV, cv > 0.10 { z += 0.30 }

        if let a = acr {
            if a > 1.5 { z += 0.65 }
            else if a > 1.3 { z += 0.40 }
        }
        if let s = strainDays, s >= 3 { z += 0.30 }
        if let r = daysSinceRest, r > 5 { z += 0.20 }

        if let sleep = sleepHours {
            if sleep < 6 { z += 0.40 }
            else if sleep >= 8 { z -= 0.25 }
        }

        let lf = fatigueLabel.lowercased()
        if lf.contains("critical") || lf == "high" { z += 0.7 }
        else if lf.contains("elevated") { z += 0.4 }
        else if lf.contains("moderate") { z += 0.2 }

        let p = 1.0 / (1.0 + exp(-z))
        return min(0.95, max(0.05, p))
    }
}
