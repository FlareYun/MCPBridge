import Foundation

/// Profile operations never resolve credentials or connect to an upstream server.
public enum ServerManagement {
    private static let fields: Set<String> = [
        "id", "transport", "enabled", "command", "arguments", "url", "workingDirectory",
        "environment", "headers", "bearerToken", "timeout", "discoveryWait", "keepConnected"
    ]
    private static let optionalFields: Set<String> = ["command", "url", "workingDirectory", "bearerToken"]

    public static func execute(action: String, id: String, input: Data?, profileURL: URL) throws -> BridgeReply {
        var patch: [String: Any] = [:]
        if let input {
            guard input.count <= 16 * 1024 * 1024,
                  let object = try? JSONSerialization.jsonObject(with: input),
                  let dictionary = object as? [String: Any] else {
                throw BridgeError(2, "Server input must be a JSON object no larger than 16 MiB.")
            }
            patch = dictionary
            guard Set(patch.keys).isSubset(of: fields) else {
                throw BridgeError(2, "Unknown server configuration field. Use the version-1 server format.")
            }
            if let suppliedID = patch["id"], suppliedID as? String != id {
                throw BridgeError(2, "Input id must match the server ID in the command.")
            }
            for (key, value) in patch where value is NSNull && !optionalFields.contains(key) {
                throw BridgeError(2, "Field '\(key)' cannot be null.")
            }
        }
        if action == "show" {
            let profile = try ProfileStore.load(profileURL)
            guard let server = profile.servers.first(where: { $0.id == id }) else {
                throw BridgeError(2, "Unknown server '\(id)'.")
            }
            return try reply(action: action, id: id, profileURL: profileURL, server: server)
        }
        try ProfileStore.edit(profileURL) { profile in
            let index = profile.servers.firstIndex(where: { $0.id == id })
            if action == "remove" {
                guard let index else { throw BridgeError(2, "Unknown server '\(id)'.") }
                profile.servers.remove(at: index)
                return
            }
            var object: [String: Any]
            switch action {
            case "add":
                guard index == nil else { throw BridgeError(2, "Server '\(id)' already exists. Use server update.") }
                object = patch
            case "update":
                guard let index else { throw BridgeError(2, "Unknown server '\(id)'.") }
                object = try JSONSerialization.jsonObject(with: BridgeJSON.encode(profile.servers[index])) as! [String: Any]
                for (key, value) in patch { object[key] = value }
            default: throw BridgeError(2, "Unsupported server configuration operation.")
            }
            object["id"] = id
            let server: ServerConfiguration
            do {
                server = try JSONDecoder().decode(ServerConfiguration.self, from: JSONSerialization.data(withJSONObject: object))
            } catch {
                throw BridgeError(2, "Invalid server configuration. Add requires transport and command (stdio) or url (http); check field types.")
            }
            try server.validate()
            if let index { profile.servers[index] = server }
            else { profile.servers.append(server) }
        }
        return try reply(action: action, id: id, profileURL: profileURL)
    }

    private static func reply(action: String, id: String, profileURL: URL, server: ServerConfiguration? = nil) throws -> BridgeReply {
        struct Result: Encodable {
            let ok = true
            let operation: String
            let server: String
            let profile: String
            let configuration: ServerConfiguration?
        }
        return BridgeReply(data: try BridgeJSON.encode(Result(operation: "server." + action, server: id,
                                                               profile: profileURL.path, configuration: server)))
    }
}
