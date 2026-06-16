import Foundation
import Combine

final class ConfigStore: ObservableObject {
    @Published private(set) var config: AppConfig

    private let fileURL: URL

    init() {
        self.fileURL = ConfigStore.configFileURL()
        self.config  = ConfigStore.load(from: fileURL)
    }

    func update(_ block: (inout AppConfig) -> Void) {
        block(&config)
        save()
    }

    // MARK: - Private

    private func save() {
        do {
            let dir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(config)
            // Atomic write: temp file + rename — prevents corrupt JSON on crash mid-write.
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Config stays in memory; next mutation will retry the write.
        }
    }

    private static func load(from url: URL) -> AppConfig {
        guard let data   = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(AppConfig.self, from: data)
        else { return .default }  // first run (missing file) or corrupt JSON
        return config
    }

    private static func configFileURL() -> URL {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support
            .appendingPathComponent("com.voxtral.dictation", isDirectory: true)
            .appendingPathComponent("AppConfig.json")
    }
}
