import Foundation
import WebKit

/// Samples process + per-window memory and runs the automated leak suite
/// used by the diagnostic overlay.
@Observable
@MainActor
final class WindowDiagnosticsService {
    static let shared = WindowDiagnosticsService()
    static let overlayEnabledKey = "windowDiagnosticsEnabled"

    var overlayEnabled: Bool {
        didSet {
            UserDefaults.standard.set(overlayEnabled, forKey: Self.overlayEnabledKey)
            if overlayEnabled {
                scheduleRefresh()
            } else {
                pollTask?.cancel()
                pollTask = nil
            }
        }
    }

    var processSample: ProcessMemorySample = .zero
    private(set) var lastSuiteAt: Date?

    private weak var controller: QuadController?
    private weak var browser: BrowserViewModel?
    private var pollTask: Task<Void, Never>?
    private var isolationTokens: [String: String] = [:]
    private var burnedKeys: Set<String> = []
    /// Isolation cookie that must disappear after a burn. Kept separate from
    /// the fresh probe planted on the next load so a new cookie is not a fail.
    private var burnedTokens: [String: String] = [:]
    private var preBurnBytes: [String: UInt64] = [:]
    private var refreshGeneration: Int = 0

    private init() {
        if UserDefaults.standard.object(forKey: Self.overlayEnabledKey) == nil {
            overlayEnabled = true
        } else {
            overlayEnabled = UserDefaults.standard.bool(forKey: Self.overlayEnabledKey)
        }
    }

    func attach(controller: QuadController, browser: BrowserViewModel) {
        self.controller = controller
        self.browser = browser
        if overlayEnabled {
            scheduleRefresh()
        }
    }

    func noteBurn(session: QuadSession) {
        let key = sessionKey(session)
        preBurnBytes[key] = session.memorySnapshot?.attributedBytes ?? preBurnBytes[key]
        burnedKeys.insert(key)
        if let token = isolationTokens.removeValue(forKey: key) {
            burnedTokens[key] = token
        }
        session.leakCheck = WindowLeakCheckReport(verdict: .running, items: session.leakCheck.items, checkedAt: .now)
        scheduleRefresh(delay: 0.4)
    }

    func noteBurn(tab: BrowserTab) {
        let key = tabKey(tab)
        preBurnBytes[key] = tab.memorySnapshot?.attributedBytes ?? preBurnBytes[key]
        burnedKeys.insert(key)
        if let token = isolationTokens.removeValue(forKey: key) {
            burnedTokens[key] = token
        }
        tab.leakCheck = WindowLeakCheckReport(verdict: .running, items: tab.leakCheck.items, checkedAt: .now)
        scheduleRefresh(delay: 0.4)
    }

    func pageDidFinish(session: QuadSession) {
        guard overlayEnabled else { return }
        Task { await self.refreshNow() }
    }

    func pageDidFinish(tab: BrowserTab) {
        guard overlayEnabled else { return }
        Task { await self.refreshNow() }
    }

    private func scheduleRefresh(delay: TimeInterval = 0) {
        pollTask?.cancel()
        guard overlayEnabled else { return }
        pollTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            while !Task.isCancelled {
                guard let self, self.overlayEnabled else { return }
                await self.refreshNow()
                try? await Task.sleep(for: .seconds(8))
            }
        }
    }

    func refreshNow() async {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        processSample = ProcessMemorySampler.sample()

        let sessions = controller?.enabledSessions ?? []
        let tabs = browser?.isQuadMode == true ? [] : (browser?.tabs ?? [])

        var sessionSnapshots: [Int: WindowMemorySnapshot] = [:]
        for session in sessions {
            if Task.isCancelled || generation != refreshGeneration { return }
            sessionSnapshots[session.index] = await sample(session: session, process: processSample)
        }

        var tabSnapshots: [String: WindowMemorySnapshot] = [:]
        for tab in tabs {
            if Task.isCancelled || generation != refreshGeneration { return }
            tabSnapshots[tab.id] = await sample(tab: tab, process: processSample)
        }

        attribute(
            process: processSample,
            sessionSnapshots: &sessionSnapshots,
            tabSnapshots: &tabSnapshots
        )

        for session in sessions {
            if let snapshot = sessionSnapshots[session.index] {
                session.memorySnapshot = snapshot
            }
        }
        for tab in tabs {
            if let snapshot = tabSnapshots[tab.id] {
                tab.memorySnapshot = snapshot
            }
        }

        await runLeakSuite(sessions: sessions, tabs: tabs)
        lastSuiteAt = .now
    }

    private func sample(session: QuadSession, process: ProcessMemorySample) async -> WindowMemorySnapshot {
        let store = WKWebsiteDataStore(forIdentifier: session.storeID)
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        let cookies = await cookies(in: store)
        let page = await pageMetrics(in: session.webView)
        if let host = session.url?.host(percentEncoded: false) {
            await plantIsolationCookie(key: sessionKey(session), host: host, index: session.index, store: store)
        }
        return WindowMemorySnapshot(
            attributedBytes: 0,
            storeRecordCount: records.count,
            cookieCount: cookies.count,
            page: page,
            sampledAt: process.sampledAt,
            processUsedBytes: process.usedBytes,
            processAvailableBytes: process.availableBytes
        )
    }

    private func sample(tab: BrowserTab, process: ProcessMemorySample) async -> WindowMemorySnapshot {
        let store = WKWebsiteDataStore(forIdentifier: tab.dataStoreID)
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        let cookies = await cookies(in: store)
        let page = await pageMetrics(in: tab.webView)
        if let host = tab.url?.host(percentEncoded: false) {
            await plantIsolationCookie(key: tabKey(tab), host: host, index: 0, store: store)
        }
        return WindowMemorySnapshot(
            attributedBytes: 0,
            storeRecordCount: records.count,
            cookieCount: cookies.count,
            page: page,
            sampledAt: process.sampledAt,
            processUsedBytes: process.usedBytes,
            processAvailableBytes: process.availableBytes
        )
    }

    private func attribute(
        process: ProcessMemorySample,
        sessionSnapshots: inout [Int: WindowMemorySnapshot],
        tabSnapshots: inout [String: WindowMemorySnapshot]
    ) {
        let sessionWeights = sessionSnapshots.map { ($0.key, $0.value.attributionWeight) }
        let tabWeights = tabSnapshots.map { ($0.key, $0.value.attributionWeight) }
        let total = sessionWeights.reduce(0) { $0 + $1.1 } + tabWeights.reduce(0) { $0 + $1.1 }
        guard total > 0, process.usedBytes > 0 else { return }

        for (index, weight) in sessionWeights {
            let share = UInt64((Double(process.usedBytes) * Double(weight) / Double(total)).rounded())
            sessionSnapshots[index]?.attributedBytes = share
        }
        for (id, weight) in tabWeights {
            let share = UInt64((Double(process.usedBytes) * Double(weight) / Double(total)).rounded())
            tabSnapshots[id]?.attributedBytes = share
        }
    }

    private func runLeakSuite(sessions: [QuadSession], tabs: [BrowserTab]) async {
        var cookiesBySession: [Int: [HTTPCookie]] = [:]
        for session in sessions {
            let store = WKWebsiteDataStore(forIdentifier: session.storeID)
            cookiesBySession[session.index] = await cookies(in: store)
        }

        let allStoreIDs = (controller?.sessions ?? sessions).map(\.storeID)
        for session in sessions {
            session.leakCheck = WindowLeakCheckReport(verdict: .running, items: session.leakCheck.items, checkedAt: .now)
            let key = sessionKey(session)
            let token = isolationTokens[key]
            let cookieName = WindowLeakCheckEvaluator.isolationCookieName(for: session.index)
            let holders = cookiesBySession.compactMap { index, cookies -> Int? in
                cookies.contains(where: { $0.name == cookieName && (token == nil || $0.value == token) }) ? index : nil
            }
            let burned = burnedKeys.contains(key)
            let burnedToken = burnedTokens[key]
            let tokenStillPresent = burnedToken != nil && cookiesBySession[session.index]?.contains(where: {
                $0.name == cookieName && $0.value == burnedToken
            }) == true

            var items: [LeakCheckItem] = [
                WindowLeakCheckEvaluator.storeIdentityItem(
                    sessionIndex: session.index,
                    storeID: session.storeID,
                    expectedID: QuadDataStore.identifier(for: session.index),
                    allStoreIDs: allStoreIDs
                ),
                WindowLeakCheckEvaluator.cookieIsolationItem(
                    sessionIndex: session.index,
                    token: token,
                    storesHoldingToken: holders
                ),
                WindowLeakCheckEvaluator.processPressureItem(availableBytes: processSample.availableBytes),
                WindowLeakCheckEvaluator.webViewItem(
                    sessionIndex: session.index,
                    hasWebView: session.webView != nil,
                    isActive: true
                )
            ]
            if let burn = WindowLeakCheckEvaluator.burnWipeItem(
                sessionIndex: session.index,
                didBurn: burned,
                tokenStillPresent: tokenStillPresent
            ) {
                items.append(burn)
            }
            if let rebound = WindowLeakCheckEvaluator.memoryReboundItem(
                sessionIndex: session.index,
                preBurnBytes: preBurnBytes[key],
                currentBytes: session.memorySnapshot?.attributedBytes ?? 0
            ) {
                items.append(rebound)
            }
            session.leakCheck = WindowLeakCheckEvaluator.report(from: items)
        }

        for tab in tabs {
            let store = WKWebsiteDataStore(forIdentifier: tab.dataStoreID)
            let cookies = await cookies(in: store)
            let key = tabKey(tab)
            let token = isolationTokens[key]
            let cookieName = WindowLeakCheckEvaluator.isolationCookieName(for: 0)
            let burned = burnedKeys.contains(key)
            let holders = cookies.contains(where: { $0.name == cookieName && (token == nil || $0.value == token) }) ? [0] : []
            let burnedToken = burnedTokens[key]
            let tokenStillPresent = burnedToken != nil && cookies.contains(where: { $0.name == cookieName && $0.value == burnedToken })
            var items: [LeakCheckItem] = [
                WindowLeakCheckEvaluator.storeIdentityItem(
                    sessionIndex: 0,
                    storeID: tab.dataStoreID,
                    expectedID: tab.dataStoreID,
                    allStoreIDs: [tab.dataStoreID]
                ),
                WindowLeakCheckEvaluator.cookieIsolationItem(
                    sessionIndex: 0,
                    token: token,
                    storesHoldingToken: holders
                ),
                WindowLeakCheckEvaluator.processPressureItem(availableBytes: processSample.availableBytes),
                WindowLeakCheckEvaluator.webViewItem(
                    sessionIndex: 0,
                    hasWebView: tab.webView != nil,
                    isActive: tab.url != nil
                )
            ]
            if let burn = WindowLeakCheckEvaluator.burnWipeItem(
                sessionIndex: 0,
                didBurn: burned,
                tokenStillPresent: tokenStillPresent
            ) {
                items.append(burn)
            }
            if let rebound = WindowLeakCheckEvaluator.memoryReboundItem(
                sessionIndex: 0,
                preBurnBytes: preBurnBytes[key],
                currentBytes: tab.memorySnapshot?.attributedBytes ?? 0
            ) {
                items.append(rebound)
            }
            tab.leakCheck = WindowLeakCheckEvaluator.report(from: items)
        }
    }

    private func plantIsolationCookie(key: String, host: String, index: Int, store: WKWebsiteDataStore) async {
        if isolationTokens[key] != nil { return }
        let token = UUID().uuidString
        let domain = host.hasPrefix(".") ? String(host.dropFirst()) : host
        guard let cookie = HTTPCookie(properties: [
            .domain: domain,
            .path: "/",
            .name: WindowLeakCheckEvaluator.isolationCookieName(for: index),
            .value: token,
            .discard: "TRUE"
        ]) else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            store.httpCookieStore.setCookie(cookie) {
                continuation.resume()
            }
        }
        isolationTokens[key] = token
    }

    private func cookies(in store: WKWebsiteDataStore) async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            store.httpCookieStore.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
    }

    private func pageMetrics(in webView: WKWebView?) async -> WindowPageMetrics {
        guard let webView else { return .empty }
        let raw = try? await webView.evaluateJavaScript(JavaScriptInjectionService.pageMemoryMetricsScript())
        return Self.parsePageMetrics(raw)
    }

    nonisolated static func parsePageMetrics(_ raw: Any?) -> WindowPageMetrics {
        let dict: [String: Any]?
        if let json = raw as? String,
           let data = json.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            dict = parsed
        } else {
            dict = raw as? [String: Any]
        }
        guard let dict else { return .empty }
        return WindowPageMetrics(
            htmlBytes: dict["htmlBytes"] as? Int ?? 0,
            nodeCount: dict["nodes"] as? Int ?? 0,
            imageCount: dict["images"] as? Int ?? 0,
            iframeCount: dict["iframes"] as? Int ?? 0,
            scriptCount: dict["scripts"] as? Int ?? 0
        )
    }

    private func sessionKey(_ session: QuadSession) -> String {
        "session-\(session.index)-\(session.storeID.uuidString)"
    }

    private func tabKey(_ tab: BrowserTab) -> String {
        "tab-\(tab.id)"
    }
}
