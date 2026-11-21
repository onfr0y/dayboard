import Foundation

struct NotionConfiguration: Codable {
    let taskSourceID: UUID
    let habitSourceID: UUID
    let activitySourceID: UUID
    let characterSourceID: UUID
    let characterPageID: UUID
    let tasksURL: URL?
    let habitsURL: URL?
    let habitSourceURL: URL?
    let activityURL: URL?
    let characterURL: URL?

    static var location: URL {
        URL.applicationSupportDirectory.appending(path: "Dayboard/notion-config.json")
    }

    static var current: Self? {
        try? read(from: location)
    }

    static func require() throws -> Self {
        guard let current else { throw NotionFailure.missingConfiguration }
        return current
    }

    static func read(from url: URL) throws -> Self {
        let config = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        for candidate in [config.tasksURL, config.habitsURL, config.habitSourceURL, config.activityURL, config.characterURL].compactMap({ $0 }) {
            guard candidate.scheme == "https", let host = candidate.host,
                  host == "notion.so" || host.hasSuffix(".notion.so") || host == "app.notion.com" else {
                throw NotionFailure.format
            }
        }
        return config
    }

    static func importFile(_ url: URL) throws {
        let config = try read(from: url)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: location.deletingLastPathComponent(),
                                        withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(config).write(to: location, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: location.path)
    }
}
