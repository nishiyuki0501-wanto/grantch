import Darwin
import Foundation

public enum SocketPath {
    public static var current: String {
        if let override = ProcessInfo.processInfo.environment["GRANTCH_SOCKET_PATH"], !override.isEmpty {
            return override
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Grantch/run/grantch.sock").path
    }
}

public enum SocketIO {
    public static func connect(path: String) throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw GrantchError.socket(String(cString: strerror(errno))) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < pathCapacity else {
            close(descriptor)
            throw GrantchError.socket("Path is too long")
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: pathCapacity) { destination in
                _ = path.withCString { source in
                    strlcpy(destination, source, pathCapacity)
                }
            }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let message = String(cString: strerror(errno))
            close(descriptor)
            throw GrantchError.socket(message)
        }
        return descriptor
    }

    public static func writeLine(_ data: Data, to descriptor: Int32) throws {
        var noSignal: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var payload = data
        payload.append(0x0A)
        try payload.withUnsafeBytes { bytes in
            var sent = 0
            while sent < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: sent), bytes.count - sent)
                guard count > 0 else { throw GrantchError.socket(String(cString: strerror(errno))) }
                sent += count
            }
        }
    }

    public static func readLine(from descriptor: Int32, limit: Int = 1_048_576) throws -> Data {
        var result = Data()
        var byte: UInt8 = 0
        while result.count < limit {
            let count = Darwin.read(descriptor, &byte, 1)
            guard count > 0 else { throw GrantchError.socket(count == 0 ? "Connection closed" : String(cString: strerror(errno))) }
            if byte == 0x0A { return result }
            result.append(byte)
        }
        throw GrantchError.socket("Message exceeds size limit")
    }
}
