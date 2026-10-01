import Foundation
import MCP
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum BridgeOperation: Codable, Sendable {
    case test, listTools, describeTool(String), callTool(String, Data)
    var name: String {
        switch self { case .test: "server.test"; case .listTools: "tools.list"; case .describeTool: "tools.describe"; case .callTool: "tools.call" }
    }
}

public struct BridgeReply: Codable, Sendable {
    public let data: Data
    public let exitCode: Int32
    public var text: String { String(decoding: data, as: UTF8.self) }
    public init(data: Data, exitCode: Int32 = 0) { self.data = data; self.exitCode = exitCode }
}

private struct Envelope<T: Encodable>: Encodable {
    let ok: Bool
    let server: String
    let operation: String
    let result: T
    let warnings: [String]?
}

public enum BridgeJSON {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    public static func error(_ error: BridgeError) -> Data {
        struct Failure: Encodable {
            struct Detail: Encodable { let code: Int32; let message: String }
            let ok = false
            let error: Detail
        }
        return (try? encode(Failure(error: .init(code: error.code, message: error.message)))) ?? Data("{\"ok\":false}".utf8)
    }
}

public enum BridgeRunner {
    public static func execute(server: ServerConfiguration, operation: BridgeOperation, timeout: Double? = nil) async throws -> BridgeReply {
        try server.validate()
        guard server.enabled else { throw BridgeError(2, "Server '\(server.id)' is disabled.") }
        let seconds = timeout ?? server.timeout
        guard seconds.isFinite, seconds > 0, seconds <= 86400 else { throw BridgeError(2, "Timeout must be between 0 and 86400 seconds.") }
        // Validate input before launching any server process.
        if case .callTool(let name, let data) = operation {
            guard !name.isEmpty else { throw BridgeError(2, "A tool name is required.") }
            _ = try arguments(data)
        }
        let session = BridgeSession(server: server, timeout: seconds)
        return try await withTaskCancellationHandler {
            do {
                let reply = try await withThrowingTaskGroup(of: BridgeReply.self) { group in
                    group.addTask { try await session.run(operation) }
                    group.addTask {
                        try await Task.sleep(for: .seconds(seconds))
                        let error = BridgeError(5, "Operation timed out after \(seconds) seconds. Execution was not retried; a remote tool may already have completed.")
                        await session.abort(error)
                        throw error
                    }
                    defer { group.cancelAll() }
                    guard let first = try await group.next() else { throw BridgeError(3, "Operation ended without a result.") }
                    return first
                }
                await session.close()
                try Task.checkCancellation()
                return reply
            } catch {
                await session.close()
                if Task.isCancelled { throw BridgeError(3, "Operation cancelled. Execution was not retried; a remote tool may already have completed.") }
                if let known = error as? BridgeError { throw known }
                throw BridgeError(3, "MCP connection or protocol failed. Check the server executable, endpoint, and credentials.")
            }
        } onCancel: {
            Task { await session.abort(BridgeError(3, "Operation cancelled.")) }
        }
    }

    static func arguments(_ data: Data) throws -> [String: Value] {
        guard data.count <= 16 * 1024 * 1024 else { throw BridgeError(2, "Arguments exceed the 16 MiB limit.") }
        do { return try JSONDecoder().decode([String: Value].self, from: data) }
        catch { throw BridgeError(2, "Tool arguments must be a valid JSON object.") }
    }
}

actor BridgeSession {
    let server: ServerConfiguration
    let timeout: Double
    let client = Client(name: "MCPBridge", version: "1.1.0")
    var initialization: Initialize.Result?
    var toolListRevision: UInt64 = 0
    var process: Process?
    var inputPipe: Pipe?
    var outputPipe: Pipe?
    var httpTransport: HTTPClientTransport?
    var closed = false
    var abortError: BridgeError?
    var closeTask: Task<Void, Never>?
    var ownsProcessGroup = false
    var resolvedHTTPHeaders: [String: String] = [:]

    init(server: ServerConfiguration, timeout: Double) { self.server = server; self.timeout = timeout }

    func run(_ operation: BridgeOperation) async throws -> BridgeReply {
        do {
            try Task.checkCancellation()
            if let abortError { throw abortError }
            if closed { throw BridgeError(3, "Session is disconnected. Reconnect in MCP Bridge; no call was retried.") }
            if initialization == nil {
                let transport: any Transport
                switch server.transport {
                case .stdio:
                    let inherited = ProcessInfo.processInfo.environment
                    var environment = inherited.filter { ["PATH", "HOME", "TMPDIR", "USER", "LOGNAME", "LANG", "LC_ALL", "SHELL"].contains($0.key) }
                    #if os(macOS)
                    environment["PATH"] = environment["PATH"] ?? "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
                    #else
                    environment["PATH"] = environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin"
                    #endif
                    for (key, ref) in server.environment { environment[key] = try ref.resolve() }
                    let executable = try Self.resolveExecutable(server.command!, path: environment["PATH"] ?? "")
                    let child = Process()
                    child.executableURL = URL(fileURLWithPath: executable)
                    child.arguments = server.arguments
                    child.environment = environment
                    if let cwd = server.workingDirectory {
                        var directory: ObjCBool = false
                        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &directory), directory.boolValue else {
                            throw BridgeError(2, "Configured working directory does not exist.")
                        }
                        child.currentDirectoryURL = URL(fileURLWithPath: cwd)
                    }
                    let stdinPipe = Pipe(), stdoutPipe = Pipe()
                    child.standardInput = stdinPipe; child.standardOutput = stdoutPipe
                    // Server stderr can include secrets. Do not copy it into logs or protocol output.
                    child.standardError = FileHandle.nullDevice
                    child.terminationHandler = { @Sendable [weak self] child in
                        Task { await self?.processExited(child.terminationStatus) }
                    }
                    process = child; inputPipe = stdinPipe; outputPipe = stdoutPipe
                    do { try child.run() }
                    catch { throw BridgeError(3, "Could not launch the server. Check executable permissions, arguments, runtime dependencies, and working directory.") }
                    ownsProcessGroup = getpgid(child.processIdentifier) == child.processIdentifier
                    try? stdinPipe.fileHandleForReading.close()
                    try? stdoutPipe.fileHandleForWriting.close()
                    transport = StdioTransport(input: .init(rawValue: stdoutPipe.fileHandleForReading.fileDescriptor),
                                               output: .init(rawValue: stdinPipe.fileHandleForWriting.fileDescriptor))
                case .http:
                    var headers: [String: String] = [:]
                    for (name, ref) in server.headers { headers[name] = try ref.resolve() }
                    if let token = server.bearerToken { headers["Authorization"] = "Bearer \(try token.resolve())" }
                    guard headers.values.allSatisfy({ !$0.contains("\r") && !$0.contains("\n") }) else { throw BridgeError(2, "Header values cannot contain newlines.") }
                    let resolvedHeaders = headers
                    resolvedHTTPHeaders = headers
                    let configuration = URLSessionConfiguration.ephemeral
                    configuration.protocolClasses = [NoRedirectURLProtocol.self]
                    configuration.timeoutIntervalForRequest = timeout
                    configuration.timeoutIntervalForResource = timeout
                    configuration.httpCookieStorage = nil
                    let http = HTTPClientTransport(endpoint: URL(string: server.url!)!, configuration: configuration, streaming: false, requestModifier: { request in
                        var request = request
                        for (name, value) in resolvedHeaders { request.setValue(value, forHTTPHeaderField: name) }
                        return request
                    })
                    httpTransport = http; transport = http
                }
                let checked = CheckedTransport(base: transport) { [weak self] error in
                    Task { await self?.abort(error) }
                }
                // Register before initialization: a proxy may publish tools immediately after it.
                await client.onNotification(ToolListChangedNotification.self) { [weak self] _ in
                    await self?.toolListChanged()
                }
                let initialized = try await client.connect(transport: checked)
                await httpTransport?.updateNegotiatedProtocolVersion(initialized.protocolVersion)
                initialization = initialized
            }
            guard let initialized = initialization else { throw BridgeError(3, "Session initialization failed.") }
            if let abortError { throw abortError }
            try Task.checkCancellation()
            switch operation {
            case .test:
                return try reply(initialized, operation)
            case .listTools, .describeTool:
                let target: String?
                if case .describeTool(let name) = operation { target = name } else { target = nil }
                let tools = try await discoverTools(target: target, dynamic: initialized.capabilities.tools?.listChanged == true)
                if case .describeTool(let name) = operation {
                    guard let tool = tools.first(where: { $0.name == name }) else { throw unavailableTool(name) }
                    return try reply(tool, operation)
                }
                return try reply(ListTools.Result(tools: tools), operation, warnings: tools.isEmpty ? ["Server connected but published no tools during live discovery. This does not establish whether the upstream app is open. If discovery works in Terminal or the desktop app but not in an agent, check the agent sandbox and request the same read-only discovery through its normal approval mechanism. Otherwise check upstream MCP settings and discoveryWait. No tool was executed."] : nil)
            case .callTool(let name, let data):
                // Every invocation owns a fresh connection, so dynamic servers need readiness here too.
                if initialized.capabilities.tools?.listChanged == true {
                    let tools = try await discoverTools(target: name, dynamic: true)
                    guard tools.contains(where: { $0.name == name }) else { throw unavailableTool(name) }
                }
                let context: RequestContext<CallTool.Result> = try await client.send(CallTool.request(.init(name: name, arguments: try BridgeRunner.arguments(data))))
                let result = try await context.value
                return try reply(result, operation, exitCode: result.isError == true ? 4 : 0)
            }
        } catch {
            if let abortError { throw abortError }
            if let known = error as? BridgeError { throw known }
            if error is CancellationError { throw BridgeError(3, "Operation cancelled.") }
            // Only emit recognized diagnostic categories; server error text may contain credentials.
            let diagnostic = String(describing: error).lowercased()
            if diagnostic.contains("authentication required") || diagnostic.contains("access forbidden") {
                throw BridgeError(3, "Server rejected authentication or access. Configure a bearer token/header reference or check server permissions. Browser OAuth is not supported in this version.")
            }
            throw BridgeError(3, "MCP connection or protocol failed. Check the server executable, endpoint, credentials, and MCP compatibility.")
        }
    }

    private func toolListChanged() { toolListRevision &+= 1 }

    private func unavailableTool(_ name: String) -> BridgeError {
        BridgeError(2, "Tool '\(name)' was not published during discovery. If discovery works in Terminal or the desktop app but not in an agent, check the agent sandbox and use its normal approval mechanism. Cached metadata cannot make live tools available. Check upstream MCP settings and discoveryWait. No tool was executed.")
    }

    private func discoverTools(target: String?, dynamic: Bool) async throws -> [Tool] {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(dynamic ? server.discoveryWait : 0))
        while true {
            let revision = toolListRevision
            var tools: [Tool] = [], cursor: String?, seen = Set<String>()
            repeat {
                try Task.checkCancellation()
                if let abortError { throw abortError }
                let page = try await client.listTools(cursor: cursor)
                tools += page.tools
                cursor = page.nextCursor
                if let cursor, !seen.insert(cursor).inserted { throw BridgeError(3, "Server repeated a pagination cursor.") }
                guard tools.count <= 100_000 else { throw BridgeError(3, "Server tool catalog exceeds the supported size.") }
            } while cursor != nil
            let ready = target.map { name in tools.contains { $0.name == name } } ?? !tools.isEmpty
            if ready || !dynamic || clock.now >= deadline { return tools }
            // Refresh on notification, with a read-only polling fallback for HTTP transports
            // without a notification stream. Never retry a failed request or a tools/call.
            let refreshAt = min(deadline, clock.now.advanced(by: .milliseconds(250)))
            while toolListRevision == revision && clock.now < refreshAt {
                try await clock.sleep(until: min(refreshAt, clock.now.advanced(by: .milliseconds(20))))
                if let abortError { throw abortError }
            }
        }
    }

    private func reply<T: Encodable>(_ result: T, _ operation: BridgeOperation, exitCode: Int32 = 0, warnings: [String]? = nil) throws -> BridgeReply {
        BridgeReply(data: try BridgeJSON.encode(Envelope(ok: exitCode == 0, server: server.id, operation: operation.name, result: result, warnings: warnings)), exitCode: exitCode)
    }

    func isConnected() -> Bool { initialization != nil && !closed && abortError == nil }

    func abort(_ error: BridgeError) async {
        if abortError == nil { abortError = error }
        await close()
    }

    func processExited(_ status: Int32) async {
        guard !closed else { return }
        await abort(BridgeError(3, "Server process exited before completing the operation (status \(status)). Check its runtime dependencies and launch configuration."))
    }

    func close() async {
        if let closeTask { await closeTask.value; return }
        closed = true
        let child = process, stdinPipe = inputPipe, stdoutPipe = outputPipe
        let client = client, http = httpTransport, ownsGroup = ownsProcessGroup
        let endpoint = server.url, headers = resolvedHTTPHeaders
        let cleanup = Task.detached {
            let sessionID = await http?.sessionID
            let protocolVersion = await http?.protocolVersion
            if let child, child.isRunning {
                if ownsGroup { kill(-child.processIdentifier, SIGTERM) } else { child.terminate() }
            }
            await client.disconnect()
            try? stdinPipe?.fileHandleForWriting.close()
            try? stdoutPipe?.fileHandleForReading.close()
            if let child {
                for _ in 0..<20 {
                    if !child.isRunning { break }
                    try? await Task.sleep(for: .milliseconds(25))
                }
                if ownsGroup { kill(-child.processIdentifier, SIGKILL) }
                else if child.isRunning { kill(child.processIdentifier, SIGKILL) }
                if child.processIdentifier > 0 { child.waitUntilExit() }
            }
            if let sessionID, let endpoint, let url = URL(string: endpoint) {
                let config = URLSessionConfiguration.ephemeral
                config.protocolClasses = [NoRedirectURLProtocol.self]
                config.timeoutIntervalForRequest = 1; config.timeoutIntervalForResource = 1
                let session = URLSession(configuration: config)
                var request = URLRequest(url: url); request.httpMethod = "DELETE"
                request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
                request.setValue(protocolVersion, forHTTPHeaderField: "Mcp-Protocol-Version")
                for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
                _ = try? await session.data(for: request)
                session.invalidateAndCancel()
            }
        }
        closeTask = cleanup
        await cleanup.value
        process = nil; inputPipe = nil; outputPipe = nil; httpTransport = nil
    }

    static func resolveExecutable(_ command: String, path: String) throws -> String {
        let fm = FileManager.default
        if command.hasPrefix("/"), fm.isExecutableFile(atPath: command) { return command }
        if !command.contains("/") {
            for directory in path.split(separator: ":") where directory.hasPrefix("/") {
                let candidate = String(directory) + "/" + command
                if fm.isExecutableFile(atPath: candidate) { return candidate }
            }
        }
        throw BridgeError(2, "Executable not found. Use an absolute executable path or install the runtime and add it to PATH.")
    }
}
