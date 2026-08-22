import SwiftUI

/// Single source of truth for run-status dot colors and pill labels, keyed
/// by a shared status-key space so the single-window and grid runners can
/// never drift apart again. Previously three private copies existed.
enum RunStatusStyle {
    static let amber = Color(red: 1.0, green: 0.75, blue: 0.1)

    static func color(for key: String) -> Color {
        switch key {
        case "idle": return .secondary
        case "navigating": return .blue
        case "filling": return .cyan
        case "submitting": return .indigo
        case "waiting": return .yellow
        case "burning": return .orange
        case "success": return .green
        case "finished": return .mint
        case "pairWait": return .teal
        case "paused": return amber
        case "frozen": return .indigo
        default: return .secondary
        }
    }

    static func label(for key: String) -> String {
        switch key {
        case "idle": return "idle"
        case "navigating": return "loading"
        case "filling": return "filling"
        case "submitting": return "submitting"
        case "waiting": return "watching"
        case "burning": return "burning"
        case "success": return "success"
        case "finished": return "done"
        case "pairWait": return "linked"
        case "paused": return "paused"
        case "frozen": return "frozen"
        default: return key
        }
    }
}

extension BrowserViewModel.RCRStatus {
    /// Shared status key for `RunStatusStyle`.
    var styleKey: String {
        switch self {
        case .idle: return "idle"
        case .navigating: return "navigating"
        case .filling: return "filling"
        case .submitting: return "submitting"
        case .waiting: return "waiting"
        case .burning: return "burning"
        case .success: return "success"
        }
    }
}

extension QuadSession.Status {
    /// Shared status key for `RunStatusStyle`.
    var styleKey: String {
        switch self {
        case .idle: return "idle"
        case .navigating: return "navigating"
        case .filling: return "filling"
        case .submitting: return "submitting"
        case .waiting: return "waiting"
        case .burning: return "burning"
        case .success: return "success"
        case .finished: return "finished"
        case .pairWait: return "pairWait"
        }
    }
}
