import SwiftUI

struct TabManagerView: View {
    let viewModel: BrowserViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(Array(viewModel.tabs.enumerated()), id: \.element.id) { index, tab in
                        tabCard(tab: tab, index: index)
                    }
                }
                .padding()
            }
            .navigationTitle("Tabs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New Tab", systemImage: "plus") {
                        viewModel.addNewTab()
                        dismiss()
                    }
                }
            }
        }
    }

    private func tabCard(tab: BrowserTab, index: Int) -> some View {
        Button {
            viewModel.switchToTab(at: index)
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(tab.title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .foregroundStyle(.primary)

                    Spacer()

                    if viewModel.tabs.count > 1 {
                        Button {
                            viewModel.closeTab(at: index)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption2.bold())
                                .foregroundStyle(.secondary)
                                .padding(4)
                                .background(.quaternary, in: Circle())
                        }
                    }
                }

                Text(tab.domain.isEmpty ? "New Tab" : tab.domain)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(.tertiarySystemBackground))
                    .frame(height: 80)
                    .overlay {
                        if let snapshot = tab.snapshot {
                            Image(uiImage: snapshot)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .allowsHitTesting(false)
                        } else if tab.url != nil {
                            Image(systemName: "globe")
                                .font(.title3)
                                .foregroundStyle(.quaternary)
                        } else {
                            Image(systemName: "bolt.shield.fill")
                                .font(.title3)
                                .foregroundStyle(.cyan.opacity(0.3))
                        }
                    }
                    .clipShape(.rect(cornerRadius: 6))
            }
            .padding(10)
            .background(
                index == viewModel.activeTabIndex
                    ? Color.accentColor.opacity(0.1)
                    : Color(.secondarySystemBackground)
            )
            .clipShape(.rect(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        index == viewModel.activeTabIndex ? Color.accentColor : .clear,
                        lineWidth: 2
                    )
            )
        }
        .buttonStyle(.plain)
    }
}
