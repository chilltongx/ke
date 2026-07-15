import Darwin
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
        self.encoder.dateEncodingStrategy = .secondsSince1970
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let seconds = try? container.decode(Double.self) {
                return Date(timeIntervalSince1970: seconds)
            }
            let value = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            guard let date = formatter.date(from: value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected a Unix timestamp or ISO-8601 date"
                )
            }
            return date
        }
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
        try withExclusiveLock {
            try encoder.encode(state).write(to: url, options: [.atomic])
        }
    }

    public func loadAll(now: Date, staleAfter: TimeInterval) throws -> [SessionState] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        return try withExclusiveLock {
            var result: [SessionState] = []
            for url in try sessionFileURLs() {
                guard let data = try? Data(contentsOf: url),
                      let state = try? decoder.decode(SessionState.self, from: data) else {
                    continue
                }
                if now.timeIntervalSince(state.updatedAt) > staleAfter {
                    try? fileManager.removeItem(at: url)
                } else {
                    result.append(state)
                }
            }
            return result
        }
    }

    public func remove(sessionId: String) throws {
        let url = try sessionFileURL(for: sessionId)
        try withExclusiveLock {
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }
    }

    public func removeAll() throws {
        guard fileManager.fileExists(atPath: directory.path) else { return }
        try withExclusiveLock {
            for url in try sessionFileURLs() {
                try fileManager.removeItem(at: url)
            }
        }
    }

    public func removeAll(updatedAtOrBefore cutoff: Date) throws {
        guard fileManager.fileExists(atPath: directory.path) else { return }
        try withExclusiveLock {
            for url in try sessionFileURLs() {
                guard let data = try? Data(contentsOf: url),
                      let state = try? decoder.decode(SessionState.self, from: data),
                      state.updatedAt <= cutoff else {
                    continue
                }
                try fileManager.removeItem(at: url)
            }
        }
    }

    private func withExclusiveLock<T>(_ operation: () throws -> T) throws -> T {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let lockURL = directory.appendingPathComponent(".store.lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw posixError() }
        defer { close(descriptor) }

        guard flock(descriptor, LOCK_EX) == 0 else { throw posixError() }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }

    private func sessionFileURLs() throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
    }

    private func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
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
