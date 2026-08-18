import Foundation
import SwiftUI
import WebKit

/// One of up to sixteen parallel browser sessions used in multi-window mode
/// (grids of 4, 6, 8, 9, 12, or 16). Owns its own WKWebView (with an isolated
/// `WKWebsiteDataStore`) and its own RCR progress so every session can run
/// completely independently of the others.
@Observable
@MainActor
final class QuadSession: Identifiable {
    enum Status: String {
        case idle, navigating, filling, submitting, waiting, burning, success, finished
        /// Dual-quad only: this side finished its result for the current
        /// credential and is waiting on its lane partner (the other URL)
        /// before the pair advances to the next vault entry.
        case pairWait
    }

    let id: String
    let index: Int
    let storeID: UUID
    /// Browser target assignment. Recalculated from the active layout and
    /// split pattern whenever the grid or dual-site pattern changes.
    var targetSiteIndex: Int
    /// True when this cell is unused in the current layout — e.g. the 3×3
    /// center window in dual-site mode. Disabled cells show an "Unused"
    /// label and are excluded from lane pairing and credential distribution.
    var isDisabled: Bool = false

    var url: URL?
    var title: String = ""
    var isLoading: Bool = false
    var estimatedProgress: Double = 0
    var canGoBack: Bool = false
    var canGoForward: Bool = false
    weak var webView: WKWebView?

    // RCR state — per session.
    var rcrRunning: Bool = false
    var rcrStatus: Status = .idle
    var rcrIndex: Int = 0
    var rcrTotal: Int = 0
    var rcrCurrentUsername: String = ""
    var rcrCurrentDomain: String = ""
    var rcrTargetURL: URL?
    var rcrSuccessCount: Int = 0
    var rcrBurnFlash: Int = 0

    var rcrQueueIDs: [String] = []
    /// Snapshot of usernames + password counts captured at run start so the
    /// queue pill stays accurate even if the user edits the vault mid-run.
    var rcrQueueUsernames: [String] = []
    var rcrQueuePasswordCounts: [Int] = []
    /// IDs that have reached a terminal state (success / disabled-burned /
    /// exhausted). Drives the "Completed" section of the queue pill.
    var rcrCompletedIDs: Set<String> = []

    var rcrPasswords: [String] = []
    var rcrPasswordIndex: Int = 0
    var rcrAwaitingNavigation: Bool = false
    /// Per-attempt watchdog: fires when a navigation or the post-submit
    /// observation produces no page state within the timeout (dead page,
    /// failed load, wedged web process) so the run advances instead of
    /// stalling in "watching" forever.
    var rcrWatchdog: Task<Void, Never>?
    /// True while the runner is performing the configured extra submits.
    /// All other RCR actions are paused until this clears.
    var rcrExtraSubmitsInFlight: Bool = false
    /// Set when this window just burned a perm-disabled session. The next
    /// navigation must wait for page boot + cookie consent before filling.
    var needsPostBurnSettle: Bool = false

    init(index: Int) {
        self.index = index
        self.id = "S\(index + 1)"
        self.storeID = QuadDataStore.identifier(for: index)
        self.targetSiteIndex = index % 2
    }

    var sessionTag: String { id }

    var displayURL: String { url?.absoluteString ?? "" }

    var domain: String {
        guard let host = url?.host(percentEncoded: false)?.lowercased() else { return "" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
