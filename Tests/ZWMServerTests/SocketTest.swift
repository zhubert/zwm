#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Testing
@testable import ZWMCommon
@testable import ZWMServer

@Test func socketServerAndClientRoundTrip() throws {
    let socketPath = "/tmp/zwm-test-\(getpid()).sock"
    defer { unlink(socketPath) }

    let server = SocketServer(socketPath: socketPath) { request in
        CommandResponse(
            exitCode: 0,
            stdout: "handled: \(request.command) \(request.args.joined(separator: " "))",
            stderr: ""
        )
    }

    // Start server on a POSIX thread
    var thread: pthread_t?
    let serverBox = Unmanaged.passRetained(server as AnyObject)
    pthread_create(&thread, nil, { arg in
        let srv = Unmanaged<AnyObject>.fromOpaque(arg).takeRetainedValue() as! SocketServer
        try? srv.start()
        return nil
    }, serverBox.toOpaque())

    // Give server time to bind
    usleep(100_000) // 100ms

    let request = CommandRequest(command: "list-windows", args: ["--workspace", "1"])
    let response = try SocketClient.send(request, socketPath: socketPath)

    #expect(response.exitCode == 0)
    #expect(response.stdout == "handled: list-windows --workspace 1")
    #expect(response.stderr == "")
}

@Test func socketClientFailsWhenServerNotRunning() {
    let socketPath = "/tmp/zwm-test-noserver-\(getpid()).sock"
    let request = CommandRequest(command: "test", args: [])
    #expect(throws: ClientError.self) {
        try SocketClient.send(request, socketPath: socketPath)
    }
}
