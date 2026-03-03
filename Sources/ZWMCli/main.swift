import Foundation
import ZWMCommon

let arguments = CommandLine.arguments.dropFirst()

guard let command = arguments.first else {
    printUsage()
    exit(1)
}

if command == "--help" || command == "-h" {
    printUsage()
    exit(0)
}

if command == "--version" || command == "-v" {
    print("zwm 0.1.0")
    exit(0)
}

let args = Array(arguments.dropFirst())
let request = CommandRequest(command: command, args: args)

do {
    let response = try SocketClient.send(request)
    if !response.stdout.isEmpty {
        print(response.stdout, terminator: "")
    }
    if !response.stderr.isEmpty {
        FileHandle.standardError.write(Data(response.stderr.utf8))
    }
    exit(response.exitCode)
} catch let error as ClientError {
    switch error {
    case .connectFailed:
        FileHandle.standardError.write(Data("Error: Cannot connect to zwm server. Is it running?\n".utf8))
    case .writeFailed:
        FileHandle.standardError.write(Data("Error: Failed to send command to server.\n".utf8))
    case .emptyResponse:
        FileHandle.standardError.write(Data("Error: Empty response from server.\n".utf8))
    }
    exit(1)
} catch {
    FileHandle.standardError.write(Data("Error: \(error)\n".utf8))
    exit(1)
}

func printUsage() {
    let usage = """
    Usage: zwm <command> [args...]

    Commands:
      list-windows           List all managed windows
      list-workspaces        List all workspaces
      focus <direction>      Focus window (left, right, up, down)
      move <direction>       Move window (left, right, up, down)
      workspace <name>       Switch to workspace
      move-to-workspace <n>  Move focused window to workspace
      layout <type>          Set layout (horizontal, vertical)
      close                  Close focused window
      fullscreen             Toggle fullscreen
      reload-config          Reload configuration

    Options:
      -h, --help             Show this help
      -v, --version          Show version
    """
    print(usage)
}
