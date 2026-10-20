import Foundation

/// Watches a hot folder (and its subfolders) for new photos written by the camera's tether
/// app (Canon EOS Utility, Nikon NX Tether, Sony Imaging Edge, Wi-Fi transfer, …).
///
/// A file counts only once it has stopped growing (same size and date on two looks),
/// because the tether app writes it while it downloads from the camera. Folder change
/// events trigger a look right away; a slow timer covers subfolders and network drives.
final class TetherWatcher {
    private let folder: URL
    private let queue = DispatchQueue(label: "darklab.tether", qos: .userInitiated)
    private let onNew: ([ScannedFile], [String: AutoOrient.Turn]) -> Void
    private var known: Set<String>
    /// path → (size, modified) from the last look, for files not yet complete.
    private var pending: [String: (size: Int64, modified: Date)] = [:]
    private var source: DispatchSourceFileSystemObject?
    private var timer: DispatchSourceTimer?
    private var recheckScheduled = false
    private var stopped = false

    /// - Parameters:
    ///   - known: files already there when tethering starts (not reported).
    ///   - onNew: complete new files, oldest first, on the main thread.
    /// - onNew also gets the Auto-Rotate turn of each file (by path), worked out here so the
    ///   main thread doesn't wait.
    init(folder: URL, known: Set<String>, onNew: @escaping ([ScannedFile], [String: AutoOrient.Turn]) -> Void) {
        self.folder = folder
        self.known = known
        self.onNew = onNew
    }

    func start() {
        queue.async { [self] in
            let fd = open(folder.path, O_EVTONLY)
            if fd >= 0 {
                let source = DispatchSource.makeFileSystemObjectSource(
                    fileDescriptor: fd, eventMask: [.write, .extend, .rename, .link], queue: queue)
                source.setEventHandler { [weak self] in self?.scheduleLook(after: 0.15) }
                source.setCancelHandler { close(fd) }
                source.resume()
                self.source = source
            }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 1.5, repeating: 1.5, leeway: .milliseconds(200))
            timer.setEventHandler { [weak self] in self?.look() }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() {
        queue.async { [self] in
            stopped = true
            source?.cancel()
            source = nil
            timer?.cancel()
            timer = nil
        }
    }

    deinit {
        source?.cancel()
        timer?.cancel()
    }

    // MARK: - On the watcher queue

    private func scheduleLook(after delay: Double) {
        guard !recheckScheduled, !stopped else { return }
        recheckScheduled = true
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.recheckScheduled = false
            self?.look()
        }
    }

    private func look() {
        guard !stopped, let files = try? FolderScanner.scan(folder) else { return }
        var ready: [ScannedFile] = []
        var stillPending: [String: (size: Int64, modified: Date)] = [:]
        for file in files {
            let path = file.url.path
            guard !known.contains(path) else { continue }
            if let last = pending[path], last.size == file.size, last.modified == file.modified, file.size > 0 {
                ready.append(file)
                known.insert(path)
            } else {
                stillPending[path] = (file.size, file.modified)
            }
        }
        pending = stillPending
        // Look again soon to confirm files that are still being written.
        if !pending.isEmpty { scheduleLook(after: 0.4) }
        guard !ready.isEmpty else { return }
        ready.sort { $0.modified == $1.modified ? $0.url.path < $1.url.path : $0.modified < $1.modified }
        var turns: [String: AutoOrient.Turn] = [:]
        if LibraryStore.autoRotateEnabled {
            for file in ready {
                let turn = AutoOrient.detect(file.url)
                if turn != .upright { turns[file.url.path] = turn }
            }
        }
        let onNew = onNew
        DispatchQueue.main.async { onNew(ready, turns) }
    }
}
