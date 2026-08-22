import Foundation

/// Live run-speed profile for the run cockpit. Scales the gap between
/// repeat submits, page-settle waits, and judge grace — but NEVER shrinks
/// safety watchdogs: a fast profile only trims non-safety waits, so a slow
/// profile can never be killed early and a turbo one can never wedge a run.
nonisolated enum SpeedProfile: String, CaseIterable, Codable, Identifiable, Sendable {
    case slow
    case normal
    case fast
    case turbo

    var id: String { rawValue }

    var label: String {
        switch self {
        case .slow: return "Slow"
        case .normal: return "Normal"
        case .fast: return "Fast"
        case .turbo: return "Turbo"
        }
    }

    /// Turtle → rabbit progression.
    var systemImage: String {
        switch self {
        case .slow: return "tortoise.fill"
        case .normal: return "tortoise"
        case .fast: return "hare"
        case .turbo: return "hare.fill"
        }
    }

    /// Multiplier applied to every non-safety wait (page settle, cookie
    /// grace, login-form poll). ≥1 stretches waits; <1 trims them.
    var settleMultiplier: Double {
        switch self {
        case .slow: return 1.75
        case .normal: return 1.0
        case .fast: return 0.7
        case .turbo: return 0.5
        }
    }

    /// Gap between repeat (extra) submits. The user's configured sure-login
    /// retries still run — they're just spaced by this profile.
    var repeatSubmitGap: Duration {
        switch self {
        case .slow: return .seconds(2.4)
        case .normal: return .seconds(1.2)
        case .fast: return .seconds(0.7)
        case .turbo: return .seconds(0.35)
        }
    }

    /// Multiplier applied to the user's configured repeat-submit delay so
    /// the dial scales the gap without overwriting their setting. Normal is
    /// exactly 1×; slow stretches it, fast/turbo tighten it.
    var submitGapMultiplier: Double {
        repeatSubmitGap.seconds / SpeedProfile.normal.repeatSubmitGap.seconds
    }

    /// Extra wait after a submit before the success judge is allowed to run.
    var judgeGrace: Duration {
        switch self {
        case .slow: return .seconds(2.0)
        case .normal: return .seconds(0.8)
        case .fast: return .seconds(0.4)
        case .turbo: return .seconds(0.15)
        }
    }

    /// Human-like pause between page settle and filling the form.
    var preFillPause: Duration {
        switch self {
        case .slow: return .seconds(1.1)
        case .normal: return .seconds(0.5)
        case .fast: return .seconds(0.25)
        case .turbo: return .seconds(0.1)
        }
    }

    /// Effective watchdog duration. Slow stretches watchdogs; fast and turbo
    /// keep the base — watchdogs never shrink.
    static func effectiveWatchdog(_ base: Duration, profile: SpeedProfile) -> Duration {
        .seconds(base.seconds * max(1.0, profile.settleMultiplier))
    }

    /// Scaled settle wait: the base settle time through this profile.
    static func scaledSettle(baseSeconds: Double, profile: SpeedProfile) -> Double {
        baseSeconds * profile.settleMultiplier
    }

    /// Persisted profile used when starting new runs.
    static var saved: SpeedProfile {
        get {
            SpeedProfile(rawValue: UserDefaults.standard.string(forKey: Self.savedKey) ?? "") ?? .normal
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.savedKey)
        }
    }

    private static let savedKey = "runSpeedProfile"
}

nonisolated extension Duration {
    /// Seconds as TimeInterval — shared by pacing + watchdog math.
    var seconds: TimeInterval {
        let c = components
        return TimeInterval(c.seconds) + TimeInterval(c.attoseconds) / 1_000_000_000_000_000_000
    }
}
