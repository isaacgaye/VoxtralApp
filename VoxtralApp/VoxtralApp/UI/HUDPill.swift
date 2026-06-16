import AppKit
import SwiftUI

// MARK: - State

enum PillState {
    case idle
    case recording
    case tailLocked  // VAD eou: text locked solid, mic badge stays, session still open
    case cleaning
    case committed
}

// MARK: - Internal view model

private struct WordToken: Identifiable {
    let id = UUID()
    let text: String
    let isDim: Bool  // true = provisional (recording), false = locked (tailLocked)
}

private enum PillPhase {
    case blank, recording, tailLocked, cleaning, committed
}

private final class PillViewModel: ObservableObject {
    @Published var words: [WordToken] = []
    @Published var phase: PillPhase = .blank
}

// MARK: - SwiftUI pill view

private struct PillBodyView: View {
    @ObservedObject var model: PillViewModel

    var body: some View {
        if model.phase != .blank {
            HStack(spacing: 8) {
                leftBadge
                if !model.words.isEmpty {
                    wordRow
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(Capsule().fill(.black.opacity(0.82)))
            .fixedSize()
        }
    }

    @ViewBuilder
    private var leftBadge: some View {
        switch model.phase {
        case .blank:
            EmptyView()
        case .recording, .tailLocked:
            Image(systemName: "mic.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .symbolEffect(.pulse, isActive: model.phase == .recording)
        case .cleaning:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
                Text("Cleaning…")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
            }
        case .committed:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(.green)
        }
    }

    private var wordRow: some View {
        HStack(spacing: 4) {
            ForEach(model.words) { token in
                Text(token.text)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(token.isDim ? 0.45 : 1.0))
            }
        }
    }
}

// MARK: - HUDPill

// Non-activating floating NSPanel overlay; driven by PillState from AppCoordinator.
// All public methods must be called on the main thread (AppCoordinator enforces this).
// The panel is created lazily on first show() and reused for the app lifetime.
@MainActor
final class HUDPill {
    private(set) var state: PillState = .idle
    private var panel: NSPanel?
    private let viewModel = PillViewModel()

    // MARK: - Public interface

    func show() {
        createPanelIfNeeded()
        guard let panel else { return }
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    func update(state: PillState, text: String = "") {
        self.state = state
        switch state {
        case .idle:
            viewModel.phase = .blank
            viewModel.words = []
        case .recording:
            viewModel.phase = .recording
            viewModel.words = rollingWords(text, dim: true)
        case .tailLocked:
            viewModel.phase = .tailLocked
            viewModel.words = rollingWords(text, dim: false)
        case .cleaning:
            viewModel.phase = .cleaning
            viewModel.words = []
        case .committed:
            viewModel.phase = .committed
            viewModel.words = []
        }
    }

    func hide() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak panel] in
            panel?.orderOut(nil)
        })
    }

    // MARK: - Private

    private func createPanelIfNeeded() {
        guard panel == nil else { return }

        // Panel wide enough to hold ~4 words; height fits one pill row.
        // ignoresMouseEvents: pill is purely decorative and must not capture input
        // from the frontmost app.
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 52),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        panel.becomesKeyOnlyIfNeeded = false
        panel.ignoresMouseEvents = true
        panel.contentView = NSHostingView(rootView: PillBodyView(model: viewModel))
        positionPanel(panel)
        self.panel = panel
    }

    // Center-x on main screen, ~80 pt below the top of the visible frame (below menu bar).
    private func positionPanel(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let sf = screen.visibleFrame
        let pw = panel.frame.width
        let ph = panel.frame.height
        panel.setFrameOrigin(NSPoint(x: sf.midX - pw / 2, y: sf.maxY - 80 - ph))
    }

    // Last ≤4 words so the pill stays compact while showing enough context.
    private func rollingWords(_ text: String, dim: Bool) -> [WordToken] {
        text.split(separator: " ", omittingEmptySubsequences: true)
            .suffix(4)
            .map { WordToken(text: String($0), isDim: dim) }
    }
}
