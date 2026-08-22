import Foundation
import SwiftData
import SwiftUI
import UIKit
import WebKit

/// Owns up to sixteen `QuadSession` objects and orchestrates multi-window
/// browsing across whichever grid size is currently active (4, 6, 8, 9, 12,
/// or 16 windows). Sessions beyond `activeCount` sit dormant — no WKWebView is
/// created for them until their cell is actually rendered.
@Observable
@MainActor
final class QuadController {
    /// All possible sessions, pre-allocated up to the largest grid (16).
    let sessions: [QuadSession]
    var focusedIndex: Int = 0
    /// The grid size currently in use. Call `setGridSize(_:)` so dual-site
    /// target assignments are recalculated whenever the window count changes.
    private(set) var gridSize: WindowGridSize = .four
    var activeCount: Int { gridSize.rawValue }
    /// The sessions actually shown/used by the current grid size.
    var activeSessions: [QuadSession] { Array(sessions.prefix(activeCount)) }
    /// Active sessions that are not disabled (e.g. 3×3 center in dual-site).
    var enabledSessions: [QuadSession] { activeSessions.filter { !$0.isDisabled } }

    var anyRCRRunning: Bool {
        enabledSessions.contains { $0.rcrRunning }
    }
    /// When `true`, sessions retry passwords that previously came back as
    /// `failed`. `success` and `disabled` results are always skipped.
    var retryFailed: Bool = false
    /// True while every window rests between attempts (pause-all).
    private(set) var isQuadRCRPaused: Bool = false
    /// One continuation per frozen window index, resolved on thaw.
    private var freezeContinuations: [Int: CheckedContinuation<Void, Never>] = [:]
    /// Every window suspended by pause-all — pause-all suspends multiple
    /// runners at once, so one continuation per waiting window.
    private var quadPauseContinuations: [CheckedContinuation<Void, Never>] = []
    /// Per-lane completed-credential counters for dual-site mode, sized to
    /// the active lane count whenever a dual-site run starts. Powers the
    /// compact summary bar shown on the larger grids.
    private(set) var laneCompletedCounts: [Int] = []

    private weak var browserViewModel: BrowserViewModel?
    /// Read-only access for multi-window UI (address bar sync, etc.).
    var hostBrowser: BrowserViewModel? { browserViewModel }
    private var modelContext: ModelContext?

    /// Re-entrancy latch: set synchronously at run start, before the
    /// off-main keychain preflight completes, so a double-tap can't stack
    /// two overlapping runs. Cleared when the run begins or is stopped.
    private(set) var isStartingRCR: Bool = false
    /// Generation guard: a stop followed by a quick restart invalidates the
    /// previous preflight task, so its continuation can't start a stale run.
    private var rcrStartGeneration: Int = 0
    private var dualSiteURLA: URL?
    private var dualSiteURLB: URL?
    private(set) var dualSiteSplitPattern: DualSiteSplitPattern = .checkerboard
    private(set) var isDualTargetMode: Bool = false

    init() {
        self.sessions = (0..<QuadDataStore.maxSessionCount).map { QuadSession(index: $0) }
    }

    func setup(modelContext: ModelContext, browser: BrowserViewModel) {
        self.modelContext = modelContext
        self.browserViewModel = browser
        for s in sessions where s.url == nil {
            s.url = BrowserViewModel.defaultHomeURL
        }
    }

    var focusedSession: QuadSession { sessions[focusedIndex] }

    /// Changes the active grid and immediately recalculates any current
    /// dual-site assignment for the new row/column geometry.
    func setGridSize(_ newSize: WindowGridSize) {
        guard newSize != gridSize else { return }
        gridSize = newSize

        // Clear any disabled state from a previous dual-site 3×3 layout.
        for s in activeSessions { s.isDisabled = false }

        if isDualTargetMode,
           newSize.supportsDualSite,
           let urlA = dualSiteURLA,
           let urlB = dualSiteURLB {
            applyDualSiteTargets(urlA: urlA, urlB: urlB, pattern: dualSiteSplitPattern)
        } else if !newSize.supportsDualSite {
            isDualTargetMode = false
            for session in activeSessions { session.targetSiteIndex = 0 }
        }
        refocusIfDisabled()
    }

    /// Moves focus off any disabled (unused) cell so the shared toolbar can
    /// never point at an inert window — e.g. the 3×3 center in dual-site
    /// mode after the user last tapped it.
    func refocusIfDisabled() {
        if focusedIndex >= activeCount || sessions[focusedIndex].isDisabled {
            focusedIndex = enabledSessions.first?.index ?? 0
        }
    }

    /// Read-only access to a dual-site lane's two sessions (URL A side, URL
    /// B side). Valid for `lane` in `0..<laneCount`.
    func lanePair(_ lane: Int) -> (QuadSession, QuadSession) {
        (sessionA(forLane: lane), sessionB(forLane: lane))
    }

    func navigateAll(to url: URL) {
        isDualTargetMode = false
        dualSiteURLA = url
        dualSiteURLB = nil
        for s in activeSessions {
            s.targetSiteIndex = 0
            s.isDisabled = false
            navigate(s, to: url)
        }
    }

    /// Navigates every currently assigned Site A or Site B browser tile.
    func navigateTargetSite(to url: URL, targetSiteIndex: Int) {
        guard targetSiteIndex == 0 || targetSiteIndex == 1 else { return }
        if targetSiteIndex == 0 { dualSiteURLA = url } else { dualSiteURLB = url }
        for session in activeSessions where session.targetSiteIndex == targetSiteIndex && !session.isDisabled {
            navigate(session, to: url)
        }
    }

    /// Recalculates an exactly even A/B assignment for the active grid, then
    /// navigates only tiles whose target changed. The 3×3 layout marks its
    /// center window as disabled and splits the remaining 8 evenly.
    func applyDualSiteTargets(urlA: URL, urlB: URL, pattern: DualSiteSplitPattern) {
        guard gridSize.supportsDualSite else {
            navigateAll(to: urlA)
            return
        }

        isDualTargetMode = true
        dualSiteURLA = urlA
        dualSiteURLB = urlB
        dualSiteSplitPattern = pattern

        for session in activeSessions {
            let target = pattern.targetSiteIndex(for: session.index, in: gridSize)
            if target == -1 {
                // 3×3 center window — disabled in dual-site mode.
                session.isDisabled = true
                session.targetSiteIndex = 0
                session.webView?.stopLoading()
                continue
            }
            session.isDisabled = false
            session.targetSiteIndex = target
            navigate(session, to: target == 0 ? urlA : urlB)
        }
        rebuildLaneMapping()
        refocusIfDisabled()
    }

    func representativeSession(forTargetSite targetSiteIndex: Int) -> QuadSession? {
        activeSessions.first { $0.targetSiteIndex == targetSiteIndex && !$0.isDisabled }
    }

    // MARK: - Page-load autofill & save-offer (multi-window)

    /// Fills a matching vault credential into one multi-window cell when
    /// Settings → Auto-fill on Page Load is enabled. Mirrors the
    /// single-window flow, keyed to this session's own domain.
    func handleQuadPageLoadAutofill(for session: QuadSession) {
        guard !anyRCRRunning, !session.rcrRunning else { return }
        guard browserViewModel?.isRCRRunning != true else { return }
        let autoFillEnabled = UserDefaults.standard.object(forKey: "autoFillOnPageLoad") as? Bool ?? true
        guard autoFillEnabled else { return }

        let domain = session.domain
        guard !domain.isEmpty, browserViewModel?.isDomainExcluded(domain) == false else { return }
        guard let webView = session.webView else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            // Brief settle so SPA login forms finish mounting.
            try? await Task.sleep(for: .milliseconds(350))
            guard !self.anyRCRRunning, !session.rcrRunning else { return }

            let detectRaw = try? await webView.evaluateJavaScript(
                JavaScriptInjectionService.detectLoginFormScript()
            )
            let hasLoginForm: Bool = {
                if let json = detectRaw as? String,
                   let data = json.data(using: .utf8),
                   let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let flag = dict["hasLoginForm"] as? Bool {
                    return flag
                }
                return false
            }()
            guard hasLoginForm else { return }

            guard let context = self.modelContext else { return }
            let domainLower = domain.lowercased()
            let domainVariants = BrowserViewModel.autofillDomainCandidates(for: domainLower)
            let descriptor = FetchDescriptor<Credential>(
                sortBy: [
                    SortDescriptor(\.lastUsedAt, order: .reverse),
                    SortDescriptor(\.usageCount, order: .reverse),
                    SortDescriptor(\.updatedAt, order: .reverse)
                ]
            )
            let all = (try? context.fetch(descriptor)) ?? []
            guard let match = all.first(where: { domainVariants.contains($0.domain.lowercased()) }) else {
                return
            }
            guard let password = KeychainService.shared.getPassword(for: match.id), !password.isEmpty else {
                return
            }

            let siteSetting = self.browserViewModel?.fetchSiteSetting(for: domainLower)
            let fillScript = JavaScriptInjectionService.fillCredentialScript(
                username: match.username,
                password: password,
                usernameSelector: siteSetting?.usernameSelector,
                passwordSelector: siteSetting?.passwordSelector,
                suppressKeyboard: true
            )
            let fillRaw = try? await webView.evaluateJavaScript(fillScript)
            let filledCount: Int = {
                if let json = fillRaw as? String,
                   let data = json.data(using: .utf8),
                   let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let count = dict["filled"] as? Int {
                    return count
                }
                return 0
            }()
            guard filledCount > 0 else { return }

            match.lastUsedAt = Date()
            match.usageCount += 1
            try? context.save()

            if let siteSetting, siteSetting.isAutoLoginEnabled {
                let submit = JavaScriptInjectionService.submitFormScript(
                    submitSelector: siteSetting.submitButtonSelector
                )
                _ = try? await webView.evaluateJavaScript(submit)
            } else {
                self.browserViewModel?.showToast("Filled login for \(match.username)")
            }
        }
    }

    /// Offers to save a manually submitted login from a multi-window cell.
    func detectAndOfferSaveQuad(session: QuadSession) {
        let offerEnabled = UserDefaults.standard.object(forKey: "offerToSavePasswords") as? Bool ?? true
        guard offerEnabled else { return }
        let domain = session.domain
        guard !domain.isEmpty, browserViewModel?.isDomainExcluded(domain) == false else { return }

        let script = JavaScriptInjectionService.extractFilledCredentialsScript()
        session.webView?.evaluateJavaScript(script) { [weak self] result, _ in
            Task { @MainActor in
                guard let self, let json = result as? String,
                      let data = json.data(using: .utf8),
                      let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let found = dict["found"] as? Bool, found,
                      let username = dict["username"] as? String, !username.isEmpty,
                      let password = dict["password"] as? String, !password.isEmpty else { return }

                guard let context = self.modelContext else { return }
                let domainLower = domain.lowercased()
                let descriptor = FetchDescriptor<Credential>(
                    predicate: #Predicate<Credential> {
                        $0.username == username && $0.domain == domainLower
                    }
                )
                let alreadyExists = (try? context.fetch(descriptor).first) != nil
                if !alreadyExists {
                    self.browserViewModel?.detectedUsername = username
                    self.browserViewModel?.detectedPassword = password
                    self.browserViewModel?.detectedDomain = domainLower
                    self.browserViewModel?.isShowingSaveCredentialAlert = true
                }
            }
        }
    }

    private func navigate(_ session: QuadSession, to url: URL) {
        session.url = url
        guard session.webView?.url != url else { return }
        session.webView?.load(URLRequest(url: url))
    }

    // MARK: - Queue snapshot for the per-session pill

    func queueSnapshot(for s: QuadSession, upcomingLimit: Int = 8) -> [RCRQueueItem] {
        guard !s.rcrQueueIDs.isEmpty else { return [] }
        var items: [RCRQueueItem] = []
        let total = s.rcrQueueIDs.count
        let upper = min(s.rcrIndex + upcomingLimit + 1, total)
        for i in s.rcrIndex..<upper {
            let id = s.rcrQueueIDs[i]
            let username = i < s.rcrQueueUsernames.count ? s.rcrQueueUsernames[i] : ""
            let pwCount = i < s.rcrQueuePasswordCounts.count ? s.rcrQueuePasswordCounts[i] : 0
            items.append(RCRQueueItem(
                id: id,
                username: username,
                passwordCount: pwCount
            ))
        }
        return items
    }

    func completedSnapshot(for s: QuadSession) -> [RCRQueueItem] {
        guard !s.rcrQueueIDs.isEmpty else { return [] }
        var items: [RCRQueueItem] = []
        for (i, id) in s.rcrQueueIDs.enumerated() where s.rcrCompletedIDs.contains(id) {
            let username = i < s.rcrQueueUsernames.count ? s.rcrQueueUsernames[i] : ""
            let pwCount = i < s.rcrQueuePasswordCounts.count ? s.rcrQueuePasswordCounts[i] : 0
            items.append(RCRQueueItem(
                id: id,
                username: username,
                passwordCount: pwCount
            ))
        }
        return items
    }

    // MARK: - Quad RCR (normal 4-way split — unchanged)

    func startQuadRCR(targetURL: URL) {
        guard !anyRCRRunning, !isStartingRCR else { return }
        guard let context = modelContext else { return }
        dualQuadActive = false
        FillHealerEngine.shared.resetRunBudget()
        ParkedSessionStore.shared.markRunStarted()
        let descriptor = FetchDescriptor<Credential>(
            sortBy: [
                SortDescriptor(\Credential.domain),
                SortDescriptor(\Credential.username)
            ]
        )
        guard let all = try? context.fetch(descriptor), !all.isEmpty else {
            browserViewModel?.showToast("Vault is empty", force: true)
            return
        }
        let excluded = browserViewModel?.excludedDomainSet ?? []
        let queue = all.filter { !excluded.contains(ExcludedDomain.canonicalize($0.domain)) }
        guard !queue.isEmpty else {
            browserViewModel?.showToast("Vault is empty", force: true)
            return
        }
        // Reset all active sessions and clear any leftover disabled state.
        for s in activeSessions {
            s.isDisabled = false
        }

        // Keychain reads block the caller — fetch password counts off the
        // main thread so a large vault can't freeze the UI at run start.
        isStartingRCR = true
        rcrStartGeneration &+= 1
        let startGeneration = rcrStartGeneration
        let credIDs = queue.map(\.id)
        Task { [weak self] in
            guard let self else { return }
            let counts = await Task.detached {
                credIDs.map { KeychainService.shared.getPasswords(for: $0).count }
            }.value
            // A stop (or a stale earlier start) during the preflight aborts
            // this run before it touches anything.
            guard self.isStartingRCR, self.rcrStartGeneration == startGeneration else { return }
            self.isStartingRCR = false
            self.partitionAndStart(queue: queue, targetURL: targetURL, passwordCounts: counts)
        }
    }

    /// Splits the vault evenly across every active window (4/6/8/9/12/16) using
    /// balanced round-robin so that every window gets either floor(N/W) or
    /// ceil(N/W) credentials — guaranteed equal to within one, no matter
    /// how small the vault. For repeatability across runs the queue is
    /// sorted the same way every time (domain → username). Disabled windows
    /// (e.g. 3×3 center in dual-site mode) are excluded from the partition.
    private func partitionAndStart(queue: [Credential], targetURL: URL, passwordCounts: [Int]) {
        guard let context = modelContext else { return }

        let participants = enabledSessions
        let count = participants.count
        guard count > 0 else {
            browserViewModel?.showToast("No active windows", force: true)
            return
        }
        var slices: [[Credential]] = Array(repeating: [], count: count)
        for (i, c) in queue.enumerated() {
            slices[i % count].append(c)
        }

        let domain = targetURL.host(percentEncoded: false)?.lowercased() ?? ""
        let tracker = AttemptTrackingService.shared
        let countsByID = Dictionary(uniqueKeysWithValues: zip(queue.map(\.id), passwordCounts))

        for (sliceIdx, s) in participants.enumerated() {
            let creds = slices[sliceIdx]
            if !creds.isEmpty {
                let allFinished = creds.allSatisfy { c in
                    tracker.credentialIsFinished(
                        context: context,
                        credentialID: c.id,
                        targetDomain: domain,
                        totalPasswords: countsByID[c.id] ?? 0
                    )
                }
                if allFinished {
                    tracker.clearAttempts(context: context, credentialIDs: Set(creds.map(\.id)), targetDomain: domain)
                }
            }
            startSessionRCR(s, creds: creds, targetURL: targetURL, targetDomain: domain, countsByID: countsByID, context: context, tracker: tracker)
        }
    }

    private func startSessionRCR(
        _ s: QuadSession,
        creds: [Credential],
        targetURL: URL,
        targetDomain: String,
        countsByID: [String: Int],
        context: ModelContext,
        tracker: AttemptTrackingService
    ) {
        let credIDs = creds.map(\.id)
        let usernames = creds.map(\.username)
        let counts: [Int] = credIDs.map { countsByID[$0] ?? 0 }

        s.rcrQueueIDs = credIDs
        s.rcrQueueUsernames = usernames
        s.rcrQueuePasswordCounts = counts
        s.rcrTotal = credIDs.count
        s.rcrIndex = 0
        s.rcrPasswordIndex = 0
        s.rcrSuccessCount = 0
        s.rcrCompletedIDs = []
        s.rcrTargetURL = targetURL
        s.rcrCurrentDomain = targetDomain
        s.rcrAwaitingNavigation = false
        s.needsPostBurnSettle = false

        while s.rcrIndex < s.rcrTotal {
            let id = s.rcrQueueIDs[s.rcrIndex]
            let total = s.rcrQueuePasswordCounts[s.rcrIndex]
            let finished = tracker.credentialIsFinished(
                context: context,
                credentialID: id,
                targetDomain: targetDomain,
                totalPasswords: total
            )
            if finished || PermaDisabledStore.shared.isDisabled(credentialID: id) {
                s.rcrCompletedIDs.insert(id)
                s.rcrIndex += 1
            } else {
                break
            }
        }

        if s.rcrTotal > 0 && s.rcrIndex < s.rcrTotal {
            s.rcrRunning = true
            s.rcrStatus = .navigating
            s.webView?.evaluateJavaScript(
                JavaScriptInjectionService.rcrScrollEnableScript(),
                completionHandler: nil
            )
            Task { await self.runCurrent(session: s) }
        } else {
            s.rcrRunning = false
            s.rcrStatus = .finished
        }
    }

    func stopQuadRCR(reason: String? = nil) {
        // Invalidate any in-flight start preflight.
        isStartingRCR = false
        rcrStartGeneration &+= 1
        // Wake every suspended runner so nothing hangs on a continuation.
        isQuadRCRPaused = false
        for continuation in quadPauseContinuations { continuation.resume() }
        quadPauseContinuations = []
        for (index, continuation) in freezeContinuations {
            continuation.resume()
            sessions[index].isRCRFrozen = false
        }
        freezeContinuations = [:]
        for s in enabledSessions where s.rcrRunning {
            s.rcrRunning = false
            s.rcrStatus = .idle
            s.rcrAwaitingNavigation = false
            s.rcrExtraSubmitsInFlight = false
            s.rcrJudging = false
            s.needsPostBurnSettle = false
            s.webView?.evaluateJavaScript(
                JavaScriptInjectionService.rcrUninstallObserverScript(),
                completionHandler: nil
            )
        }
        for s in activeSessions {
            s.rcrWatchdog?.cancel()
            s.rcrWatchdog = nil
            // Don't leave plaintext passwords sitting in memory after a stop.
            s.rcrPasswords = []
            s.rcrPasswordsCredentialID = ""
            s.webView?.evaluateJavaScript(
                JavaScriptInjectionService.rcrScrollDisableScript(),
                completionHandler: nil
            )
        }
        dualQuadActive = false
        laneStates = []
        laneCompletedCounts = Array(repeating: 0, count: laneCount)
        dualNeedsBurn = [:]
        if let reason { browserViewModel?.showToast(reason) }
        ParkedSessionStore.shared.markRunFinished()
    }

    private func currentCredential(_ session: QuadSession) -> Credential? {
        guard session.rcrIndex < session.rcrQueueIDs.count, let context = modelContext else { return nil }
        let id = session.rcrQueueIDs[session.rcrIndex]
        let descriptor = FetchDescriptor<Credential>(predicate: #Predicate<Credential> { $0.id == id })
        return try? context.fetch(descriptor).first
    }

    // MARK: - Grid cockpit (pause-all / freeze / skip / retry / speed)

    /// The live speed profile — shared with single-window mode through the
    /// host browser so the dial stays consistent across modes.
    var activeSpeedProfile: SpeedProfile {
        browserViewModel?.runSpeedProfile ?? SpeedProfile.saved
    }

    /// Pauses or resumes every running window between attempts. The
    /// in-flight attempt always completes.
    func setQuadRCRPaused(_ paused: Bool) {
        guard anyRCRRunning, paused != isQuadRCRPaused else { return }
        isQuadRCRPaused = paused
        if paused {
            for s in activeSessions { cancelRCRWatchdog(for: s) }
            browserViewModel?.showToast("All windows paused")
        } else {
            for continuation in quadPauseContinuations { continuation.resume() }
            quadPauseContinuations = []
            for s in activeSessions where s.rcrRunning
                && (s.rcrStatus == .waiting || s.rcrStatus == .navigating) {
                armRCRWatchdog(for: s)
            }
            browserViewModel?.showToast("Run resumed")
        }
    }

    func toggleQuadRCRPause() {
        setQuadRCRPaused(!isQuadRCRPaused)
    }

    /// Freezes or thaws one window. Frozen windows rest between attempts
    /// while the rest of the grid keeps working.
    func setSessionFrozen(_ s: QuadSession, _ frozen: Bool) {
        guard frozen != s.isRCRFrozen else { return }
        s.isRCRFrozen = frozen
        if frozen {
            cancelRCRWatchdog(for: s)
            browserViewModel?.showToast("\(s.id) frozen — rests between attempts")
        } else {
            freezeContinuations[s.index]?.resume()
            freezeContinuations[s.index] = nil
            if s.rcrRunning, s.rcrStatus == .waiting || s.rcrStatus == .navigating {
                armRCRWatchdog(for: s)
            }
            browserViewModel?.showToast("\(s.id) thawed")
        }
    }

    func toggleSessionFrozen(_ s: QuadSession) {
        setSessionFrozen(s, !s.isRCRFrozen)
    }

    /// Suspends a session's runner while pause-all is on or the window is
    /// frozen. Every async leg of a session's run passes through here.
    private func waitIfPausedOrFrozen(_ s: QuadSession) async {
        if isQuadRCRPaused {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                quadPauseContinuations.append(continuation)
            }
        }
        if s.isRCRFrozen {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                freezeContinuations[s.index] = continuation
            }
        }
    }

    /// Skips the current credential in one window: records it as skipped
    /// with a reason and moves that window's run on. In dual-site mode the
    /// skip finishes this window's side of the lane so the pairing stays
    /// in sync.
    func skipCurrentForSession(_ s: QuadSession) {
        guard s.rcrRunning, s.rcrIndex < s.rcrQueueIDs.count else { return }
        cancelRCRWatchdog(for: s)
        s.rcrJudging = false
        s.rcrExtraSubmitsInFlight = false
        s.rcrAttemptGeneration &+= 1
        if dualQuadActive {
            let lane = laneIndex(for: s)
            guard let credential = currentDualCredential(s) else { return }
            if let context = modelContext {
                let password = s.rcrPasswords[safe: s.rcrPasswordIndex] ?? ""
                _ = AttemptTrackingService.shared.recordAttempt(
                    context: context,
                    credentialID: credential.id,
                    username: credential.username,
                    password: password,
                    passwordIndex: s.rcrPasswordIndex + 1,
                    passwordTotal: s.rcrPasswords.count,
                    targetDomain: s.rcrTargetURL?.host(percentEncoded: false)?.lowercased() ?? credential.domain,
                    sessionTag: s.sessionTag,
                    status: .skipped,
                    judge: SuccessJudgeEngine.Decision.local(
                        status: .skipped,
                        verdict: "skipped",
                        confidence: 1,
                        reason: "Skipped by you during the run"
                    )
                )
            }
            browserViewModel?.showToast("Skipped \(credential.username) (\(s.id))")
            finishDualSide(session: s, lane: lane, status: .skipped)
            return
        }
        guard let credential = currentCredential(s) else { return }
        let password = s.rcrPasswords[safe: s.rcrPasswordIndex] ?? ""
        if let context = modelContext {
            _ = AttemptTrackingService.shared.recordAttempt(
                context: context,
                credentialID: credential.id,
                username: credential.username,
                password: password,
                passwordIndex: s.rcrPasswordIndex + 1,
                passwordTotal: s.rcrPasswords.count,
                targetDomain: s.rcrTargetURL?.host(percentEncoded: false)?.lowercased() ?? credential.domain,
                sessionTag: s.sessionTag,
                status: .skipped,
                judge: SuccessJudgeEngine.Decision.local(
                    status: .skipped,
                    verdict: "skipped",
                    confidence: 1,
                    reason: "Skipped by you during the run"
                )
            )
        }
        browserViewModel?.showToast("Skipped \(credential.username) (\(s.id))")
        s.rcrCompletedIDs.insert(credential.id)
        s.rcrIndex += 1
        s.rcrPasswordIndex = 0
        s.rcrPasswords = []
        s.rcrPasswordsCredentialID = ""
        Task { await runCurrent(session: s) }
    }

    /// Re-fills and re-submits the password a window just tried.
    func retryCurrentForSession(_ s: QuadSession) {
        guard s.rcrRunning, !s.rcrPasswords.isEmpty,
              s.rcrPasswordIndex < s.rcrPasswords.count else { return }
        guard !s.rcrJudging else {
            browserViewModel?.showToast("Judging the current attempt — retry in a moment", force: true)
            return
        }
        guard s.rcrStatus == .waiting || s.rcrStatus == .submitting else {
            browserViewModel?.showToast("Retry is available while watching a submit", force: true)
            return
        }
        cancelRCRWatchdog(for: s)
        s.rcrJudging = false
        s.rcrExtraSubmitsInFlight = false
        s.rcrAttemptGeneration &+= 1
        browserViewModel?.showToast("Retrying \(s.rcrCurrentUsername) (\(s.id))")
        if dualQuadActive {
            Task { await attemptFillDual(session: s, lane: laneIndex(for: s)) }
        } else {
            Task { await attemptFill(session: s) }
        }
    }

    private func runCurrent(session s: QuadSession) async {
        guard s.rcrRunning else { return }
        await waitIfPausedOrFrozen(s)
        guard s.rcrRunning else { return }
        // Skip credentials in temp-disabled cooldown OR ever perma-disabled.
        while s.rcrIndex < s.rcrQueueIDs.count {
            let id = s.rcrQueueIDs[s.rcrIndex]
            if TempDisabledStore.shared.isDisabled(credentialID: id)
                || PermaDisabledStore.shared.isDisabled(credentialID: id) {
                s.rcrCompletedIDs.insert(id)
                s.rcrIndex += 1
                s.rcrPasswordIndex = 0
            } else {
                break
            }
        }
        guard s.rcrIndex < s.rcrQueueIDs.count else {
            s.rcrRunning = false
            s.rcrStatus = .finished
            cancelRCRWatchdog(for: s)
            // Don't leave plaintext passwords sitting in memory.
            s.rcrPasswords = []
            checkAllFinished()
            return
        }

        guard let credential = currentCredential(s) else {
            s.rcrIndex += 1
            await runCurrent(session: s)
            return
        }

        let credID = credential.id
        let allPasswords = await Task.detached {
            KeychainService.shared.getPasswords(for: credID)
        }.value

        guard !allPasswords.isEmpty else {
            s.rcrCompletedIDs.insert(credential.id)
            s.rcrIndex += 1
            s.rcrPasswordIndex = 0
            await runCurrent(session: s)
            return
        }

        // Resume-safe filtering.
        let targetDomain = s.rcrTargetURL?.host(percentEncoded: false)?.lowercased() ?? ""
        let filtered: [String]
        if let context = modelContext {
            if retryFailed {
                let tracker = AttemptTrackingService.shared
                filtered = allPasswords.filter { pw in
                    !tracker.isTerminallyAttempted(
                        context: context,
                        credentialID: credID,
                        passwordHash: PasswordFingerprint.hash(pw),
                        targetDomain: targetDomain
                    )
                }
            } else {
                let descriptor = FetchDescriptor<AttemptRecord>(
                    predicate: #Predicate<AttemptRecord> { rec in
                        rec.credentialID == credID
                            && rec.targetDomain == targetDomain
                            && rec.statusRaw != "pending"
                            && rec.statusRaw != "skipped"
                    }
                )
                let attempted = Set(((try? context.fetch(descriptor)) ?? []).map { $0.passwordHash })
                filtered = allPasswords.filter { !attempted.contains(PasswordFingerprint.hash($0)) }
            }
        } else {
            filtered = allPasswords
        }

        guard !filtered.isEmpty else {
            s.rcrCompletedIDs.insert(credential.id)
            s.rcrIndex += 1
            s.rcrPasswordIndex = 0
            await runCurrent(session: s)
            return
        }

        s.rcrPasswords = filtered
        s.rcrPasswordIndex = 0
        s.rcrPasswordsCredentialID = credential.id
        s.rcrCurrentUsername = credential.username
        if let target = s.rcrTargetURL {
            s.rcrCurrentDomain = target.host(percentEncoded: false) ?? credential.domain
        }

        let liveURL = s.webView?.url ?? s.url
        if !BrowserViewModel.sameTarget(liveURL, s.rcrTargetURL), let target = s.rcrTargetURL {
            s.rcrStatus = .navigating
            s.rcrAwaitingNavigation = true
            s.url = target
            s.webView?.load(URLRequest(url: target))
            // If this load never finishes (dead page, wedged process), the
            // watchdog advances the run instead of stalling forever.
            armRCRWatchdog(for: s)
            return
        }

        await attemptFill(session: s)
    }

    // MARK: - Per-attempt watchdog

    private static let rcrWatchdogTimeout: Duration = PageSettleService.attemptWatchdog

    /// Arms the per-attempt watchdog. If the page produces no state message
    /// within the timeout (navigation failure, dead page, wedged web
    /// process), the attempt is recorded as failed and the run advances —
    /// previously the session sat in "watching" forever. Stretched by the
    /// speed profile, never shrunk below base.
    private func armRCRWatchdog(for s: QuadSession, timeout: Duration = rcrWatchdogTimeout) {
        let effective = SpeedProfile.effectiveWatchdog(timeout, profile: activeSpeedProfile)
        s.rcrWatchdog?.cancel()
        s.rcrWatchdog = Task { [weak self, weak s] in
            try? await Task.sleep(for: effective)
            guard let self, let s, !Task.isCancelled else { return }
            self.rcrWatchdogFired(session: s)
        }
    }

    private func cancelRCRWatchdog(for s: QuadSession) {
        s.rcrWatchdog?.cancel()
        s.rcrWatchdog = nil
    }

    private func rcrWatchdogFired(session s: QuadSession) {
        guard s.rcrRunning, s.rcrStatus == .waiting || s.rcrStatus == .navigating else { return }
        // Paused or frozen windows must never be advanced by their own
        // watchdog — re-arm and wait.
        guard !isQuadRCRPaused, !s.isRCRFrozen else { armRCRWatchdog(for: s); return }
        s.rcrAwaitingNavigation = false

        if dualQuadActive {
            // Mirror the normal failed-password flow so lanes stay paired.
            let lane = laneIndex(for: s)
            guard let credential = currentDualCredential(s) else {
                finishDualSide(session: s, lane: lane, status: .failed)
                return
            }
            let password = s.rcrPasswords[safe: s.rcrPasswordIndex] ?? ""
            captureAndRecord(session: s, credential: credential, password: password, status: .failed)
            if s.rcrPasswordIndex + 1 < s.rcrPasswords.count {
                s.rcrPasswordIndex += 1
                Task { await self.attemptFillDual(session: s, lane: lane) }
            } else {
                finishDualSide(session: s, lane: lane, status: .failed)
            }
            return
        }

        guard let credential = currentCredential(s) else {
            s.rcrIndex += 1
            Task { await self.runCurrent(session: s) }
            return
        }
        let password = s.rcrPasswords[safe: s.rcrPasswordIndex] ?? ""
        captureAndRecord(session: s, credential: credential, password: password, status: .failed)
        browserViewModel?.showToast("No response — skipping \(credential.username)")
        if s.rcrPasswordIndex + 1 < s.rcrPasswords.count {
            s.rcrPasswordIndex += 1
            Task { await self.attemptFill(session: s) }
        } else {
            s.rcrCompletedIDs.insert(credential.id)
            s.rcrIndex += 1
            s.rcrPasswordIndex = 0
            Task { await self.runCurrent(session: s) }
        }
    }

    private func attemptFill(session s: QuadSession) async {
        guard s.rcrRunning else { return }
        await waitIfPausedOrFrozen(s)
        guard s.rcrRunning else { return }
        guard let credential = currentCredential(s) else {
            s.rcrIndex += 1
            await runCurrent(session: s)
            return
        }
        // Cross-credential guard: the in-memory password list must belong
        // to THIS credential. After a park or burn the list still holds the
        // previous credential's passwords — rebuild instead of filling the
        // wrong account's secrets.
        guard s.rcrPasswordsCredentialID == credential.id, !s.rcrPasswords.isEmpty else {
            s.rcrPasswords = []
            await runCurrent(session: s)
            return
        }
        let password = s.rcrPasswords[s.rcrPasswordIndex]
        let targetDomain = s.rcrTargetURL?.host(percentEncoded: false)?.lowercased() ?? credential.domain
        let siteSetting = browserViewModel?.fetchSiteSetting(for: targetDomain)

        s.rcrStatus = .filling
        let fillScript = JavaScriptInjectionService.fillCredentialScript(
            username: credential.username,
            password: password,
            usernameSelector: siteSetting?.usernameSelector,
            passwordSelector: siteSetting?.passwordSelector,
            suppressKeyboard: true
        )
        let fillResult = try? await s.webView?.evaluateJavaScript(fillScript)

        var healedSubmitSelector: String? = nil
        if FillHealerEngine.fillMissed(fillResult),
           let webView = s.webView,
           let context = self.modelContext {
            let outcome = await FillHealerEngine.shared.healAndRefill(
                webView: webView,
                domain: targetDomain,
                sessionTag: s.sessionTag,
                username: credential.username,
                password: password,
                modelContext: context
            )
            healedSubmitSelector = outcome?.submitSelector
        }

        s.rcrStatus = .submitting
        let submitScript = JavaScriptInjectionService.submitFormScript(
            submitSelector: healedSubmitSelector ?? siteSetting?.submitButtonSelector
        )
        _ = try? await s.webView?.evaluateJavaScript(submitScript)

        // Optional extra submits (sure-login). Paused while in-flight. The
        // page is checked after every extra submit — a permanent disable,
        // temp-disable, or success stops further submits immediately.
        let extraCount = max(0, UserDefaults.standard.integer(forKey: "rcrExtraSubmits"))
        let rawDelay = UserDefaults.standard.double(forKey: "rcrSubmitDelay")
        let baseDelay = rawDelay > 0 ? rawDelay : 1.5
        let delay = max(0.2, baseDelay * activeSpeedProfile.submitGapMultiplier)
        if extraCount > 0 {
            // The extra-submit loop is self-driving (state check after every
            // submit) and can legitimately run for ~50s — the watchdog must
            // not fire during it. It re-arms when the loop finishes.
            cancelRCRWatchdog(for: s)
            s.rcrExtraSubmitsInFlight = true
            for _ in 0..<extraCount {
                await waitIfPausedOrFrozen(s)
                guard s.rcrRunning else { s.rcrExtraSubmitsInFlight = false; return }
                try? await Task.sleep(for: .seconds(delay))
                guard s.rcrRunning else { s.rcrExtraSubmitsInFlight = false; return }
                _ = try? await s.webView?.evaluateJavaScript(submitScript)

                try? await Task.sleep(for: .seconds(0.35))
                guard s.rcrRunning else { s.rcrExtraSubmitsInFlight = false; return }
                let rawState = try? await s.webView?.evaluateJavaScript(
                    JavaScriptInjectionService.pageStateSnapshotScript()
                )
                if let payload = JavaScriptInjectionService.parsePageState(rawState),
                   JavaScriptInjectionService.isTerminalRCRState(payload) {
                    s.rcrExtraSubmitsInFlight = false
                    s.rcrStatus = .waiting
                    handleRCRMessage(session: s, payload: payload)
                    return
                }
            }
            s.rcrExtraSubmitsInFlight = false
        }

        credential.lastUsedAt = Date()
        credential.usageCount += 1
        try? modelContext?.save()

        // Pre-record pending.
        if let context = modelContext {
            _ = AttemptTrackingService.shared.recordAttempt(
                context: context,
                credentialID: credential.id,
                username: credential.username,
                password: password,
                passwordIndex: s.rcrPasswordIndex + 1,
                passwordTotal: s.rcrPasswords.count,
                targetDomain: targetDomain,
                sessionTag: s.sessionTag,
                status: .pending
            )
        }

        s.rcrStatus = .waiting
        let installScript = JavaScriptInjectionService.rcrInstallObserverScript()
        _ = try? await s.webView?.evaluateJavaScript(installScript)
        armRCRWatchdog(for: s)
    }

    /// Entry point for the WKScriptMessageHandler — routes to the normal
    /// 4-way handler or the dual-quad paired-lane handler.
    func handleRCRMessage(session s: QuadSession, payload: [String: Any]) {
        if dualQuadActive {
            handleDualQuadMessage(session: s, payload: payload)
            return
        }
        guard s.rcrRunning, s.rcrStatus == .waiting else { return }
        if s.rcrExtraSubmitsInFlight { return }
        if s.rcrJudging { return }

        guard let credential = currentCredential(s) else {
            s.rcrIndex += 1
            Task { await self.runCurrent(session: s) }
            return
        }

        let password = s.rcrPasswords[safe: s.rcrPasswordIndex] ?? ""
        let signal = SuccessJudgeEngine.classifyLocal(payload)

        switch signal {
        case .disabled:
            applyLocalDisabled(session: s, credential: credential, password: password)
        case .tempDisabled:
            applyLocalTempDisabled(session: s, credential: credential, password: password)
        case .stillOnLogin:
            ParkedSessionStore.shared.recordFailure()
            captureAndRecord(session: s, credential: credential, password: password, status: .failed)
            advanceAfterFailure(session: s, credential: credential)
        case .apparentSuccess, .unclear:
            s.rcrJudging = true
            cancelRCRWatchdog(for: s)
            let credID = credential.id
            Task {
                await self.judgeAndAdvance(session: s, payload: payload, credentialID: credID, password: password)
                s.rcrJudging = false
            }
        }
    }

    private func applyLocalDisabled(session s: QuadSession, credential: Credential, password: String) {
        ParkedSessionStore.shared.recordFailure()
        PermaDisabledStore.shared.markDisabled(credentialID: credential.id)
        captureAndRecord(session: s, credential: credential, password: password, status: .disabled)
        let deletedID = credential.id
        deleteCredentialPermanently(credential)
        Task { await self.burnAndAdvance(session: s, completedID: deletedID) }
    }

    private func applyLocalTempDisabled(session s: QuadSession, credential: Credential, password: String) {
        captureAndRecord(session: s, credential: credential, password: password, status: .tempDisabled)
        if s.rcrPasswords.count > 1 {
            TempDisabledStore.shared.markDisabled(credentialID: credential.id)
            browserViewModel?.showToast("Temp-disabled — \(credential.username)")
        }
        s.rcrCompletedIDs.insert(credential.id)
        s.rcrIndex += 1
        s.rcrPasswordIndex = 0
        Task { await self.runCurrent(session: s) }
    }

    private func advanceAfterFailure(session s: QuadSession, credential: Credential) {
        if s.rcrPasswordIndex + 1 < s.rcrPasswords.count {
            s.rcrPasswordIndex += 1
            Task { await self.attemptFill(session: s) }
        } else {
            s.rcrCompletedIDs.insert(credential.id)
            s.rcrIndex += 1
            s.rcrPasswordIndex = 0
            Task { await self.runCurrent(session: s) }
        }
    }

    private func judgeAndAdvance(
        session s: QuadSession,
        payload: [String: Any],
        credentialID: String,
        password: String
    ) async {
        guard s.rcrRunning else { return }
        guard let credential = currentCredential(s), credential.id == credentialID else { return }
        // Speed-scaled grace before judging so the page settles into its
        // final state — slower profiles judge later, never sooner.
        try? await Task.sleep(for: activeSpeedProfile.judgeGrace)
        guard s.rcrRunning else { return }
        let image = await WebViewSnapshotter.capture(s.webView)
        let filename = image.flatMap { ScreenshotStorage.save($0) }
        let domain = s.rcrTargetURL?.host(percentEncoded: false)?.lowercased() ?? credential.domain
        let decision = await SuccessJudgeEngine.judge(
            payload: payload,
            image: image,
            domain: domain,
            sessionTag: s.sessionTag
        )
        recordOutcome(
            session: s,
            credential: credential,
            password: password,
            status: decision.status,
            filename: filename,
            judge: decision
        )

        switch decision.status {
        case .disabled:
            applyLocalDisabled(session: s, credential: credential, password: password)
        case .tempDisabled:
            applyLocalTempDisabled(session: s, credential: credential, password: password)
        case .failed, .pending, .skipped:
            ParkedSessionStore.shared.recordFailure()
            advanceAfterFailure(session: s, credential: credential)
        case .review:
            s.rcrCompletedIDs.insert(credential.id)
            s.rcrIndex += 1
            s.rcrPasswordIndex = 0
            Task { await self.runCurrent(session: s) }
        case .success:
            s.rcrSuccessCount += 1
            s.rcrStatus = .success
            s.rcrCompletedIDs.insert(credential.id)
            s.rcrIndex += 1
            s.rcrPasswordIndex = 0
            if decision.shouldPark {
                parkSession(s, credential: credential, thumbnail: image)
                if s.rcrIndex >= s.rcrTotal {
                    s.rcrRunning = false
                    s.rcrStatus = .finished
                    checkAllFinished()
                    return
                }
                s.rcrAwaitingNavigation = true
                s.rcrStatus = .navigating
                armRCRWatchdog(for: s)
            } else {
                Task { await self.runCurrent(session: s) }
            }
        }
    }

    private func parkSession(_ s: QuadSession, credential: Credential, thumbnail: UIImage?) {
        _ = ParkedSessionStore.shared.park(
            storeID: s.storeID,
            url: s.webView?.url ?? s.url,
            username: credential.username,
            domain: s.rcrTargetURL?.host(percentEncoded: false)?.lowercased() ?? credential.domain,
            credentialID: credential.id,
            sessionTag: s.sessionTag,
            thumbnail: thumbnail,
            sourceWindowIndex: s.index
        )
        s.adoptFreshStore()
        s.url = s.rcrTargetURL
    }

    private func recordOutcome(
        session s: QuadSession,
        credential: Credential,
        password: String,
        status: AttemptRecord.Status,
        filename: String?,
        judge: SuccessJudgeEngine.Decision?
    ) {
        guard let context = modelContext else { return }
        _ = AttemptTrackingService.shared.recordAttempt(
            context: context,
            credentialID: credential.id,
            username: credential.username,
            password: password,
            passwordIndex: s.rcrPasswordIndex + 1,
            passwordTotal: s.rcrPasswords.count,
            targetDomain: s.rcrTargetURL?.host(percentEncoded: false)?.lowercased() ?? credential.domain,
            sessionTag: s.sessionTag,
            status: status,
            resultURL: s.webView?.url?.absoluteString,
            resultPageTitle: s.webView?.title,
            screenshotFilename: filename,
            judge: judge
        )
    }

    private func burnAndAdvance(session s: QuadSession, completedID: String) async {
        s.rcrStatus = .burning
        s.rcrBurnFlash &+= 1
        WindowDiagnosticsService.shared.noteBurn(session: s)
        if !ParkedSessionStore.shared.contains(storeID: s.storeID) {
            await QuadDataStore.burn(dataStoreID: s.storeID)
        }
        s.rcrCompletedIDs.insert(completedID)
        s.rcrIndex += 1
        s.rcrPasswordIndex = 0
        s.needsPostBurnSettle = true
        if let target = s.rcrTargetURL {
            s.rcrStatus = .navigating
            s.rcrAwaitingNavigation = true
            s.url = target
            s.webView?.load(URLRequest(url: target))
            armRCRWatchdog(for: s, timeout: PageSettleService.postBurnNavigationWatchdog)
            return
        }
        await runCurrent(session: s)
    }

    func cellPageDidFinish(session s: QuadSession) {
        guard s.rcrRunning else { return }
        if s.rcrAwaitingNavigation {
            s.rcrAwaitingNavigation = false
            // Navigation leg completed — attemptFill arms the observation
            // watchdog once the submit is out.
            cancelRCRWatchdog(for: s)
            // Cookie popups only ever appear on a window's first load or
            // right after a burn+reload — both land here. After a perm-
            // disabled burn the next credential gets extra boot + consent
            // time so the login form is actually ready before we fill.
            Task {
                await self.settleThenFill(session: s)
            }
            return
        }
        if s.rcrExtraSubmitsInFlight { return }
        if s.rcrStatus == .waiting || s.rcrStatus == .submitting {
            s.webView?.evaluateJavaScript(
                JavaScriptInjectionService.rcrInstallObserverScript(),
                completionHandler: nil
            )
            // A reload during observation gets a fresh watchdog window so a
            // dead reload can't stall the run.
            armRCRWatchdog(for: s)
        }
    }

    /// Deletes a permanently-disabled credential's keychain password and its
    /// SwiftData row so it can never be selected again by any future run in
    /// any window. History of the attempt lives on in `AttemptRecord`.
    private func deleteCredentialPermanently(_ credential: Credential) {
        KeychainService.shared.deletePassword(for: credential.id)
        if let context = modelContext {
            context.delete(credential)
            try? context.save()
        }
    }

    /// After a navigation finishes: wait for cookie/consent (and, after a
    /// burn, extra page-boot + login-form time) then start the fill. Also
    /// applies the site-smart pacing pause (learned settle, scaled by the
    /// live speed profile, plus a brief human-like pre-fill pause).
    private func settleThenFill(session s: QuadSession) async {
        let extra = s.needsPostBurnSettle
        s.needsPostBurnSettle = false
        let settleStart = Date()
        await waitForCookieNoticeIfNeeded(session: s, extraBoot: extra)
        guard s.rcrRunning else { return }
        if extra, let webView = s.webView {
            await PageSettleService.waitForLoginForm(in: webView)
            guard s.rcrRunning else { return }
        }
        // Learn how long this site really took to settle (bounded EMA),
        // then rest for the profile-scaled learned time before filling.
        let domain = s.rcrTargetURL?.host(percentEncoded: false)?.lowercased() ?? ""
        if !domain.isEmpty {
            let observed = Date().timeIntervalSince(settleStart)
            SitePacingStore.shared.recordSettle(seconds: observed, domain: domain)
            let learned = SitePacingStore.shared.settleSeconds(for: domain)
            let scaled = SpeedProfile.scaledSettle(baseSeconds: learned, profile: activeSpeedProfile)
            try? await Task.sleep(for: .seconds(scaled))
            guard s.rcrRunning else { return }
            let humanPause = SitePacingStore.shared.humanPauseSeconds(for: domain)
            try? await Task.sleep(for: .seconds(humanPause))
            guard s.rcrRunning else { return }
        }
        if dualQuadActive {
            await attemptFillDual(session: s, lane: laneIndex(for: s))
        } else {
            await attemptFill(session: s)
        }
    }

    /// Waits for a cookie/consent banner to appear and be dismissed.
    /// After a burn, gives the page extra time to boot and the CMP extra
    /// time to inject before concluding there is no banner.
    private func waitForCookieNoticeIfNeeded(session s: QuadSession, extraBoot: Bool) async {
        guard let webView = s.webView else { return }
        if extraBoot {
            try? await Task.sleep(for: PageSettleService.postBurnBootDelay)
            guard s.rcrRunning else { return }
        }
        let grace = extraBoot ? PageSettleService.postBurnCookieGraceMs : PageSettleService.normalCookieGraceMs
        let timeout = extraBoot ? PageSettleService.postBurnCookieTimeoutMs : PageSettleService.normalCookieTimeoutMs
        _ = try? await webView.evaluateJavaScript(
            JavaScriptInjectionService.waitForCookieNoticeScript(timeoutMs: timeout, graceMs: grace)
        )
    }

    private func checkAllFinished() {
        let allDone = enabledSessions.allSatisfy { !$0.rcrRunning }
        guard allDone else { return }
        let totalSuccess = enabledSessions.reduce(0) { $0 + $1.rcrSuccessCount }
        let totalTried = enabledSessions.reduce(0) { $0 + $1.rcrTotal }
        ParkedSessionStore.shared.markRunFinished()
        browserViewModel?.showToast("Quad RCR complete — \(totalSuccess) hits / \(totalTried) tried")
    }

    private func captureAndRecord(
        session s: QuadSession,
        credential: Credential,
        password: String,
        status: AttemptRecord.Status
    ) {
        guard let context = modelContext else { return }
        let webView = s.webView
        let pageURL = webView?.url?.absoluteString
        let pageTitle = webView?.title
        let targetDomain = s.rcrTargetURL?.host(percentEncoded: false)?.lowercased() ?? credential.domain
        let pwIndex = s.rcrPasswordIndex + 1
        let pwTotal = s.rcrPasswords.count
        let credID = credential.id
        let username = credential.username
        let tag = s.sessionTag

        if let webView {
            let config = WKSnapshotConfiguration()
            config.snapshotWidth = 600
            webView.takeSnapshot(with: config) { image, _ in
                guard let image else {
                    Task { @MainActor in
                        _ = AttemptTrackingService.shared.recordAttempt(
                            context: context,
                            credentialID: credID,
                            username: username,
                            password: password,
                            passwordIndex: pwIndex,
                            passwordTotal: pwTotal,
                            targetDomain: targetDomain,
                            sessionTag: tag,
                            status: status,
                            resultURL: pageURL,
                            resultPageTitle: pageTitle,
                            screenshotFilename: nil
                        )
                    }
                    return
                }
                let filename = ScreenshotStorage.save(image)
                Task { @MainActor in
                    let record = AttemptTrackingService.shared.recordAttempt(
                        context: context,
                        credentialID: credID,
                        username: username,
                        password: password,
                        passwordIndex: pwIndex,
                        passwordTotal: pwTotal,
                        targetDomain: targetDomain,
                        sessionTag: tag,
                        status: status,
                        resultURL: pageURL,
                        resultPageTitle: pageTitle,
                        screenshotFilename: filename
                    )
                    // We must not capture the non-Sendable ModelContext or
                    // the @Model record inside a detached task (Swift 6
                    // isolation error). Keep everything here on the main
                    // actor; `classify` hops off-actor internally for the
                    // Vision work.
                    let result = await ScreenshotOCRService.classify(image)
                    record.ocrCategory = result.category.rawValue
                    try? context.save()
                }
            }
        } else {
            _ = AttemptTrackingService.shared.recordAttempt(
                context: context,
                credentialID: credID,
                username: username,
                password: password,
                passwordIndex: pwIndex,
                passwordTotal: pwTotal,
                targetDomain: targetDomain,
                sessionTag: tag,
                status: status,
                resultURL: pageURL,
                resultPageTitle: pageTitle,
                screenshotFilename: nil
            )
        }
    }

    // MARK: - Dual-quad RCR (paired-lane model)
    //
    // Dual URL split mode tests two vault entries at a time per pair — not
    // independent per-window slices. Active sessions are grouped into lanes
    // determined by the active split pattern (horizontal, vertical, or
    // checkerboard). Each lane pairs one Site A session with one Site B
    // session so that both sides test the SAME credential concurrently —
    // one against URL A, the other against URL B. The lane only advances
    // once BOTH sides reach a terminal result.
    //
    // Credentials are pre-balanced across lanes using round-robin so every
    // lane gets either floor(N/lanes) or ceil(N/lanes) — equal to within
    // one credential, no matter the vault size. This replaces the old
    // greedy shared-pool model that could starve slow lanes.

    private struct LaneState {
        var credentials: [Credential] = []
        /// Credentials already finished against both target sites when this
        /// run (re)started. Skipped during assignment; their completed count
        /// was backfilled at start so pause→resume keeps the display honest.
        var skipIDs: Set<String> = []
        var index: Int = 0
        var resultA: AttemptRecord.Status?
        var resultB: AttemptRecord.Status?
        var finalizing: Bool = false
    }

    private var dualQuadActive: Bool = false
    private var dualQuadURLA: URL?
    private var dualQuadURLB: URL?
    private var dualQuadTargetDomainA: String = ""
    private var dualQuadTargetDomainB: String = ""
    private var laneStates: [LaneState] = []
    /// Dynamic lane→session mapping, rebuilt from the active split pattern
    /// so that horizontal, vertical, and checkerboard distributions each
    /// pair the correct A-side and B-side sessions together.
    private var laneSessionAIndices: [Int] = []
    private var laneSessionBIndices: [Int] = []
    /// True when a session's side hit a permanent "been disabled" and needs
    /// its isolated data store burned + the login page reloaded (with a
    /// cookie-notice wait) before the lane's next credential is attempted.
    private var dualNeedsBurn: [Int: Bool] = [:]
    private var dualCredentialIDBySessionIndex: [Int: String] = [:]

    /// Number of A/B lane pairs available for dual-site RCR.
    var laneCount: Int { laneSessionAIndices.count }

    /// Compact-bar progress across every dual-site lane — sums the per-lane
    /// completed and total counters so 6/8/9/12/16-window grids never show only
    /// the first pair's numbers.
    var dualOverallProgress: (completed: Int, total: Int) {
        Self.overallProgress(
            completedPerLane: laneCompletedCounts,
            totalsPerLane: laneStates.map { $0.credentials.count }
        )
    }

    /// Sums per-lane completed/total counters into one overall pair.
    nonisolated static func overallProgress(
        completedPerLane: [Int],
        totalsPerLane: [Int]
    ) -> (completed: Int, total: Int) {
        (completedPerLane.reduce(0, +), totalsPerLane.reduce(0, +))
    }

    /// Backfills per-lane completed counts for a resumed dual run: counts
    /// each lane's credentials that were already finished against both
    /// target sites.
    nonisolated static func laneBackfillCounts(
        slices: [[String]],
        finishedIDs: Set<String>
    ) -> [Int] {
        slices.map { slice in slice.filter { finishedIDs.contains($0) }.count }
    }

    /// Rebuilds lane pairings from the current `targetSiteIndex` assignments.
    /// Each lane pairs one Site A session with one Site B session, in index
    /// order, so the pairing always matches the visual split pattern.
    /// Disabled sessions (e.g. 3×3 center) are excluded entirely.
    private func rebuildLaneMapping() {
        let activeIndices = Array(0..<activeCount).filter { !sessions[$0].isDisabled }
        let aIndices = activeIndices.filter { sessions[$0].targetSiteIndex == 0 }
        let bIndices = activeIndices.filter { sessions[$0].targetSiteIndex == 1 }
        let count = min(aIndices.count, bIndices.count)
        laneSessionAIndices = Array(aIndices.prefix(count))
        laneSessionBIndices = Array(bIndices.prefix(count))
    }

    private func laneIndex(for session: QuadSession) -> Int {
        for i in 0..<laneSessionAIndices.count {
            if laneSessionAIndices[i] == session.index || laneSessionBIndices[i] == session.index {
                return i
            }
        }
        return 0
    }
    private func isASide(_ session: QuadSession) -> Bool {
        laneSessionAIndices.contains(session.index)
    }
    private func sessionA(forLane lane: Int) -> QuadSession {
        guard laneSessionAIndices.indices.contains(lane) else { return sessions[0] }
        return sessions[laneSessionAIndices[lane]]
    }
    private func sessionB(forLane lane: Int) -> QuadSession {
        guard laneSessionBIndices.indices.contains(lane) else { return sessions[1] }
        return sessions[laneSessionBIndices[lane]]
    }

    private func currentDualCredential(_ s: QuadSession) -> Credential? {
        guard let id = dualCredentialIDBySessionIndex[s.index], let context = modelContext else { return nil }
        let descriptor = FetchDescriptor<Credential>(predicate: #Predicate<Credential> { $0.id == id })
        return try? context.fetch(descriptor).first
    }

    /// Dual-quad RCR: two lanes, each testing one credential against BOTH
    /// URL A and URL B before advancing to the next vault entry.
    func startDualQuadRCR(urlA: URL, urlB: URL) {
        guard !anyRCRRunning, !isStartingRCR else { return }
        guard let context = modelContext else { return }
        FillHealerEngine.shared.resetRunBudget()
        ParkedSessionStore.shared.markRunStarted()
        let descriptor = FetchDescriptor<Credential>(
            sortBy: [
                SortDescriptor(\Credential.domain),
                SortDescriptor(\Credential.username)
            ]
        )
        guard let all = try? context.fetch(descriptor), !all.isEmpty else {
            browserViewModel?.showToast("Vault is empty", force: true)
            return
        }
        let excluded = browserViewModel?.excludedDomainSet ?? []

        let eligible = all.filter { cred in
            !excluded.contains(ExcludedDomain.canonicalize(cred.domain))
                && !PermaDisabledStore.shared.isDisabled(credentialID: cred.id)
        }
        guard !eligible.isEmpty else {
            browserViewModel?.showToast("Vault is empty", force: true)
            return
        }

        let lanes = laneSessionAIndices.count
        guard lanes > 0 else {
            browserViewModel?.showToast("No valid lane pairing for this layout", force: true)
            return
        }

        // Keychain reads block the caller — fetch password counts off the
        // main thread so a large vault can't freeze the UI at run start.
        isStartingRCR = true
        rcrStartGeneration &+= 1
        let startGeneration = rcrStartGeneration
        let credIDs = eligible.map(\.id)
        Task { [weak self] in
            guard let self else { return }
            let counts = await Task.detached {
                Dictionary(uniqueKeysWithValues: credIDs.map {
                    ($0, KeychainService.shared.getPasswords(for: $0).count)
                })
            }.value
            guard self.isStartingRCR, self.rcrStartGeneration == startGeneration else { return }
            self.isStartingRCR = false
            self.beginDualQuadRun(urlA: urlA, urlB: urlB, eligible: eligible, passwordCounts: counts, context: context)
        }
    }

    /// Continues `startDualQuadRCR` on the main actor once password counts
    /// are ready: applies the restart/resume rules and kicks off every lane.
    private func beginDualQuadRun(
        urlA: URL,
        urlB: URL,
        eligible: [Credential],
        passwordCounts: [String: Int],
        context: ModelContext
    ) {
        let domainA = urlA.host(percentEncoded: false)?.lowercased() ?? ""
        let domainB = urlB.host(percentEncoded: false)?.lowercased() ?? ""
        let tracker = AttemptTrackingService.shared

        func finishedBoth(_ cred: Credential) -> Bool {
            let pwCount = passwordCounts[cred.id] ?? 0
            let doneA = tracker.credentialIsFinished(
                context: context, credentialID: cred.id, targetDomain: domainA, totalPasswords: pwCount
            )
            let doneB = tracker.credentialIsFinished(
                context: context, credentialID: cred.id, targetDomain: domainB, totalPasswords: pwCount
            )
            return doneA && doneB
        }

        let lanes = laneSessionAIndices.count
        let finishedBeforeRestart = eligible.filter { finishedBoth($0) }
        let restartingClean = finishedBeforeRestart.count == eligible.count
        if restartingClean {
            // The whole vault already finished against both URLs — restart clean.
            tracker.clearAttempts(context: context, targetDomain: domainA)
            tracker.clearAttempts(context: context, targetDomain: domainB)
        }
        let previouslyFinishedIDs: Set<String> = restartingClean
            ? []
            : Set(finishedBeforeRestart.map(\.id))

        // Split each lane's FULL share up front so a resumed run still shows
        // previously-finished credentials in the queue and counters.
        var fullLaneSlices: [[Credential]] = Array(repeating: [], count: lanes)
        for (i, cred) in eligible.enumerated() {
            fullLaneSlices[i % lanes].append(cred)
        }

        dualQuadURLA = urlA
        dualQuadURLB = urlB
        dualQuadTargetDomainA = domainA
        dualQuadTargetDomainB = domainB
        dualQuadActive = true
        dualNeedsBurn = [:]
        dualCredentialIDBySessionIndex = [:]
        laneStates = (0..<lanes).map { lane in
            let fullSlice = fullLaneSlices[lane]
            return LaneState(
                credentials: fullSlice,
                skipIDs: Set(fullSlice.map(\.id)).intersection(previouslyFinishedIDs)
            )
        }
        // Backfill counters with credentials already finished against BOTH
        // sites so pause→resume doesn't reset the visible progress.
        laneCompletedCounts = Self.laneBackfillCounts(
            slices: fullLaneSlices.map { $0.map(\.id) },
            finishedIDs: previouslyFinishedIDs
        )

        for lane in 0..<lanes {
            let slice = fullLaneSlices[lane]
            let sliceIDs = slice.map(\.id)
            let sliceUsernames = slice.map(\.username)
            let sliceCounts: [Int] = sliceIDs.map { passwordCounts[$0] ?? 0 }
            let skipIDs = laneStates[lane].skipIDs
            for s in [sessionA(forLane: lane), sessionB(forLane: lane)] {
                s.rcrQueueIDs = sliceIDs
                s.rcrQueueUsernames = sliceUsernames
                s.rcrQueuePasswordCounts = sliceCounts
                s.rcrTotal = slice.count
                s.rcrCompletedIDs = skipIDs
                s.rcrIndex = 0
                s.rcrSuccessCount = 0
                s.rcrAwaitingNavigation = false
                s.rcrExtraSubmitsInFlight = false
                s.needsPostBurnSettle = false
            }
        }

        // Human-like scrolling only runs while an automated run is active.
        for s in activeSessions {
            s.webView?.evaluateJavaScript(
                JavaScriptInjectionService.rcrScrollEnableScript(),
                completionHandler: nil
            )
        }

        for lane in 0..<lanes {
            assignNextCredential(lane: lane)
        }
    }

    /// Pulls the next unclaimed credential from the shared pool for `lane`
    /// and kicks off both of its sessions "sortve parallel" against URL A
    /// and URL B. If the pool is exhausted, the lane is marked finished.
    private func assignNextCredential(lane: Int) {
        guard dualQuadActive else { return }
        let sA = sessionA(forLane: lane)
        let sB = sessionB(forLane: lane)

        // Skip credentials already finished against both sites when this
        // run started — they're counted via the backfilled counter, not
        // re-tested.
        while laneStates[lane].index < laneStates[lane].credentials.count,
              laneStates[lane].skipIDs.contains(
                  laneStates[lane].credentials[laneStates[lane].index].id
              ) {
            laneStates[lane].index += 1
        }

        guard laneStates[lane].index < laneStates[lane].credentials.count else {
            sA.rcrRunning = false
            sA.rcrStatus = .finished
            sB.rcrRunning = false
            sB.rcrStatus = .finished
            cancelRCRWatchdog(for: sA)
            cancelRCRWatchdog(for: sB)
            // Don't leave plaintext passwords sitting in memory.
            sA.rcrPasswords = []
            sB.rcrPasswords = []
            checkDualQuadAllFinished()
            return
        }

        let credential = laneStates[lane].credentials[laneStates[lane].index]
        laneStates[lane].resultA = nil
        laneStates[lane].resultB = nil
        laneStates[lane].finalizing = false
        dualCredentialIDBySessionIndex[sA.index] = credential.id
        dualCredentialIDBySessionIndex[sB.index] = credential.id

        for s in [sA, sB] {
            s.rcrIndex = laneStates[lane].index
            s.rcrCurrentUsername = credential.username
            s.rcrRunning = true
            s.rcrStatus = .navigating
        }

        guard let urlA = dualQuadURLA, let urlB = dualQuadURLB else { return }
        Task {
            await self.runDualSide(
                session: sA, credential: credential, targetURL: urlA,
                targetDomain: self.dualQuadTargetDomainA, lane: lane
            )
        }
        Task {
            await self.runDualSide(
                session: sB, credential: credential, targetURL: urlB,
                targetDomain: self.dualQuadTargetDomainB, lane: lane
            )
        }
    }

    /// Runs ONE side (URL A or URL B) of a lane's current credential —
    /// fetches/filters passwords, burns+reloads first if the previous round
    /// left a pending "been disabled" burn for this session, navigates if
    /// needed, then hands off to `attemptFillDual`.
    private func runDualSide(
        session s: QuadSession,
        credential: Credential,
        targetURL: URL,
        targetDomain: String,
        lane: Int
    ) async {
        guard dualQuadActive, s.rcrRunning else { return }
        await waitIfPausedOrFrozen(s)
        guard dualQuadActive, s.rcrRunning else { return }

        if TempDisabledStore.shared.isDisabled(credentialID: credential.id) {
            finishDualSide(session: s, lane: lane, status: .tempDisabled)
            return
        }
        if PermaDisabledStore.shared.isDisabled(credentialID: credential.id) {
            finishDualSide(session: s, lane: lane, status: .disabled)
            return
        }

        let credID = credential.id
        let allPasswords = await Task.detached {
            KeychainService.shared.getPasswords(for: credID)
        }.value
        guard !allPasswords.isEmpty else {
            finishDualSide(session: s, lane: lane, status: .failed)
            return
        }

        let tracker = AttemptTrackingService.shared
        let filtered: [String]
        if let context = modelContext {
            if retryFailed {
                filtered = allPasswords.filter { pw in
                    !tracker.isTerminallyAttempted(
                        context: context, credentialID: credID,
                        passwordHash: PasswordFingerprint.hash(pw), targetDomain: targetDomain
                    )
                }
            } else {
                let descriptor = FetchDescriptor<AttemptRecord>(
                    predicate: #Predicate<AttemptRecord> { rec in
                        rec.credentialID == credID
                            && rec.targetDomain == targetDomain
                            && rec.statusRaw != "pending"
                            && rec.statusRaw != "skipped"
                    }
                )
                let attempted = Set(((try? context.fetch(descriptor)) ?? []).map { $0.passwordHash })
                filtered = allPasswords.filter { !attempted.contains(PasswordFingerprint.hash($0)) }
            }
        } else {
            filtered = allPasswords
        }

        guard !filtered.isEmpty else {
            finishDualSide(session: s, lane: lane, status: .failed)
            return
        }

        s.rcrPasswords = filtered
        s.rcrPasswordIndex = 0
        s.rcrPasswordsCredentialID = credential.id
        s.rcrTargetURL = targetURL
        s.rcrCurrentDomain = targetDomain

        // A permanent disable on the previous round for this window needs a
        // full burn + fresh reload (and cookie-notice wait) before we try
        // the next credential here — regardless of the current URL.
        if dualNeedsBurn[s.index] == true {
            dualNeedsBurn[s.index] = false
            s.rcrStatus = .burning
            s.rcrBurnFlash &+= 1
            if !ParkedSessionStore.shared.contains(storeID: s.storeID) {
                await QuadDataStore.burn(dataStoreID: s.storeID)
            }
            guard dualQuadActive, s.rcrRunning else { return }
            s.needsPostBurnSettle = true
            s.rcrStatus = .navigating
            s.rcrAwaitingNavigation = true
            s.url = targetURL
            s.webView?.load(URLRequest(url: targetURL))
            armRCRWatchdog(for: s, timeout: PageSettleService.postBurnNavigationWatchdog)
            return
        }

        let liveURL = s.webView?.url ?? s.url
        if !BrowserViewModel.sameTarget(liveURL, targetURL) {
            s.rcrStatus = .navigating
            s.rcrAwaitingNavigation = true
            s.url = targetURL
            s.webView?.load(URLRequest(url: targetURL))
            armRCRWatchdog(for: s)
            return
        }

        await attemptFillDual(session: s, lane: lane)
    }

    private func attemptFillDual(session s: QuadSession, lane: Int) async {
        guard dualQuadActive, s.rcrRunning else { return }
        await waitIfPausedOrFrozen(s)
        guard dualQuadActive, s.rcrRunning, !s.rcrPasswords.isEmpty else { return }
        guard let credential = currentDualCredential(s) else {
            finishDualSide(session: s, lane: lane, status: .failed)
            return
        }
        let password = s.rcrPasswords[s.rcrPasswordIndex]
        let targetDomain = s.rcrTargetURL?.host(percentEncoded: false)?.lowercased() ?? credential.domain
        let siteSetting = browserViewModel?.fetchSiteSetting(for: targetDomain)

        s.rcrStatus = .filling
        let fillScript = JavaScriptInjectionService.fillCredentialScript(
            username: credential.username,
            password: password,
            usernameSelector: siteSetting?.usernameSelector,
            passwordSelector: siteSetting?.passwordSelector,
            suppressKeyboard: true
        )
        let fillResult = try? await s.webView?.evaluateJavaScript(fillScript)

        var healedSubmitSelector: String? = nil
        if FillHealerEngine.fillMissed(fillResult),
           let webView = s.webView,
           let context = self.modelContext {
            let outcome = await FillHealerEngine.shared.healAndRefill(
                webView: webView,
                domain: targetDomain,
                sessionTag: s.sessionTag,
                username: credential.username,
                password: password,
                modelContext: context
            )
            healedSubmitSelector = outcome?.submitSelector
        }

        s.rcrStatus = .submitting
        let submitScript = JavaScriptInjectionService.submitFormScript(
            submitSelector: healedSubmitSelector ?? siteSetting?.submitButtonSelector
        )
        _ = try? await s.webView?.evaluateJavaScript(submitScript)

        let extraCount = max(0, UserDefaults.standard.integer(forKey: "rcrExtraSubmits"))
        let rawDelay = UserDefaults.standard.double(forKey: "rcrSubmitDelay")
        let baseDelay = rawDelay > 0 ? rawDelay : 1.5
        let delay = max(0.2, baseDelay * activeSpeedProfile.submitGapMultiplier)
        if extraCount > 0 {
            // Self-driving loop — watchdog must not fire during it; it
            // re-arms when the loop hands back to the observer.
            cancelRCRWatchdog(for: s)
            s.rcrExtraSubmitsInFlight = true
            for _ in 0..<extraCount {
                await waitIfPausedOrFrozen(s)
                guard s.rcrRunning, dualQuadActive else { s.rcrExtraSubmitsInFlight = false; return }
                try? await Task.sleep(for: .seconds(delay))
                guard s.rcrRunning, dualQuadActive else { s.rcrExtraSubmitsInFlight = false; return }
                _ = try? await s.webView?.evaluateJavaScript(submitScript)

                try? await Task.sleep(for: .seconds(0.35))
                guard s.rcrRunning, dualQuadActive else { s.rcrExtraSubmitsInFlight = false; return }
                let rawState = try? await s.webView?.evaluateJavaScript(
                    JavaScriptInjectionService.pageStateSnapshotScript()
                )
                if let payload = JavaScriptInjectionService.parsePageState(rawState),
                   JavaScriptInjectionService.isTerminalRCRState(payload) {
                    s.rcrExtraSubmitsInFlight = false
                    s.rcrStatus = .waiting
                    handleDualQuadMessage(session: s, payload: payload)
                    return
                }
            }
            s.rcrExtraSubmitsInFlight = false
        }

        credential.lastUsedAt = Date()
        credential.usageCount += 1
        try? modelContext?.save()

        if let context = modelContext {
            _ = AttemptTrackingService.shared.recordAttempt(
                context: context,
                credentialID: credential.id,
                username: credential.username,
                password: password,
                passwordIndex: s.rcrPasswordIndex + 1,
                passwordTotal: s.rcrPasswords.count,
                targetDomain: targetDomain,
                sessionTag: s.sessionTag,
                status: .pending
            )
        }

        s.rcrStatus = .waiting
        let installScript = JavaScriptInjectionService.rcrInstallObserverScript()
        _ = try? await s.webView?.evaluateJavaScript(installScript)
        armRCRWatchdog(for: s)
    }

    private func handleDualQuadMessage(session s: QuadSession, payload: [String: Any]) {
        guard dualQuadActive, s.rcrRunning, s.rcrStatus == .waiting else { return }
        if s.rcrExtraSubmitsInFlight { return }
        if s.rcrJudging { return }
        let lane = laneIndex(for: s)
        guard let credential = currentDualCredential(s) else {
            finishDualSide(session: s, lane: lane, status: .failed)
            return
        }
        let password = s.rcrPasswords[safe: s.rcrPasswordIndex] ?? ""
        let signal = SuccessJudgeEngine.classifyLocal(payload)

        switch signal {
        case .disabled:
            ParkedSessionStore.shared.recordFailure()
            captureAndRecord(session: s, credential: credential, password: password, status: .disabled)
            dualNeedsBurn[s.index] = true
            finishDualSide(session: s, lane: lane, status: .disabled)
        case .tempDisabled:
            captureAndRecord(session: s, credential: credential, password: password, status: .tempDisabled)
            if s.rcrPasswords.count > 1 {
                TempDisabledStore.shared.markDisabled(credentialID: credential.id)
                browserViewModel?.showToast("Temp-disabled — \(credential.username)")
            }
            finishDualSide(session: s, lane: lane, status: .tempDisabled)
        case .stillOnLogin:
            ParkedSessionStore.shared.recordFailure()
            captureAndRecord(session: s, credential: credential, password: password, status: .failed)
            if s.rcrPasswordIndex + 1 < s.rcrPasswords.count {
                s.rcrPasswordIndex += 1
                Task { await self.attemptFillDual(session: s, lane: lane) }
            } else {
                finishDualSide(session: s, lane: lane, status: .failed)
            }
        case .apparentSuccess, .unclear:
            s.rcrJudging = true
            cancelRCRWatchdog(for: s)
            let credID = credential.id
            Task {
                await self.judgeDualAndAdvance(session: s, lane: lane, payload: payload, credentialID: credID, password: password)
                s.rcrJudging = false
            }
        }
    }

    private func judgeDualAndAdvance(
        session s: QuadSession,
        lane: Int,
        payload: [String: Any],
        credentialID: String,
        password: String
    ) async {
        guard dualQuadActive, s.rcrRunning else { return }
        guard let credential = currentDualCredential(s), credential.id == credentialID else { return }
        // Speed-scaled grace before judging so the page settles into its
        // final state — slower profiles judge later, never sooner.
        try? await Task.sleep(for: activeSpeedProfile.judgeGrace)
        guard dualQuadActive, s.rcrRunning else { return }
        let image = await WebViewSnapshotter.capture(s.webView)
        let filename = image.flatMap { ScreenshotStorage.save($0) }
        let domain = s.rcrTargetURL?.host(percentEncoded: false)?.lowercased() ?? credential.domain
        let decision = await SuccessJudgeEngine.judge(
            payload: payload,
            image: image,
            domain: domain,
            sessionTag: s.sessionTag
        )
        recordOutcome(
            session: s,
            credential: credential,
            password: password,
            status: decision.status,
            filename: filename,
            judge: decision
        )

        switch decision.status {
        case .disabled:
            ParkedSessionStore.shared.recordFailure()
            dualNeedsBurn[s.index] = true
            finishDualSide(session: s, lane: lane, status: .disabled)
        case .tempDisabled:
            if s.rcrPasswords.count > 1 {
                TempDisabledStore.shared.markDisabled(credentialID: credential.id)
            }
            finishDualSide(session: s, lane: lane, status: .tempDisabled)
        case .failed, .pending, .skipped:
            ParkedSessionStore.shared.recordFailure()
            if s.rcrPasswordIndex + 1 < s.rcrPasswords.count {
                s.rcrPasswordIndex += 1
                Task { await self.attemptFillDual(session: s, lane: lane) }
            } else {
                finishDualSide(session: s, lane: lane, status: .failed)
            }
        case .review:
            finishDualSide(session: s, lane: lane, status: .review)
        case .success:
            s.rcrSuccessCount += 1
            s.rcrStatus = .success
            if decision.shouldPark {
                parkSession(s, credential: credential, thumbnail: image)
            }
            finishDualSide(session: s, lane: lane, status: .success)
        }
    }

    /// Records this session's side result for the lane's current credential.
    /// Once BOTH sides have reported in, finalizes the pairing exactly once.
    private func finishDualSide(session s: QuadSession, lane: Int, status: AttemptRecord.Status) {
        guard dualQuadActive else { return }
        if isASide(s) {
            laneStates[lane].resultA = status
        } else {
            laneStates[lane].resultB = status
        }
        s.rcrStatus = .pairWait

        guard let resultA = laneStates[lane].resultA, let resultB = laneStates[lane].resultB else {
            // Still waiting on the other URL's result for this credential.
            return
        }
        guard !laneStates[lane].finalizing else { return }
        laneStates[lane].finalizing = true
        finalizeLane(lane: lane, resultA: resultA, resultB: resultB)
    }

    /// Applies the paired deletion rule: only delete when a permanent
    /// disable is paired with another removal-safe result (another
    /// permanent disable, or an ordinary login failure). Never delete when
    /// paired with success or temp-disabled — those credentials are kept.
    private func finalizeLane(lane: Int, resultA: AttemptRecord.Status, resultB: AttemptRecord.Status) {
        guard let credential = laneStates[lane].credentials[safe: laneStates[lane].index] else {
            advanceLane(lane: lane)
            return
        }

        let keepStatuses: Set<AttemptRecord.Status> = [.success, .tempDisabled, .review]
        let isRemovalSafe = (resultA == .disabled || resultB == .disabled)
            && !keepStatuses.contains(resultA)
            && !keepStatuses.contains(resultB)

        if isRemovalSafe {
            PermaDisabledStore.shared.markDisabled(credentialID: credential.id)
            // Capture before deletion — reading a property off a deleted
            // SwiftData model can fault.
            let deletedUsername = credential.username
            deleteCredentialPermanently(credential)
            browserViewModel?.showToast("Removed (disabled) — \(deletedUsername)")
        }

        for s in [sessionA(forLane: lane), sessionB(forLane: lane)] {
            s.rcrCompletedIDs.insert(credential.id)
        }
        if laneCompletedCounts.indices.contains(lane) {
            laneCompletedCounts[lane] += 1
        }

        advanceLane(lane: lane)
    }

    private func advanceLane(lane: Int) {
        laneStates[lane].index += 1
        assignNextCredential(lane: lane)
    }

    private func checkDualQuadAllFinished() {
        guard dualQuadActive else { return }
        let allLanesDone = laneStates.allSatisfy { $0.index >= $0.credentials.count }
        guard allLanesDone else { return }
        let stillWorking = enabledSessions.contains { $0.rcrRunning && $0.rcrStatus != .finished }
        guard !stillWorking else { return }
        dualQuadActive = false
        let totalSuccess = enabledSessions.reduce(0) { $0 + $1.rcrSuccessCount }
        let totalTried = laneStates.reduce(0) { $0 + $1.credentials.count }
        ParkedSessionStore.shared.markRunFinished()
        browserViewModel?.showToast("Dual RCR complete — \(totalSuccess) hits / \(totalTried) tried")
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
