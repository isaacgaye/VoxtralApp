import Foundation
import Combine

enum ModelState: String, Decodable, Equatable {
    case warmingUp = "warming_up"
    case ready
}

struct SidecarHealth: Decodable, Equatable {
    var stt: ModelState
}

// Polls GET /health every 2s and publishes SidecarHealth.
// stt == .warmingUp → block dictation; show "warming up…" pill
// stt == .ready     → dictation available
final class SidecarMonitor: ObservableObject, @unchecked Sendable {
    @Published private(set) var health = SidecarHealth(stt: .warmingUp)

    private var timer: AnyCancellable?
    private var port: Int = 50051

    func start(port: Int) {
        self.port = port
        timer?.cancel()
        timer = Timer.publish(every: 2.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.fetchHealth() }
    }

    func stop() {
        timer?.cancel()
    }

    private func fetchHealth() {
        let url = URL(string: "http://127.0.0.1:\(port)/health")!
        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            guard let self, error == nil,
                  let data,
                  let decoded = try? JSONDecoder().decode(SidecarHealth.self, from: data)
            else { return }
            DispatchQueue.main.async {
                if decoded != self.health { self.health = decoded }
            }
        }.resume()
    }
}
