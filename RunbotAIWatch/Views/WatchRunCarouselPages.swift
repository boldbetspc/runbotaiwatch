import SwiftUI
import MapKit
import CoreLocation

// MARK: - Cumulative vs-target + compact ETAs

struct WatchDisplacementETAPage: View {
    @ObservedObject var runTracker: RunTracker
    @ObservedObject var aiCoach: AICoachManager
    var userSettings: UserPreferences.Settings
    var currentZone: Int?

    private var coveredKm: Double { (runTracker.statsUpdate?.distance ?? 0) / 1000.0 }
    private var elapsedMin: Double { (runTracker.currentSession?.duration ?? 0) / 60.0 }
    private var avgPace: Double { runTracker.statsUpdate?.averagePace ?? 0 }
    private var curPace: Double { runTracker.statsUpdate?.pace ?? runTracker.statsUpdate?.effectivePace ?? 0 }
    private var targetPace: Double { userSettings.targetPaceMinPerKm }
    private var targetRaceKm: Double { userSettings.targetDistanceKm }

    var body: some View {
        let ctx = WatchRunStoryHelpers.liveTargetContext(
            runArc: aiCoach.runArcForUI,
            coveredKm: coveredKm,
            elapsedMin: elapsedMin,
            userTargetPace: targetPace
        )
        let rows = WatchRunStoryHelpers.etaProjectionRows(
            targetDistanceKm: targetRaceKm,
            coveredKm: coveredKm,
            currentPace: curPace > 0 ? curPace : avgPace,
            averagePace: avgPace,
            targetPace: targetPace
        )
        let smartIdx = WatchRunStoryHelpers.etaSmartScenarioIndex(
            rows: rows,
            fatigueRaw: aiCoach.lastFatigueLevel,
            injuryRaw: aiCoach.lastInjuryRiskFlag,
            currentZone: currentZone
        )

        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text("VS TARGET")
                    .font(.system(size: 9, weight: .heavy, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))

                compactWave(
                    entries: ctx.entries,
                    yNormalized: ctx.waveY,
                    cumulativeSeconds: ctx.cumulativeSeconds,
                    badgeMeters: ctx.badgeMeters,
                    badgeAhead: ctx.badgeAhead
                )
                .frame(height: 56)

                if targetRaceKm > 0 {
                    Text("FINISH \(String(format: "%.1f", targetRaceKm)) km")
                        .font(.system(size: 8, weight: .heavy, design: .monospaced))
                        .foregroundColor(.cyan.opacity(0.7))
                        .padding(.top, 2)

                    if let idx = smartIdx, rows.indices.contains(idx) {
                        let r = rows[idx]
                        HStack {
                            Text("AI")
                                .font(.system(size: 7, weight: .bold))
                                .foregroundColor(.black)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(r.color.opacity(0.9)))
                            Text(r.title)
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                            Spacer(minLength: 0)
                            Text(r.etaLabel)
                                .font(.system(size: 11, weight: .black, design: .monospaced))
                                .foregroundColor(r.color)
                        }
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(rows.prefix(4)) { row in
                            HStack(spacing: 4) {
                                Text(row.title)
                                    .font(.system(size: 8, weight: .heavy, design: .monospaced))
                                    .foregroundColor(.white.opacity(0.55))
                                    .frame(width: 36, alignment: .leading)
                                Text(row.paceLabel)
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .foregroundColor(row.color.opacity(0.95))
                                Spacer(minLength: 0)
                                Text(row.etaLabel)
                                    .font(.system(size: 10, weight: .black, design: .monospaced))
                            }
                        }
                    }
                    .padding(.top, 2)
                } else {
                    Text("Set race distance on iPhone for ETAs.")
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.45))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func compactWave(
        entries: [WatchRunStoryHelpers.ArcEntry],
        yNormalized: [CGFloat],
        cumulativeSeconds: Int,
        badgeMeters: Int?,
        badgeAhead: Bool
    ) -> some View {
        let statusColor: Color = badgeAhead
            ? Color(red: 0.25, green: 0.98, blue: 0.65)
            : Color(red: 1.0, green: 0.45, blue: 0.48)
        let statusText: String = {
            if let meters = badgeMeters {
                let value = abs(meters)
                if value >= 1000 {
                    return String(format: "%@%.2fkm", badgeAhead ? "+" : "−", Double(value) / 1000.0)
                }
                return "\(badgeAhead ? "+" : "−")\(value)m"
            }
            let value = abs(cumulativeSeconds)
            return "\(badgeAhead ? "+" : "−")\(value)s"
        }()

        VStack(alignment: .leading, spacing: 4) {
            Text(statusText)
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .foregroundColor(statusColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                    if yNormalized.count > 1 {
                        let n = yNormalized.count
                        Path { p in
                            for i in 0..<n {
                                let x = n == 1 ? w * 0.5 : CGFloat(i) / CGFloat(n - 1) * (w - 4) + 2
                                let yn = yNormalized[i]
                                let y = 2 + (1 - yn) * (h - 4)
                                let pt = CGPoint(x: x, y: y)
                                if i == 0 { p.move(to: pt) }
                                else {
                                    let prevX = n == 1 ? w * 0.5 : CGFloat(i - 1) / CGFloat(n - 1) * (w - 4) + 2
                                    let prevY = 2 + (1 - yNormalized[i - 1]) * (h - 4)
                                    let mid = (prevX + x) / 2
                                    p.addQuadCurve(to: pt, control: CGPoint(x: mid, y: prevY))
                                }
                            }
                        }
                        .stroke(Color.cyan.opacity(0.9), style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))

                        Path { p in
                            p.move(to: CGPoint(x: 2, y: h / 2))
                            p.addLine(to: CGPoint(x: w - 2, y: h / 2))
                        }
                        .stroke(Color.white.opacity(0.2), style: StrokeStyle(lineWidth: 0.6, dash: [3, 3]))
                    } else {
                        Text("Per-km splits fill this curve")
                            .font(.system(size: 8))
                            .foregroundColor(.white.opacity(0.35))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
    }
}

// MARK: - Compact route map

struct WatchRouteMapPage: View {
    let locations: [LocationPoint]

    @State private var mapPosition: MapCameraPosition = .automatic

    private var coordinates: [CLLocationCoordinate2D] {
        let raw = locations.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        guard raw.count > 100 else { return raw }
        let step = max(1, raw.count / 100)
        return stride(from: 0, to: raw.count, by: step).map { raw[$0] }
    }

    var body: some View {
        VStack(spacing: 4) {
            Text("ROUTE")
                .font(.system(size: 9, weight: .heavy, design: .monospaced))
                .foregroundColor(.white.opacity(0.5))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)

            if coordinates.count >= 2 {
                Map(position: $mapPosition) {
                    MapPolyline(coordinates: coordinates)
                        .stroke(Color.cyan, lineWidth: 2.5)
                }
                .mapStyle(.standard)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.cyan.opacity(0.35), lineWidth: 0.8)
                )
                .padding(.horizontal, 6)
                .onChange(of: coordinates.count) { _, _ in
                    mapPosition = .automatic
                }
            } else {
                Spacer()
                Text("Collecting GPS…")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.45))
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Fatigue / injury (tap for detail)

struct WatchFatigueInjuryPage: View {
    @ObservedObject var aiCoach: AICoachManager
    private enum DetailPanel: Equatable {
        case none, fatigue, injury
    }
    @State private var detailPanel: DetailPanel = .none

    private var fatigue: (Int, String) {
        WatchRunStoryHelpers.fatigueBucket(aiCoach.lastFatigueLevel)
    }
    private var injury: (Int, String) {
        WatchRunStoryHelpers.injuryBucket(aiCoach.lastInjuryRiskFlag)
    }

    var body: some View {
        VStack(spacing: 8) {
            Text("LOAD & RISK")
                .font(.system(size: 9, weight: .heavy, design: .monospaced))
                .foregroundColor(.white.opacity(0.5))

            HStack(alignment: .top, spacing: 10) {
                meterColumn(
                    title: "FATIGUE",
                    bucket: fatigue.0,
                    label: fatigue.1,
                    low: Color(red: 0.2, green: 0.85, blue: 0.45),
                    mid: Color(red: 1.0, green: 0.75, blue: 0.2),
                    high: Color(red: 1.0, green: 0.35, blue: 0.35),
                    inactive: false,
                    isExpanded: detailPanel == .fatigue
                ) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        detailPanel = detailPanel == .fatigue ? .none : .fatigue
                    }
                }
                meterColumn(
                    title: "INJURY",
                    bucket: injury.0,
                    label: injury.1,
                    low: Color(red: 0.25, green: 0.7, blue: 1.0),
                    mid: Color(red: 1.0, green: 0.55, blue: 0.2),
                    high: Color(red: 1.0, green: 0.25, blue: 0.45),
                    inactive: injury.0 < 0,
                    isExpanded: detailPanel == .injury
                ) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        detailPanel = detailPanel == .injury ? .none : .injury
                    }
                }
            }
            .padding(.horizontal, 6)

            if detailPanel == .fatigue {
                Text(truncate(fatigueDetailText, 260))
                    .font(.system(size: 8, weight: .regular))
                    .foregroundColor(.white.opacity(0.72))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.06)))
                    .padding(.horizontal, 6)
            } else if detailPanel == .injury {
                Text(truncate(injuryDetailText, 260))
                    .font(.system(size: 8, weight: .regular))
                    .foregroundColor(.white.opacity(0.72))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.06)))
                    .padding(.horizontal, 6)
            }

            Spacer(minLength: 0)
        }
        .padding(.top, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var fatigueDetailText: String {
        let s = aiCoach.lastFatigueLevel.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty || s == "—" {
            return "No fatigue line yet — updates after interval coaching."
        }
        return s
    }

    private var injuryDetailText: String {
        let s = aiCoach.lastInjuryRiskFlag.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty || s == "—" {
            return "No injury-risk flags from the latest analysis."
        }
        return s
    }

    private func truncate(_ s: String, _ max: Int) -> String {
        if s.count <= max { return s }
        return String(s.prefix(max)) + "…"
    }

    @ViewBuilder
    private func meterColumn(
        title: String,
        bucket: Int,
        label: String,
        low: Color,
        mid: Color,
        high: Color,
        inactive: Bool,
        isExpanded: Bool,
        onTapInfo: @escaping () -> Void
    ) -> some View {
        let active = !inactive && bucket >= 0
        let b = max(0, min(2, bucket))
        VStack(spacing: 4) {
            Text(title)
                .font(.system(size: 7, weight: .heavy, design: .monospaced))
                .foregroundColor(.white.opacity(0.4))
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(segmentColor(i: i, filled: active && i <= b, low: low, mid: mid, high: high, inactive: inactive))
                        .frame(width: 10, height: 22)
                }
            }
            Text(label)
                .font(.system(size: 9, weight: .heavy, design: .rounded))
                .foregroundColor(active ? .white.opacity(0.9) : .white.opacity(0.35))
            Button(action: onTapInfo) {
                Text(isExpanded ? "hide" : "info")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundColor(.cyan.opacity(0.85))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
    }

    private func segmentColor(i: Int, filled: Bool, low: Color, mid: Color, high: Color, inactive: Bool) -> Color {
        if inactive { return Color.white.opacity(0.08) }
        let base: Color = (i == 0) ? low : (i == 1 ? mid : high)
        return filled ? base : Color.white.opacity(0.12)
    }
}
