import Foundation

/// Connects to the ZWM server over a UNIX domain socket,
/// sends a CommandRequest, and returns the CommandResponse.
public enum SocketClient {
    public static func send(
        _ request: CommandRequest,
        socketPath: String = ZWMSocket.defaultPath
    ) throws -> CommandResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ClientError.connectFailed(errno: errno)
        }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                for (i, byte) in pathBytes.enumerated() {
                    dest[i] = byte
                }
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            throw ClientError.connectFailed(errno: errno)
        }

        // Send request
        let requestData = try JSONEncoder().encode(request)
        try requestData.withUnsafeBytes { rawBuffer in
            guard let ptr = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < requestData.count {
                let n = write(fd, ptr + offset, requestData.count - offset)
                guard n > 0 else { throw ClientError.writeFailed(errno: errno) }
                offset += n
            }
        }

        // Signal end of write so server knows we're done
        shutdown(fd, SHUT_WR)

        // Read response
        var buffer = Data()
        let chunk = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { chunk.deallocate() }
        while true {
            let n = read(fd, chunk, 4096)
            if n > 0 {
                buffer.append(chunk, count: n)
            }
            if n <= 0 { break }
        }

        guard !buffer.isEmpty else {
            throw ClientError.emptyResponse
        }

        return try JSONDecoder().decode(CommandResponse.self, from: buffer)
    }
}

public enum ClientError: Error, Sendable {
    case connectFailed(errno: Int32)
    case writeFailed(errno: Int32)
    case emptyResponse
}
