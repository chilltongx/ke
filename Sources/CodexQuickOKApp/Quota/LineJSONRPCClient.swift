import Foundation

actor LineJSONRPCClient {
    enum RPCError: Error, Sendable {
        case closed
        case transport(String)
        case server(String)
        case malformedResponse
    }

    private let input: FileHandle
    private let output: FileHandle
    private var nextId = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var readerTask: Task<Void, Never>?
    private var notificationHandler: (@Sendable (String) -> Void)?
    private var terminalError: RPCError?

    init(input: FileHandle, output: FileHandle) {
        self.input = input
        self.output = output
    }

    func request(method: String, params: [String: JSONValue]) async throws -> JSONValue {
        if let terminalError {
            throw terminalError
        }
        ensureReaderStarted()
        let id = nextId
        nextId += 1
        let body = Request(method: method, id: id, params: params)
        let data = try JSONEncoder().encode(body) + Data([0x0A])
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            output.write(data)
        }
    }

    func sendNotification(method: String, params: [String: JSONValue]) throws {
        if let terminalError {
            throw terminalError
        }
        ensureReaderStarted()
        let body = Request(method: method, id: nil, params: params)
        let data = try JSONEncoder().encode(body) + Data([0x0A])
        output.write(data)
    }

    func setNotificationHandler(_ handler: @escaping @Sendable (String) -> Void) {
        notificationHandler = handler
    }

    private func ensureReaderStarted() {
        guard terminalError == nil, readerTask == nil else { return }
        readerTask = Task { await self.readLoop() }
    }

    private func readLoop() async {
        do {
            for try await line in input.bytes.lines {
                guard let data = line.data(using: .utf8),
                      let response = try? JSONDecoder().decode(Response.self, from: data)
                else {
                    continue
                }

                if let method = response.method, response.id == nil {
                    notificationHandler?(method)
                    continue
                }

                guard let id = response.id,
                      let continuation = pending.removeValue(forKey: id)
                else {
                    continue
                }

                if let error = response.error {
                    continuation.resume(throwing: RPCError.server(String(describing: error)))
                } else if let result = response.result {
                    continuation.resume(returning: result)
                } else {
                    continuation.resume(throwing: RPCError.malformedResponse)
                }
            }

            finish(with: .closed)
        } catch {
            finish(with: .transport(String(describing: error)))
        }
    }

    private func finish(with error: RPCError) {
        guard terminalError == nil else { return }
        terminalError = error
        for continuation in pending.values {
            continuation.resume(throwing: error)
        }
        pending.removeAll()
    }
}

private extension LineJSONRPCClient {
    struct Request: Encodable {
        let method: String
        let id: Int?
        let params: [String: JSONValue]
    }

    struct Response: Decodable {
        let id: Int?
        let method: String?
        let result: JSONValue?
        let error: JSONValue?
    }
}
