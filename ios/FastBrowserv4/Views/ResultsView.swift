import SwiftUI
import SwiftData
import UIKit
import Combine

/// Unified results screen — every (credential × password × target) attempt
/// the app has ever made, with screenshots, status, and source session.
struct ResultsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: [SortDescriptor(\AttemptRecord.timestamp, order: .reverse)])
    private var records: [AttemptRecord]

    enum Tab: String, CaseIterable, Identifiable {
        case results = "Results"
        case screenshots = "Screenshots"
        case tempDisabled = "Temp Disabled"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .results
    @State private var statusFilter: AttemptRecord.Status? = nil
    @State private var sessionFilter: String? = nil
    @State private var showClearConfirmation: Bool = false
    @State private var selectedRecord: AttemptRecord?

    private var filtered: [AttemptRecord] {
        records.filter { rec in
            (statusFilter.map { rec.status == $0 } ?? true)
                && (sessionFilter.map { rec.sessionTag == $0 } ?? true)
        }
    }

    private var sessionTags: [String] {
        Array(Set(records.map { $0.sessionTag })).sorted()
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top, 8)

            filterBar

            switch tab {
            case .results:
                resultsList
            case .screenshots:
                screenshotsGrid
            case .tempDisabled:
                TempDisabledList()
            }
        }
        .navigationTitle("Results")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Done") { dismiss() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(role: .destructive) {
                        showClearConfirmation = true
                    } label: {
                        Label("Clear All Results", systemImage: "trash")
                    }
                    .disabled(records.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog(
            "Clear all attempt results?",
            isPresented: $showClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear All", role: .destructive) {
                AttemptTrackingService.shared.clearAll(context: modelContext)
                // Re-enable every disabled credential too — the docs promise
                // that Clear All is the way to reset blocked logins.
                PermaDisabledStore.shared.clearAll()
                TempDisabledStore.shared.clearAll()
            }
        } message: {
            Text("Removes every attempt record and screenshot, and re-enables all disabled credentials. The vault and passwords are not affected.")
        }
        .sheet(item: $selectedRecord) { record in
            NavigationStack { ResultDetailView(record: record) }
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FilterChip(label: "All", isOn: statusFilter == nil) {
                    statusFilter = nil
                }
                ForEach(AttemptRecord.Status.allCases, id: \.self) { status in
                    FilterChip(
                        label: status.label,
                        tint: status.color,
                        isOn: statusFilter == status
                    ) {
                        statusFilter = (statusFilter == status) ? nil : status
                    }
                }
                if !sessionTags.isEmpty {
                    Divider().frame(height: 16)
                    FilterChip(label: "Any cell", isOn: sessionFilter == nil) {
                        sessionFilter = nil
                    }
                    ForEach(sessionTags, id: \.self) { tag in
                        FilterChip(label: tag.uppercased(), tint: .cyan, isOn: sessionFilter == tag) {
                            sessionFilter = (sessionFilter == tag) ? nil : tag
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    private var resultsList: some View {
        Group {
            if filtered.isEmpty {
                ContentUnavailableView(
                    "No Attempts Yet",
                    systemImage: "list.bullet.rectangle",
                    description: Text("Run RCR to populate the results page.")
                )
            } else {
                List(filtered) { record in
                    Button {
                        selectedRecord = record
                    } label: {
                        ResultRow(record: record)
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        }
    }

    private var screenshotsGrid: some View {
        let withShots = filtered.filter { $0.screenshotFilename != nil }
        return Group {
            if withShots.isEmpty {
                ContentUnavailableView(
                    "No Screenshots",
                    systemImage: "photo.on.rectangle",
                    description: Text("Screenshots are captured after every submit.")
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)], spacing: 8) {
                        ForEach(withShots) { record in
                            Button {
                                selectedRecord = record
                            } label: {
                                ScreenshotThumbnail(record: record)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 16)
                }
            }
        }
    }
}

private struct FilterChip: View {
    let label: String
    var tint: Color = .secondary
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.caption.weight(.bold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(isOn ? tint.opacity(0.25) : Color.clear)
                        .overlay(
                            Capsule().stroke(isOn ? tint : .secondary.opacity(0.3), lineWidth: 1)
                        )
                )
                .foregroundStyle(isOn ? tint : .primary)
        }
        .buttonStyle(.plain)
    }
}

private struct ResultRow: View {
    let record: AttemptRecord

    var body: some View {
        HStack(spacing: 12) {
            ScreenshotThumbnail(record: record, size: 48)
                .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 2) {
                Text(record.username)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(record.targetDomain)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text("pw \(record.passwordIndex) / \(record.passwordTotal)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Text(record.sessionTag.uppercased())
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.cyan)
                    Text(record.timestamp, format: .relative(presentation: .named))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                StatusBadge(status: record.status)
                if let verdict = record.judgeVerdict, !verdict.isEmpty {
                    JudgeBadge(verdict: verdict)
                } else if let cat = record.ocrCategory, cat != "Unknown" {
                    OcrBadge(category: cat)
                }
                if record.status == .skipped, let reason = record.judgeReason, !reason.isEmpty {
                    Text(reason)
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ScreenshotThumbnail: View {
    let record: AttemptRecord
    var size: CGFloat = 110
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.tertiarySystemFill))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .allowsHitTesting(false)
            } else {
                Image(systemName: "photo")
                    .font(.title3)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: 8))
        .overlay(alignment: .topTrailing) {
            Circle()
                .fill(record.status.color)
                .frame(width: 10, height: 10)
                .overlay(Circle().stroke(.white, lineWidth: 1.5))
                .padding(4)
        }
        // Decode off the main thread — previously every row decoded its
        // full JPEG synchronously in body, hitching grid/list scrolling.
        .task(id: record.screenshotFilename) {
            guard let filename = record.screenshotFilename else { return }
            image = await ScreenshotStorage.loadImageAsync(filename)
        }
    }
}

private struct StatusBadge: View {
    let status: AttemptRecord.Status

    var body: some View {
        Text(status.label.uppercased())
            .font(.system(size: 9, weight: .heavy))
            .kerning(0.6)
            .foregroundStyle(status.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(status.color.opacity(0.15)))
    }
}

private struct OcrBadge: View {
    let category: String

    var color: Color {
        switch category {
        case "Login Success": return .green
        case "Login Failure": return .red
        case "Captcha Triggered": return .orange
        case "Account Locked": return .purple
        default: return .secondary
        }
    }

    var icon: String {
        switch category {
        case "Login Success": return "checkmark.circle.fill"
        case "Login Failure": return "xmark.circle.fill"
        case "Captcha Triggered": return "exclamationmark.triangle.fill"
        case "Account Locked": return "lock.circle.fill"
        default: return "questionmark.circle.fill"
        }
    }

    var shortLabel: String {
        switch category {
        case "Login Success": return "SUCCESS"
        case "Login Failure": return "FAILED"
        case "Captcha Triggered": return "CAPTCHA"
        case "Account Locked": return "LOCKED"
        default: return category.uppercased()
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 8))
            Text(shortLabel)
                .font(.system(size: 8, weight: .heavy))
                .kerning(0.4)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.15)))
    }
}

/// Lists every credential currently parked in the temp-disabled cooldown
/// store, with a live countdown to when it'll be eligible for RCR again.
private struct TempDisabledList: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var credentials: [Credential]
    @State private var entries: [(credentialID: String, expiresAt: Date)] = []
    @State private var now: Date = Date()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if resolved.isEmpty {
                ContentUnavailableView(
                    "No Temp-Disabled Credentials",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Credentials marked temp-disabled by RCR appear here with a 1-hour cooldown.")
                )
            } else {
                List {
                    ForEach(resolved, id: \.credentialID) { entry in
                        HStack(spacing: 12) {
                            Image(systemName: "clock.fill")
                                .foregroundStyle(.pink)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.username)
                                    .font(.body.weight(.medium))
                                Text(entry.domain)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(remaining(until: entry.expiresAt))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.pink)
                            Button {
                                TempDisabledStore.shared.clear(credentialID: entry.credentialID)
                                refresh()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .onAppear { refresh() }
        .onReceive(timer) { _ in
            now = Date()
            // Auto-expire entries whose cooldown is up.
            let active = TempDisabledStore.shared.allActive()
            if active.count != entries.count { refresh() }
        }
    }

    private struct ResolvedEntry {
        let credentialID: String
        let username: String
        let domain: String
        let expiresAt: Date
    }

    private var resolved: [ResolvedEntry] {
        entries.map { entry in
            let cred = credentials.first { $0.id == entry.credentialID }
            return ResolvedEntry(
                credentialID: entry.credentialID,
                username: cred?.username ?? "(unknown)",
                domain: cred?.domain ?? "",
                expiresAt: entry.expiresAt
            )
        }.sorted { $0.expiresAt < $1.expiresAt }
    }

    private func refresh() {
        TempDisabledStore.shared.purgeExpired()
        entries = TempDisabledStore.shared.allActive()
    }

    private func remaining(until date: Date) -> String {
        let secs = max(0, Int(date.timeIntervalSince(now)))
        let m = secs / 60
        let s = secs % 60
        return String(format: "%02d:%02d", m, s)
    }
}

extension AttemptRecord.Status {
    var label: String {
        switch self {
        case .pending: return "Pending"
        case .success: return "Success"
        case .failed: return "Failed"
        case .disabled: return "Disabled"
        case .tempDisabled: return "Temp"
        case .skipped: return "Skipped"
        case .review: return "Review"
        }
    }

    var color: Color {
        switch self {
        case .pending: return .yellow
        case .success: return .green
        case .failed: return .red
        case .disabled: return .orange
        case .tempDisabled: return .pink
        case .skipped: return .secondary
        case .review: return .orange
        }
    }
}

struct JudgeBadge: View {
    let verdict: String

    var color: Color {
        switch verdict {
        case "confirmed": return .green
        case "review": return .orange
        case "failed", "disabled": return .secondary
        default: return .cyan
        }
    }

    var label: String {
        switch verdict {
        case "confirmed": return "CONFIRMED"
        case "review": return "REVIEW"
        case "failed": return "FAILED"
        case "disabled": return "DISABLED"
        case "local": return "LOCAL"
        default: return verdict.uppercased()
        }
    }

    var body: some View {
        Text(label)
            .font(.system(size: 8, weight: .heavy))
            .kerning(0.4)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.15)))
    }
}
