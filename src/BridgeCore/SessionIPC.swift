import Foundation
import CryptoKit
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private struct SessionRequest: Codable, Sendable {
    let version: Int
    let server: String
    let fingerprint: String
    let operation: BridgeOperation
    let timeout: Double
}

/// One bounded, length-prefixed JSON exchange per connection. No TCP listener.
private final class LocalSocket: @unchecked Sendable {
    let fd: Int32
    init(_ fd: Int32) throws {
        guard fd >= 0 else { throw BridgeError(3, "Could not create local session socket.") }
        self.fd = fd
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        #if os(macOS)
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
    }
    deinit { close(fd) }
    func shutDown() { _ = shutdown(fd, Int32(SHUT_RDWR)) }
    func verifyPeer() throws {
        #if os(macOS)
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == geteuid() else {
            throw BridgeError(3, "Local session peer identity does not match this user.")
        }
        #elseif os(Linux)
        var credentials = ucred()
        var length = socklen_t(MemoryLayout<ucred>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &credentials, &length) == 0,
              credentials.uid == geteuid() else {
            throw BridgeError(3, "Local session peer identity does not match this user.")
        }
        #endif
    }
    func read(_ count: Int, deadline: ContinuousClock.Instant) async throws -> Data {
        var data = Data(), buffer = [UInt8](repeating: 0, count: min(count, 65536))
        while data.count < count {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw BridgeError(5, "Local session response timed out. No call was retried.") }
            let n = recv(fd, &buffer, min(buffer.count, count - data.count), 0)
            if n > 0 { data.append(contentsOf: buffer.prefix(n)); continue }
            if n == 0 { throw BridgeError(3, "Local session closed. A tool may already have completed; no call was retried.") }
            guard errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR else { throw BridgeError(3, "Local session read failed. No call was retried.") }
            try await Task.sleep(for: .milliseconds(10))
        }
        return data
    }
    func readFrame(deadline: ContinuousClock.Instant) async throws -> Data {
        let header = try await read(4, deadline: deadline)
        let count = header.reduce(0) { ($0 << 8) | Int($1) }
        guard count > 0, count <= 64 * 1024 * 1024 else { throw BridgeError(3, "Invalid local session frame size.") }
        return try await read(count, deadline: deadline)
    }
    func writeFrame(_ payload: Data, deadline: ContinuousClock.Instant) async throws {
        guard !payload.isEmpty, payload.count <= 64 * 1024 * 1024 else { throw BridgeError(3, "Local session result exceeds 64 MiB.") }
        let count = UInt32(payload.count)
        var data = Data([UInt8((count >> 24) & 255), UInt8((count >> 16) & 255), UInt8((count >> 8) & 255), UInt8(count & 255)])
        data.append(payload)
        var offset = 0
        while offset < data.count {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw BridgeError(5, "Local session send timed out. No call was retried.") }
            #if os(Linux)
            let flags = Int32(MSG_NOSIGNAL)
            #else
            let flags: Int32 = 0
            #endif
            let n = data.withUnsafeBytes { send(fd, $0.baseAddress!.advanced(by: offset), data.count - offset, flags) }
            if n > 0 { offset += n; continue }
            guard n < 0, errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR else { throw BridgeError(3, "Local session send failed. No call was retried.") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    func waitForDisconnect() async throws -> BridgeReply {
        var byte: UInt8 = 0
        while true {
            try Task.checkCancellation()
            let n = recv(fd, &byte, 1, MSG_PEEK)
            if n == 0 { throw BridgeError(3, "CLI disconnected; shared operation cancelled.") }
            if n > 0 { throw BridgeError(3, "Unexpected extra local session data.") }
            guard errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR else { throw BridgeError(3, "CLI connection lost.") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

private enum LocalEndpoint {
    static var directory: String { "/tmp/mcp-bridge-\(geteuid())" }
    static func path(_ profile: URL) -> String {
        let key = SHA256.hash(data: Data(profile.standardizedFileURL.resolvingSymlinksInPath().path.utf8))
            .prefix(16).map { String(format: "%02x", $0) }.joined()
        return directory + "/" + key + ".sock"
    }
    static func checkDirectory(create: Bool) throws {
        if create { _ = mkdir(directory, 0o700) }
        var info = stat()
        guard lstat(directory, &info) == 0, info.st_uid == geteuid(),
              info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o777 == 0o700 else {
            throw BridgeError(3, "Shared session unavailable or its directory permissions are invalid. Open MCP Bridge and connect this server.")
        }
    }
    static func checkSocket(_ path: String, missingOK: Bool = false) throws {
        var info = stat()
        if lstat(path, &info) != 0 {
            if missingOK && errno == ENOENT { return }
            throw BridgeError(3, "Shared session unavailable. Open MCP Bridge with this profile and connect the server.")
        }
        guard info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFSOCK, info.st_mode & 0o777 == 0o600 else {
            throw BridgeError(3, "Local session socket ownership or permissions are invalid.")
        }
    }
    static func address<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T) throws -> T {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        #if os(macOS)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        #endif
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw BridgeError(2, "Local socket path is too long.") }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in destination.copyBytes(from: bytes) }
        return try withUnsafePointer(to: &address) { ptr in
            try ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { try body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }
}

public enum SessionClient {
    public static func socketPath(profileURL: URL) -> String { LocalEndpoint.path(profileURL) }
    public static func execute(server: ServerConfiguration, profileURL: URL, operation: BridgeOperation, timeout: Double? = nil) async throws -> BridgeReply {
        try server.validate()
        let seconds = timeout ?? server.timeout
        guard seconds.isFinite, seconds > 0, seconds <= 86400 else { throw BridgeError(2, "Invalid timeout.") }
        if case .callTool(_, let data) = operation { _ = try BridgeRunner.arguments(data) }
        try LocalEndpoint.checkDirectory(create: false)
        let path = LocalEndpoint.path(profileURL)
        try LocalEndpoint.checkSocket(path)
        #if os(Linux)
        let socketType = Int32(SOCK_STREAM.rawValue)
        #else
        let socketType = SOCK_STREAM
        #endif
        let socket = try LocalSocket(socket(AF_UNIX, socketType, 0))
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds + 3))
        return try await withTaskCancellationHandler {
            let result = try LocalEndpoint.address(path) { connect(socket.fd, $0, $1) }
            if result != 0 {
                guard errno == EINPROGRESS else { throw BridgeError(3, "Cannot reach the app's shared session. Open MCP Bridge with this profile and connect the server. No direct fallback was attempted.") }
                while true {
                    try Task.checkCancellation()
                    guard ContinuousClock.now < deadline else { throw BridgeError(5, "Local connection timed out.") }
                    var descriptor = pollfd(fd: socket.fd, events: Int16(POLLOUT), revents: 0)
                    if poll(&descriptor, 1, 0) > 0 { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                var error: Int32 = 0, length = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(socket.fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else { throw BridgeError(3, "Shared session connection failed.") }
            }
            try socket.verifyPeer()
            let request = SessionRequest(version: 1, server: server.id, fingerprint: try ToolCatalog.fingerprint(server), operation: operation, timeout: seconds)
            try await socket.writeFrame(BridgeJSON.encode(request), deadline: deadline)
            let data = try await socket.readFrame(deadline: deadline)
            do { return try JSONDecoder().decode(BridgeReply.self, from: data) }
            catch { throw BridgeError(3, "Invalid reply from shared session. No call was retried.") }
        } onCancel: { socket.shutDown() }
    }
}

public actor SessionHost {
    private let profileURL: URL
    public let sessions: PersistentSessions
    private var listener: LocalSocket?
    private var lockFD: Int32 = -1
    private var acceptTask: Task<Void, Never>?
    private var workers: [UUID: Task<Void, Never>] = [:]
    public init(profileURL: URL, sessions: PersistentSessions) { self.profileURL = profileURL; self.sessions = sessions }

    public func start() throws {
        guard listener == nil else { return }
        try LocalEndpoint.checkDirectory(create: true)
        let path = LocalEndpoint.path(profileURL)
        let lock = open(path + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw BridgeError(3, "Cannot lock the local session endpoint.") }
        var info = stat()
        guard fstat(lock, &info) == 0, info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o777 == 0o600, flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            close(lock)
            throw BridgeError(3, "Another MCP Bridge app owns this profile, or endpoint permissions are invalid. Close that app before connecting here.")
        }
        var bound = false
        do {
            try LocalEndpoint.checkSocket(path, missingOK: true)
            _ = unlink(path)
            #if os(Linux)
            let socketType = Int32(SOCK_STREAM.rawValue)
            #else
            let socketType = SOCK_STREAM
            #endif
            let socket = try LocalSocket(socket(AF_UNIX, socketType, 0))
            guard try LocalEndpoint.address(path, { bind(socket.fd, $0, $1) }) == 0 else { throw BridgeError(3, "Cannot bind local session socket.") }
            bound = true
            guard chmod(path, 0o600) == 0, listen(socket.fd, 32) == 0 else { throw BridgeError(3, "Cannot listen on local session socket.") }
            listener = socket; lockFD = lock
            acceptTask = Task { await self.acceptConnections(socket) }
        } catch {
            if bound { _ = unlink(path) }
            close(lock)
            throw error
        }
    }

    private func acceptConnections(_ listener: LocalSocket) async {
        while !Task.isCancelled {
            let fd = accept(listener.fd, nil, nil)
            if fd < 0 {
                if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { break }
                do { try await Task.sleep(for: .milliseconds(25)) } catch { break }
                continue
            }
            do {
                let socket = try LocalSocket(fd)
                try socket.verifyPeer()
                guard workers.count < 64 else { socket.shutDown(); continue }
                let id = UUID()
                workers[id] = Task {
                    await self.handle(socket)
                    self.finished(id)
                }
            } catch { /* LocalSocket owns and closes accepted descriptors. */ }
        }
    }
    private func finished(_ id: UUID) { workers.removeValue(forKey: id) }

    private func handle(_ socket: LocalSocket) async {
        defer { socket.shutDown() }
        do {
            let frame = try await socket.readFrame(deadline: .now.advanced(by: .seconds(30)))
            let request = try JSONDecoder().decode(SessionRequest.self, from: frame)
            let reply: BridgeReply
            do {
                guard request.version == 1 else { throw BridgeError(3, "Unsupported local session protocol.") }
                // The app chooses configuration from disk, never a caller-supplied command or credential.
                let server = try ProfileStore.load(profileURL).server(request.server)
                guard server.keepConnected, try ToolCatalog.fingerprint(server) == request.fingerprint else {
                    throw BridgeError(2, "Shared session configuration changed or is disabled. Reconnect in the app. No tool was executed.")
                }
                reply = try await withThrowingTaskGroup(of: BridgeReply.self) { group in
                    group.addTask { try await self.sessions.execute(server: server, operation: request.operation, timeout: request.timeout) }
                    group.addTask { try await socket.waitForDisconnect() }
                    defer { group.cancelAll() }
                    return try await group.next()!
                }
            } catch {
                let error = error as? BridgeError ?? BridgeError(3, "Shared operation cancelled or failed. No call was retried.")
                reply = BridgeReply(data: BridgeJSON.error(error), exitCode: error.code)
            }
            try await socket.writeFrame(BridgeJSON.encode(reply), deadline: .now.advanced(by: .seconds(5)))
        } catch { /* A malformed or disconnected local client never launches a server. */ }
    }

    public func stop() async {
        let accepting = acceptTask
        acceptTask = nil
        accepting?.cancel(); listener?.shutDown()
        let current = Array(workers.values)
        for worker in current { worker.cancel() }
        await sessions.close()
        await accepting?.value
        for worker in current { await worker.value }
        workers.removeAll(); listener = nil
        if lockFD >= 0 {
            _ = unlink(LocalEndpoint.path(profileURL))
            close(lockFD); lockFD = -1
        }
    }
}
