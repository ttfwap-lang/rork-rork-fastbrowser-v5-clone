import SwiftUI
import SwiftData

struct BrowserView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel = BrowserViewModel()
    @FocusState private var isURLBarFocused: Bool
    @FocusState private var isURLBarBFocused: Bool

    // Swipe-to-hide state for the live RCR queue pill(s).
    @State private var singlePillHidden: Bool = false
    @State private var singlePillDrag: CGFloat = 0
    @State private var quadPillsHidden: [Bool] = Array(repeating: false, count: 12)
    @State private var quadPillsDrag: [CGFloat] = Array(repeating: 0, count: 12)
    // Larger grids show a compact summary bar instead of a wall of per-window
    // cards; tapping it expands to the same detailed view.
    @State private var isQuadDetailExpanded: Bool = false

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                urlBar
                if viewModel.isDualQuadMode {
                    urlBarB
                }
                progressBar
                webContent
                bottomToolbar
            }

            if viewModel.toastVisible, let message = viewModel.toastMessage {
                ToastView(message: message)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, 70)
                    .zIndex(100)
            }

            if viewModel.isRCRRunning || (viewModel.rcrTotal > 0 && !viewModel.isQuadMode) {
                hideablePill(
                    hidden: $singlePillHidden,
                    drag: $singlePillDrag,
                    label: "Show RCR queue"
                ) {
                    singleQueuePill
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .padding(.bottom, 70)
                .zIndex(99)
            } else if viewModel.isQuadMode && (viewModel.quadController.anyRCRRunning || viewModel.quadController.activeSessions.contains(where: { $0.rcrTotal > 0 })) {
                quadSummarySection
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, 70)
                    .zIndex(99)
            }
        }
        .onChange(of: viewModel.quadMode) { _, _ in
            isQuadDetailExpanded = false
            quadPillsHidden = Array(repeating: false, count: 12)
            quadPillsDrag = Array(repeating: 0, count: 12)
        }
        .onChange(of: viewModel.quadController.focusedIndex) { _, _ in
            if viewModel.isQuadMode, !viewModel.isURLBarEditing {
                viewModel.updateURLBar()
            }
        }
        .onChange(of: viewModel.isRCRRunning) { _, running in
            if running { isURLBarFocused = false; isURLBarBFocused = false; dismissKeyboard() }
        }
        .onChange(of: viewModel.quadController.anyRCRRunning) { _, running in
            if running { isURLBarFocused = false; isURLBarBFocused = false; dismissKeyboard() }
        }
        .task {
            viewModel.setup(modelContext: modelContext)
            await WebViewConfigurationFactory.shared.prepare()
            DNSPrewarmService.shared.prewarmTopDomains(modelContext: modelContext)
        }
        .sheet(item: $viewModel.presentedSheet, onDismiss: {
            viewModel.reloadExcludedDomains()
            viewModel.invalidateCredentialCache()
        }) { sheet in
            sheetContent(for: sheet)
        }
        .alert("Save Login?", isPresented: $viewModel.isShowingSaveCredentialAlert) {
            Button("Save") { viewModel.saveDetectedCredential() }
            Button("Not Now", role: .cancel) {}
        } message: {
            Text("Save credentials for \(viewModel.activeTab?.domain ?? "this site")?\nUsername: \(viewModel.detectedUsername)")
        }
    }

    /// Carries the current URL into quad mode without toggling (used when
    /// onChange fires from external sources).
    @ViewBuilder
    private func sheetContent(for sheet: PresentedSheet) -> some View {
        switch sheet {
        case .tabs:
            TabManagerView(viewModel: viewModel)
        case .vault:
            NavigationStack { VaultView() }
        case .siteSettings(let domain):
            NavigationStack { SiteSettingsView(domain: domain) }
        case .settings:
            NavigationStack { AppSettingsView() }
        case .bookmarks:
            NavigationStack { BookmarksView(viewModel: viewModel) }
        case .history:
            NavigationStack { HistoryView(viewModel: viewModel) }
        case .results:
            NavigationStack { ResultsView() }
        }
    }

    // MARK: - URL bars

    /// Pull-tab shown at the top edge when the main URL bar is hidden.
    private var urlBarPullTab: some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                viewModel.isURLBarVisible = true
                viewModel.resetURLBarTimer()
            }
        } label: {
            Capsule()
                .fill(Color(.secondarySystemBackground))
                .frame(width: 36, height: 5)
                .padding(.top, 8)
                .padding(.bottom, 2)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    /// Main URL bar with auto-hide, swipe gesture, and dual-quad label.
    private var urlBar: some View {
        Group {
            if viewModel.isURLBarVisible {
                urlBarView(label: viewModel.isDualQuadMode ? "Site A" : nil, barID: "main")
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else {
                urlBarPullTab
            }
        }
    }

    /// Secondary URL bar for dual-quad mode Site B.
    private var urlBarB: some View {
        Group {
            if viewModel.isURLBarBVisible {
                urlBarView(label: "Site B", barID: "b")
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    @ViewBuilder
    private func urlBarView(label: String?, barID: String) -> some View {
        let isBarB = barID == "b"
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if let label {
                    Text(label)
                        .font(.system(.caption, design: .rounded, weight: .heavy))
                        .foregroundStyle(.cyan)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.cyan.opacity(0.15)))
                }

                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(viewModel.activeTab?.url?.scheme == "https" ? .green : .secondary)

                TextField("Search or enter URL", text: isBarB ? $viewModel.urlBarTextB : $viewModel.urlBarText)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .submitLabel(.go)
                    .focused(isBarB ? $isURLBarBFocused : $isURLBarFocused)
                    .disabled(isAnyRCRRunning)
                    .onSubmit {
                        if isBarB {
                            viewModel.navigateToB(viewModel.urlBarTextB)
                            isURLBarBFocused = false
                        } else {
                            viewModel.navigateTo(viewModel.urlBarText)
                            isURLBarFocused = false
                        }
                    }
                    .onTapGesture {
                        if isBarB { viewModel.resetURLBarBTimer() }
                        else { viewModel.resetURLBarTimer() }
                    }
                    .onChange(of: isBarB ? isURLBarBFocused : isURLBarFocused) { _, focused in
                        viewModel.isURLBarEditing = focused
                        if focused {
                            // Cancels any pending hide countdown and pins
                            // the bar open — no new countdown starts while
                            // editing is true.
                            if isBarB { viewModel.resetURLBarBTimer() }
                            else { viewModel.resetURLBarTimer() }
                            DispatchQueue.main.async {
                                UIApplication.shared.sendAction(
                                    #selector(UIResponder.selectAll(_:)),
                                    to: nil, from: nil, for: nil
                                )
                            }
                        } else {
                            viewModel.updateURLBar()
                            // Editing ended — now it is safe to start the
                            // auto-hide countdown.
                            if isBarB { viewModel.resetURLBarBTimer() }
                            else { viewModel.resetURLBarTimer() }
                        }
                    }

                if (isBarB ? isURLBarBFocused : isURLBarFocused) && !(isBarB ? viewModel.urlBarTextB : viewModel.urlBarText).isEmpty {
                    Button {
                        if isBarB {
                            viewModel.urlBarTextB = ""
                        } else {
                            viewModel.urlBarText = ""
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                } else if isCurrentPageLoading {
                    ProgressView()
                        .scaleEffect(0.7)
                }

                Menu {
                    Button("Site Settings", systemImage: "gearshape") {
                        if let domain = viewModel.activeTab?.domain, !domain.isEmpty {
                            viewModel.presentedSheet = .siteSettings(domain)
                        }
                    }
                    Button("Add Bookmark", systemImage: "bookmark") {
                        viewModel.addBookmark()
                    }
                    Button("Share", systemImage: "square.and.arrow.up") {}
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.body)
                        .foregroundStyle(.primary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(.secondarySystemBackground))
            .clipShape(.rect(cornerRadius: 12))
            .padding(.horizontal, 12)
            .padding(.bottom, 2)
        }
        .gesture(
            DragGesture(minimumDistance: 10)
                .onChanged { value in
                    // Block swipe-to-hide while the user is typing so an
                    // accidental upward drag can't dismiss the field.
                    guard !viewModel.isURLBarEditing else { return }
                    if value.translation.height < -20 {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            if barID == "b" {
                                viewModel.isURLBarBVisible = false
                            } else {
                                viewModel.isURLBarVisible = false
                            }
                        }
                    }
                }
        )
        .padding(.top, 4)
    }

    private var progressBar: some View {
        let isLoading = viewModel.isQuadMode
            ? viewModel.quadController.focusedSession.isLoading
            : viewModel.activeTab?.isLoading == true
        let progress = viewModel.isQuadMode
            ? viewModel.quadController.focusedSession.estimatedProgress
            : (viewModel.activeTab?.estimatedProgress ?? 0)
        return GeometryReader { geo in
            if isLoading {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: geo.size.width * progress, height: 2)
                    .animation(.linear, value: progress)
            }
        }
        .frame(height: 2)
    }

    private var webContent: some View {
        ZStack {
            if viewModel.isQuadMode {
                QuadBrowserView(controller: viewModel.quadController)
            } else if let tab = viewModel.activeTab, tab.url != nil {
                WebViewWrapper(tab: tab, viewModel: viewModel)
                    .id(tab.id)
            } else {
                speedDialHome
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var speedDialHome: some View {
        SpeedDialHomeView { entry in
            viewModel.openSpeedDial(entry)
        }
    }

    // MARK: - Bottom toolbar

    private var bottomToolbar: some View {
        HStack(spacing: 0) {
            toolbarButton(icon: "chevron.left", disabled: !canGoBack) {
                viewModel.goBack()
            }

            toolbarButton(icon: "chevron.right", disabled: !canGoForward) {
                viewModel.goForward()
            }

            rcrButton

            toolbarButton(icon: "flame.fill", tint: .red) {
                viewModel.burnCurrentTab()
            }

            quadModeToggle

            moreMenu
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var rcrButton: some View {
        Button {
            viewModel.toggleRCR()
        } label: {
            ZStack {
                Circle()
                    .fill(.linearGradient(
                        colors: [.cyan, .blue],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .frame(width: 44, height: 44)
                    .shadow(color: .cyan.opacity(viewModel.isRCRRunning ? 0.55 : 0), radius: 10)
                    .scaleEffect(viewModel.isRCRRunning ? 1.05 : 1)
                    .animation(
                        viewModel.isRCRRunning
                            ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                            : .default,
                        value: viewModel.isRCRRunning
                    )

                if viewModel.isRCRRunning {
                    Circle()
                        .trim(from: 0, to: rcrProgressFraction)
                        .stroke(
                            Color.white.opacity(0.95),
                            style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                        .frame(width: 40, height: 40)
                        .animation(.easeInOut(duration: 0.25), value: viewModel.rcrIndex)

                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.white)
                        .frame(width: 10, height: 10)
                } else {
                    Text("RCR")
                        .font(.system(.caption2, design: .rounded, weight: .black))
                        .foregroundStyle(.white)
                        .kerning(0.5)
                }
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: viewModel.rcrIndex)
        .sensoryFeedback(.success, trigger: viewModel.rcrStatus == .success)
        .sensoryFeedback(.impact(weight: .heavy), trigger: viewModel.rcrBurnFlash)
        .frame(maxWidth: .infinity)
    }

    private var rcrProgressFraction: CGFloat {
        guard viewModel.rcrTotal > 0 else { return 0 }
        return CGFloat(min(viewModel.rcrIndex, viewModel.rcrTotal)) / CGFloat(viewModel.rcrTotal)
    }

    private var quadModeToggle: some View {
        Menu {
            modeMenuItem(title: "Single Window", isSelected: viewModel.quadMode == .single) {
                viewModel.setQuadMode(.single)
            }
            ForEach(WindowGridSize.allCases) { size in
                Section("\(size.rawValue) Windows (\(size.label))") {
                    modeMenuItem(
                        title: "Single Site",
                        isSelected: viewModel.quadMode == .grid(size, dual: false)
                    ) {
                        viewModel.setQuadMode(.grid(size, dual: false))
                    }

                    if size.supportsDualSite {
                        Menu("Dual Site") {
                            ForEach(DualSiteSplitPattern.allCases) { pattern in
                                modeMenuItem(
                                    title: pattern.label,
                                    isSelected: viewModel.quadMode == .grid(size, dual: true)
                                        && viewModel.dualSiteSplitPattern == pattern
                                ) {
                                    viewModel.setDualSiteSplitPattern(pattern)
                                    viewModel.setQuadMode(.grid(size, dual: true))
                                }
                            }
                        }
                        if size == .nine {
                            Text("Center window unused")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } label: {
            quadModeIcon
        }
        .simultaneousGesture(TapGesture().onEnded {
            isURLBarFocused = false
            dismissKeyboard()
        })
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func modeMenuItem(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if isSelected {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    private var quadModeIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .stroke(quadModeStrokeColor, lineWidth: 1.5)
                .frame(width: 28, height: 28)

            switch viewModel.quadMode {
            case .single:
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(.cyan)
                    .frame(width: 14, height: 14)
            case .grid(let size, let dual):
                VStack(spacing: 1.5) {
                    ForEach(0..<size.rows, id: \.self) { row in
                        HStack(spacing: 1.5) {
                            ForEach(0..<size.columns, id: \.self) { column in
                                let index = row * size.columns + column
                                let targetSite = viewModel.dualSiteSplitPattern.targetSiteIndex(
                                    for: index,
                                    in: size
                                )
                                if dual && targetSite == -1 {
                                    RoundedRectangle(cornerRadius: 1)
                                        .fill(Color.secondary.opacity(0.3))
                                } else {
                                    RoundedRectangle(cornerRadius: 1)
                                        .fill(dual ? (targetSite == 0 ? Color.purple : Color.orange) : Color.cyan)
                                }
                            }
                        }
                    }
                }
                .frame(width: 18, height: 18)
            }
        }
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
    }

    private var quadModeStrokeColor: Color {
        switch viewModel.quadMode {
        case .single: return .secondary.opacity(0.5)
        case .grid(_, let dual): return dual ? .purple : .cyan
        }
    }

    // MARK: - Single queue pill

    private var singleQueuePill: some View {
        QueuePillView(
            title: "RCR",
            titleColor: .cyan,
            statusDotColor: statusColor(viewModel.rcrStatus),
            statusLabel: statusLabel(viewModel.rcrStatus),
            isWaitingPulse: viewModel.rcrStatus == .waiting || viewModel.rcrStatus == .filling,
            total: viewModel.rcrTotal,
            completedCount: viewModel.rcrCompletedIDs.count,
            upcoming: viewModel.queueSnapshot(upcomingLimit: 8),
            completed: viewModel.completedSnapshot(),
            pulseTrigger: viewModel.rcrIndex,
            onViewResults: {
                viewModel.presentedSheet = .results
            }
        )
    }

    // MARK: - Quad pills

    /// Progress data behind the compact summary bar used by larger grids.
    private var quadOverallStats: (completed: Int, total: Int, success: Int) {
        let active = viewModel.quadController.activeSessions
        let success = active.reduce(0) { $0 + $1.rcrSuccessCount }
        if viewModel.isDualQuadMode {
            // Dual-site sessions all share the same queue snapshot, so any
            // one session's completed/total reflects the whole run.
            let first = active.first
            return (first?.rcrCompletedIDs.count ?? 0, first?.rcrTotal ?? 0, success)
        }
        return (
            active.reduce(0) { $0 + $1.rcrCompletedIDs.count },
            active.reduce(0) { $0 + $1.rcrTotal },
            success
        )
    }

    private var quadLaneSummaries: [QuadSummaryBarView.LaneSummary] {
        guard viewModel.isDualQuadMode else { return [] }
        let controller = viewModel.quadController
        let laneCount = controller.laneCount > 0 ? controller.laneCount : controller.enabledSessions.count / 2
        return (0..<laneCount).map { lane in
            let (sessionA, sessionB) = controller.lanePair(lane)
            let done = controller.laneCompletedCounts.indices.contains(lane) ? controller.laneCompletedCounts[lane] : 0
            return QuadSummaryBarView.LaneSummary(
                id: lane,
                label: "Pair \(lane + 1)",
                doneCount: done,
                currentUsername: sessionA.rcrCurrentUsername,
                statusColorA: quadStatusColor(sessionA.rcrStatus),
                statusColorB: quadStatusColor(sessionB.rcrStatus)
            )
        }
    }

    /// The 4-window grid always shows the full per-window pill stack. Larger
    /// grids show a compact summary bar that expands into the same detailed
    /// stack on tap.
    @ViewBuilder
    private var quadSummarySection: some View {
        if viewModel.quadController.gridSize == .four {
            quadQueuePills
        } else if isQuadDetailExpanded {
            VStack(spacing: 6) {
                collapseSummaryButton
                ScrollView {
                    quadQueuePills
                }
                .frame(maxHeight: 340)
            }
        } else {
            QuadSummaryBarView(
                isDual: viewModel.isDualQuadMode,
                overallCompleted: quadOverallStats.completed,
                overallTotal: quadOverallStats.total,
                overallSuccess: quadOverallStats.success,
                anyRunning: viewModel.quadController.anyRCRRunning,
                lanes: quadLaneSummaries
            )
            .onTapGesture {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    isQuadDetailExpanded = true
                }
            }
        }
    }

    private var collapseSummaryButton: some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                isQuadDetailExpanded = false
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.down")
                    .font(.caption2.bold())
                Text("Collapse")
                    .font(.caption2.weight(.bold))
            }
            .foregroundStyle(.cyan)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: .capsule)
            .overlay(
                Capsule().strokeBorder(.cyan.opacity(0.35), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.horizontal, 16)
    }

    private var quadQueuePills: some View {
        VStack(spacing: 4) {
            ForEach(Array(viewModel.quadController.activeSessions.enumerated()), id: \.element.id) { idx, session in
                hideablePill(
                    hidden: Binding(
                        get: { quadPillsHidden.indices.contains(idx) ? quadPillsHidden[idx] : false },
                        set: { newValue in
                            if quadPillsHidden.indices.contains(idx) { quadPillsHidden[idx] = newValue }
                        }
                    ),
                    drag: Binding(
                        get: { quadPillsDrag.indices.contains(idx) ? quadPillsDrag[idx] : 0 },
                        set: { newValue in
                            if quadPillsDrag.indices.contains(idx) { quadPillsDrag[idx] = newValue }
                        }
                    ),
                    label: "Show \(session.id)"
                ) {
                    QueuePillView(
                        title: viewModel.isDualQuadMode ? "\(session.id) · \(session.targetSiteIndex == 0 ? "A" : "B")" : session.id,
                        titleColor: .cyan,
                        statusDotColor: quadStatusColor(session.rcrStatus),
                        statusLabel: quadStatusLabel(session.rcrStatus),
                        isWaitingPulse: session.rcrStatus == .waiting || session.rcrStatus == .filling,
                        total: session.rcrTotal,
                        completedCount: session.rcrCompletedIDs.count,
                        upcoming: viewModel.quadController.queueSnapshot(for: session, upcomingLimit: 4),
                        completed: viewModel.quadController.completedSnapshot(for: session),
                        pulseTrigger: session.rcrIndex,
                        onViewResults: {
                            viewModel.presentedSheet = .results
                        }
                    )
                }
            }
        }
    }

    /// Wraps a pill so it can be swiped down to hide. When hidden, shows a
    /// tappable chevron tab to bring it back.
    @ViewBuilder
    private func hideablePill<Content: View>(
        hidden: Binding<Bool>,
        drag: Binding<CGFloat>,
        label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if hidden.wrappedValue {
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    hidden.wrappedValue = false
                    drag.wrappedValue = 0
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.up")
                        .font(.caption2.bold())
                    Text(label)
                        .font(.caption2.weight(.bold))
                }
                .foregroundStyle(.cyan)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.ultraThinMaterial, in: .capsule)
                .overlay(
                    Capsule().strokeBorder(.cyan.opacity(0.35), lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        } else {
            content()
                .offset(y: drag.wrappedValue)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            drag.wrappedValue = max(0, value.translation.height)
                        }
                        .onEnded { value in
                            if value.translation.height > 60 {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                    hidden.wrappedValue = true
                                    drag.wrappedValue = 0
                                }
                            } else {
                                withAnimation(.spring) { drag.wrappedValue = 0 }
                            }
                        }
                )
        }
    }

    // MARK: - Status helpers

    private func statusColor(_ s: BrowserViewModel.RCRStatus) -> Color {
        switch s {
        case .idle: return .secondary
        case .navigating: return .blue
        case .filling: return .cyan
        case .submitting: return .indigo
        case .waiting: return .yellow
        case .burning: return .orange
        case .success: return .green
        }
    }

    private func statusLabel(_ s: BrowserViewModel.RCRStatus) -> String {
        switch s {
        case .idle: return "idle"
        case .navigating: return "loading"
        case .filling: return "filling"
        case .submitting: return "submitting"
        case .waiting: return "watching"
        case .burning: return "burning"
        case .success: return "success"
        }
    }

    private func quadStatusColor(_ s: QuadSession.Status) -> Color {
        switch s {
        case .idle: return .secondary
        case .navigating: return .blue
        case .filling: return .cyan
        case .submitting: return .indigo
        case .waiting: return .yellow
        case .burning: return .orange
        case .success: return .green
        case .finished: return .mint
        case .pairWait: return .teal
        }
    }

    private func quadStatusLabel(_ s: QuadSession.Status) -> String {
        switch s {
        case .idle: return "idle"
        case .navigating: return "loading"
        case .filling: return "filling"
        case .submitting: return "submitting"
        case .waiting: return "watching"
        case .burning: return "burning"
        case .success: return "success"
        case .finished: return "done"
        case .pairWait: return "linked"
        }
    }

    // MARK: - More menu

    private var moreMenu: some View {
        Menu {
            Button("Vault", systemImage: "lock.shield") {
                viewModel.presentedSheet = .vault
            }
            Button("Results", systemImage: "photo.on.rectangle.angled") {
                viewModel.presentedSheet = .results
            }
            Divider()
            Button("Tabs (\(viewModel.tabs.count))", systemImage: "square.on.square") {
                viewModel.presentedSheet = .tabs
            }
            Button("Bookmarks", systemImage: "bookmark") {
                viewModel.presentedSheet = .bookmarks
            }
            Button("History", systemImage: "clock") {
                viewModel.presentedSheet = .history
            }
            Divider()
            Button("Home", systemImage: "house") {
                viewModel.goHome()
            }
            Button("New Tab", systemImage: "plus") {
                viewModel.addNewTab()
            }
            Button("Reload", systemImage: "arrow.clockwise") {
                viewModel.reload()
            }
            Divider()
            Button("Settings", systemImage: "gear") {
                viewModel.presentedSheet = .settings
            }
        } label: {
            Image(systemName: "line.3.horizontal")
                .font(.body)
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .frame(maxWidth: .infinity)
    }

    private func toolbarButton(
        icon: String,
        disabled: Bool = false,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(disabled ? AnyShapeStyle(.tertiary) : AnyShapeStyle(tint ?? .primary))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .disabled(disabled)
        .frame(maxWidth: .infinity)
    }

    private var isAnyRCRRunning: Bool {
        viewModel.isRCRRunning || viewModel.quadController.anyRCRRunning
    }

    private var canGoBack: Bool {
        if viewModel.isQuadMode {
            return viewModel.quadController.focusedSession.canGoBack
        }
        return viewModel.activeTab?.canGoBack == true
    }

    private var canGoForward: Bool {
        if viewModel.isQuadMode {
            return viewModel.quadController.focusedSession.canGoForward
        }
        return viewModel.activeTab?.canGoForward == true
    }

    private var isCurrentPageLoading: Bool {
        if viewModel.isQuadMode {
            return viewModel.quadController.focusedSession.isLoading
        }
        return viewModel.activeTab?.isLoading == true
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil, from: nil, for: nil
        )
    }
}
