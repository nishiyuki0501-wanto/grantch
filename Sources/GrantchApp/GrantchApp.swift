import AppKit
import Combine
import GrantchCore
import SwiftUI

/// Japanese is the base language: keys are the Japanese text, and
/// `en.lproj/Localizable.strings` in the app bundle supplies English. Outside
/// the bundle (`swift run`) the Japanese keys are shown as they are.
func L(_ key: String, _ arguments: CVarArg...) -> String {
    let format = Bundle.main.localizedString(forKey: key, value: key, table: nil)
    return arguments.isEmpty ? format : String(format: format, locale: .current, arguments: arguments)
}

let appName = L("にゃんこのスタミナ")

/// One request that auto-approval let through, kept so the user can read back
/// what ran while they were away.
struct AutoApprovedRecord: Identifiable, Equatable {
    let id: String
    let agent: String
    let command: String
    let risk: RiskLevel
    let decidedAt: Date
}

@MainActor
final class ApprovalStore: ObservableObject {
    @Published var requests: [ApprovalRequest] = []
    /// Set when the socket could not be opened. Hooks then fall back to each
    /// CLI's own handling, so the notch must not look like it is watching.
    @Published private(set) var serverError: String?
    @Published var notchWidth: CGFloat = 180
    /// Auto-approval is deliberately in-memory only: a relaunch always comes
    /// back in the normal, asking state.
    @Published private(set) var autoApproveUntil: Date?
    /// The most recent requests the last auto-approval window let through.
    /// Kept after the window ends so a run can be read back, until the next
    /// window starts or the user clears it.
    @Published private(set) var autoApproved: [AutoApprovedRecord] = []
    @Published private(set) var autoApprovedCount = 0
    private let server = ApprovalServer()
    private var reconciliationTask: Task<Void, Never>?

    var isAutoApproving: Bool { (autoApproveUntil ?? .distantPast) > Date() }

    func startAutoApproving(for duration: TimeInterval) {
        autoApproveUntil = Date().addingTimeInterval(duration)
        clearAutoApprovedRecord()
        for request in requests { autoApprove(request) }
    }

    func extendAutoApproving(by duration: TimeInterval) {
        guard let until = autoApproveUntil, until > Date() else { return }
        autoApproveUntil = until.addingTimeInterval(duration)
    }

    func stopAutoApproving() {
        autoApproveUntil = nil
    }

    func clearAutoApprovedRecord() {
        autoApproved.removeAll()
        autoApprovedCount = 0
    }

    private func autoApprove(_ request: ApprovalRequest) {
        guard decide(.allowOnce, request: request) else { return }
        autoApprovedCount += 1
        autoApproved.insert(
            AutoApprovedRecord(
                id: request.id,
                agent: request.agent,
                command: request.command,
                risk: request.risk,
                decidedAt: Date()
            ),
            at: 0
        )
        if autoApproved.count > 30 { autoApproved.removeLast(autoApproved.count - 30) }
    }

    func start() {
        do {
            try server.start(
                handler: { [weak self] request in
                    Task { @MainActor in
                        guard let self, self.server.pendingRequestIDs.contains(request.id), !self.requests.contains(where: { $0.id == request.id }) else { return }
                        guard !self.isAutoApproving else {
                            self.autoApprove(request)
                            return
                        }
                        self.requests.append(request)
                    }
                },
                onRequestEnded: { [weak self] requestId in
                    Task { @MainActor in
                        self?.requests.removeAll { $0.id == requestId }
                    }
                }
            )
            startReconciliation()
        } catch {
            serverError = error.localizedDescription
        }
    }

    private func startReconciliation() {
        reconciliationTask?.cancel()
        reconciliationTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self else { return }
                let pendingRequestIDs = self.server.pendingRequestIDs
                self.requests.removeAll { !pendingRequestIDs.contains($0.id) }
                if self.autoApproveUntil != nil, !self.isAutoApproving { self.autoApproveUntil = nil }
            }
        }
    }

    /// Returns whether the decision reached the waiting CLI. A request that
    /// already expired or ended is simply dropped from the queue.
    @discardableResult
    func decide(_ decision: ApprovalDecision, request: ApprovalRequest) -> Bool {
        defer { requests.removeAll { $0.id == request.id } }
        guard request.expiresAt > Date() else { return false }
        return (try? server.resolve(ApprovalResponse(requestId: request.id, decision: decision))) != nil
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = ApprovalStore()
    private var panel: NSPanel?
    private var cancellables: Set<AnyCancellable> = []
    /// The idle panel grows for auto-approval, its record, or a startup error.
    private var idleExpanded = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            store.start()
            showPanel()
            NSApplication.shared.setActivationPolicy(.accessory)
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(screenParametersDidChange),
                name: NSApplication.didChangeScreenParametersNotification,
                object: nil
            )
        }
    }

    @objc private func screenParametersDidChange() {
        guard let panel else { return }
        position(panel)
    }

    @MainActor private func showPanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 132),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let hostingView = NSHostingView(rootView: NotchView(store: store))
        hostingView.sizingOptions = []
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 132))
        container.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: container.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        panel.contentView = container
        panel.setContentSize(NSSize(width: 620, height: 132))
        position(panel)
        panel.orderFrontRegardless()
        self.panel = panel
        store.$requests
            .map(\.count)
            .removeDuplicates()
            .sink { [weak self] count in self?.resizePanel(for: count) }
            .store(in: &cancellables)
        // The idle panel grows when auto-approval is on: it carries the
        // countdown, the off switch, and the record of what it let through.
        // @Published emits before the property changes, so size from the
        // emitted values rather than reading the store back.
        Publishers.CombineLatest3(
            store.$autoApproveUntil.map { $0 != nil },
            store.$autoApproved.map { !$0.isEmpty },
            store.$serverError.map { $0 != nil }
        )
        .map { $0 || $1 || $2 }
        .removeDuplicates()
        .sink { [weak self] expanded in
            guard let self else { return }
            self.idleExpanded = expanded
            self.resizePanel(for: self.store.requests.count)
        }
        .store(in: &cancellables)
    }

    private func resizePanel(for approvalCount: Int) {
        guard let panel else { return }
        let idleHeight: CGFloat = idleExpanded ? 290 : 132
        let height: CGFloat = approvalCount == 0
            ? idleHeight
            : min(380, 96 + CGFloat(min(approvalCount, 3)) * 86)
        panel.setContentSize(NSSize(width: 620, height: height))
        position(panel)
    }

    @MainActor private func position(_ panel: NSPanel) {
        guard let screen = preferredDisplay else { return }
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            store.notchWidth = max(0, right.minX - left.maxX)
        } else {
            store.notchWidth = 180
        }
        let x = screen.frame.midX - panel.frame.width / 2
        let y = screen.frame.maxY - panel.frame.height
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private var preferredDisplay: NSScreen? {
        NSScreen.screens.first {
            $0.safeAreaInsets.top > 0
                && $0.auxiliaryTopLeftArea != nil
                && $0.auxiliaryTopRightArea != nil
        } ?? NSScreen.main ?? NSScreen.screens.first
    }
}

struct NotchView: View {
    @ObservedObject var store: ApprovalStore

    var body: some View {
        ZStack(alignment: .top) {
            if !store.requests.isEmpty {
                ApprovalQueueView(requests: store.requests, notchWidth: store.notchWidth) { decision, request in
                    store.decide(decision, request: request)
                }
            } else {
                IdleNotchView(store: store, notchWidth: store.notchWidth)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.snappy, value: store.requests.count)
    }
}

extension RiskLevel {
    var interfaceColor: Color {
        switch self {
        case .low: Color(red: 0.43, green: 0.61, blue: 0.51)
        case .medium: Color(red: 0.72, green: 0.58, blue: 0.34)
        case .high: Color(red: 0.72, green: 0.43, blue: 0.31)
        case .critical: Color(red: 0.72, green: 0.32, blue: 0.36)
        }
    }

    var interfaceLabel: String {
        switch self {
        case .low: L("低リスク")
        case .medium: L("注意")
        case .high: L("高リスク")
        case .critical: L("危険")
        }
    }
}

enum InterfaceTheme: String, CaseIterable, Identifiable {
    case sage
    case blue
    case violet
    case sand

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sage: L("セージ")
        case .blue: L("ブルー")
        case .violet: L("バイオレット")
        case .sand: L("サンド")
        }
    }

    var color: Color {
        switch self {
        case .sage: Color(red: 0.43, green: 0.61, blue: 0.51)
        case .blue: Color(red: 0.38, green: 0.55, blue: 0.72)
        case .violet: Color(red: 0.55, green: 0.46, blue: 0.70)
        case .sand: Color(red: 0.68, green: 0.56, blue: 0.39)
        }
    }
}

struct ApprovalQueueView: View {
    let requests: [ApprovalRequest]
    let notchWidth: CGFloat
    let decide: (ApprovalDecision, ApprovalRequest) -> Void
    @AppStorage("accentTheme") private var themeKey = InterfaceTheme.sage.rawValue

    private var accent: Color {
        (InterfaceTheme(rawValue: themeKey) ?? .sage).color
    }

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 8) {
                Text(L("承認確認")).font(.system(size: 14, weight: .black, design: .monospaced))
                PixelWalker(tint: accent)
                    .frame(width: 40, height: 23)
                Spacer()
                if requests.count > 1 {
                    Text(L("%ld件", requests.count))
                        .font(.system(size: 11, weight: .black, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }

            ForEach(Array(requests.prefix(3).enumerated()), id: \.element.id) { position, request in
                ApprovalQueueRow(request: request, position: position) { decide($0, request) }
            }

            if requests.count > 3 {
                Text(L("ほか %ld件の承認待ち", requests.count - 3))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12).padding(.top, 43).padding(.bottom, 14)
        .frame(width: 600)
        .foregroundStyle(.white)
        .background {
            PixelBlockBackground(accent: accent, isActive: true)
                .mask {
                    NotchShellShape(notchWidth: notchWidth + 16, notchHeight: 35)
                        .fill(style: FillStyle(eoFill: true))
                }
        }
        .overlay {
            NotchShellShape(notchWidth: notchWidth + 16, notchHeight: 35)
                .stroke(.black.opacity(0.9), lineWidth: 3)
        }
        .shadow(color: .black.opacity(0.75), radius: 0, y: 5)
        .padding(.horizontal, 10)
    }
}

struct ApprovalQueueRow: View {
    let request: ApprovalRequest
    let position: Int
    let decide: (ApprovalDecision) -> Void
    @State private var isArmed = false

    private var accent: Color {
        request.risk.interfaceColor
    }

    private var agentName: String {
        switch request.agent {
        case "codex": "Codex"
        case "antigravity": "Antigravity"
        default: "Claude"
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 7) {
                Text(ToolSummary.displayLine(request.project)).font(.system(size: 12, weight: .black, design: .monospaced)).lineLimit(1)
                Text(agentName).font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(.white.opacity(0.38))
                Spacer()
                VoxelRiskBadge(label: request.risk.interfaceLabel, tint: accent)
                    .help(request.riskReasons.map { L($0) }.joined(separator: "\n"))
            }
            HStack(spacing: 8) {
                Text(ToolSummary.displayLine(request.command))
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.72), in: Rectangle())
                    .overlay(Rectangle().stroke(.white.opacity(0.12), lineWidth: 1))
                    .help(commandHelp)
                Spacer(minLength: 6)
                Group {
                    Button(L("拒否")) { decide(.deny) }
                        .help(L("この操作を実行させません"))
                    if request.agent == "claude-code" {
                        Button(L("停止")) { decide(.denyAndStop) }
                            .buttonStyle(VoxelButtonStyle(tint: accent, emphasis: .subtle))
                            .help(L("拒否して、エージェントの作業も中断します"))
                    }
                    if request.risk == .low || request.risk == .medium {
                        // Claude Code's suggestion is often broader than this
                        // call (`Bash(git:*)`), so the button names the rule.
                        if let rules = request.sessionSuggestion?.rules {
                            Button { decide(.allowSession) } label: {
                                Text(L("セッション: %@", ToolSummary.displayLine(rules)))
                                    .lineLimit(1).truncationMode(.middle)
                                    .frame(maxWidth: 150)
                            }
                            .help(L("このセッションのあいだ、%@ に当てはまる操作を確認なしで許可します", ToolSummary.displayLine(rules)))
                        }
                        Button(L("許可")) { decide(.allowOnce) }
                            .buttonStyle(VoxelButtonStyle(tint: accent, emphasis: .primary))
                            .help(approvalHelp)
                    } else {
                        LongPressApprovalButton { decide(.allowOnce) }
                            .help(approvalHelp)
                    }
                }
                .disabled(!isArmed)
                .allowsHitTesting(isArmed)
                .opacity(isArmed ? 1 : 0.55)
            }
            .buttonStyle(VoxelButtonStyle(tint: accent))
            .controlSize(.small)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Color(white: 0.055), in: Rectangle())
        .overlay {
            Rectangle()
                .stroke(Color(white: 0.20), lineWidth: 2)
                .overlay(Rectangle().stroke(.white.opacity(0.10), lineWidth: 1).padding(2))
        }
        .task(id: position) {
            // The panel appears over whatever the pointer was heading for, and
            // rows shift up as others are decided. Ignore clicks briefly after
            // either, so a click aimed elsewhere cannot land on a decision.
            isArmed = false
            guard (try? await Task.sleep(for: .milliseconds(500))) != nil else { return }
            isArmed = true
        }
    }

    /// The full input, made visible, plus the agent's own description marked
    /// as such: it explains the call but is not what runs.
    private var commandHelp: String {
        var help = ToolSummary.displayLine(request.command)
        if let detail = request.detail, !detail.isEmpty {
            help += "\n\n" + L("エージェントの説明: %@", ToolSummary.displayLine(detail))
        }
        return help
    }

    private var approvalHelp: String {
        L("今回の操作だけを許可します")
    }
}

let autoApproveDurations: [(label: String, seconds: TimeInterval)] = [
    ("15分", 15 * 60),
    ("1時間", 60 * 60),
    ("3時間", 3 * 60 * 60)
]

func autoApproveCountdown(until: Date, now: Date) -> String {
    let remaining = max(0, Int(until.timeIntervalSince(now).rounded(.up)))
    return String(format: "%d:%02d", remaining / 60, remaining % 60)
}

struct IdleNotchView: View {
    @ObservedObject var store: ApprovalStore
    let notchWidth: CGFloat
    @State private var isHovered = false
    @State private var isPinnedOpen = false
    @AppStorage("accentTheme") private var themeKey = InterfaceTheme.sage.rawValue

    private var hoverWidth: CGFloat { max(notchWidth + 38, 220) }
    private var outlineWidth: CGFloat { max(notchWidth + 30, 212) }
    private var expandedWidth: CGFloat { min(max(notchWidth + 90, 272), 340) }
    private var panelWidth: CGFloat {
        store.isAutoApproving || !store.autoApproved.isEmpty || store.serverError != nil ? 420 : max(expandedWidth, 320)
    }
    private var idleAccent: Color { (InterfaceTheme(rawValue: themeKey) ?? .sage).color }
    /// Auto-approval borrows the critical-risk color: the notch should not look
    /// calm while every request is being waved through.
    private var statusAccent: Color {
        store.isAutoApproving || store.serverError != nil ? RiskLevel.critical.interfaceColor : idleAccent
    }
    private var statusTitle: String {
        if store.serverError != nil { return L("停止中") }
        return store.isAutoApproving ? L("自動承認中") : L("承認待ちなし")
    }

    var body: some View {
        Group {
            if isHovered || isPinnedOpen {
                Group {
                    if isPinnedOpen {
                        VStack(spacing: 8) {
                            HStack(spacing: 9) {
                                PixelWalker(tint: statusAccent)
                                    .frame(width: 42, height: 23)
                                Text(statusTitle)
                                    .font(.system(size: 12, weight: .black, design: .monospaced))
                                Image(systemName: "pin.fill")
                                    .font(.system(size: 9, weight: .black))
                                    .foregroundStyle(statusAccent)
                            }
                            if let error = store.serverError {
                                Text(L("承認要求を受け取れません: %@\nClaude Code と Codex は通常の確認に戻り、Antigravity は拒否されます。", error))
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.8))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            AutoApproveControls(store: store, accent: statusAccent)
                        }
                        .padding(.top, 35).padding(.horizontal, 12).padding(.bottom, 12)
                        .frame(width: panelWidth, alignment: .top)
                        .foregroundStyle(.white)
                        .background {
                            PixelBlockBackground(accent: statusAccent, isActive: true)
                                .mask {
                                    NotchShellShape(notchWidth: notchWidth + 10, notchHeight: 35)
                                        .fill(style: FillStyle(eoFill: true))
                                }
                        }
                        .overlay {
                            NotchShellShape(notchWidth: notchWidth + 10, notchHeight: 35)
                                .stroke(.black, lineWidth: 3)
                        }
                    } else {
                        Color.clear
                            .frame(width: outlineWidth, height: 48)
                            .background {
                                NotchShellShape(notchWidth: notchWidth + 8, notchHeight: 35)
                                    .fill(.black.opacity(0.96), style: FillStyle(eoFill: true))
                            }
                            .overlay {
                                NotchShellShape(notchWidth: notchWidth + 8, notchHeight: 35)
                                    .stroke(.black, lineWidth: 2)
                            }
                    }
                }
                .shadow(color: .black.opacity(0.45), radius: 0, y: 3)
                .contentShape(Rectangle())
                .onTapGesture {
                    isPinnedOpen.toggle()
                }
                .onContinuousHover { phase in
                    switch phase {
                    case .active:
                        isHovered = true
                        NSCursor.pointingHand.set()
                    case .ended:
                        isHovered = false
                        NSCursor.arrow.set()
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.985, anchor: .top)))
            } else {
                VStack(spacing: 0) {
                    if store.isAutoApproving {
                        AutoApproveBadge(store: store)
                    } else if let error = store.serverError {
                        StatusBadge(text: "ERROR")
                            .help(L("%@ は承認要求を受け取れません: %@", appName, error))
                    }
                }
                .frame(width: hoverWidth, height: 42, alignment: .bottom)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    if case .active = phase {
                        isHovered = true
                        NSCursor.pointingHand.set()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .contextMenu {
            if store.isAutoApproving {
                Button(L("自動承認をオフにする")) { store.stopAutoApproving() }
            } else {
                ForEach(autoApproveDurations, id: \.label) { duration in
                    Button(L("自動承認 %@", L(duration.label))) { store.startAutoApproving(for: duration.seconds) }
                }
            }
            Divider()
            ForEach(InterfaceTheme.allCases) { theme in
                Button {
                    themeKey = theme.rawValue
                } label: {
                    Label(theme.displayName, systemImage: themeKey == theme.rawValue ? "checkmark.circle.fill" : "circle")
                }
            }
            Divider()
            Button(L("%@を終了", appName)) { NSApp.terminate(nil) }
        }
        .animation(.spring(response: 0.22, dampingFraction: 0.72), value: isHovered)
        .animation(.snappy(duration: 0.18), value: isPinnedOpen)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(store.serverError != nil ? L("%@、停止中", appName) : store.isAutoApproving ? L("%@、自動承認中", appName) : L("%@、監視中", appName))
        .accessibilityHint(isPinnedOpen ? L("クリックするとピン留めを解除します") : L("クリックすると承認待ち表示を固定します"))
    }
}

struct AutoApproveBadge: View {
    @ObservedObject var store: ApprovalStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            StatusBadge(
                text: "AUTO",
                detail: [
                    store.autoApproveUntil.map { autoApproveCountdown(until: $0, now: timeline.date) },
                    store.autoApprovedCount > 0 ? L("%ld件", store.autoApprovedCount) : nil
                ].compactMap { $0 }.joined(separator: " ")
            )
        }
        .help(L("自動承認中です。すべての承認要求が確認なしで許可されます"))
    }
}

struct StatusBadge: View {
    let text: String
    var detail = ""

    var body: some View {
        HStack(spacing: 5) {
            Rectangle().fill(.white).frame(width: 5, height: 5)
            Text(text)
            if !detail.isEmpty {
                Text(detail).foregroundStyle(.white.opacity(0.75))
            }
        }
        .font(.system(size: 9, weight: .black, design: .monospaced))
        .foregroundStyle(.white)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(RiskLevel.critical.interfaceColor, in: Rectangle())
        .overlay(Rectangle().stroke(.black.opacity(0.9), lineWidth: 2))
        .shadow(color: .black.opacity(0.6), radius: 0, y: 2)
    }
}

struct AutoApproveControls: View {
    @ObservedObject var store: ApprovalStore
    let accent: Color

    var body: some View {
        VStack(spacing: 7) {
            if let until = store.autoApproveUntil, store.isAutoApproving {
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    HStack(spacing: 7) {
                        Text(L("残り %@", autoApproveCountdown(until: until, now: timeline.date)))
                            .font(.system(size: 11, weight: .black, design: .monospaced))
                        Spacer(minLength: 4)
                        Button(L("+15分")) { store.extendAutoApproving(by: 15 * 60) }
                            .buttonStyle(VoxelButtonStyle(tint: accent, emphasis: .subtle))
                        Button(L("オフ")) { store.stopAutoApproving() }
                            .buttonStyle(VoxelButtonStyle(tint: accent, emphasis: .primary))
                    }
                }
                Text(L("すべての要求を確認なしで許可しています"))
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, alignment: .leading)
                AutoApprovedRecordList(store: store)
            } else {
                HStack(spacing: 7) {
                    Text(L("自動承認"))
                        .font(.system(size: 11, weight: .black, design: .monospaced))
                    Spacer(minLength: 4)
                    ForEach(autoApproveDurations, id: \.label) { duration in
                        Button(L(duration.label)) { store.startAutoApproving(for: duration.seconds) }
                            .buttonStyle(VoxelButtonStyle(tint: accent))
                            .help(L("%@のあいだ、すべての承認要求を確認なしで許可します", L(duration.label)))
                    }
                }
                if !store.autoApproved.isEmpty {
                    HStack(spacing: 7) {
                        Text(L("前回の自動承認"))
                            .font(.system(size: 10, weight: .black, design: .monospaced))
                        Spacer(minLength: 4)
                        Button(L("消去")) { store.clearAutoApprovedRecord() }
                            .buttonStyle(VoxelButtonStyle(tint: accent, emphasis: .subtle))
                            .help(L("自動承認の記録を消去します"))
                    }
                    AutoApprovedRecordList(store: store)
                }
            }
        }
        .controlSize(.small)
    }
}

/// Nothing asked the user during auto-approval, so this record is the only way
/// to see what ran while they were away.
struct AutoApprovedRecordList: View {
    @ObservedObject var store: ApprovalStore

    var body: some View {
        if store.autoApproved.isEmpty {
            Text(L("まだ何も通っていません"))
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.35))
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(spacing: 3) {
                ForEach(store.autoApproved.prefix(4)) { record in
                    HStack(spacing: 6) {
                        Rectangle()
                            .fill(record.risk.interfaceColor)
                            .frame(width: 5, height: 5)
                        Text(ToolSummary.displayLine(record.command))
                            .lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                    .help(ToolSummary.displayLine(record.command))
                }
            }
            Text(store.autoApprovedCount > store.autoApproved.count
                 ? L("計 %ld件を自動承認（最新 %ld件を保持）", store.autoApprovedCount, store.autoApproved.count)
                 : L("計 %ld件を自動承認", store.autoApprovedCount))
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.4))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct NotchShellShape: Shape {
    let notchWidth: CGFloat
    let notchHeight: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRoundedRect(
            in: rect.insetBy(dx: 2, dy: 2),
            cornerSize: CGSize(width: 9, height: 9)
        )
        let safeWidth = min(max(notchWidth, 150), rect.width - 48)
        let cutout = CGRect(
            x: rect.midX - safeWidth / 2,
            y: -4,
            width: safeWidth,
            height: notchHeight + 4
        )
        path.addRoundedRect(
            in: cutout,
            cornerSize: CGSize(width: 10, height: 10)
        )
        return path
    }
}

struct PixelWalker: View {
    let tint: Color

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.animation(minimumInterval: 1.0 / 12.0)) { timeline in
                let elapsed = timeline.date.timeIntervalSinceReferenceDate
                let cycle = elapsed.truncatingRemainder(dividingBy: 4.0) / 4.0
                let isReturning = cycle >= 0.5
                let progress = isReturning ? (1.0 - cycle) * 2.0 : cycle * 2.0
                let stride = Int(elapsed * 6.0) % 2
                let travel = max(0, geometry.size.width - 13)

                PixelAdventurer(tint: tint, alternateStride: stride == 1)
                    .scaleEffect(x: isReturning ? -1 : 1, y: 1)
                    .offset(
                        x: travel * progress,
                        y: stride == 1 ? 0 : 1
                    )
            }
        }
        .accessibilityHidden(true)
    }
}

struct PixelAdventurer: View {
    let tint: Color
    let alternateStride: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Hair and head
            Rectangle().fill(Color(red: 0.22, green: 0.12, blue: 0.06)).frame(width: 9, height: 3).offset(x: 2)
            Rectangle().fill(Color(red: 0.86, green: 0.62, blue: 0.39)).frame(width: 9, height: 6).offset(x: 2, y: 3)
            Rectangle().fill(.black.opacity(0.9)).frame(width: 2, height: 2).offset(x: 8, y: 5)

            // Shirt, arms, and the bright backpack/tool pixel
            Rectangle().fill(tint.opacity(0.95)).frame(width: 7, height: 6).offset(x: 3, y: 9)
            Rectangle().fill(Color(red: 0.86, green: 0.62, blue: 0.39)).frame(width: 2, height: 5)
                .offset(x: alternateStride ? 1 : 10, y: 9)
            Rectangle().fill(Color(red: 0.86, green: 0.62, blue: 0.39)).frame(width: 2, height: 5)
                .offset(x: alternateStride ? 10 : 1, y: 10)
            Rectangle().fill(.white.opacity(0.8)).frame(width: 2, height: 2).offset(x: 4, y: 10)

            // Alternating legs make the silhouette visibly walk.
            Rectangle().fill(Color(red: 0.15, green: 0.22, blue: 0.38)).frame(width: 3, height: 5)
                .offset(x: alternateStride ? 2 : 4, y: 15)
            Rectangle().fill(Color(red: 0.15, green: 0.22, blue: 0.38)).frame(width: 3, height: 5)
                .offset(x: alternateStride ? 7 : 6, y: 15)
            Rectangle().fill(Color(white: 0.08)).frame(width: 4, height: 2)
                .offset(x: alternateStride ? 1 : 3, y: 20)
            Rectangle().fill(Color(white: 0.08)).frame(width: 4, height: 2)
                .offset(x: alternateStride ? 7 : 6, y: 20)
        }
        .frame(width: 13, height: 22)
        .drawingGroup(opaque: false, colorMode: .nonLinear)
        .shadow(color: .black.opacity(0.7), radius: 0, x: 1, y: 1)
    }
}

struct VoxelRiskBadge: View {
    let label: String
    let tint: Color

    var body: some View {
        HStack(spacing: 4) {
            Rectangle().fill(tint).frame(width: 6, height: 6)
            Text(label)
        }
        .font(.system(size: 9, weight: .black, design: .monospaced))
        .foregroundStyle(.white)
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(tint.opacity(0.35), in: Rectangle())
        .overlay(Rectangle().stroke(tint.opacity(0.85), lineWidth: 1))
    }
}

struct VoxelButtonStyle: ButtonStyle {
    /// Identically styled buttons force the user to read every label before
    /// acting. Emphasis makes the affirmative and the hand-off distinguishable
    /// at a glance, whichever CLI produced the request.
    enum Emphasis {
        case standard
        case primary
        case subtle
    }

    let tint: Color
    var emphasis: Emphasis = .standard

    private var fill: Color {
        switch emphasis {
        case .standard: Color(white: 0.22)
        case .primary: tint.opacity(0.62)
        case .subtle: Color(white: 0.13)
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .black, design: .monospaced))
            .foregroundStyle(.white.opacity(emphasis == .subtle ? 0.62 : 1))
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(configuration.isPressed ? tint.opacity(0.85) : fill, in: Rectangle())
            .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.32)).frame(height: 2) }
            .overlay(alignment: .leading) { Rectangle().fill(.white.opacity(0.18)).frame(width: 2) }
            .overlay(alignment: .bottom) { Rectangle().fill(.black.opacity(0.75)).frame(height: 3) }
            .overlay(alignment: .trailing) { Rectangle().fill(.black.opacity(0.55)).frame(width: 3) }
            .overlay(Rectangle().stroke(.black.opacity(0.92), lineWidth: 1))
            .offset(y: configuration.isPressed ? 2 : 0)
            .shadow(color: .black.opacity(configuration.isPressed ? 0 : 0.8), radius: 0, y: configuration.isPressed ? 0 : 3)
    }
}

struct PixelBlockBackground: View {
    let accent: Color
    let isActive: Bool

    var body: some View {
        Canvas { context, size in
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .color(Color(red: 0.035, green: 0.043, blue: 0.052))
            )
            let tile: CGFloat = 14
            let columns = Int(ceil(size.width / tile))
            let rows = Int(ceil(size.height / tile))

            for row in 0..<rows {
                for column in 0..<columns {
                    let signature = (column * 17 + row * 31 + column * row * 7) % 19
                    let rect = CGRect(
                        x: CGFloat(column) * tile,
                        y: CGFloat(row) * tile,
                        width: tile - 1,
                        height: tile - 1
                    )
                    let color: Color
                    if row == 0 {
                        color = accent.opacity(signature % 3 == 0 ? 0.62 : 0.40)
                    } else if signature == 0 || (isActive && signature == 7) {
                        color = accent.opacity(isActive ? 0.24 : 0.12)
                    } else {
                        let stone = Double(signature % 5) * 0.012
                        color = Color(
                            red: 0.048 + stone,
                            green: 0.057 + stone,
                            blue: 0.068 + stone
                        )
                    }
                    context.fill(Path(rect), with: .color(color))
                    context.fill(Path(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 1)), with: .color(.white.opacity(0.07)))
                    context.fill(Path(CGRect(x: rect.minX, y: rect.maxY - 2, width: rect.width, height: 2)), with: .color(.black.opacity(0.25)))
                }
            }
        }
        .background(Color(red: 0.035, green: 0.043, blue: 0.052))
    }
}

struct LongPressApprovalButton: View {
    let approve: () -> Void
    @State private var progress: CGFloat = 0

    var body: some View {
        Text(L("長押しで許可"))
            .font(.system(size: 11, weight: .black, design: .monospaced))
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(Color(white: 0.22), in: Rectangle())
            .overlay(Rectangle().stroke(.black.opacity(0.92), lineWidth: 1))
            .overlay(alignment: .bottomLeading) {
                GeometryReader { geometry in
                    Rectangle()
                        .fill(RiskLevel.high.interfaceColor)
                        .frame(width: geometry.size.width * progress, height: 2)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .onLongPressGesture(
                minimumDuration: 1.2,
                maximumDistance: 12,
                perform: {
                    progress = 0
                    approve()
                },
                onPressingChanged: { pressing in
                    withAnimation(pressing ? .linear(duration: 1.2) : .easeOut(duration: 0.12)) {
                        progress = pressing ? 1 : 0
                    }
                }
            )
            .accessibilityLabel(L("危険な操作を許可"))
            .accessibilityHint(L("1.2秒間押し続けます"))
    }
}

@main
struct GrantchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene { Settings { EmptyView() } }
}
