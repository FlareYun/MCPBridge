import XCTest
@testable import BridgeCore

final class ConfigurationTests: XCTestCase {
    func testMinimalProfileDefaultsAndRoundTrip() throws {
        let profile = try ProfileStore.decode(Data(#"{"version":1,"servers":[{"id":"fixture","transport":"stdio","command":"/usr/bin/example"}]}"#.utf8))
        XCTAssertEqual(profile.servers[0].timeout, 60)
        XCTAssertFalse(profile.servers[0].keepConnected)
        XCTAssertEqual(profile.servers[0].discoveryWait, 10)
        XCTAssertTrue(profile.servers[0].enabled)
        XCTAssertEqual(try ProfileStore.decode(ProfileStore.data(profile)), profile)
    }
    func testRejectDuplicateIDsAndUnknownVersion() throws {
        let server = ServerConfiguration(id: "one", command: "/bin/cat")
        XCTAssertThrowsError(try BridgeProfile(servers: [server, server]).validate())
        XCTAssertThrowsError(try BridgeProfile(version: 2).validate())
    }
    func testSecretsRemainReferences() throws {
        let reference = SecretReference(name: "TEST_SECRET")
        let server = ServerConfiguration(id: "remote", transport: .http, url: "https://example.com/mcp", bearerToken: reference)
        let data = try ProfileStore.data(BridgeProfile(servers: [server]))
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("TEST_SECRET"))
        XCTAssertEqual(try reference.resolve(environment: ["TEST_SECRET": "private-value"]), "private-value")
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("private-value"))
        XCTAssertThrowsError(try reference.resolve(environment: [:]))
    }
    func testInvalidConfigurationAndDisabledServer() throws {
        XCTAssertThrowsError(try ServerConfiguration(id: "bad id", command: "/bin/cat").validate())
        XCTAssertThrowsError(try ServerConfiguration(id: "http", transport: .http, url: "http://remote.example/mcp").validate())
        XCTAssertThrowsError(try ServerConfiguration(id: "http", transport: .http, url: "https://user:password@example.com/mcp").validate())
        XCTAssertThrowsError(try ServerConfiguration(id: "bad", command: "/bin/cat", timeout: .infinity).validate())
        let disabled = ServerConfiguration(id: "off", enabled: false, command: "/bin/cat")
        XCTAssertThrowsError(try BridgeProfile(servers: [disabled]).server("off"))
    }
    func testArgumentValidation() throws {
        XCTAssertNoThrow(try BridgeRunner.arguments(Data(#"{"text":"hello 世界 🌉","n":1,"nested":{"ok":true}}"#.utf8)))
        XCTAssertThrowsError(try BridgeRunner.arguments(Data("[]".utf8)))
        XCTAssertThrowsError(try BridgeRunner.arguments(Data("null".utf8)))
        XCTAssertThrowsError(try BridgeRunner.arguments(Data("not JSON".utf8)))
    }
    func testDiscoveryWaitValidationAndRoundTrip() throws {
        for invalid in [-1.0, Double.infinity, 86401] {
            XCTAssertThrowsError(try ServerConfiguration(command: "/bin/cat", discoveryWait: invalid).validate())
        }
        for valid in [0.0, 0.25, 30] {
            let profile = BridgeProfile(servers: [ServerConfiguration(command: "/bin/cat", discoveryWait: valid)])
            XCTAssertEqual(try ProfileStore.decode(ProfileStore.data(profile)), profile)
        }
    }
    func testSaveCreatesPrivateFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("profile.json")
        try ProfileStore.save(BridgeProfile(), to: url)
        XCTAssertEqual(try ProfileStore.load(url), BridgeProfile())
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }
}
