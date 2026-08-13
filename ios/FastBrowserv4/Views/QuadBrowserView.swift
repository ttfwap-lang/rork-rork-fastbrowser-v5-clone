import SwiftUI
import WebKit

/// A single cell of the Quad-Mode grid. Owns its own `WKWebView` backed by
/// the session's isolated `WKWebsiteDataStore` so cookies, cache and storage
/// are completely separated from the other three cells.
struct QuadCellWebView: UIViewRepresentable {
    let session: QuadSession
    let controller: QuadController

    func makeUIView(context: Context) -> WKWebView {
        let config = WebViewConfigurationFactory.shared.makeIsolatedConfiguration(dataStoreID: session.storeID)
        config.userContentController.add(context.coordinator, name: "rcrObserver")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.isInspectable = true
        // KVO for live estimatedProgress so the per-cell progress bar
        // tracks the actual load progression instead of staying at 0.
        webView.addObserver(context.coordinator, forKeyPath: #keyPath(WKWebView.estimatedProgress), options: .new, context: nil)

        context.coordinator.ownedWebView = webView
        session.webView = webView
        if let url = session.url {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if session.webView !== webView {
            context.coordinator.ownedWebView?.configuration.userContentController.removeAllScriptMessageHandlers()
            session.webView = webView
            context.coordinator.ownedWebView = webView
        }
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.removeObserver(coordinator, forKeyPath: #keyPath(WKWebView.estimatedProgress), context: nil)
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        coordinator.session.webView = nil
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session, controller: controller)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let session: QuadSession
        weak var controller: QuadController?
        /// Stored reference to clean up the script message handler on dismantle.
        weak var ownedWebView: WKWebView?

        init(session: QuadSession, controller: QuadController) {
            self.session = session
            self.controller = controller
        }

        nonisolated func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            Task { @MainActor in
                session.isLoading = true
                session.estimatedProgress = 0
                session.canGoBack = webView.canGoBack
                session.canGoForward = webView.canGoForward
                if controller?.focusedIndex == session.index {
                    controller?.hostBrowser?.updateURLBar()
                }
            }
        }

        nonisolated func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            Task { @MainActor in
                session.url = webView.url
                session.title = webView.title ?? "Loading…"
                session.canGoBack = webView.canGoBack
                session.canGoForward = webView.canGoForward
                if controller?.focusedIndex == session.index {
                    controller?.hostBrowser?.updateURLBar()
                }
            }
        }

        nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in
                session.isLoading = false
                session.estimatedProgress = 1.0
                session.url = webView.url
                session.title = webView.title ?? session.domain
                session.canGoBack = webView.canGoBack
                session.canGoForward = webView.canGoForward
                // Keep the shared address bar in sync when the focused tile
                // finishes a load (back/forward, link taps, form submits).
                if controller?.focusedIndex == session.index {
                    controller?.hostBrowser?.updateURLBar()
                }
                controller?.cellPageDidFinish(session: session)
                // Page-load autofill for multi-window tiles (skips while any
                // RCR run is active).
                if !session.rcrRunning {
                    controller?.handleQuadPageLoadAutofill(for: session)
                }
            }
        }

        nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            Task { @MainActor in
                session.isLoading = false
                session.estimatedProgress = 1.0
            }
        }

        nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            Task { @MainActor in
                session.isLoading = false
                session.estimatedProgress = 1.0
            }
        }

        nonisolated func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            let navType = await MainActor.run { navigationAction.navigationType }
            if navType == .formSubmitted {
                await MainActor.run {
                    if controller?.anyRCRRunning != true {
                        controller?.detectAndOfferSaveQuad(session: session)
                    }
                }
            }
            return .allow
        }

        // KVO handler for WKWebView.estimatedProgress.
        nonisolated override func observeValue(
            forKeyPath keyPath: String?,
            of object: Any?,
            change: [NSKeyValueChangeKey: Any]?,
            context: UnsafeMutableRawPointer?
        ) {
            guard keyPath == #keyPath(WKWebView.estimatedProgress),
                  let webView = object as? WKWebView else {
                super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
                return
            }
            let progress = webView.estimatedProgress
            Task { @MainActor in
                session.estimatedProgress = progress
            }
        }

        nonisolated func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == "rcrObserver" else { return }
            let body = message.body as? [String: Any] ?? [:]
            Task { @MainActor in
                controller?.handleRCRMessage(session: session, payload: body)
            }
        }
    }
}

/// Grid of isolated browser sessions — 2×2, 2×3, 4×2, 3×3, or 3×4 depending
/// on the active `WindowGridSize`. The cell that's currently "focused" (tap to
/// switch) gets a cyan ring and is the target for the shared URL bar /
/// toolbar.
struct QuadBrowserView: View {
    @Bindable var controller: QuadController

    var body: some View {
        GeometryReader { geo in
            let size = controller.gridSize
            let spacing: CGFloat = 1
            // Floor each cell size so every tile is identical; leftover
            // fractional pixels are absorbed by centered gutters so 6- and
            // 12-window grids never leave uneven rows/columns.
            let totalHSpacing = spacing * CGFloat(max(0, size.columns - 1))
            let totalVSpacing = spacing * CGFloat(max(0, size.rows - 1))
            let cellW = floor((geo.size.width - totalHSpacing) / CGFloat(size.columns))
            let cellH = floor((geo.size.height - totalVSpacing) / CGFloat(size.rows)
            )
            let usedW = cellW * CGFloat(size.columns) + totalHSpacing
            let usedH = cellH * CGFloat(size.rows) + totalVSpacing
            let hPad = max(0, (geo.size.width - usedW) / 2)
            let vPad = max(0, (geo.size.height - usedH) / 2)

            VStack(spacing: spacing) {
                ForEach(0..<size.rows, id: \.self) { row in
                    HStack(spacing: spacing) {
                        ForEach(0..<size.columns, id: \.self) { column in
                            let index = row * size.columns + column
                            if index < controller.activeCount {
                                cell(controller.sessions[index])
                                    .frame(width: cellW, height: cellH)
                                    .clipped()
                            } else {
                                Color.black
                                    .frame(width: cellW, height: cellH)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, hPad)
            .padding(.vertical, vPad)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
            .background(Color.black)
        }
    }

    private func cell(_ session: QuadSession) -> some View {
        let isFocused = controller.focusedIndex == session.index

        // Disabled cells (e.g. 3×3 center in dual-site mode) show an
        // "Unused" label and no web view.
        if session.isDisabled {
            return AnyView(
                ZStack {
                    Color(.tertiarySystemFill)
                    VStack(spacing: 4) {
                        Image(systemName: "square.slash")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.secondary)
                        Text("Unused")
                            .font(.system(size: 9, weight: .heavy, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 0)
                        .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
                )
            )
        }

        return AnyView(
            ZStack {
                QuadCellWebView(session: session, controller: controller)

                // Top-left badge with session id and status dot.
                VStack {
                    HStack {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(statusColor(session.rcrStatus))
                                .frame(width: 6, height: 6)
                            Text(session.id)
                                .font(.system(size: 10, weight: .heavy, design: .rounded))
                                .foregroundStyle(.white)
                            if controller.isDualTargetMode {
                                Text(session.targetSiteIndex == 0 ? "A" : "B")
                                    .font(.system(size: 8, weight: .black, design: .rounded))
                                    .foregroundStyle(session.targetSiteIndex == 0 ? .purple : .orange)
                            }
                            if session.rcrTotal > 0 {
                                Text("\(min(session.rcrIndex, session.rcrTotal))/\(session.rcrTotal)")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.8))
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.55), in: .capsule)
                        .padding(6)
                        Spacer(minLength: 0)
                    }
                    Spacer(minLength: 0)
                }

                if session.isLoading {
                    VStack {
                        Spacer(minLength: 0)
                        GeometryReader { g in
                            Rectangle()
                                .fill(Color.cyan)
                                .frame(width: g.size.width * session.estimatedProgress, height: 1.5)
                        }
                        .frame(height: 1.5)
                    }
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 0)
                    .strokeBorder(isFocused ? Color.cyan : .clear, lineWidth: 2)
            )
            .contentShape(Rectangle())
            .onTapGesture {
                controller.focusedIndex = session.index
            }
        )
    }

    private func statusColor(_ s: QuadSession.Status) -> Color {
        switch s {
        case .idle: return .secondary
        case .navigating: return .blue
        case .filling: return .cyan
        case .submitting: return .indigo
        case .waiting: return .yellow
        case .burning: return .orange
        case .success: return .green
        case .finished: return .mint
        case .pairWait: return .teal
        }
    }
}
