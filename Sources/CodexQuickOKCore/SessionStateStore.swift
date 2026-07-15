import Foundation

public actor SessionStateStore {
    public let directory: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    public static func defaultDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        return base.appendingPathComponent("CodexQuickOK/sessions", isDirectory: true)
    }

    public func save(_ state: SessionState) throws {
        let url = try sessionFileURL(for: state.sessionId)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(state).write(to: url, options: [.atomic])
    }

    public func loadAll(now: Date, staleAfter: TimeInterval) throws -> [SessionState] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        var result: [SessionState] = []
        for url in try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let state = try? decoder.decode(SessionState.self, from: data) else { continue }
            if now.timeIntervalSince(state.updatedAt) > staleAfter {
                try? fileManager.removeItem(at: url)
            } else {
                result.append(state)
            }
        }
        return result
    }

    public func remove(sessionId: String) throws {
        let url = try sessionFileURL(for: sessionId)
        if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
    }

    public func removeAll() throws {
        guard fileManager.fileExists(atPath: directory.path) else { return }
        for url in try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where url.pathExtension == "json" {
            try fileManager.removeItem(at: url)
        }
    }

    private func sessionFileURL(for sessionId: String) throws -> URL {
        guard !sessionId.isEmpty,
              sessionId != ".",
              sessionId != "..",
              !sessionId.contains("/"),
              !sessionId.contains("\0") else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        return directory.appendingPathComponent(sessionId).appendingPathExtension("json")
    }
}
