import XCTest
import MCP
@testable import BridgeCore

final class ToolCatalogTests: XCTestCase {
    func withProfile(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try body(directory.appendingPathComponent("profile.json"))
    }

    func catalog(_ server: ServerConfiguration) throws -> ToolCatalog {
        ToolCatalog(version: 1, serverID: server.id, configurationFingerprint: try ToolCatalog.fingerprint(server),
                    capturedAt: Date(timeIntervalSince1970: 1_700_000_000), tools: [[
                        "name": .string("inspect"), "description": .string("Unicode 世界"),
                        "inputSchema": .object(["type": .string("object"), "properties": .object(["target": .object(["type": .string("string")])])]),
                        "annotations": .object(["readOnlyHint": .bool(true)]), "_meta": .object(["extension": .string("preserved")])
                    ]])
    }

    func testRoundTripSchemaMetadataAndPrivateFiles() throws {
        try withProfile { url in
            let server = ServerConfiguration(id: "fixture", command: "/bin/cat")
            let original = try catalog(server)
            try original.save(profileURL: url)
            let loaded = try XCTUnwrap(ToolCatalog.load(server: server, profileURL: url))
            XCTAssertEqual(loaded.tools, original.tools)
            let reply = try loaded.reply(operation: .describeTool("inspect"), profileURL: url)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: reply.data) as? [String: Any])
            XCTAssertEqual((json["catalog"] as? [String: Any])?["source"] as? String, "cache")
            XCTAssertEqual((json["catalog"] as? [String: Any])?["capturedAt"] as? String, "2023-11-14T22:13:20Z")
            XCTAssertFalse((json["warnings"] as? [String] ?? []).isEmpty)
            let file = ToolCatalog.location(profileURL: url, serverID: server.id)
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)[.posixPermissions] as? Int, 0o700)
        }
    }

    func testConfigurationAndProfileIsolation() throws {
        try withProfile { url in
            let server = ServerConfiguration(id: "fixture", command: "/bin/cat")
            try catalog(server).save(profileURL: url)
            var changed = server; changed.arguments = ["different"]
            XCTAssertNil(try ToolCatalog.load(server: changed, profileURL: url))
            changed = server; changed.environment = ["TOKEN": SecretReference(name: "different-account")]
            XCTAssertNil(try ToolCatalog.load(server: changed, profileURL: url))
            XCTAssertNil(try ToolCatalog.load(server: server, profileURL: url.deletingLastPathComponent().appendingPathComponent("other.json")))
            changed = server; changed.enabled = false
            XCTAssertThrowsError(try ToolCatalog.load(server: changed, profileURL: url))
        }
    }

    func testMissingAndMalformedCatalogs() throws {
        try withProfile { url in
            let server = ServerConfiguration(id: "fixture", command: "/bin/cat")
            XCTAssertNil(try ToolCatalog.load(server: server, profileURL: url))
            try catalog(server).save(profileURL: url)
            let path = ToolCatalog.location(profileURL: url, serverID: server.id)
            try Data("bad JSON".utf8).write(to: path)
            XCTAssertThrowsError(try ToolCatalog.load(server: server, profileURL: url))
        }
    }

    func testCatalogCannotExecuteOrInventTools() throws {
        let server = ServerConfiguration(id: "fixture", command: "/bin/cat")
        let saved = try catalog(server)
        let url = URL(fileURLWithPath: "/tmp/test-profile.json")
        XCTAssertThrowsError(try saved.reply(operation: .callTool("inspect", Data("{}".utf8)), profileURL: url))
        XCTAssertThrowsError(try saved.reply(operation: .describeTool("unknown"), profileURL: url))
    }
}
