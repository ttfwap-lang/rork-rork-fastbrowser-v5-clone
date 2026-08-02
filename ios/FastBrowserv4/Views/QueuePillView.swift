import SwiftUI

/// Translucent pill that shows the current RCR target plus the next 8
/// credentials in the queue, with a collapsible completed list underneath.
struct QueuePillView: View {
    let title: String
    let titleColor: Color
    let statusDotColor: Color
    let statusLabel: String
    let isWaitingPulse: Bool
    let total: Int
    let completedCount: Int
    let upcoming: [RCRQueueItem]   // includes current as the first item
    let completed: [RCRQueueItem]
    let pulseTrigger: Int          // anything that changes when state advances
    /// Optional "View Results" action shown when the run is finished.
    let onViewResults: (() -> Void)?

    @State private var showAll: Bool = false
    @State private var showCompleted: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            if let current = upcoming.first {
                currentRow(current)
            }

            if upcoming.count > 1 {
                Divider().opacity(0.25)
                Text("NEXT \(min(upcoming.count - 1, 8))")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(.secondary)
                    .kerning(0.6)

                VStack(spacing: 4) {
                    ForEach(Array(upcoming.dropFirst().prefix(8))) { item in
                        upcomingRow(item)
                    }
                }
            }

            if !completed.isEmpty {
                Divider().opacity(0.25)
                Button {
                    withAnimation(.snappy) { showCompleted.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: showCompleted ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                        Text("DONE \(completed.count) / \(total)")
                            .font(.system(size: 9, weight: .heavy))
                            .kerning(0.6)
                        Spacer()
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if showCompleted {
                    VStack(spacing: 4) {
                        ForEach(completed) { item in
                            completedRow(item)
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }

            if let onViewResults, total > 0 && completedCount >= total {
                Button(action: onViewResults) {
                    HStack(spacing: 6) {
                        Image(systemName: "photo.on.rectangle.angled")
                        Text("View Results")
                    }
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.cyan)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(.cyan.opacity(0.12), in: .capsule)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .padding(.horizontal, 16)
    }

    private var header: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 8, height: 8)
                Circle()
                    .stroke(statusDotColor.opacity(0.4), lineWidth: 4)
                    .frame(width: 8, height: 8)
                    .scaleEffect(isWaitingPulse ? 1.8 : 1)
                    .opacity(isWaitingPulse ? 0 : 1)
                    .animation(
                        isWaitingPulse
                            ? .easeOut(duration: 1.0).repeatForever(autoreverses: false)
                            : .default,
                        value: isWaitingPulse
                    )
            }
            Text(title)
                .font(.caption.weight(.heavy))
                .foregroundStyle(titleColor)
                .kerning(0.5)
            Text("\(min(completedCount + (upcoming.first?.isCurrent == true ? 1 : 0), total)) / \(total)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            Text(statusLabel)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
        }
    }

    private func currentRow(_ item: RCRQueueItem) -> some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(statusDotColor.opacity(0.18))
                    .frame(width: 22, height: 22)
                Image(systemName: "arrowtriangle.right.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(statusDotColor)
            }
            Text(item.username)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            passwordCountBadge(item.passwordCount)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.cyan.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(.cyan.opacity(0.35), lineWidth: 1)
                )
        )
        .shadow(color: .cyan.opacity(isWaitingPulse ? 0.45 : 0.0), radius: 6)
        .scaleEffect(isWaitingPulse ? 1.005 : 1.0)
        .animation(
            isWaitingPulse
                ? .easeInOut(duration: 1.1).repeatForever(autoreverses: true)
                : .default,
            value: pulseTrigger
        )
    }

    private func upcomingRow(_ item: RCRQueueItem) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "circle")
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
                .frame(width: 22)
            Text(item.username)
                .font(.caption2)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            passwordCountBadge(item.passwordCount)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private func completedRow(_ item: RCRQueueItem) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.green)
                .frame(width: 22)
            Text(item.username)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            passwordCountBadge(item.passwordCount, dim: true)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .opacity(0.55)
    }

    private func passwordCountBadge(_ count: Int, dim: Bool = false) -> some View {
        Text("\(count) pw")
            .font(.system(size: 9, weight: .heavy, design: .rounded))
            .foregroundStyle(dim ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.cyan))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(dim ? Color.secondary.opacity(0.12) : Color.cyan.opacity(0.18))
            )
    }
}
