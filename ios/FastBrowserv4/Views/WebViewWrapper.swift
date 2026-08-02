import SwiftUI
import WebKit

struct WebViewWrapper: UIViewRepresentable {
    let tab: BrowserTab
    let viewModel: BrowserViewModel

    func makeUIView(context: Context) -> WKWebView {
        // Each tab gets its own persistent data store + process pool so
        // cookies, cache, localStorage and in-memory WebKit state never
        // leak across tabs.
        let config = WebViewConfigurationFactory.shared.makeConfiguration(dataStoreID: tab.dataStoreID)
        config.userContentController.add(context.coordinator, name: "rcrObserver")
        config.userContentController.add(context.coordinator, name: "loginResponse")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        context.coordinator.observeProgress(of: webView)
        webView.allowsBackForwardNavigationGestures = true
        webView.isInspectable = true

        tab.webView = webView
        tab.isWebViewActive = true
        if let url = tab.url {
            webView.load(URLRequest(url: url))
        }

        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if tab.webView !== webView {
            tab.webView = webView
        }
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        coordinator.stopObservingProgress()
        coordinator.tab.webView = nil
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(tab: tab, viewModel: viewModel)
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let tab: BrowserTab
        weak var viewModel: BrowserViewModel?
        private var progressObservation: NSKeyValueObservation?

        init(tab: BrowserTab, viewModel: BrowserViewModel) {
            self.tab = tab
            self.viewModel = viewModel
        }

        func observeProgress(of webView: WKWebView) {
            progressObservation = webView.observe(\.estimatedProgress, options: [.initial, .new]) { [weak self] webView, _ in
                Task { @MainActor in
                    self?.tab.estimatedProgress = webView.estimatedProgress
                }
            }
        }

        func stopObservingProgress() {
            progressObservation?.invalidate()
            progressObservation = nil
        }

        nonisolated func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            Task { @MainActor in
                tab.isLoading = true
                tab.estimatedProgress = webView.estimatedProgress
                tab.canGoBack = webView.canGoBack
                tab.canGoForward = webView.canGoForward
            }
        }

        nonisolated func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            Task { @MainActor in
                tab.url = webView.url
                tab.title = webView.title ?? "Loading..."
                tab.canGoBack = webView.canGoBack
                tab.canGoForward = webView.canGoForward
                viewModel?.updateURLBar()
            }
        }

        nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in
                tab.isLoading = false
                tab.estimatedProgress = 1
                tab.url = webView.url
                tab.title = webView.title ?? tab.domain
                tab.canGoBack = webView.canGoBack
                tab.canGoForward = webView.canGoForward
                viewModel?.updateURLBar()

                if let url = webView.url?.absoluteString {
                    viewModel?.addHistoryEntry(url: url, title: tab.title)
                }

                if viewModel?.isRCRRunning == true {
                    viewModel?.rcrPageDidFinish()
                } else {
                    viewModel?.handlePageLoadAutofill(for: tab)
                }
            }
        }

        nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            Task { @MainActor in tab.isLoading = false }
        }

        nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            let _ = error
            Task { @MainActor in tab.isLoading = false }
        }

        nonisolated func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            let navType = await MainActor.run { navigationAction.navigationType }
            if navType == .formSubmitted {
                await MainActor.run {
                    if viewModel?.isRCRRunning != true {
                        viewModel?.detectAndOfferSave()
                    }
                }
            }
            return .allow
        }

        nonisolated func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            let name = message.name
            let body = message.body as? [String: Any] ?? [:]
            Task { @MainActor in
                switch name {
                case "rcrObserver":
                    viewModel?.handleRCRStateMessage(body)
                case "loginResponse":
                    viewModel?.handleLoginResponseMessage(body)
                default: break
                }
            }
        }
    }
}
