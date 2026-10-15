import Foundation

/// Watches a single file via kqueue (DispatchSource) and calls back on the main queue.
/// Survives atomic saves (rename over the original) by reopening the path.
final class FileWatcher {
    private let path: String
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?

    init(path: String, onChange: @escaping () -> Void) {
        self.path = path
        self.onChange = onChange
        start()
    }

    deinit { source?.cancel() }

    private func start() {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            // File missing (mid atomic save?) — retry shortly.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.start() }
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename, .attrib],
            queue: .main
        )
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = src.data
            self.debounce()
            if flags.contains(.delete) || flags.contains(.rename) {
                src.cancel()
                self.source = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.start() }
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    private func debounce() {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.onChange() }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: item)
    }
}
