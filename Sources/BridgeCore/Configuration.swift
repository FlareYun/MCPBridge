import Foundation
import Security
import LocalAuthentication

public struct BridgeError: Error, Sendable, LocalizedError {
    public let code: Int32
    public let message: String
    public init(_ code: Int32 = 2, _ message: String) { self.code = code; self.message = message }
    public var errorDescription: String? { message }
}

public struct SecretReference: Codable, Sendable, Equatable {
    public enum Source: String, Codable, Sendable { case environment, keychain }
    public var source: Source
    public var name: String
    public init(source: Source = .environment, name: String) { self.source = source; self.name = name }
    public func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> String {
        switch source {
        case .environment:
            guard let value = environment[name], !value.isEmpty else {
                throw BridgeError(2, "Missing environment variable '\(name)'. Set it in the invoking environment or use a Keychain reference.")
            }
            return value
        case .keychain: return try CredentialStore.read(name)
        }
    }
}

public struct ServerConfiguration: Codable, Sendable, Equatable, Identifiable {
    public enum Transport: String, Codable, Sendable, CaseIterable { case stdio, http }
    public var id: String
    public var transport: Transport
    public var enabled: Bool
    public var command: String?
    public var arguments: [String]
    public var url: String?
    public var workingDirectory: String?
    public var environment: [String: SecretReference]
    public var headers: [String: SecretReference]
    public var bearerToken: SecretReference?
    public var timeout: Double
    public var keepConnected: Bool
    public var discoveryWait: Double

    public init(id: String = "new-server", transport: Transport = .stdio, enabled: Bool = true,
                command: String? = nil, arguments: [String] = [], url: String? = nil,
                workingDirectory: String? = nil, environment: [String: SecretReference] = [:],
                headers: [String: SecretReference] = [:], bearerToken: SecretReference? = nil,
                timeout: Double = 60, discoveryWait: Double = 10, keepConnected: Bool = false) {
        self.id = id; self.transport = transport; self.enabled = enabled; self.command = command
        self.arguments = arguments; self.url = url; self.workingDirectory = workingDirectory
        self.environment = environment; self.headers = headers; self.bearerToken = bearerToken; self.timeout = timeout
        self.discoveryWait = discoveryWait
        self.keepConnected = keepConnected
    }

    enum CodingKeys: String, CodingKey { case id, transport, enabled, command, arguments, url, workingDirectory, environment, headers, bearerToken, timeout, discoveryWait, keepConnected }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        transport = try c.decode(Transport.self, forKey: .transport)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        command = try c.decodeIfPresent(String.self, forKey: .command)
        arguments = try c.decodeIfPresent([String].self, forKey: .arguments) ?? []
        url = try c.decodeIfPresent(String.self, forKey: .url)
        workingDirectory = try c.decodeIfPresent(String.self, forKey: .workingDirectory)
        environment = try c.decodeIfPresent([String: SecretReference].self, forKey: .environment) ?? [:]
        headers = try c.decodeIfPresent([String: SecretReference].self, forKey: .headers) ?? [:]
        bearerToken = try c.decodeIfPresent(SecretReference.self, forKey: .bearerToken)
        timeout = try c.decodeIfPresent(Double.self, forKey: .timeout) ?? 60
        keepConnected = try c.decodeIfPresent(Bool.self, forKey: .keepConnected) ?? false
        discoveryWait = try c.decodeIfPresent(Double.self, forKey: .discoveryWait) ?? 10
    }

    public func validate() throws {
        guard !id.isEmpty, id.count <= 100, id.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil else {
            throw BridgeError(2, "Server IDs must contain letters, digits, dots, underscores or hyphens, starting with a letter or digit.")
        }
        guard timeout.isFinite, timeout > 0, timeout <= 86400 else { throw BridgeError(2, "Timeout must be between 0 and 86400 seconds.") }
        guard discoveryWait.isFinite, discoveryWait >= 0, discoveryWait <= 86400 else { throw BridgeError(2, "Discovery wait must be between 0 and 86400 seconds.") }
        switch transport {
        case .stdio:
            guard let command, !command.isEmpty, !command.contains("\0") else { throw BridgeError(2, "A stdio server requires an executable command.") }
            guard arguments.allSatisfy({ !$0.contains("\0") }) else { throw BridgeError(2, "Arguments cannot contain NUL characters.") }
        case .http:
            guard let url, let u = URL(string: url), let host = u.host, !host.isEmpty,
                  ["https", "http"].contains(u.scheme?.lowercased() ?? ""), u.user == nil, u.password == nil, u.fragment == nil else {
                throw BridgeError(2, "An HTTP server requires an http(s) URL without embedded credentials or a fragment.")
            }
            if u.scheme == "http" && !["localhost", "127.0.0.1", "[::1]", "::1"].contains(host.lowercased()) {
                throw BridgeError(2, "Use HTTPS for remote servers. Plain HTTP is supported only for loopback servers.")
            }
        }
        for (key, ref) in environment {
            guard key.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil, !ref.name.isEmpty else {
                throw BridgeError(2, "Environment mappings require valid variable names and nonempty references.")
            }
        }
        for (key, ref) in headers {
            guard key.range(of: "^[!#$%&'*+.^_`|~A-Za-z0-9-]+$", options: .regularExpression) != nil, !ref.name.isEmpty else {
                throw BridgeError(2, "Header mappings require valid header names and nonempty references.")
            }
            guard !["host", "content-length", "mcp-session-id", "mcp-protocol-version", "accept", "content-type"].contains(key.lowercased()) else {
                throw BridgeError(2, "Header '\(key)' is managed by the transport.")
            }
        }
        guard Set(headers.keys.map { $0.lowercased() }).count == headers.count else { throw BridgeError(2, "Header names must be unique, ignoring case.") }
        if bearerToken != nil && headers.keys.contains(where: { $0.lowercased() == "authorization" }) {
            throw BridgeError(2, "Configure either a bearer token or an Authorization header, not both.")
        }
        if let bearerToken, bearerToken.name.isEmpty { throw BridgeError(2, "A bearer token reference needs a name.") }
        if let workingDirectory, !workingDirectory.hasPrefix("/") { throw BridgeError(2, "Working directories must be absolute paths.") }
    }
}

public struct BridgeProfile: Codable, Sendable, Equatable {
    public var version: Int
    public var servers: [ServerConfiguration]
    public init(version: Int = 1, servers: [ServerConfiguration] = []) { self.version = version; self.servers = servers }
    public func validate() throws {
        guard version == 1 else { throw BridgeError(2, "Unsupported profile version. Expected version 1.") }
        guard Set(servers.map(\.id)).count == servers.count else { throw BridgeError(2, "Server IDs must be unique.") }
        for server in servers { try server.validate() }
    }
    public func server(_ id: String) throws -> ServerConfiguration {
        guard let server = servers.first(where: { $0.id == id }) else { throw BridgeError(2, "Unknown server '\(id)'. Run 'servers list' to see configured servers.") }
        guard server.enabled else { throw BridgeError(2, "Server '\(id)' is disabled. Enable it in the profile first.") }
        return server
    }
}

public enum ProfileStore {
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MCP Bridge/profile.json")
    }
    public static func load(_ url: URL) throws -> BridgeProfile {
        guard FileManager.default.fileExists(atPath: url.path) else { return BridgeProfile() }
        do {
            let p = try JSONDecoder().decode(BridgeProfile.self, from: Data(contentsOf: url))
            try p.validate(); return p
        } catch let error as BridgeError { throw error }
        catch { throw BridgeError(2, "Cannot read profile. Check file permissions and the version-1 JSON format.") }
    }
    public static func decode(_ data: Data) throws -> BridgeProfile {
        do {
            let p = try JSONDecoder().decode(BridgeProfile.self, from: data); try p.validate(); return p
        } catch let error as BridgeError { throw error }
        catch { throw BridgeError(2, "Invalid profile JSON. Import a version-1 MCP Bridge profile.") }
    }
    public static func data(_ profile: BridgeProfile) throws -> Data {
        try profile.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(profile)
    }
    public static func save(_ profile: BridgeProfile, to url: URL) throws {
        let data = try data(profile)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { throw BridgeError(2, "Cannot save profile. Choose a writable location.") }
    }
}

public enum CredentialStore {
    private static let service = "MCPBridge.Credentials"
    public static func read(_ name: String) throws -> String {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: name, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
                                   kSecUseAuthenticationContext as String: context]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data, let value = String(data: data, encoding: .utf8), !value.isEmpty else {
            throw BridgeError(2, "Keychain credential '\(name)' is missing or unavailable. Save it in the app, or use an environment reference for unattended CLI use.")
        }
        return value
    }
    public static func save(_ name: String, value: String) throws {
        guard !name.isEmpty, !value.isEmpty else { throw BridgeError(2, "Credential name and value are required.") }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: name]
        let data = Data(value.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query; add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            // Explicitly trust this executable and its bundled companion CLI, so a
            // GUI-created credential is usable without interactive agent prompts.
            var trusted: [SecTrustedApplication] = []
            var current: SecTrustedApplication?
            if SecTrustedApplicationCreateFromPath(nil, &current) == errSecSuccess, let current { trusted.append(current) }
            let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
            let cli = executable.deletingLastPathComponent().appendingPathComponent("mcp-bridge")
            if FileManager.default.isExecutableFile(atPath: cli.path) {
                var companion: SecTrustedApplication?
                if SecTrustedApplicationCreateFromPath(cli.path, &companion) == errSecSuccess, let companion { trusted.append(companion) }
            }
            var access: SecAccess?
            if !trusted.isEmpty, SecAccessCreate("MCP Bridge credential" as CFString, trusted as CFArray, &access) == errSecSuccess, let access {
                add[kSecAttrAccess as String] = access
            }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw BridgeError(2, "Could not save credential in macOS Keychain (status \(status)).") }
    }
    public static func delete(_ name: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: name]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw BridgeError(2, "Could not remove the Keychain credential (status \(status)).") }
    }
}
