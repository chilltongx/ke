import Foundation

actor LineJSONRPCClient {
    typealias Sleep = @Sendable (Duration) async throws -> Void

    enum RPCError: Error, Equatable, Sendable {
        case closed
        case transport(String)
        case server(String)
        case malformedResponse
        case requestTimedOut(method: String)
    }

    private struct PendingRequest {
        let continuation: CheckedContinuation<JSONValue, Error>
        let deadlineTask: Task<Void, Never>
    }

    private let input: FileHandle
    private let output: FileHandle
    private let requestTimeout: Duration
    private let sleep: Sleep
    private var nextId = 1
    private var pending: [Int: PendingRequest] = [:]
    private var readerTask: Task<Void, Never>?
    private var notificationHandler: (@Sendable (String) -> Void)?
    private var terminalError: RPCError?

    init(
        input: FileHandle,
        output: FileHandle,
        requestTimeout: Duration = .seconds(10),
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) {
        self.input = input
        self.output = output
        self.requestTimeout = requestTimeout
        self.sleep = sleep
    }

    func request(
        method: String,
        params: [String: JSONValue],
        timeout: Duration? = nil
    ) async throws -> JSONValue {
        if let terminalError {
            throw terminalError
        }
        ensureReaderStarted()
        let id = nextId
        nextId += 1
        let body = Request(method: method, id: id, params: params)
        let data = try JSONEncoder().encode(body) + Data([0x0A])
        let deadline = max(timeout ?? requestTimeout, .zero)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let deadlineTask = Task { [sleep] in
                    do {
                        try await sleep(deadline)
                    } catch {
                        return
                    }
                    guard !Task.isCancelled else { return }
                    self.expireRequest(id: id, method: method)
                }
                pending[id] = PendingRequest(
                    continuation: continuation,
                    deadlineTask: deadlineTask
                )

                do {
                    try output.write(contentsOf: data)
                } catch {
                    resolveRequest(
                        id: id,
                        with: .failure(.transport(String(describing: error)))
                    )
                }
            }
        } onCancel: {
            Task { await self.cancelRequest(id: id) }
        }
    }

    func sendNotification(method: String, params: [String: JSONValue]) throws {
        if let terminalError {
            throw terminalError
        }
        ensureReaderStarted()
        let body = Request(method: method, id: nil, params: params)
        let data = try JSONEncoder().encode(body) + Data([0x0A])
        do {
            try output.write(contentsOf: data)
        } catch {
            let error = RPCError.transport(String(describing: error))
            finish(with: error)
            throw error
        }
    }

    func setNotificationHandler(_ handler: @escaping @Sendable (String) -> Void) {
        notificationHandler = handler
    }

    func close() {
        finish(with: .closed)
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
                      pending[id] != nil
                else {
                    continue
                }

                if let error = response.error {
                    resolveRequest(
                        id: id,
                        with: .failure(.server(String(describing: error)))
                    )
                } else if let result = response.result {
                    resolveRequest(id: id, with: .success(result))
                } else {
                    resolveRequest(id: id, with: .failure(.malformedResponse))
                }
            }

            finish(with: .closed)
        } catch is CancellationError {
            if terminalError == nil {
                finish(with: .closed)
            }
        } catch {
            finish(with: .transport(String(describing: error)))
        }
    }

    private func expireRequest(id: Int, method: String) {
        resolveRequest(id: id, with: .failure(.requestTimedOut(method: method)))
    }

    private func cancelRequest(id: Int) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.deadlineTask.cancel()
        request.continuation.resume(throwing: CancellationError())
    }

    private func resolveRequest(
        id: Int,
        with result: Result<JSONValue, RPCError>
    ) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.deadlineTask.cancel()
        switch result {
        case let .success(value):
            request.continuation.resume(returning: value)
        case let .failure(error):
            request.continuation.resume(throwing: error)
        }
    }

    private func finish(with error: RPCError) {
        guard terminalError == nil else { return }
        terminalError = error
        readerTask?.cancel()
        readerTask = nil
        notificationHandler = nil
        let pendingRequests = pending.values
        pending.removeAll()
        for request in pendingRequests {
            request.deadlineTask.cancel()
            request.continuation.resume(throwing: error)
        }
        try? input.close()
        try? output.close()
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
