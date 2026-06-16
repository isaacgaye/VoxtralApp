import Foundation

struct AppConfig: Codable {
    var hotkey:      String
    var sidecarPort: Int
    var dictionary:  [DictionaryEntry]

    static let `default` = AppConfig(
        hotkey: "rightCommand",
        sidecarPort: 50051,
        dictionary: []
    )
}
