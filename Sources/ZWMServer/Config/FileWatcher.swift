import Foundation

/// Watches files for modifications using DispatchSource.
public final class FileWatcher: @unchecked Sendable {
    private var sources: [DispatchSourceFileSystemObject] = []
    private let onChange: @Sendable () -> Void

    public init(paths: [String], onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        for path in paths {
            watchPath(path)
        }
    }

    private func watchPath(_ path: String) {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: DispatchQueue.global(qos: .utility)
        )

        source.setEventHandler { [weak self] in
            self?.onChange()
        }

        source.setCancelHandler {
            close(fd)
        }

        source.resume()
        sources.append(source)
    }

    public func stop() {
        for source in sources {
            source.cancel()
        }
        sources.removeAll()
    }

    deinit {
        stop()
    }
}
