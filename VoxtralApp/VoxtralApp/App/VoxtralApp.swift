import SwiftUI
import Combine

// Owns and wires all Core components. A single @StateObject in VoxtralApp avoids
// the DictionaryStore(configStore:) initialization-ordering problem that arises
// when using multiple @StateObject properties.
@MainActor
final class AppCoordinator: ObservableObject {

    // MARK: - Exposed to views via .environmentObject

    let configStore     = ConfigStore()
    let sidecarMonitor  = SidecarMonitor()
    let dictionaryStore: DictionaryStore    // init'd from configStore below

    // MARK: - Pipeline (private)

    private let hotkeyManager = HotkeyManager()
    private let audioRecorder = AudioRecorder()
    private let sttClient     = STTClient()
    private let injector      = Injector()
    private let hudPill       = HUDPill()

    // MARK: - Session state

    private var accumulatedText  = ""   // tokens from STTClient (Layer-2 applied)
    private var hotkeyInstalled  = false  // single-install guard for HotkeyManager
    private var cancellables: Set<AnyCancellable> = []

    // MARK: - Init

    init() {
        dictionaryStore = DictionaryStore(configStore: configStore)
        wirePipeline()
    }

    // MARK: - Wiring

    private func wirePipeline() {
        sidecarMonitor.start(port: configStore.config.sidecarPort)

        // Install HotkeyManager once when STT first becomes ready.
        // $health may re-emit .ready (e.g. sidecar restart); the flag prevents re-installation.
        sidecarMonitor.$health
            .receive(on: DispatchQueue.main)
            .sink { [weak self] health in
                vlog("health sink fired: stt:\(health.stt) hotkeyInstalled:\(self?.hotkeyInstalled ?? false)")
                guard let self, !self.hotkeyInstalled, health.stt == .ready else { return }
                self.hotkeyInstalled = true
                self.hotkeyManager.start(hotkey: self.configStore.config.hotkey)
            }
            .store(in: &cancellables)

        // Re-start HotkeyManager whenever the user changes the hotkey in Settings.
        // dropFirst skips the initial emission; the health sink above handles first install.
        configStore.$config
            .map(\.hotkey)
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newHotkey in
                guard let self, self.hotkeyInstalled else { return }
                self.hotkeyManager.stop()
                self.hotkeyManager.start(hotkey: newHotkey)
            }
            .store(in: &cancellables)

        vlog("wirePipeline(): subscribed — current health stt:\(sidecarMonitor.health.stt)")

        // CGEvent tap fires on the main RunLoop thread; dispatch to main queue
        // to satisfy @MainActor isolation before touching session state.
        hotkeyManager.onEvent = { [weak self] event in
            DispatchQueue.main.async {
                guard let self else { return }
                switch event {
                case .startRecording: self.handleStartRecording()
                case .stopRecording:  self.handleStopRecording()
                }
            }
        }

        // Audio thread → STTClient. sttClient.send is a fire-and-forget URLSession send;
        // accessing the `let sttClient` constant from the audio thread is safe.
        audioRecorder.onBuffer = { [weak self] data in
            self?.sttClient.send(data)
        }

        // STTClient fires on URLSession background queue → dispatch to main.
        sttClient.onEvent = { [weak self] event in
            DispatchQueue.main.async {
                guard let self else { return }
                switch event {
                case .token(let text):
                    // STTClient now emits the full accumulated, Layer-2-substituted
                    // text each time (not a delta) — see STTClient.rawBuffer.
                    self.accumulatedText = text
                    self.hudPill.update(state: .recording, text: self.accumulatedText)
                case .eou:
                    // Hold-to-talk: advisory only — freeze pill tail dim→solid; keep session open.
                    self.hudPill.update(state: .tailLocked, text: self.accumulatedText)
                case .error:
                    self.hudPill.update(state: .idle)
                    self.hudPill.hide()
                }
            }
        }
    }

    // MARK: - Session handlers

    private func handleStartRecording() {
        vlog("handleStartRecording: stt=\(sidecarMonitor.health.stt)")
        guard sidecarMonitor.health.stt == .ready else { return }
        accumulatedText = ""
        sttClient.configure(layer2Map: dictionaryStore.layer2Map)
        sttClient.connect(port: configStore.config.sidecarPort)
        try? audioRecorder.start()
        hudPill.show()
        hudPill.update(state: .recording)
    }

    private func handleStopRecording() {
        vlog("handleStopRecording: textLength=\(accumulatedText.count)")
        audioRecorder.stop()
        sttClient.disconnect()
        injector.inject(accumulatedText)
        commitAndDismiss()
    }

    private func commitAndDismiss() {
        hudPill.update(state: .committed)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.hudPill.update(state: .idle)
            self?.hudPill.hide()
        }
    }
}

// MARK: -

// @main — owns the MenuBarExtra scene and a single AppCoordinator that assembles
// the full dictation pipeline.
@main
struct VoxtralApp: App {
    @StateObject private var coordinator = AppCoordinator()

    var body: some Scene {
        MenuBarExtra(Bundle.main.appName, systemImage: "mic") {
            MenuBarView()
                .environmentObject(coordinator.configStore)
                .environmentObject(coordinator.sidecarMonitor)
        }
        Settings {
            SettingsView()
                .environmentObject(coordinator.configStore)
                .environmentObject(coordinator.dictionaryStore)
        }
    }
}

private extension Bundle {
    var appName: String {
        (infoDictionary?["CFBundleDisplayName"] as? String) ?? "Voxtral"
    }
}
