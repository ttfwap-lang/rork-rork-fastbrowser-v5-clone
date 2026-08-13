import Foundation
import WebKit
import UIKit

@Observable
@MainActor
class BrowserTab: Identifiable {
    let id: String
    /// Persistent WebKit data-store identity for this tab. Cookies, cache,
    /// localStorage and IndexedDB stay isolated from every other tab and
    /// every multi-window cell.
    let dataStoreID: UUID
    var url: URL?
    var title: String
    var isLoading: Bool
    var canGoBack: Bool
    var canGoForward: Bool
    var estimatedProgress: Double
    var webView: WKWebView?
    var lastURL: URL?
    var snapshot: UIImage?
    var isWebViewActive: Bool

    init(url: URL? = nil, dataStoreID: UUID = UUID()) {
        self.id = UUID().uuidString
        self.dataStoreID = dataStoreID
        self.url = url
        self.title = "New Tab"
        self.isLoading = false
        self.canGoBack = false
        self.canGoForward = false
        self.estimatedProgress = 0
        self.lastURL = url
        self.isWebViewActive = false
    }

    var domain: String {
        guard let host = url?.host(percentEncoded: false)?.lowercased() else { return "" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    var displayURL: String {
        url?.absoluteString ?? ""
    }

    func captureSnapshot() {
        guard let webView else { return }
        let config = WKSnapshotConfiguration()
        config.snapshotWidth = 200
        webView.takeSnapshot(with: config) { [weak self] image, _ in
            Task { @MainActor in
                self?.snapshot = image
            }
        }
    }
}
