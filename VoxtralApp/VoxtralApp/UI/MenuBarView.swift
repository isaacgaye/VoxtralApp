import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var configStore:    ConfigStore
    @EnvironmentObject private var sidecarMonitor: SidecarMonitor
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Voxtral")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

            Divider()

            HealthBadge(label: "Voice", state: sidecarMonitor.health.stt)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            Divider()

            Button("Settings…") {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 220)
    }
}

// MARK: - Health badge

private struct HealthBadge: View {
    let label: String
    let state: ModelState

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
            Text("\(label): \(stateLabel)")
                .font(.system(size: 12))
        }
    }

    private var dotColor: Color {
        switch state {
        case .ready:     .green
        case .warmingUp: .yellow
        }
    }

    private var stateLabel: String {
        switch state {
        case .ready:     "ready"
        case .warmingUp: "warming up…"
        }
    }
}
