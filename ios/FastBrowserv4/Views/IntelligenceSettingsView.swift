import SwiftUI
import SwiftData

/// Settings → Intelligence: brain status, per-job routing, provider list
/// with reorder/delete, the AI activity log, and the privacy contract.
struct IntelligenceSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\AIProviderConfig.sortOrder)]) private var providers: [AIProviderConfig]
    @Query(sort: [SortDescriptor(\AIRepairEvent.timestamp, order: .reverse)]) private var events: [AIRepairEvent]

    @State private var center = IntelligenceCenter.shared
    @State private var isAddingProvider: Bool = false
    @State private var routeTick: Int = 0

    var body: some View {
        Form {
            Section {
                brainRow(
                    icon: "iphone",
                    tint: .cyan,
                    title: "Apple on-device",
                    note: center.onDeviceNote,
                    isReady: center.onDeviceAvailable
                )
                brainRow(
                    icon: "icloud",
                    tint: .indigo,
                    title: "Apple Private Cloud",
                    note: center.appleCloudNote,
                    isReady: center.appleCloudAvailable
                )
                brainRow(
                    icon: "key.fill",
                    tint: .orange,
                    title: "Your API keys",
                    note: center.hasUsableKeys
                        ? "\(center.providers.filter { $0.keyCount > 0 }.count) provider(s) configured"
                        : "No keys yet — add a provider below",
                    isReady: center.hasUsableKeys
                )
            } header: {
                Text("Brains")
            } footer: {
                Text("Jobs try your chosen brain first and fall over automatically if it's unavailable. Passwords and field contents are never sent to any AI — only page structure and visible text.")
            }

            Section {
                ForEach(IntelligenceCenter.AIJob.allCases) { job in
                    Picker(job.label, selection: routeBinding(for: job)) {
                        ForEach(IntelligenceCenter.AIBrain.allCases) { brain in
                            Text(brain.label).tag(brain)
                        }
                    }
                }
                .id(routeTick)
            } header: {
                Text("Routing")
            } footer: {
                Text("Quick checks stay on-device by default; fill repair uses the strongest brain you allow. Choose \"On-device\" everywhere for fully local-only AI.")
            }

            Section {
                if providers.isEmpty {
                    Text("No providers yet")
                        .foregroundStyle(.secondary)
                }
                ForEach(providers) { provider in
                    NavigationLink {
                        EditAIProviderView(config: provider)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(provider.displayName)
                                    .font(.body.weight(.semibold))
                                if !provider.isEnabled {
                                    Text("OFF")
                                        .font(.caption2.weight(.heavy))
                                        .foregroundStyle(.orange)
                                }
                                if provider.lastTestOK {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                        .font(.caption)
                                }
                            }
                            Text("\(provider.modelName) · \(provider.keyCount) key\(provider.keyCount == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete(perform: deleteProviders)
                .onMove(perform: moveProviders)

                Button {
                    isAddingProvider = true
                } label: {
                    Label("Add Provider…", systemImage: "plus.circle.fill")
                        .foregroundStyle(.cyan)
                }
            } header: {
                Text("API Providers")
            } footer: {
                Text("OpenAI-compatible endpoints. Providers are tried in the order shown; keys inside a provider rotate automatically when one is rate-limited.")
            }

            Section {
                if events.isEmpty {
                    Text("No AI activity yet")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(events.prefix(20)) { event in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: icon(for: event.kind))
                                .foregroundStyle(color(for: event.kind))
                                .font(.callout)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(event.summary)
                                    .font(.caption)
                                Text("\(event.brain) · \(event.timestamp.formatted(.relative(presentation: .named)))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Button("Clear Log", role: .destructive) {
                        for event in events { modelContext.delete(event) }
                        try? modelContext.save()
                    }
                }
            } header: {
                Text("AI Activity")
            } footer: {
                Text("Every repair and verdict the AI makes, in plain English.")
            }
        }
        .navigationTitle("Intelligence")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !providers.isEmpty {
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
            }
        }
        .onAppear {
            center.attach(context: modelContext)
            center.refreshProviders()
            center.refreshAvailability()
        }
        .sheet(isPresented: $isAddingProvider) {
            NavigationStack { AddAIProviderView() }
        }
    }

    private func brainRow(icon: String, tint: Color, title: String, note: String, isReady: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.semibold))
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Circle()
                .fill(isReady ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
        }
    }

    private func routeBinding(for job: IntelligenceCenter.AIJob) -> Binding<IntelligenceCenter.AIBrain> {
        Binding(
            get: { center.preferredBrain(for: job) },
            set: { newValue in
                UserDefaults.standard.set(newValue.rawValue, forKey: job.settingsKey)
                routeTick &+= 1
            }
        )
    }

    private func deleteProviders(at offsets: IndexSet) {
        for index in offsets {
            let provider = providers[index]
            LLMKeyVault.shared.deleteAllKeys(providerID: provider.id)
            modelContext.delete(provider)
        }
        try? modelContext.save()
        center.refreshProviders()
    }

    private func moveProviders(from source: IndexSet, to destination: Int) {
        var reordered = providers
        reordered.move(fromOffsets: source, toOffset: destination)
        for (index, provider) in reordered.enumerated() {
            provider.sortOrder = index
        }
        try? modelContext.save()
        center.refreshProviders()
    }

    private func icon(for kind: String) -> String {
        switch kind {
        case "heal": return "wrench.and.screwdriver"
        case "judge": return "checkmark.shield"
        default: return "info.circle"
        }
    }

    private func color(for kind: String) -> Color {
        switch kind {
        case "heal": return .cyan
        case "judge": return .green
        default: return .secondary
        }
    }
}
