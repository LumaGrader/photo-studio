import Foundation
import AppKit

/// Runs exports in the background (two photos at a time) so you can keep working;
/// progress shows in the top bar. One job = one photo with one set of export options.
/// Used from the main thread.
final class ExportQueue: ObservableObject {
    struct Job {
        let photo: Photo
        let number: Int
        let options: ExportOptions
    }

    @Published private(set) var total = 0
    @Published private(set) var done = 0
    @Published private(set) var failures: [String] = []
    @Published private(set) var isRunning = false
    @Published private(set) var lastExported: URL?
    /// Each set of options used by the last export (Export with Previous).
    @Published private(set) var lastOptions: [ExportOptions] = []
    /// Counts export runs that finished with at least one file (the Support card watches it).
    @Published private(set) var finishedRuns = 0

    private var task: Task<Void, Never>?

    var progressText: String { "Exporting \(min(done + 1, total)) of \(total)…" }

    private var pending: [Job] = []

    /// Starts exporting, or adds to the queue when an export is already running.
    func start(_ jobs: [Job]) {
        guard !jobs.isEmpty else { return }
        // Every option set starts numbering at 1, so its first job carries it.
        lastOptions = jobs.filter { $0.number == 1 }.map(\.options)
        if isRunning {
            pending += jobs
            total += jobs.count
            return
        }
        pending = jobs
        total = jobs.count
        done = 0
        failures = []
        isRunning = true
        task = Task { @MainActor [weak self] in
            while let self, !self.pending.isEmpty {
                if Task.isCancelled { break }
                let batch = Array(self.pending.prefix(2))
                self.pending.removeFirst(batch.count)
                await withTaskGroup(of: Result<URL, Error>.self) { group in
                    for job in batch {
                        group.addTask(priority: .userInitiated) {
                            Result { try Exporter.export(job.photo, number: job.number, options: job.options) }
                        }
                    }
                    for await result in group {
                        switch result {
                        case .success(let url): self.lastExported = url
                        case .failure(let error): self.failures.append(error.localizedDescription)
                        }
                        self.done += 1
                    }
                }
            }
            // A cancelled run was already wound down by cancel(); don't touch a newer run.
            guard let self, !Task.isCancelled else { return }
            self.isRunning = false
            if self.done > self.failures.count { self.finishedRuns += 1 }
            self.finishedNotice()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        pending = []
        isRunning = false
    }

    func showInFinder() {
        if let lastExported { NSWorkspace.shared.activateFileViewerSelecting([lastExported]) }
    }

    /// Bounce the Dock icon when a long export finishes in the background.
    private func finishedNotice() {
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
    }
}
