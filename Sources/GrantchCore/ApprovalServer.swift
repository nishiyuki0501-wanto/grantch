import Darwin
import Foundation

public final class ApprovalServer: @unchecked Sendable {
    public typealias RequestHandler = @Sendable (ApprovalRequest) -> Void
    public typealias RequestEndedHandler = @Sendable (String) -> Void
    private let path: String
    private let listenerQueue = DispatchQueue(
        label: "com.wanto.grantch.socket.listener",
        qos: .userInitiated
    )
    private let clientQueue = DispatchQueue(
        label: "com.wanto.grantch.socket.clients",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private let sweepQueue = DispatchQueue(
        label: "com.wanto.grantch.socket.sweep",
        qos: .userInitiated
    )
    private let lock = NSLock()
    private var listener: Int32 = -1
    private struct Client {
        let descriptor: Int32
        let request: ApprovalRequest
        let processID: pid_t?
        let disconnectSource: DispatchSourceRead
        var lastHeartbeat: Date
    }
    private var clients: [String: Client] = [:]
    private var acceptSource: DispatchSourceRead?
    private var disconnectSweep: DispatchSourceTimer?
    private var handler: RequestHandler?
    private var requestEndedHandler: RequestEndedHandler?

    public init(path: String = SocketPath.current) { self.path = path }

    public var pendingRequestIDs: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return Set(clients.keys)
    }

    public func start(
        handler: @escaping RequestHandler,
        onRequestEnded: @escaping RequestEndedHandler = { _ in }
    ) throws {
        self.handler = handler
        requestEndedHandler = onRequestEnded
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(directory.path, 0o700)
        unlink(path)
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw GrantchError.socket(String(cString: strerror(errno))) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < pathCapacity else {
            close(listener)
            listener = -1
            throw GrantchError.socket("Path is too long")
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: pathCapacity) { destination in
                _ = path.withCString { source in
                    strlcpy(destination, source, pathCapacity)
                }
            }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(listener, 16) == 0 else {
            let message = String(cString: strerror(errno))
            close(listener)
            listener = -1
            throw GrantchError.socket(message)
        }
        chmod(path, 0o600)
        // Non-blocking so a connection that vanished before accept() cannot
        // stall the queue; the listener is closed only once the source is
        // cancelled, so its descriptor number is never reused under it.
        let fd = listener
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: listenerQueue)
        source.setEventHandler { [weak self] in self?.acceptPending(on: fd) }
        source.setCancelHandler { close(fd) }
        acceptSource = source
        startDisconnectSweep()
        source.resume()
    }

    public func resolve(_ response: ApprovalResponse) throws {
        lock.lock()
        let client = clients.removeValue(forKey: response.requestId)
        lock.unlock()
        guard let client else { throw GrantchError.timedOut }
        // The cancel handler closes the descriptor, so write before cancelling.
        defer { client.disconnectSource.cancel() }
        try SocketIO.writeLine(JSONEncoder.grantch.encode(response), to: client.descriptor)
    }

    public func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        listener = -1
        lock.lock()
        let activeClients = Array(clients.values)
        clients.removeAll()
        lock.unlock()
        activeClients.forEach { $0.disconnectSource.cancel() }
        disconnectSweep?.cancel()
        disconnectSweep = nil
        unlink(path)
    }

    private func acceptPending(on listener: Int32) {
        while true {
            let client = accept(listener, nil, nil)
            // EAGAIN: nothing left to accept; the source fires again when there is.
            guard client >= 0 else {
                // Out of descriptors: the source stays readable, so throttle it.
                if errno == EMFILE || errno == ENFILE { usleep(100_000) }
                return
            }
            // Accepted sockets inherit O_NONBLOCK on Darwin; reads here block.
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
            clientQueue.async { [weak self] in self?.receive(client) }
        }
    }

    private func receive(_ descriptor: Int32) {
        // The socket's file mode already limits it to this user; checking the
        // peer as well keeps that true if the mode or directory is loosened.
        var peerUser: uid_t = 0
        var peerGroup: gid_t = 0
        guard getpeereid(descriptor, &peerUser, &peerGroup) == 0, peerUser == getuid() else {
            close(descriptor)
            return
        }
        // A peer that never finishes a line must not hold a client thread forever.
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        do {
            let data = try SocketIO.readLine(from: descriptor)
            if let completion = try? JSONDecoder.grantch.decode(ApprovalCompletion.self, from: data), completion.type == "completed" {
                complete(completion)
                close(descriptor)
                return
            }
            let request = try JSONDecoder.grantch.decode(ApprovalRequest.self, from: data)
            guard request.expiresAt > Date() else { throw GrantchError.timedOut }
            let processID = peerProcessID(for: descriptor)
            lock.lock()
            // A reused ID would redirect the pending decision to another connection.
            guard clients[request.id] == nil else {
                lock.unlock()
                throw GrantchError.invalidInput
            }
            let disconnectSource = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: clientQueue)
            disconnectSource.setEventHandler { [weak self] in
                self?.handleClientMessage(request.id, descriptor: descriptor)
            }
            // Closing only once the source is cancelled keeps a running event
            // handler from reading a descriptor number that was already reused.
            disconnectSource.setCancelHandler { close(descriptor) }
            clients[request.id] = Client(
                descriptor: descriptor,
                request: request,
                processID: processID,
                disconnectSource: disconnectSource,
                lastHeartbeat: Date()
            )
            lock.unlock()
            disconnectSource.resume()
            handler?(request)
            clientQueue.asyncAfter(deadline: .now() + max(0, request.expiresAt.timeIntervalSinceNow)) { [weak self] in
                self?.expire(request.id)
            }
        } catch {
            close(descriptor)
        }
    }

    private func complete(_ completion: ApprovalCompletion) {
        lock.lock()
        let matching = clients.filter { completion.matches($0.value.request) }
        // Without a call ID, identical concurrent calls cannot be distinguished.
        let exact = completion.toolUseId != nil && matching.values.allSatisfy { $0.request.toolUseId != nil }
        let ids = completion.sessionEnded || completion.turnEnded || exact || matching.count == 1
            ? Array(matching.keys) : []
        lock.unlock()
        for id in ids {
            try? resolve(ApprovalResponse(requestId: id, decision: .native))
            requestEndedHandler?(id)
        }
    }

    private func expire(_ id: String) {
        lock.lock()
        let client = clients.removeValue(forKey: id)
        lock.unlock()
        guard let client else { return }
        // An unanswered request hands back to the CLI: Claude Code and Codex
        // show their own prompt, and Antigravity reads it as a denial.
        let response = ApprovalResponse(requestId: id, decision: .native)
        try? SocketIO.writeLine(try JSONEncoder.grantch.encode(response), to: client.descriptor)
        client.disconnectSource.cancel()
        requestEndedHandler?(id)
    }

    private func removeDisconnectedClient(_ id: String, descriptor: Int32) {
        lock.lock()
        let client = clients[id]
        let isCurrent = client?.descriptor == descriptor
        if isCurrent { clients.removeValue(forKey: id) }
        lock.unlock()
        guard isCurrent, let client else { return }
        client.disconnectSource.cancel()
        requestEndedHandler?(id)
    }

    private func handleClientMessage(_ id: String, descriptor: Int32) {
        do {
            let data = try SocketIO.readLine(from: descriptor)
            let heartbeat = try JSONDecoder.grantch.decode(ApprovalHeartbeat.self, from: data)
            guard heartbeat.type == "heartbeat", heartbeat.requestId == id else {
                removeDisconnectedClient(id, descriptor: descriptor)
                return
            }
            lock.lock()
            if clients[id]?.descriptor == descriptor {
                clients[id]?.lastHeartbeat = Date()
            }
            lock.unlock()
        } catch {
            removeDisconnectedClient(id, descriptor: descriptor)
        }
    }

    private func startDisconnectSweep() {
        let timer = DispatchSource.makeTimerSource(queue: sweepQueue)
        timer.schedule(
            deadline: .now() + .milliseconds(100),
            repeating: .milliseconds(100),
            leeway: .milliseconds(20)
        )
        timer.setEventHandler { [weak self] in self?.sweepDisconnectedClients() }
        disconnectSweep = timer
        timer.resume()
    }

    private func sweepDisconnectedClients() {
        lock.lock()
        let snapshot = clients.map {
            ($0.key, $0.value.descriptor, $0.value.processID, $0.value.lastHeartbeat)
        }
        lock.unlock()

        for (id, descriptor, processID, lastHeartbeat) in snapshot
            where Date().timeIntervalSince(lastHeartbeat) > 1
                || clientHasDisconnected(descriptor, processID: processID) {
            removeDisconnectedClient(id, descriptor: descriptor)
        }
    }

    private func clientHasDisconnected(_ descriptor: Int32, processID: pid_t?) -> Bool {
        if let processID, Darwin.kill(processID, 0) != 0, errno == ESRCH {
            return true
        }

        var status = pollfd(
            fd: descriptor,
            events: Int16(POLLIN | POLLHUP | POLLERR),
            revents: 0
        )
        let pollResult = Darwin.poll(&status, 1, 0)
        if pollResult < 0 { return errno != EINTR }
        if pollResult > 0, status.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 {
            return true
        }

        var byte: UInt8 = 0
        let readResult = Darwin.recv(descriptor, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
        return readResult == 0
            || (readResult < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)
    }

    private func peerProcessID(for descriptor: Int32) -> pid_t? {
        var processID: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        let result = withUnsafeMutablePointer(to: &processID) { pointer in
            getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, pointer, &length)
        }
        return result == 0 && processID > 0 ? processID : nil
    }

    deinit { stop() }
}

public extension JSONEncoder {
    static var grantch: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

public extension JSONDecoder {
    static var grantch: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
