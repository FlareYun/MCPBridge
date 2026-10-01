import Foundation
import CryptoKit
import MCP

/// Metadata only. A catalog never authorizes a call or changes its execution context.
public struct ToolCatalog: Codable, Sendable {
    public let version: Int
    public let serverID: String
    public let configurationFingerprint: String
    public let capturedAt: Date
    public let tools: [[String: Value]]

    public static func fingerprint(_ server: ServerConfiguration) throws -> String {
        SHA256.hash(data: try BridgeJSON.encode(server)).map { String(format: "%02x", $0) }.joined()
    }

    public static func location(profileURL: URL, serverID: String) -> URL {
        let profile = profileURL.standardizedFileURL.resolvingSymlinksInPath()
        let key = SHA256.hash(data: Data((profile.path + "\n" + serverID).utf8))
            .map { String(format: "%02x", $0) }.joined()
        return profile.deletingLastPathComponent().appendingPathComponent("tool-cache", isDirectory: true)
            .appendingPathComponent(key + ".json")
    }

    public static func load(server: ServerConfiguration, profileURL: URL) throws -> ToolCatalog? {
        try server.validate()
        guard server.enabled else { throw BridgeError(2, "Server '\(server.id)' is disabled.") }
        let url = location(profileURL: profileURL, serverID: server.id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let size = attributes[.size] as? NSNumber, size.intValue <= 64 * 1024 * 1024 else {
                throw BridgeError(2, "Tool catalog exceeds the 64 MiB limit.")
            }
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let catalog = try decoder.decode(ToolCatalog.self, from: Data(contentsOf: url))
            guard catalog.version == 1, catalog.serverID == server.id,
                  catalog.configurationFingerprint == (try fingerprint(server)) else { return nil }
            guard !catalog.tools.isEmpty, catalog.tools.count <= 100_000,
                  catalog.tools.allSatisfy({ tool in
                      guard let name = tool["name"]?.stringValue, !name.isEmpty,
                            case .object = tool["inputSchema"] else { return false }
                      return true
                  }), Set(catalog.tools.compactMap { $0["name"]?.stringValue }).count == catalog.tools.count else {
                throw BridgeError(2, "Tool catalog contains invalid tool metadata.")
            }
            return catalog
        } catch {
            throw BridgeError(2, "Cannot read the tool catalog. Refresh tools in MCP Bridge or run 'tools list <server> --live' through your normal approval mechanism.")
        }
    }

    public func save(profileURL: URL) throws {
        let url = Self.location(profileURL: profileURL, serverID: serverID)
        let directory = url.deletingLastPathComponent()
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= 64 * 1024 * 1024 else { throw BridgeError(2, "Tool catalog exceeds the 64 MiB limit.") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func reply(operation: BridgeOperation, profileURL: URL, source: String = "cache", warnings: [String] = []) throws -> BridgeReply {
        var warnings = warnings
        if source == "cache" {
            warnings.append("Saved tool metadata; live availability and permissions have not been checked. Use --live to refresh. Tool calls always use a live connection and normal agent approvals.")
        }
        struct Metadata: Encodable {
            let source: String
            let capturedAt: String
            let ageSeconds: Int
            let path: String
        }
        struct Response: Encodable {
            let ok = true
            let server: String
            let operation: String
            let result: Value
            let catalog: Metadata
            let warnings: [String]
        }
        let result: Value
        switch operation {
        case .listTools: result = .object(["tools": .array(tools.map(Value.object))])
        case .describeTool(let name):
            guard let tool = tools.first(where: { $0["name"]?.stringValue == name }) else {
                throw BridgeError(2, source == "cache"
                    ? "Tool '\(name)' is absent from the saved catalog. Refresh with 'tools list <server> --live' or Discover & cache tools in the app. No tool was executed."
                    : "Tool '\(name)' was not published during live discovery. No tool was executed.")
            }
            result = .object(tool)
        default: throw BridgeError(2, "Catalogs support tool listing and description only; execution must use a live connection.")
        }
        return BridgeReply(data: try BridgeJSON.encode(Response(server: serverID, operation: operation.name, result: result,
            catalog: Metadata(source: source, capturedAt: ISO8601DateFormatter().string(from: capturedAt),
                              ageSeconds: max(0, Int(Date().timeIntervalSince(capturedAt))),
                              path: Self.location(profileURL: profileURL, serverID: serverID).path), warnings: warnings)))
    }
}

public enum ToolDiscovery {
    public enum Mode: Sendable { case automatic, cached, live }

    public static func execute(server: ServerConfiguration, profileURL: URL, operation: BridgeOperation,
                               mode: Mode = .automatic, timeout: Double? = nil,
                               liveExecutor: (@Sendable (BridgeOperation) async throws -> BridgeReply)? = nil) async throws -> BridgeReply {
        try server.validate()
        guard server.enabled else { throw BridgeError(2, "Server '\(server.id)' is disabled.") }
        switch operation {
        case .listTools, .describeTool: break
        default: throw BridgeError(2, "Discovery modes apply only to 'tools list' and 'tools describe'.")
        }
        var warnings: [String] = []
        if mode != .live {
            let saved: ToolCatalog?
            do { saved = try ToolCatalog.load(server: server, profileURL: profileURL) }
            catch {
                if mode == .cached { throw error }
                saved = nil
                warnings.append("The saved tool catalog could not be read; performing live discovery.")
            }
            if let saved { return try saved.reply(operation: operation, profileURL: profileURL) }
            if mode == .cached {
                throw BridgeError(2, "No saved tool catalog matches this server configuration. Use Discover & cache tools in the app or run 'tools list <server> --live' through your normal approval mechanism. No server was started.")
            }
        }
        // Exactly one discovery operation; never retry a failed or timed-out request.
        let live: BridgeReply
        if let liveExecutor { live = try await liveExecutor(.listTools) }
        else { live = try await BridgeRunner.execute(server: server, operation: .listTools, timeout: timeout) }
        struct LiveResult: Decodable {
            struct Payload: Decodable { let tools: [[String: Value]] }
            let result: Payload
            let warnings: [String]?
        }
        let decoded = try JSONDecoder().decode(LiveResult.self, from: live.data)
        warnings += decoded.warnings ?? []
        let catalog = ToolCatalog(version: 1, serverID: server.id,
            configurationFingerprint: try ToolCatalog.fingerprint(server), capturedAt: Date(), tools: decoded.result.tools)
        if catalog.tools.isEmpty {
            warnings.append("Any previously saved catalog was preserved. Use --cached to read it; an empty live list does not establish whether the upstream app is open.")
        } else {
            do { try catalog.save(profileURL: profileURL) }
            catch { warnings.append("Live discovery succeeded, but the catalog could not be saved. Choose a writable profile location or refresh from the desktop app.") }
        }
        return try catalog.reply(operation: operation, profileURL: profileURL, source: "live", warnings: warnings)
    }
}
