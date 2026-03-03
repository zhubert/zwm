import Foundation

/// Default UNIX domain socket path for ZWM IPC.
public enum ZWMSocket {
    public static var defaultPath: String {
        let uid = getuid()
        return "/tmp/zwm-\(uid).sock"
    }
}
