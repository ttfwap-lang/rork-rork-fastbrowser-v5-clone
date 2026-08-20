import SwiftUI
import UIKit

/// Frosted edge handle + slide-out parked-session rail. The handle stays
/// quiet during a run; tapping it (or finishing a batch) opens a glass
/// tray of still-signed-in sessions.
struct ParkedSessionRailOverlay: View {
    let viewModel: BrowserViewModel
    @Bindable private var store = ParkedSessionStore.shared
    @State private var sendTarget: ParkedSession?

    var body: some View {
        ZStack(alignment: .trailing) {
            if store.isRailOpen {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
                            store.isRailOpen = false
                        }
                    }
            }

            if store.runActive || !store.sessions.isEmpty {
                edgeHandle
                    .padding(.trailing, store.isRailOpen ? railWidth : 0)
                    .animation(.spring(response: 0.38, dampingFraction: 0.86), value: store.isRailOpen)
            }

            if store.isRailOpen {
                rail
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: store.isRailOpen)
        .confirmationDialog(
            "Send to which window?",
            isPresented: Binding(
                get: { sendTarget != nil },
                set: { if !$0 { sendTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            let count = viewModel.isQuadMode ? viewModel.quadController.activeCount : 4
            ForEach(0..<count, id: \.self) { index in
                Button("Window S\(index + 1)") {
                    if let parked = sendTarget {
                        viewModel.sendParkedSession(parked, toWindow: index)
                    }
                    sendTarget = nil
                }
            }
            Button("Cancel", role: .cancel) { sendTarget = nil }
        }
    }

    private var railWidth: CGFloat { 300 }

    private var edgeHandle: some View {
        Button {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
                store.isRailOpen.toggle()
            }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: "rectangle.stack.fill")
                    .font(.caption.weight(.bold))
                Text("\(store.sessions.count)")
                    .font(.system(.caption, design: .rounded, weight: .black))
                    .monospacedDigit()
            }
            .foregroundStyle(.white)
            .frame(width: 36, height: 72)
            .background {
                if #available(iOS 26.0, *) {
                    Capsule().fill(.clear).glassEffect()
                } else {
                    Capsule().fill(.ultraThinMaterial)
                }
            }
            .overlay(
                Capsule()
                    .stroke(Color.cyan.opacity(store.justParkedID == nil ? 0.35 : 0.95), lineWidth: 1.4)
            )
            .shadow(color: .cyan.opacity(store.justParkedID == nil ? 0.15 : 0.7), radius: store.justParkedID == nil ? 4 : 14)
            .scaleEffect(store.justParkedID == nil ? 1 : 1.08)
            .animation(.spring(response: 0.32, dampingFraction: 0.7), value: store.justParkedID)
            .accessibilityLabel("Parked sessions, \(store.sessions.count)")
        }
        .buttonStyle(.plain)
        .padding(.trailing, 4)
    }

    private var rail: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.12))
            if store.sessions.isEmpty {
                ContentUnavailableView(
                    "No parked sessions",
                    systemImage: "rectangle.stack",
                    description: Text("AI-confirmed logins land here, still signed in.")
                )
                .foregroundStyle(.white)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(store.sessions, id: \.id) { session in
                            ParkedSessionCard(
                                session: session,
                                flourish: store.justParkedID == session.id,
                                onRestore: { viewModel.restoreParkedSession(session) },
                                onSend: { sendTarget = session },
                                onForget: { viewModel.forgetParkedSession(session) }
                            )
                        }
                    }
                    .padding(14)
                }
            }
        }
        .frame(width: railWidth)
        .frame(maxHeight: .infinity)
        .background {
            if #available(iOS 26.0, *) {
                Rectangle().fill(.clear).glassEffect()
            } else {
                Rectangle().fill(.ultraThinMaterial)
            }
        }
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.cyan.opacity(0.35))
                .frame(width: 1)
        }
        .ignoresSafeArea(edges: .vertical)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Parked")
                    .font(.system(.title3, design: .rounded, weight: .bold))
                    .foregroundStyle(.white)
                Text("\(store.sessions.count) parked · \(store.failedThisRun) failed")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
            }
            Spacer()
            Button {
                withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
                    store.isRailOpen = false
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color.white.opacity(0.12)))
            }
            .buttonStyle(.plain)
        }
        .padding(16)
    }
}

private struct ParkedSessionCard: View {
    let session: ParkedSession
    let flourish: Bool
    let onRestore: () -> Void
    let onSend: () -> Void
    let onForget: () -> Void
    @State private var thumb: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(0.08))
                    if let thumb {
                        Image(uiImage: thumb)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .allowsHitTesting(false)
                    } else {
                        Image(systemName: "globe")
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }
                .frame(width: 64, height: 64)
                .clipShape(.rect(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 3) {
                    Text(session.username)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(session.domain)
                        .font(.caption)
                        .foregroundStyle(.cyan)
                        .lineLimit(1)
                    Text(session.parkedAt, format: .relative(presentation: .named))
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.55))
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 6) {
                cardButton("Bring back", systemImage: "arrow.uturn.backward", tint: .cyan, action: onRestore)
                cardButton("Send", systemImage: "square.grid.2x2", tint: .white, action: onSend)
                cardButton("Forget", systemImage: "trash", tint: .red, action: onForget)
            }
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.white.opacity(0.07))
        }
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.cyan.opacity(flourish ? 0.9 : 0.2), lineWidth: flourish ? 1.6 : 1)
        )
        .shadow(color: .cyan.opacity(flourish ? 0.45 : 0), radius: flourish ? 12 : 0)
        .scaleEffect(flourish ? 1.02 : 1)
        .animation(.spring(response: 0.4, dampingFraction: 0.72), value: flourish)
        .task(id: session.thumbnailFilename) {
            guard let name = session.thumbnailFilename else { return }
            thumb = await ScreenshotStorage.loadImageAsync(name)
        }
    }

    private func cardButton(_ title: String, systemImage: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Capsule().fill(tint.opacity(0.16)))
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44)
    }
}
