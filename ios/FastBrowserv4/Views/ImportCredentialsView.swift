import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct ImportCredentialsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var importTab: ImportTab
    @State private var selectedFormat: ImportFormat = .chromeCSV
    @State private var isShowingFilePicker: Bool = false
    @State private var importResult: String?
    @State private var isImporting: Bool = false

    // Paste / combo-list state
    @State private var pasteText: String = ""
    @State private var comboSeparator: ComboListSeparator = .auto
    @State private var comboFormat: ComboListFormat = .email

    enum ImportTab: String, CaseIterable, Identifiable {
        case file = "File"
        case paste = "Paste"
        var id: String { rawValue }
    }

    init(initialTab: ImportTab = .file) {
        _importTab = State(initialValue: initialTab)
    }

    var body: some View {
        Form {
            Section {
                Picker("", selection: $importTab) {
                    ForEach(ImportTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))

            if importTab == .file {
                fileTab
            } else {
                pasteTab
            }
        }
        .navigationTitle("Import Credentials")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }
        .fileImporter(
            isPresented: $isShowingFilePicker,
            allowedContentTypes: [UTType.commaSeparatedText, UTType.plainText],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
        }
    }

    // MARK: - File tab

    @ViewBuilder
    private var fileTab: some View {
        Section("Format") {
            Picker("Import Format", selection: $selectedFormat) {
                ForEach(ImportFormat.allCases, id: \.self) { format in
                    Text(format.rawValue).tag(format)
                }
            }
            .pickerStyle(.segmented)

            Text(selectedFormat.description)
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section {
            Button {
                isShowingFilePicker = true
            } label: {
                Label("Select File", systemImage: "doc.badge.plus")
                    .frame(maxWidth: .infinity)
                    .font(.headline)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isImporting)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }

        if let result = importResult {
            Section("Result") {
                Label(result, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }

        Section("Instructions") {
            VStack(alignment: .leading, spacing: 8) {
                instructionRow(number: "1", text: "Export passwords from your browser as CSV or a combo-list .txt")
                instructionRow(number: "2", text: "Select the matching format above")
                instructionRow(number: "3", text: "Tap \"Select File\" and choose the export")
                instructionRow(number: "4", text: "Credentials will be imported to your vault")
            }
        }
    }

    // MARK: - Paste tab

    @ViewBuilder
    private var pasteTab: some View {
        Section {
            Picker("Separator", selection: $comboSeparator) {
                ForEach(ComboListSeparator.allCases, id: \.self) { sep in
                    Text(sep.label).tag(sep)
                }
            }
            .pickerStyle(.segmented)

            Picker("Login Type", selection: $comboFormat) {
                ForEach(ComboListFormat.allCases, id: \.self) { fmt in
                    Text(fmt.rawValue).tag(fmt)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Combo List Options")
        } footer: {
            Text("Each line: login\u{2009}\u{2022}password. Extra fields become extra passwords for that login.")
                .font(.caption2)
        }

        Section("Combo List") {
            ZStack(alignment: .topLeading) {
                if pasteText.isEmpty {
                    Text("email:password\nusername:password\nlogin;pass\none,two")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .allowsHitTesting(false)
                        .padding(.top, 8)
                        .padding(.leading, 6)
                }
                TextEditor(text: $pasteText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 180)
                    .scrollContentBackground(.hidden)
            }

            Button {
                if let clipboard = UIPasteboard.general.string {
                    pasteText = clipboard
                }
            } label: {
                Label("Paste from Clipboard", systemImage: "doc.on.clipboard")
                    .frame(maxWidth: .infinity)
                    .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.bordered)
        }

        let preview = CredentialImportService.comboListPreview(
            pasteText,
            separator: comboSeparator,
            format: comboFormat
        )

        if !pasteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Section("Preview") {
                HStack(spacing: 16) {
                    statPill(
                        value: preview.credentialCount,
                        label: "credentials",
                        color: .cyan
                    )
                    statPill(
                        value: preview.passwordCount,
                        label: "passwords",
                        color: .blue
                    )
                    if preview.skippedCount > 0 {
                        statPill(
                            value: preview.skippedCount,
                            label: "skipped",
                            color: .orange
                        )
                    }
                    if preview.mergedCount > 0 {
                        statPill(
                            value: preview.mergedCount,
                            label: "merged",
                            color: .purple
                        )
                    }
                }
            }

            Section {
                Button {
                    performComboImport()
                } label: {
                    HStack {
                        if isImporting {
                            ProgressView()
                                .tint(.white)
                        }
                        Text("Import \(preview.credentialCount) Credential\(preview.credentialCount == 1 ? "" : "s")")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isImporting || preview.isEmpty)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
        }

        if let result = importResult, importTab == .paste {
            Section("Result") {
                Label(result, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }

        Section {
            VStack(alignment: .leading, spacing: 8) {
                instructionRow(number: "1", text: "Copy a combo list — one login\u{2009}:password per line")
                instructionRow(number: "2", text: "Pick the separator (or leave on Auto) and login type")
                instructionRow(number: "3", text: "Paste into the box or use \"Paste from Clipboard\"")
                instructionRow(number: "4", text: "Review the preview count and tap Import")
            }
        } header: {
            Text("Instructions")
        }
    }

    // MARK: - Helpers

    private func statPill(value: Int, label: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.system(size: 20, weight: .heavy, design: .rounded))
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func instructionRow(number: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(number)
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(.cyan, in: Circle())

            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Import actions

    private func handleFileImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        isImporting = true

        guard url.startAccessingSecurityScopedResource() else {
            importResult = "Could not access file"
            isImporting = false
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }

        do {
            let content = try String(contentsOf: url, encoding: .utf8)

            let imported: [ImportedCredential]
            if selectedFormat == .comboList {
                let sep = CredentialImportService.detectSeparator(in: content)
                imported = CredentialImportService.parseComboList(
                    content,
                    separator: sep,
                    format: comboFormat
                )
            } else {
                imported = CredentialImportService.parseCSV(content, format: selectedFormat)
            }

            let summary = persistImported(imported)
            importResult = summary
        } catch {
            importResult = "Error reading file: \(error.localizedDescription)"
        }

        isImporting = false
    }

    private func performComboImport() {
        isImporting = true
        let imported = CredentialImportService.parseComboList(
            pasteText,
            separator: comboSeparator,
            format: comboFormat
        )
        let summary = persistImported(imported)
        importResult = summary
        if !imported.isEmpty {
            pasteText = ""
        }
        isImporting = false
    }

    /// Inserts the parsed credentials into SwiftData + Keychain and returns a
    /// human-readable summary string.
    @discardableResult
    private func persistImported(_ imported: [ImportedCredential]) -> String {
        guard !imported.isEmpty else {
            return "No valid credentials found"
        }

        var credentials: [(Credential, [String])] = []
        for item in imported {
            let credential = Credential(domain: item.domain, username: item.username, notes: item.notes)
            modelContext.insert(credential)
            credentials.append((credential, item.passwords))
        }

        try? modelContext.save()

        var count = 0
        var passwordTotal = 0
        for (credential, passwords) in credentials {
            if KeychainService.shared.savePasswords(passwords, for: credential.id) {
                count += 1
                passwordTotal += passwords.count
            }
        }

        try? modelContext.save()
        return "Imported \(count) credentials (\(passwordTotal) passwords)"
    }
}
