import Foundation

/// Sessions explicitly enabled by the desktop app. Requests are serialized per server.
public actor PersistentSessions {
    private struct Entry {
        let id = UUID()
        let configuration: ServerConfiguration
        let session: BridgeSession
    }
    private var entries: [String: Entry] = [:]
    private var busy = Set<String>()
    public init() {}

    public func statuses() async -> [String: String] {
        var result: [String: String] = [:]
        for (id, entry) in entries {
            result[id] = await entry.session.isConnected() ? "Connected" : (busy.contains(id) ? "Connecting" : "Disconnected · reconnect required")
        }
        return result
    }

    public func connect(_ server: ServerConfiguration) async throws {
        try server.validate()
        guard server.enabled else { throw BridgeError(2, "Server is disabled.") }
        _ = try await limited(seconds: server.timeout) {
            try await self.connectSerial(server)
        }
    }

    private func acquire(_ id: String) async throws {
        while busy.contains(id) { try await Task.sleep(for: .milliseconds(20)) }
        try Task.checkCancellation()
        busy.insert(id)
    }

    private func connectSerial(_ server: ServerConfiguration) async throws -> BridgeReply {
        try await acquire(server.id)
        defer { busy.remove(server.id) }
        if let existing = entries[server.id] {
            if existing.configuration == server, await existing.session.isConnected() {
                return try await run(existing, operation: .test)
            }
            await existing.session.close()
        }
        let entry = Entry(configuration: server, session: BridgeSession(server: server, timeout: 86400))
        entries[server.id] = entry
        return try await run(entry, operation: .test)
    }

    public func execute(server: ServerConfiguration, operation: BridgeOperation, timeout: Double? = nil) async throws -> BridgeReply {
        try server.validate()
        guard server.enabled else { throw BridgeError(2, "Server is disabled.") }
        if case .callTool(let name, let data) = operation {
            guard !name.isEmpty else { throw BridgeError(2, "A tool name is required.") }
            _ = try BridgeRunner.arguments(data)
        }
        return try await limited(seconds: timeout ?? server.timeout) {
            try await self.executeSerial(server: server, operation: operation)
        }
    }

    private func executeSerial(server: ServerConfiguration, operation: BridgeOperation) async throws -> BridgeReply {
        try await acquire(server.id)
        defer { busy.remove(server.id) }
        guard let entry = entries[server.id], entry.configuration == server else {
            throw BridgeError(3, "No shared session matches this configuration. Connect this server in MCP Bridge. No tool was executed.")
        }
        guard await entry.session.isConnected() else {
            throw BridgeError(3, "Shared session disconnected. Reconnect in MCP Bridge. No tool was executed or retried.")
        }
        return try await run(entry, operation: operation)
    }

    private func run(_ entry: Entry, operation: BridgeOperation) async throws -> BridgeReply {
        try await withTaskCancellationHandler {
            do {
                let reply = try await entry.session.run(operation)
                try Task.checkCancellation()
                return reply
            } catch {
                // Close on all request failures; never silently replace a session or replay a call.
                await entry.session.close()
                throw error
            }
        } onCancel: {
            Task { await entry.session.abort(BridgeError(3, "Shared operation cancelled; execution was not retried.")) }
        }
    }

    public func disconnect(_ id: String) async {
        guard let entry = entries.removeValue(forKey: id) else { return }
        await entry.session.abort(BridgeError(3, "Session disconnected by the app. Execution was not retried."))
    }

    public func close() async {
        let current = entries
        entries.removeAll()
        for entry in current.values { await entry.session.abort(BridgeError(3, "MCP Bridge is closing. Execution was not retried.")) }
    }

    private func limited(seconds: Double, operation: @escaping @Sendable () async throws -> BridgeReply) async throws -> BridgeReply {
        guard seconds.isFinite, seconds > 0, seconds <= 86400 else { throw BridgeError(2, "Timeout must be between 0 and 86400 seconds.") }
        return try await withThrowingTaskGroup(of: BridgeReply.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw BridgeError(5, "Shared operation timed out. Execution was not retried; a tool may already have completed.")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}
