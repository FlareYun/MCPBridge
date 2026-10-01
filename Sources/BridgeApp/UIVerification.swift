#if DEBUG
import AppKit
import Foundation
import BridgeCore

/// Development-only verification of this app's own window and asynchronous view model.
/// Does not inspect other apps or require desktop capture/accessibility permissions.
@MainActor
enum UIVerification {
    private static var started = false
    static func startIfRequested(model: AppModel) {
        let args = CommandLine.arguments
        guard !started, let i = args.firstIndex(of: "--verify-ui"), args.indices.contains(i + 1) else { return }
        started = true
        NSApplication.shared.appearance = NSAppearance(named: .aqua)
        let directory = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        Task {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try await Task.sleep(for: .milliseconds(400))
                guard let server = model.profile.servers.first else { throw BridgeError(2, "UI verification requires a fixture profile.") }
                try snapshot("configuration", in: directory)
                model.selectedTab = "tools"
                model.run(server, .listTools, label: "Discover tools", discover: true)
                await model.runningTask?.value
                guard model.tools.count == 8 else { throw BridgeError(3, "UI tool discovery failed.") }
                guard try ToolCatalog.load(server: server, profileURL: model.profileURL)?.tools.count == 8 else {
                    throw BridgeError(3, "App did not save its catalog for the CLI.")
                }
                let restarted = AppModel()
                guard restarted.tools.count == 8, restarted.result.contains("cache") else {
                    throw BridgeError(3, "App did not restore saved tools on launch.")
                }
                try await Task.sleep(for: .milliseconds(300))
                try snapshot("tools", in: directory)
                let siblingCLI = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
                    .deletingLastPathComponent().appendingPathComponent("mcp-bridge")
                guard FileManager.default.isExecutableFile(atPath: siblingCLI.path) else {
                    throw BridgeError(3, "Agent setup companion CLI does not exist.")
                }
                model.selectedTab = "help"
                try await Task.sleep(for: .milliseconds(250))
                try snapshot("agent-setup", in: directory)
                model.run(server, .callTool("slow", Data(#"{"seconds":0.8}"#.utf8)), label: "Responsiveness test")
                let start = Date()
                try await Task.sleep(for: .milliseconds(100))
                guard model.busy, Date().timeIntervalSince(start) < 0.5 else { throw BridgeError(3, "Main actor was blocked during tool execution.") }
                await model.runningTask?.value
                guard model.status == "Success" else { throw BridgeError(3, "UI tool call failed.") }
                model.selectedTab = "results"
                try await Task.sleep(for: .milliseconds(250))
                try snapshot("results", in: directory)
                model.run(server, .callTool("slow", Data(#"{"seconds":10}"#.utf8)), label: "Cancellation test")
                try await Task.sleep(for: .milliseconds(150))
                model.runningTask?.cancel()
                await model.runningTask?.value
                guard !model.busy, model.status == "Cancelled" else { throw BridgeError(3, "UI cancellation failed.") }
                var emptyServer = server
                emptyServer.arguments += ["--tools-ready-after", "60"]
                emptyServer.discoveryWait = 0.2
                model.selectedTab = "tools"
                model.run(emptyServer, .listTools, label: "Empty discovery test", discover: true)
                await model.runningTask?.value
                guard model.status == "No tools published", model.tools.isEmpty, model.result.contains("warnings") else {
                    throw BridgeError(3, "Empty discovery diagnostic failed.")
                }
                try await Task.sleep(for: .milliseconds(200))
                try snapshot("empty-tools", in: directory)
                try await verifyKeychain(server: server, directory: directory)
                model.setConnection(server, connected: true)
                await model.runningTask?.value
                guard model.sessionStates[server.id] == "Connected", let connected = model.profile.servers.first else {
                    throw BridgeError(3, "Persistent UI connect failed.")
                }
                model.run(connected, .listTools, label: "Shared discovery", discover: true)
                await model.runningTask?.value
                guard model.tools.count == 8 else { throw BridgeError(3, "Shared UI discovery failed.") }
                try await Task.sleep(for: .milliseconds(200))
                try snapshot("connected-session", in: directory)
                model.setConnection(connected, connected: false)
                await model.runningTask?.value
                guard model.sessionStates[server.id] == nil else { throw BridgeError(3, "Persistent UI disconnect failed.") }
                let report: [String: String] = ["persistentConnectAndDisconnect": "passed", "status": "passed", "toolsDiscovered": "8", "mainActorResponsive": "true", "cancellation": "passed", "emptyDiscovery": "passed", "keychainAppAndCLI": "passed", "catalogSaveAndRestore": "passed", "snapshots": "configuration, tools, agent-setup, results, empty-tools, connected-session"]
                try BridgeJSON.encode(report).write(to: directory.appendingPathComponent("report.json"))
                NSApplication.shared.terminate(nil)
            } catch {
                let report = ["status": "failed", "message": error.localizedDescription]
                try? BridgeJSON.encode(report).write(to: directory.appendingPathComponent("report.json"))
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private static func verifyKeychain(server: ServerConfiguration, directory: URL) async throws {
        let name = "MCPBridge-UI-Test-" + UUID().uuidString
        defer { try? CredentialStore.delete(name) }
        try CredentialStore.save(name, value: "disposable-fixture-value")
        guard try CredentialStore.read(name) == "disposable-fixture-value" else { throw BridgeError(3, "App Keychain read failed.") }
        var server = server
        server.keepConnected = true
        server.environment["BRIDGE_FIXTURE_VALUE"] = SecretReference(source: .keychain, name: name)
        let profileURL = directory.appendingPathComponent("keychain-test.profile.json")
        try ProfileStore.save(BridgeProfile(servers: [server]), to: profileURL)
        let pool = PersistentSessions()
        let host = SessionHost(profileURL: profileURL, sessions: pool)
        try await host.start()
        try await pool.connect(server)
        let cli = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("mcp-bridge")
        let serverID = server.id
        let result = try await Task.detached {
            let process = Process(); process.executableURL = cli
            process.arguments = ["--config", profileURL.path, "call", serverID, "environment", "--stdin"]
            let input = Pipe(), output = Pipe()
            process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
            try process.run()
            input.fileHandleForWriting.write(Data("{}".utf8)); try input.fileHandleForWriting.close()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }.value
        await host.stop()
        guard result.0 == 0, result.1.contains("disposable-fixture-value") else { throw BridgeError(3, "Companion CLI could not use the app-owned credential through its shared session.") }
    }

    private static func snapshot(_ name: String, in directory: URL) throws {
        guard let window = NSApplication.shared.windows.first(where: { $0.isVisible && $0.contentView != nil }),
              let view = window.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw BridgeError(3, "App window could not be rendered.")
        }
        view.layoutSubtreeIfNeeded()
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: view.bounds, to: bitmap)
        }
        // cacheDisplay leaves the window's backing surface transparent. Composite
        // onto its actual appearance color so exported PNGs remain legible.
        let size = NSSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
        guard let opaque = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: bitmap.pixelsWide, pixelsHigh: bitmap.pixelsHigh,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: opaque), let cgImage = bitmap.cgImage else {
            throw BridgeError(3, "Could not compose app snapshot.")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
            NSImage(cgImage: cgImage, size: size).draw(in: NSRect(origin: .zero, size: size))
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let png = opaque.representation(using: .png, properties: [:]) else { throw BridgeError(3, "Could not encode app snapshot.") }
        try png.write(to: directory.appendingPathComponent(name + ".png"))
    }
}
#endif
