import Foundation
import MCP
import Logging

/// The SDK tolerates undecodable messages. A command-line operation instead needs
/// a prompt, bounded failure when its server sends invalid JSON-RPC or closes early.
actor CheckedTransport: Transport {
    nonisolated let logger = Logger(label: "MCPBridge.Transport", factory: { _ in SwiftLogNoOpLogHandler() })
    private let base: any Transport
    private let onFailure: @Sendable (BridgeError) -> Void
    private let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var reader: Task<Void, Never>?
    private var closed = false

    init(base: any Transport, onFailure: @escaping @Sendable (BridgeError) -> Void) {
        self.base = base; self.onFailure = onFailure
        let pair = AsyncThrowingStream<Data, Error>.makeStream()
        stream = pair.stream; continuation = pair.continuation
    }

    func connect() async throws {
        try await base.connect()
        reader = Task {
            do {
                for try await data in await base.receive() {
                    if closed || Task.isCancelled { break }
                    guard data.count <= 32 * 1024 * 1024, Self.validMessage(data) else {
                        throw BridgeError(3, "Server sent an invalid JSON-RPC message or exceeded the 32 MiB message limit.")
                    }
                    continuation.yield(data)
                }
                if !closed && !Task.isCancelled { throw BridgeError(3, "Server connection closed before completing the operation.") }
            } catch {
                if !closed && !Task.isCancelled {
                    onFailure(error as? BridgeError ?? BridgeError(3, "MCP transport failed while receiving a response."))
                }
            }
            continuation.finish()
        }
    }

    func disconnect() async {
        closed = true; reader?.cancel()
        await base.disconnect()
        continuation.finish()
        await reader?.value
        reader = nil
    }
    func send(_ data: Data) async throws { try await base.send(data) }
    func receive() -> AsyncThrowingStream<Data, Error> { stream }

    private static func validMessage(_ data: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return false }
        func valid(_ object: Any) -> Bool {
            guard let message = object as? [String: Any], message["jsonrpc"] as? String == "2.0" else { return false }
            if message["method"] is String { return message["result"] == nil && message["error"] == nil }
            return message["id"] != nil && ((message["result"] != nil) != (message["error"] != nil))
        }
        if let batch = json as? [Any] { return !batch.isEmpty && batch.allSatisfy(valid) }
        return valid(json)
    }
}
