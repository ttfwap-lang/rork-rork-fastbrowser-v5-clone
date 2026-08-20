import Foundation
import SwiftData
import UIKit
import WebKit

/// Owns parked, still-signed-in sessions. Each parked row keeps its own
/// isolated WebKit store identity so cookies never bleed between accounts,
/// and the metadata survives an app restart.
@MainActor
@Observable
final class ParkedSessionStore {
    static let shared = ParkedSessionStore()

    private(set) var sessions: [ParkedSession] = []
    /// Failures recorded during the current (or most recent) run — powers
    /// the rail header ("3 parked, 12 failed").
    private(set) var failedThisRun: Int = 0
    var isRailOpen: Bool = false
    /// Set briefly after a park so the handle can flourish.
    var justParkedID: String?
    var runActive: Bool = false

    private var modelContext: ModelContext?

    private init() {}

    func attach(context: ModelContext) {
        modelContext = context
        reload()
    }

    func reload() {
        guard let modelContext else { return }
        let descriptor = FetchDescriptor<ParkedSession>(
            sortBy: [SortDescriptor(\.parkedAt, order: .reverse)]
        )
        sessions = (try? modelContext.fetch(descriptor)) ?? []
    }

    func markRunStarted() {
        failedThisRun = 0
        runActive = true
    }

    func markRunFinished() {
        runActive = false
        if !sessions.isEmpty {
            isRailOpen = true
        }
    }

    func recordFailure() {
        failedThisRun += 1
    }

    func contains(storeID: UUID) -> Bool {
        let raw = storeID.uuidString
        return sessions.contains { $0.storeID == raw }
    }

    /// Parks a live store. The caller is responsible for handing the window
    /// a fresh store afterwards so the batch can continue.
    @discardableResult
    func park(
        storeID: UUID,
        url: URL?,
        username: String,
        domain: String,
        credentialID: String,
        sessionTag: String,
        thumbnail: UIImage?,
        sourceWindowIndex: Int
    ) -> ParkedSession? {
        guard let modelContext else { return nil }
        let filename = thumbnail.flatMap { ScreenshotStorage.save($0) }
        let row = ParkedSession(
            storeID: storeID,
            urlString: url?.absoluteString ?? "",
            username: username,
            domain: domain,
            credentialID: credentialID,
            sessionTag: sessionTag,
            thumbnailFilename: filename,
            sourceWindowIndex: sourceWindowIndex
        )
        modelContext.insert(row)
        try? modelContext.save()
        reload()
        justParkedID = row.id
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            if justParkedID == row.id { justParkedID = nil }
        }
        return row
    }

    /// Removes the row without wiping the WebKit store — used when the
    /// session is brought back or sent to a window.
    func detach(_ session: ParkedSession) {
        guard let modelContext else { return }
        if let filename = session.thumbnailFilename {
            ScreenshotStorage.delete(filename)
        }
        modelContext.delete(session)
        try? modelContext.save()
        reload()
    }

    /// Closes the parked session and wipes its isolated cookie store.
    func forget(_ session: ParkedSession) async {
        let storeID = session.storeUUID
        detach(session)
        await QuadDataStore.burn(dataStoreID: storeID)
    }

    func clearAll() async {
        let snapshot = sessions
        for session in snapshot {
            await forget(session)
        }
        failedThisRun = 0
        isRailOpen = false
    }
}

/// Tiny helper so snapshot-then-park can share one code path.
enum WebViewSnapshotter {
    @MainActor
    static func capture(_ webView: WKWebView?, width: CGFloat = 600) async -> UIImage? {
        guard let webView else { return nil }
        return await withCheckedContinuation { continuation in
            let config = WKSnapshotConfiguration()
            config.snapshotWidth = NSNumber(value: Double(width))
            webView.takeSnapshot(with: config) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }
}
