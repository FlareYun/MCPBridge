import Foundation
import BridgeCore
#if canImport(Darwin)
import Darwin
import Security
#elseif canImport(Glibc)
import Glibc
#endif

@main
struct BridgeCLI {
    static let help = """
    MCP Bridge 1.2.0 — local command interface for MCP tools

    mcp-bridge servers list
    mcp-bridge server add <server> --server-file <path> | --stdin
    mcp-bridge server update <server> --server-file <path> | --stdin
    mcp-bridge server show <server>
    mcp-bridge server remove <server>
    mcp-bridge server test <server>
    mcp-bridge tools list <server>
    mcp-bridge tools describe <server> <tool>
    mcp-bridge call <server> <tool> --args-file <path>
    mcp-bridge call <server> <tool> --stdin

    Options: --config <profile.json>  --timeout <seconds>  --cached  --live  --session  --direct  --help  --version
    Add accepts a server JSON object; update changes only supplied fields (maps are replaced).
    Configuration commands save locally without connecting or resolving credentials.
    Tool list/describe use saved metadata when available. --cached never connects; --live refreshes.
    Calls use the app session when Keep connected is enabled; otherwise they connect directly.
    --session requires the app session; --direct explicitly uses a separate connection.
    Shared calls execute in the desktop app’s context. Normal agent approvals still apply.
    Options may appear before or after the command. Default timeout: 60 seconds.
    Arguments must be a JSON object. Output is one JSON document; diagnostics use stderr.
    Exit codes: 0 success, 2 input/config, 3 connection/protocol/cancelled, 4 tool error, 5 timeout.
    """

    static func main() async {
        // Legacy macOS Keychain ACL prompts are not covered by LAContext alone.
        // A command-line agent must fail promptly instead of waiting for an invisible prompt.
        #if os(macOS)
        _ = SecKeychainSetUserInteractionAllowed(false)
        #endif
        signal(SIGPIPE, SIG_IGN)
        let args = Array(CommandLine.arguments.dropFirst())
        if args == ["--help"] || args == ["-h"] || args.isEmpty { print(help); return }
        if args == ["--version"] { print("1.2.0"); return }
        let task = Task { try await run(args) }
        signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        interrupt.setEventHandler(handler: { @Sendable in task.cancel() })
        terminate.setEventHandler(handler: { @Sendable in task.cancel() })
        interrupt.resume(); terminate.resume()
        let code: Int32
        do {
            let reply = try await task.value
            FileHandle.standardOutput.write(reply.data + Data([10])); code = reply.exitCode
        } catch {
            let error = error as? BridgeError ?? (error is CancellationError ? BridgeError(3, "Operation cancelled.") : BridgeError(2, "Could not read input. Check the file path and permissions."))
            FileHandle.standardOutput.write(BridgeJSON.error(error) + Data([10]))
            FileHandle.standardError.write(Data((error.message + "\n").utf8)); code = error.code
        }
        interrupt.cancel(); terminate.cancel()
        exit(code)
    }

    static func run(_ args: [String]) async throws -> BridgeReply {
        var positional: [String] = [], config = ProfileStore.defaultURL, timeout: Double?
        var argsFile: String?, serverFile: String?, useStdin = false, i = 0, seen = Set<String>()
        var requireSession = false, direct = false
        var discoveryMode = ToolDiscovery.Mode.automatic
        while i < args.count {
            let arg = args[i]
            if arg.hasPrefix("--") {
                guard seen.insert(arg).inserted else { throw BridgeError(2, "Duplicate option '\(arg)'.") }
                switch arg {
                case "--stdin": useStdin = true
                case "--session": requireSession = true
                case "--direct": direct = true
                case "--cached", "--live":
                    guard !seen.contains(arg == "--cached" ? "--live" : "--cached") else {
                        throw BridgeError(2, "Use either --cached or --live, not both.")
                    }
                    discoveryMode = arg == "--cached" ? .cached : .live
                case "--config", "--timeout", "--args-file", "--server-file":
                    i += 1; guard i < args.count else { throw BridgeError(2, "Missing value for '\(arg)'.") }
                    switch arg {
                    case "--config":
                        config = URL(fileURLWithPath: args[i])
                    case "--timeout":
                        guard let n = Double(args[i]), n.isFinite, n > 0, n <= 86400 else { throw BridgeError(2, "Timeout must be between 0 and 86400 seconds.") }
                        timeout = n
                    case "--server-file": serverFile = args[i]
                    default: argsFile = args[i]
                    }
                default: throw BridgeError(2, "Unknown option '\(arg)'. Run --help for usage.")
                }
            } else { positional.append(arg) }
            i += 1
        }
        if discoveryMode != .automatic {
            guard positional.count >= 2, positional[0] == "tools", ["list", "describe"].contains(positional[1]) else {
                throw BridgeError(2, "--cached and --live apply only to tools list/describe. Calls always connect live.")
            }
        }
        guard !(requireSession && direct) else { throw BridgeError(2, "Use either --session or --direct, not both.") }
        if positional.count == 3, positional[0] == "server", ["add", "update", "show", "remove"].contains(positional[1]) {
            guard seen.isDisjoint(with: ["--timeout", "--cached", "--live", "--session", "--direct", "--args-file"]) else {
                throw BridgeError(2, "Configuration commands accept only --config and, for add/update, --server-file or --stdin.")
            }
            let action = positional[1]
            let needsInput = action == "add" || action == "update"
            guard needsInput ? useStdin != (serverFile != nil) : !useStdin && serverFile == nil else {
                throw BridgeError(2, needsInput ? "Use exactly one of --stdin or --server-file for server configuration." : "Input is only supported for server add/update.")
            }
            if action != "add", seen.contains("--config"), !FileManager.default.fileExists(atPath: config.path) {
                throw BridgeError(2, "Explicit configuration file does not exist.")
            }
            let input = needsInput ? try await readInput(path: serverFile) : nil
            return try ServerManagement.execute(action: action, id: positional[2], input: input, profileURL: config)
        }
        guard serverFile == nil else { throw BridgeError(2, "--server-file applies only to server add/update.") }
        if seen.contains("--config"), !FileManager.default.fileExists(atPath: config.path) {
            throw BridgeError(2, "Explicit configuration file does not exist.")
        }
        let profile = try ProfileStore.load(config)
        if positional == ["servers", "list"] {
            guard argsFile == nil, !useStdin else { throw BridgeError(2, "Argument input is only supported for 'call'.") }
            struct ListedServer: Encodable { let id: String; let transport: String; let enabled: Bool }
            struct ServerList: Encodable { let ok = true; let servers: [ListedServer] }
            return BridgeReply(data: try BridgeJSON.encode(ServerList(servers: profile.servers.map { .init(id: $0.id, transport: $0.transport.rawValue, enabled: $0.enabled) })))
        }
        let operation: BridgeOperation
        let serverID: String
        if positional.count == 3 && positional[0] == "server" && positional[1] == "test" {
            operation = .test; serverID = positional[2]
        } else if positional.count == 3 && positional[0] == "tools" && positional[1] == "list" {
            operation = .listTools; serverID = positional[2]
        } else if positional.count == 4 && positional[0] == "tools" && positional[1] == "describe" {
            operation = .describeTool(positional[3]); serverID = positional[2]
        } else if positional.count == 3 && positional[0] == "call" {
            guard useStdin != (argsFile != nil) else { throw BridgeError(2, "Use exactly one of --stdin or --args-file for tool arguments.") }
            // Resolve the server before potentially blocking on stdin.
            _ = try profile.server(positional[1])
            let data = try await readInput(path: argsFile)
            operation = .callTool(positional[2], data); serverID = positional[1]
        } else { throw BridgeError(2, "Invalid command. Run --help for usage.") }
        if positional[0] != "call" && (useStdin || argsFile != nil) { throw BridgeError(2, "Argument input is only supported for 'call'.") }
        let server = try profile.server(serverID)
        let useSession = !direct && (requireSession || server.keepConnected)
        #if !os(macOS)
        if useSession {
            throw BridgeError(2, "App-owned shared sessions are only available on macOS. Use --direct for this call.")
        }
        #endif
        let profileURL = config, limit = timeout
        let executor: @Sendable (BridgeOperation) async throws -> BridgeReply = { operation in
            if useSession {
                return try await SessionClient.execute(server: server, profileURL: profileURL, operation: operation, timeout: limit)
            }
            return try await BridgeRunner.execute(server: server, operation: operation, timeout: limit)
        }
        if positional[0] == "tools" {
            return try await ToolDiscovery.execute(server: server, profileURL: config, operation: operation, mode: discoveryMode, timeout: timeout, liveExecutor: executor)
        }
        return try await executor(operation)
    }

    static func readInput(path: String?) async throws -> Data {
        if let path {
            let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            defer { try? file.close() }
            return try readArguments(file)
        }
        let reader = Task.detached { try readArguments(FileHandle.standardInput) }
        return try await withTaskCancellationHandler { try await reader.value } onCancel: { reader.cancel() }
    }

    static func readArguments(_ file: FileHandle) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            try Task.checkCancellation()
            var descriptor = pollfd(fd: file.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 100)
            if ready == 0 { continue }
            if ready < 0 {
                if errno == EINTR { continue }
                throw BridgeError(2, "Could not read argument input.")
            }
            let count = read(file.fileDescriptor, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw BridgeError(2, "Could not read argument input.")
            }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= 16 * 1024 * 1024 else { throw BridgeError(2, "Arguments exceed the 16 MiB limit.") }
        }
        return data
    }
}
