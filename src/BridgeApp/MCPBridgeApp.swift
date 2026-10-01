import SwiftUI
import AppKit
import UniformTypeIdentifiers
import BridgeCore
import Darwin

struct ToolItem: Identifiable {
    var id: String { name }
    let name: String
    let description: String
    let schema: String
}

struct ActivityItem: Identifiable {
    let id = UUID()
    let time = Date()
    let server: String
    let operation: String
    let status: String
    let seconds: Double
}

@MainActor
final class AppModel: ObservableObject {
    @Published var profile = BridgeProfile()
    @Published var selectedID: String?
    @Published var selectedTab = "configuration"
    @Published var selectedTool: String?
    @Published var tools: [ToolItem] = []
    @Published var result = "Run a connection test or tool to see its result here."
    @Published var busy = false
    @Published var status = "Ready"
    @Published var message: String?
    @Published var activity: [ActivityItem] = []
    @Published var profileURL = ProfileStore.defaultURL
    var runningTask: Task<Void, Never>?
    let sessions = PersistentSessions()
    lazy var sessionHost = SessionHost(profileURL: profileURL, sessions: sessions)
    var sessionTask: Task<Void, Never>?
    @Published var sessionStates: [String: String] = [:]

    func startSessions() {
        guard sessionTask == nil else { return }
        sessionTask = Task {
            do { try await sessionHost.start() }
            catch { message = error.localizedDescription; return }
            for server in profile.servers where server.enabled && server.keepConnected {
                sessionStates[server.id] = "Connecting"
                do { try await sessions.connect(server) }
                catch { sessionStates[server.id] = "Disconnected · reconnect required"; status = error.localizedDescription }
            }
            while !Task.isCancelled {
                sessionStates = await sessions.statuses()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    func shutdown() async {
        runningTask?.cancel(); sessionTask?.cancel()
        await runningTask?.value
        await sessionTask?.value
        await sessionHost.stop()
    }

    func setConnection(_ server: ServerConfiguration, connected: Bool) {
        guard !busy else { return }
        var updated = server; updated.keepConnected = connected
        do {
            var next = profile
            guard let i = next.servers.firstIndex(where: { $0.id == server.id }) else { return }
            next.servers[i] = updated
            try ProfileStore.save(next, to: profileURL)
            profile = next
        } catch { message = error.localizedDescription; return }
        changeSession(updated)
    }

    func changeSession(_ server: ServerConfiguration, oldID: String? = nil) {
        busy = true; status = server.keepConnected && server.enabled ? "Connecting shared session…" : "Disconnecting…"
        runningTask = Task {
            await sessions.disconnect(oldID ?? server.id)
            do {
                if server.keepConnected && server.enabled {
                    try await sessionHost.start()
                    try await sessions.connect(server)
                    status = "Connected · session shared with CLI"
                } else { status = "Disconnected" }
            } catch { status = "Connection failed"; message = error.localizedDescription }
            sessionStates = await sessions.statuses()
            busy = false; runningTask = nil
        }
    }

    init() {
        // An explicit profile supports portable setups and isolated UI verification.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--config"), args.indices.contains(i + 1) { profileURL = URL(fileURLWithPath: args[i + 1]) }
        do { profile = try ProfileStore.load(profileURL); selectedID = profile.servers.first?.id }
        catch { message = error.localizedDescription }
        restoreCatalog()
    }

    func displayTools(_ reply: BridgeReply) throws {
        let json = try JSONSerialization.jsonObject(with: reply.data) as? [String: Any]
        let payload = json?["result"] as? [String: Any]
        tools = (payload?["tools"] as? [[String: Any]] ?? []).compactMap { item in
            guard let name = item["name"] as? String else { return nil }
            let schema = (try? JSONSerialization.data(withJSONObject: item["inputSchema"] ?? [:], options: [.prettyPrinted, .sortedKeys])) ?? Data()
            return ToolItem(name: name, description: item["description"] as? String ?? "", schema: String(decoding: schema, as: UTF8.self))
        }
        selectedTool = tools.first?.name
    }

    func restoreCatalog() {
        tools = []; selectedTool = nil
        guard let server = profile.servers.first(where: { $0.id == selectedID }), server.enabled else { return }
        do {
            guard let catalog = try ToolCatalog.load(server: server, profileURL: profileURL) else { return }
            let reply = try catalog.reply(operation: .listTools, profileURL: profileURL)
            try displayTools(reply)
            result = reply.text
            status = "Loaded \(tools.count) saved tools · live availability unchecked"
        } catch { status = "Saved catalog unavailable · discover tools to refresh" }
    }

    func add() {
        var id = "new-server", n = 2
        while profile.servers.contains(where: { $0.id == id }) { id = "new-server-\(n)"; n += 1 }
        profile.servers.append(ServerConfiguration(id: id, command: "/absolute/path/to/server"))
        selectedID = id; tools = []
    }

    func save(_ server: ServerConfiguration, replacing id: String) {
        do {
            var server = server
            server.keepConnected = profile.servers.first(where: { $0.id == id })?.keepConnected ?? server.keepConnected
            try server.validate()
            guard !profile.servers.contains(where: { $0.id == server.id && $0.id != id }) else { throw BridgeError(2, "That server ID is already in use.") }
            var updated = profile
            guard let index = updated.servers.firstIndex(where: { $0.id == id }) else { return }
            updated.servers[index] = server
            try ProfileStore.save(updated, to: profileURL)
            profile = updated; selectedID = server.id; tools = []; selectedTool = nil; status = "Configuration saved"
            restoreCatalog()
            changeSession(server, oldID: id)
        } catch { message = error.localizedDescription }
    }

    func remove(_ id: String) {
        do {
            var updated = profile; updated.servers.removeAll { $0.id == id }
            try ProfileStore.save(updated, to: profileURL)
            profile = updated; selectedID = updated.servers.first?.id; tools = []; status = "Server removed"
            Task { await sessions.disconnect(id) }
        } catch { message = error.localizedDescription }
    }

    func importProfile() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.canChooseDirectories = false
        panel.message = "Import an MCP Bridge profile. Existing server IDs must be unique."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            var imported = try ProfileStore.decode(Data(contentsOf: url))
            for i in imported.servers.indices { imported.servers[i].keepConnected = false }
            let merged = BridgeProfile(servers: profile.servers + imported.servers)
            try ProfileStore.save(merged, to: profileURL)
            profile = merged; selectedID = imported.servers.first?.id ?? selectedID
            status = "Imported \(imported.servers.count) servers"
        } catch { message = error.localizedDescription }
    }

    func exportProfile() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "mcp-bridge-profile.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try ProfileStore.save(profile, to: url); status = "Exported profile; credential values are not included" }
        catch { message = error.localizedDescription }
    }

    func run(_ server: ServerConfiguration, _ operation: BridgeOperation, label: String, discover: Bool = false) {
        guard !busy else { return }
        busy = true; status = label; result = "Running…"
        runningTask = Task {
            let start = Date()
            var outcome = "Success"
            do {
                let reply: BridgeReply
                let pool = sessions
                let executor: @Sendable (BridgeOperation) async throws -> BridgeReply = { operation in
                    if server.keepConnected { return try await pool.execute(server: server, operation: operation) }
                    return try await BridgeRunner.execute(server: server, operation: operation)
                }
                if discover {
                    reply = try await ToolDiscovery.execute(server: server, profileURL: profileURL, operation: operation, mode: .live, liveExecutor: executor)
                } else {
                    reply = try await executor(operation)
                }
                result = reply.text
                if reply.exitCode != 0 { outcome = "Tool error" }
                if discover {
                    try displayTools(reply)
                    if tools.isEmpty { outcome = "No tools published" }
                    else if reply.text.contains("catalog could not be saved") { outcome = "Tools discovered · catalog not saved" }
                    else { outcome = "Saved \(tools.count) tools for agents" }
                }
            } catch {
                outcome = Task.isCancelled ? "Cancelled" : "Failed"
                let error = error as? BridgeError ?? BridgeError(3, "Operation failed.")
                result = String(decoding: BridgeJSON.error(error), as: UTF8.self)
            }
            activity.insert(ActivityItem(server: server.id, operation: label, status: outcome, seconds: Date().timeIntervalSince(start)), at: 0)
            activity = Array(activity.prefix(50))
            status = outcome; busy = false; runningTask = nil
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    var terminationSignal: DispatchSourceSignal?
    var quitting = false
    var cleanupComplete = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApplication.shared.terminate(nil) }
        source.resume(); terminationSignal = source
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, !cleanupComplete else { return .terminateNow }
        guard !quitting else { return .terminateCancel }
        quitting = true
        // Keep the regular run loop alive while Swift concurrency drains sessions.
        // A termination-modal loop can starve MainActor shutdown tasks.
        Task {
            await model.shutdown()
            cleanupComplete = true
            sender.terminate(nil)
        }
        return .terminateCancel
    }
}

@main
struct MCPBridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup("MCP Bridge") {
            ContentView().environmentObject(model).frame(minWidth: 1000, minHeight: 700)
                .onAppear {
                    delegate.model = model
                    model.startSessions()
                }
                .onDisappear { model.runningTask?.cancel() }
        }
        .defaultSize(width: 1140, height: 800)
        .commands { CommandGroup(replacing: .newItem) { Button("Add Server") { model.add() }.keyboardShortcut("n").disabled(model.busy) } }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var credentials = false
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 26)).foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("MCP Bridge").font(.headline)
                        Text("Your tools. One command.").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.horizontal, 14).padding(.top, 20)
                HStack {
                    Text("SERVERS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(model.profile.servers.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }.padding(.horizontal, 16)
                List(selection: $model.selectedID) {
                    ForEach(model.profile.servers) { server in
                        HStack(spacing: 10) {
                            Image(systemName: server.transport == .stdio ? "terminal" : "network").foregroundStyle(server.enabled ? .blue : .gray)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(server.id).lineLimit(1)
                                Text(server.enabled ? (server.transport == .stdio ? "Process · stdio" : "Remote · HTTP") : "Disabled").font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 6).tag(server.id)
                    }
                }.listStyle(.plain).disabled(model.busy)
                Button { model.add() } label: { Label("Add server", systemImage: "plus").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered).disabled(model.busy).padding(.horizontal, 14)
                VStack(alignment: .leading, spacing: 6) {
                    Label("Local by design", systemImage: "desktopcomputer").font(.caption.weight(.medium))
                    Text("Shared sessions while open. No TCP listener.").font(.caption).foregroundStyle(.secondary)
                }.padding(16)
            }.navigationSplitViewColumnWidth(min: 230, ideal: 250, max: 300)
        } detail: {
            VStack(spacing: 0) {
                if let server = model.profile.servers.first(where: { $0.id == model.selectedID }) {
                    ServerDetail(server: server).id(server.id)
                } else {
                    VStack(spacing: 20) {
                        Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 58)).foregroundStyle(.blue)
                        Text("Bring your tools together").font(.largeTitle.weight(.semibold))
                        Text("Add an MCP server, explore its tools, and call them\nfrom any agent or terminal.").multilineTextAlignment(.center).foregroundStyle(.secondary)
                        Button("Add your first server") { model.add() }.buttonStyle(.borderedProminent).controlSize(.large)
                        Text("Local processes and Streamable HTTP supported").font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Divider()
                HStack(spacing: 8) {
                    Circle().fill(model.busy ? Color.orange : Color.green).frame(width: 6, height: 6)
                    Text(model.status).font(.caption)
                    Spacer()
                    if model.busy { Button("Cancel") { model.runningTask?.cancel() }.controlSize(.small) }
                    Text("MCP BRIDGE 1.1.0").font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
                }.padding(.horizontal, 20).padding(.vertical, 10)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button { model.importProfile() } label: { Label("Import", systemImage: "square.and.arrow.down") }.disabled(model.busy)
                Button { model.exportProfile() } label: { Label("Export", systemImage: "square.and.arrow.up") }
                Button { credentials = true } label: { Label("Credentials", systemImage: "key") }
            }
        }
        .sheet(isPresented: $credentials) { CredentialView() }
        .alert("MCP Bridge", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("OK") { model.message = nil }
        } message: { Text(model.message ?? "") }
        .onChange(of: model.selectedID) { _ in
            model.tools = []; model.selectedTool = nil
            model.result = "Run a connection test or tool to see its result here."
            model.status = "Ready"
            model.restoreCatalog()
        }
    }
}

struct ServerDetail: View {
    @EnvironmentObject var model: AppModel
    let server: ServerConfiguration
    @State private var deleting = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text(server.id).font(.system(size: 27, weight: .semibold)).lineLimit(1).help(server.id)
                    Text(server.transport == .stdio ? "Local process connection" : "Streamable HTTP connection").foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.run(server, .test, label: "Test connection"); model.selectedTab = "results" } label: { Label("Test connection", systemImage: "bolt") }
                    .disabled(model.busy || !server.enabled)
                Button { model.run(server, .listTools, label: "Discover & cache tools", discover: true); model.selectedTab = "tools" } label: { Label("Discover & cache tools", systemImage: "sparkle.magnifyingglass") }
                    .buttonStyle(.borderedProminent).disabled(model.busy || !server.enabled)
            }.padding(.horizontal, 24).padding(.top, 24)
            HStack {
                Circle().fill(model.sessionStates[server.id] == "Connected" ? Color.green : Color.gray).frame(width: 8, height: 8)
                Text(model.sessionStates[server.id] ?? (server.keepConnected ? "Disconnected · reconnect required" : "Direct connections · no shared session")).font(.caption)
                Spacer()
                if server.keepConnected {
                    Button("Reconnect") { model.setConnection(server, connected: true) }.disabled(model.busy || !server.enabled)
                    Button("Disconnect") { model.setConnection(server, connected: false) }.disabled(model.busy)
                } else {
                    Button("Connect & keep open") { model.setConnection(server, connected: true) }.disabled(model.busy || !server.enabled)
                }
            }.padding(.horizontal, 24)
            VStack(spacing: 0) {
                HStack(spacing: 4) {
                    tabButton("Configuration", id: "configuration")
                    tabButton("Tools", id: "tools")
                    tabButton("Results", id: "results")
                    tabButton("Activity", id: "activity")
                    tabButton("Agent setup", id: "help")
                    Spacer()
                }.padding(10)
                Divider()
                ZStack {
                    tabContent("configuration") { ServerEditor(server: server) }
                    tabContent("tools") { ToolBrowser(server: server) }
                    tabContent("results") { ResultView() }
                    tabContent("activity") { ActivityView() }
                    tabContent("help") { AgentHelpView(server: server) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }.background(Color(nsColor: .controlBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.12)))
                .padding(.horizontal, 20).padding(.bottom, 16)
        }
    }
    private func tabButton(_ title: String, id: String) -> some View {
        Button { model.selectedTab = id } label: {
            Text(title).font(.callout.weight(model.selectedTab == id ? .semibold : .regular))
                .foregroundStyle(model.selectedTab == id ? Color.accentColor : Color.primary)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(model.selectedTab == id ? Color.accentColor.opacity(0.10) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain).accessibilityAddTraits(model.selectedTab == id ? .isSelected : [])
    }
    private func tabContent<V: View>(_ id: String, @ViewBuilder content: () -> V) -> some View {
        content().opacity(model.selectedTab == id ? 1 : 0).allowsHitTesting(model.selectedTab == id)
            .accessibilityHidden(model.selectedTab != id)
    }
}

struct ServerEditor: View {
    @EnvironmentObject var model: AppModel
    let server: ServerConfiguration
    @State private var draft: ServerConfiguration
    @State private var arguments: String
    @State private var refs: String
    @State private var deleting = false
    init(server: ServerConfiguration) {
        self.server = server
        _draft = State(initialValue: server)
        _arguments = State(initialValue: String(decoding: (try? BridgeJSON.encode(server.arguments)) ?? Data("[]".utf8), as: UTF8.self))
        let references = ReferenceFields(environment: server.environment, headers: server.headers, bearerToken: server.bearerToken)
        _refs = State(initialValue: String(decoding: (try? BridgeJSON.encode(references)) ?? Data("{}".utf8), as: UTF8.self))
    }
    struct ReferenceFields: Codable {
        var environment: [String: SecretReference] = [:]
        var headers: [String: SecretReference] = [:]
        var bearerToken: SecretReference?
    }
    func save() {
        do {
            var updated = draft
            updated.arguments = try JSONDecoder().decode([String].self, from: Data(arguments.utf8))
            let references = try JSONDecoder().decode(ReferenceFields.self, from: Data(refs.utf8))
            updated.environment = references.environment; updated.headers = references.headers; updated.bearerToken = references.bearerToken
            model.save(updated, replacing: server.id)
        } catch { model.message = "Arguments must be a JSON string array. References must contain environment and headers objects, plus an optional bearerToken reference." }
    }
    var body: some View {
        VStack(spacing: 0) {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            TextField("Server ID", text: $draft.id).accessibilityLabel("Server ID")
                            Toggle("Enabled", isOn: $draft.enabled).toggleStyle(.switch)
                        }
                        Picker("Transport", selection: $draft.transport) {
                            Text("Local process (stdio)").tag(ServerConfiguration.Transport.stdio)
                            Text("Streamable HTTP").tag(ServerConfiguration.Transport.http)
                        }.pickerStyle(.segmented)
                        if draft.transport == .stdio {
                            TextField("Executable path or command", text: Binding(get: { draft.command ?? "" }, set: { draft.command = $0 }))
                                .accessibilityLabel("Executable command")
                            Text("Arguments · JSON array").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                            codeEditor($arguments, height: 70).accessibilityLabel("Command arguments")
                            TextField("Working directory (optional, absolute path)", text: Binding(get: { draft.workingDirectory ?? "" }, set: { draft.workingDirectory = $0.isEmpty ? nil : $0 }))
                        } else {
                            TextField("https://example.com/mcp", text: Binding(get: { draft.url ?? "" }, set: { draft.url = $0 }))
                                .accessibilityLabel("Server URL")
                        }
                        HStack {
                            Text("Operation timeout")
                            TextField("Seconds", value: $draft.timeout, format: .number).frame(width: 90)
                            Text("seconds").foregroundStyle(.secondary)
                        }
                        HStack {
                            Text("Tool discovery wait")
                            TextField("Seconds", value: $draft.discoveryWait, format: .number).frame(width: 90)
                            Text("seconds · dynamic servers").foregroundStyle(.secondary)
                        }
                    }.padding(12)
                } label: { Label("Connection", systemImage: "cable.connector") }

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Map environment variables and HTTP headers to values in your environment or Keychain. Store credential values using the key button in the toolbar.")
                            .font(.callout).foregroundStyle(.secondary)
                        codeEditor($refs, height: 135).accessibilityLabel("Credential references")
                        Text("Reference format: {\"source\": \"environment\", \"name\": \"TOKEN_VAR\"}")
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                    }.padding(12)
                } label: { Label("Environment & credentials", systemImage: "key") }
            }.padding(20).disabled(model.busy)
        }
        Divider()
        HStack {
            Button("Remove server", role: .destructive) { deleting = true }
            Spacer()
            Text("Save changes before testing or running tools.").font(.caption).foregroundStyle(.secondary)
            Button("Save configuration", action: save).buttonStyle(.borderedProminent).keyboardShortcut("s", modifiers: .command)
        }.padding(16).disabled(model.busy)
        }
        .confirmationDialog("Remove \(server.id)?", isPresented: $deleting) {
            Button("Remove server", role: .destructive) { model.remove(server.id) }
        } message: { Text("This removes the profile entry. The server software and Keychain credentials are retained.") }
    }
}

func codeEditor(_ text: Binding<String>, height: CGFloat) -> some View {
    TextEditor(text: text).font(.system(size: 12, design: .monospaced)).scrollContentBackground(.hidden)
        .padding(8).frame(height: height).background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 7)).overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.secondary.opacity(0.2)))
}

struct ToolBrowser: View {
    @EnvironmentObject var model: AppModel
    let server: ServerConfiguration
    @State private var query = ""
    @State private var arguments = "{}"
    var body: some View {
        HSplitView {
            VStack(spacing: 10) {
                TextField("Search tools", text: $query).textFieldStyle(.roundedBorder).padding(.horizontal, 12).padding(.top, 14)
                List(selection: $model.selectedTool) {
                    ForEach(model.tools.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.description.localizedCaseInsensitiveContains(query) }) { tool in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(tool.name).font(.system(.body, design: .monospaced))
                            Text(tool.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }.padding(.vertical, 6).tag(tool.name)
                    }
                }
                Text("\(model.tools.count) tools").font(.caption).foregroundStyle(.secondary).padding(.bottom, 10)
            }.frame(minWidth: 210, idealWidth: 240, maxWidth: 300)
            ScrollView {
                if let tool = model.tools.first(where: { $0.name == model.selectedTool }) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(tool.name).font(.title2.weight(.semibold)).textSelection(.enabled)
                        Text(tool.description).foregroundStyle(.secondary).textSelection(.enabled)
                        DisclosureGroup("Input schema") { Text(tool.schema).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(10) }
                        Text("Arguments").font(.headline)
                        codeEditor($arguments, height: 150).accessibilityLabel("Tool arguments")
                        HStack {
                            Text("Tools may change data in the connected service.").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Run tool") { model.run(server, .callTool(tool.name, Data(arguments.utf8)), label: "Call \(tool.name)") }
                                .buttonStyle(.borderedProminent).disabled(model.busy || !server.enabled)
                        }
                        Divider()
                        HStack { Text("Result").font(.headline); Spacer(); if model.busy { ProgressView().controlSize(.small) } }
                        Text(model.result).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(20)
                } else {
                    VStack(spacing: 14) {
                        Image(systemName: "wrench.and.screwdriver").font(.largeTitle).foregroundStyle(.secondary)
                        Text(model.status == "No tools published" ? "Connected, but no tools published" : (model.tools.isEmpty ? "Discover what this server can do" : "Select a tool")).font(.headline)
                        Text(model.status == "No tools published" ? "No live tools were reported. Check MCP settings and connection permissions. An empty list does not establish whether the upstream app is open; any saved catalog is preserved." : "Use Discover & cache tools to save names, descriptions, and schemas for your agent.").foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }.frame(maxWidth: .infinity).padding(.top, 100).padding(.horizontal, 30)
                }
            }.frame(minWidth: 360)
        }.onChange(of: model.selectedTool) { _ in arguments = "{}" }
    }
}

struct ResultView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Latest response").font(.headline)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button("Copy JSON") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.result, forType: .string) }
            }
            ScrollView([.horizontal, .vertical]) { Text(model.result).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(14) }
                .background(Color(nsColor: .textBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 8))
            Text("Tool execution results stay in this window. Discovered tool metadata is saved beside the profile for agents.").font(.caption).foregroundStyle(.secondary)
        }.padding(20)
    }
}

struct ActivityView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent operations").font(.headline)
            Text("This session only. Arguments, results, and credentials are not recorded.").font(.caption).foregroundStyle(.secondary)
            List(model.activity) { item in
                HStack {
                    Image(systemName: item.status == "Success" ? "checkmark.circle" : "exclamationmark.circle").foregroundStyle(item.status == "Success" ? .green : .orange)
                    VStack(alignment: .leading, spacing: 4) { Text(item.operation); Text(item.server).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Text(item.status).font(.caption)
                    Text(String(format: "%.2fs", item.seconds)).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    Text(item.time, style: .time).font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 5)
            }.overlay { if model.activity.isEmpty { Text("No operations yet").foregroundStyle(.secondary) } }
        }.padding(20)
    }
}

struct AgentHelpView: View {
    @EnvironmentObject var model: AppModel
    let server: ServerConfiguration
    func quoted(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    var instructions: String {
        let executable = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .deletingLastPathComponent().appendingPathComponent("mcp-bridge").path
        return """
        Use MCP Bridge to discover and call configured tools:

        \(quoted(executable)) --config \(quoted(model.profileURL.path)) tools list \(quoted(server.id))

        Inspect a tool with:
        \(quoted(executable)) --config \(quoted(model.profileURL.path)) tools describe \(quoted(server.id)) <tool-name>

        Call it with a JSON argument file:
        \(quoted(executable)) --config \(quoted(model.profileURL.path)) call \(quoted(server.id)) <tool-name> --args-file /absolute/path/to/arguments.json

        Use the same full executable path and --config option for every command.
        For shared sessions, click Connect & keep open and leave this app open.
        Add --session to require that connection; --live refreshes tools through it.
        --cached reads saved schemas only. Cached tools do not prove live availability.
        Shared calls run in the desktop app's environment and credentials through a private
        Unix-domain socket. Honor the agent's normal permissions and approvals. Do not bypass restrictions.
        If a shared session is unavailable, reconnect in the app; there is no silent direct fallback.
        --direct explicitly creates a separate connection, useful while the app is closed.
        Read the JSON result and exit code. Never automatically retry a failed or timed-out call.
        An empty studio list does not prove that Studio is closed.
        """
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Label("Ready for your agent", systemImage: "terminal").font(.title2.weight(.semibold))
                Text("Save the tool catalog once, then give these instructions to your agent. Refresh after changing the server or its tools.").foregroundStyle(.secondary)
                HStack {
                    Button("Discover & cache tools") { model.run(server, .listTools, label: "Discover & cache tools", discover: true) }
                        .disabled(model.busy || !server.enabled)
                    Button("Copy instructions") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(instructions, forType: .string) }
                        .buttonStyle(.borderedProminent)
                }
                Text(model.status).font(.caption).foregroundStyle(.secondary)
                Text(instructions).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Color(nsColor: .textBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 8))
            }.padding(24)
        }
    }
}

struct CredentialView: View {
    @Environment(\.dismiss) var dismiss
    @State private var name = ""
    @State private var value = ""
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Save a credential", systemImage: "key.fill").font(.title2.weight(.semibold))
            Text("Values are stored in macOS Keychain. Profiles contain only the reference name.").foregroundStyle(.secondary)
            TextField("Reference name (for example, service-token)", text: $name)
            SecureField("Credential value", text: $value)
            Text("Use {\"source\": \"keychain\", \"name\": \"\(name.isEmpty ? "service-token" : name)\"} in your server configuration.")
                .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Spacer()
                Button("Cancel") { value = ""; dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save to Keychain") {
                    do { try CredentialStore.save(name, value: value); value = ""; dismiss() }
                    catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).disabled(name.isEmpty || value.isEmpty)
            }
        }.padding(28).frame(width: 460)
    }
}
