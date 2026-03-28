import Foundation

/// A simple UNIX domain socket server that accepts connections,
/// reads a JSON CommandRequest, dispatches to a handler, and writes back a JSON CommandResponse.
public final class SocketServer: Sendable {
    private let socketPath: String
    private let syncHandler: (@Sendable (CommandRequest) -> CommandResponse)?
    private let asyncHandler: (@Sendable (CommandRequest) async -> CommandResponse)?

    public init(socketPath: String, handler: @escaping @Sendable (CommandRequest) -> CommandResponse) {
        self.socketPath = socketPath
        self.syncHandler = handler
        self.asyncHandler = nil
    }

    public init(socketPath: String, asyncHandler: @escaping @Sendable (CommandRequest) async -> CommandResponse) {
        self.socketPath = socketPath
        self.syncHandler = nil
        self.asyncHandler = asyncHandler
    }

    /// Start listening for connections. This blocks the calling thread.
    /// Call from a detached Task or background thread.
    public func start() throws {
        // Remove stale socket file
        unlink(socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw SocketError.createFailed(errno: errno)
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            throw SocketError.pathTooLong
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                for (i, byte) in pathBytes.enumerated() {
                    dest[i] = byte
                }
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            throw SocketError.bindFailed(errno: errno)
        }

        guard listen(fd, 5) == 0 else {
            close(fd)
            throw SocketError.listenFailed(errno: errno)
        }

        while true {
            let clientFd = accept(fd, nil, nil)
            guard clientFd >= 0 else { continue }
            handleClient(clientFd)
        }
    }

    private func handleClient(_ clientFd: Int32) {
        defer { close(clientFd) }

        guard let data = readAll(clientFd) else { return }

        let response: CommandResponse
        if let request = try? JSONDecoder().decode(CommandRequest.self, from: data) {
            if let syncHandler {
                response = syncHandler(request)
            } else if let asyncHandler {
                let sem = DispatchSemaphore(value: 0)
                let box = ResponseBox()
                // Dispatch to main queue so the Task has proper executor context
                // for MainActor-isolated AppKit calls
                DispatchQueue.main.async {
                    Task { @Sendable in
                        let r = await asyncHandler(request)
                        box.set(r)
                        sem.signal()
                    }
                }
                sem.wait()
                response = box.get()
            } else {
                response = CommandResponse(exitCode: 1, stdout: "", stderr: "No handler configured\n")
            }
        } else {
            response = CommandResponse(exitCode: 1, stdout: "", stderr: "Invalid request JSON\n")
        }

        if let responseData = try? JSONEncoder().encode(response) {
            writeAll(clientFd, responseData)
        }
    }

    private func readAll(_ fd: Int32) -> Data? {
        var buffer = Data()
        let chunk = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { chunk.deallocate() }
        while true {
            let n = read(fd, chunk, 4096)
            if n > 0 {
                buffer.append(chunk, count: n)
            }
            if n < 4096 { break }
        }
        return buffer.isEmpty ? nil : buffer
    }

    private func writeAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { rawBuffer in
            guard let ptr = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let n = write(fd, ptr + offset, data.count - offset)
                if n <= 0 { break }
                offset += n
            }
        }
    }
}

public enum SocketError: Error, Sendable {
    case createFailed(errno: Int32)
    case bindFailed(errno: Int32)
    case listenFailed(errno: Int32)
    case pathTooLong
}

/// Thread-safe box for passing a CommandResponse between Task and semaphore.
private final class ResponseBox: @unchecked Sendable {
    private var value: CommandResponse = CommandResponse(exitCode: 1, stdout: "", stderr: "Internal error\n")
    func set(_ v: CommandResponse) { value = v }
    func get() -> CommandResponse { value }
}

// Re-export for server target convenience
@_exported import ZWMCommon
