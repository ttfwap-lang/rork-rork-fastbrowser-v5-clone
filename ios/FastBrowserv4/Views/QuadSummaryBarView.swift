import SwiftUI

/// Compact progress summary shown for the 6-, 8-, 9-, 12-, and 16-window grids instead of
/// a full stack of per-window cards. Tapping it expands into the detailed
/// per-window view (see `BrowserView.quadSummarySection`).
struct QuadSummaryBarView: View {
    struct LaneSummary: Identifiable {
        let id: Int
        let label: String
        let doneCount: Int
        let currentUsername: String
        let statusColorA: Color
        let statusColorB: Color
    }

    let isDual: Bool
    let overallCompleted: Int
    let overallTotal: Int
    let overallSuccess: Int
    let anyRunning: Bool
    let lanes: [LaneSummary]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(anyRunning ? Color.yellow : Color.secondary)
                    .frame(width: 8, height: 8)
                Text(isDual ? "Dual RCR" : "RCR")
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(.cyan)
                    .kerning(0.5)
                Text("\(min(overallCompleted, overallTotal)) / \(overallTotal) · \(overallSuccess) hits")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Expand")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(.cyan)
                Image(systemName: "chevron.up")
                    .font(.caption2.bold())
                    .foregroundStyle(.cyan)
            }

            if isDual && !lanes.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(lanes) { lane in
                            laneChip(lane)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18))
        .padding(.horizontal, 16)
        .contentShape(Rectangle())
    }

    private func laneChip(_ lane: LaneSummary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Circle().fill(lane.statusColorA).frame(width: 6, height: 6)
                Circle().fill(lane.statusColorB).frame(width: 6, height: 6)
                Text(lane.label)
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(.secondary)
            }
            Text(lane.currentUsername.isEmpty ? "—" : lane.currentUsername)
                .font(.system(size: 10))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 84, alignment: .leading)
            Text("\(lane.doneCount) done")
                .font(.system(size: 9, weight: .heavy, design: .rounded))
                .foregroundStyle(.cyan)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.cyan.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(.cyan.opacity(0.25), lineWidth: 0.5)
                )
        )
    }
}
