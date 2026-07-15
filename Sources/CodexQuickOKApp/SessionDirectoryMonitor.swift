import Darwin
import Foundation

@MainActor
final class SessionDirectoryMonitor {
    enum MonitorError: Error {
        case cannotOpenDirectory
    }

    var onChange: (() -> Void)?

    private let directory: URL
    private let debounceInterval: TimeInterval
    private var descriptor: CInt = -1
    private var source: DispatchSourceFileSystemObject?
    private var debounce: DispatchWorkItem?

    init(directory: URL, debounceInterval: TimeInterval = 0.1) {
        self.directory = directory
        self.debounceInterval = debounceInterval
    }

    func start() throws {
        guard source == nil else { return }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else {
            throw MonitorError.cannotOpenDirectory
        }

        let descriptor = descriptor
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.scheduleChange()
        }
        source.setCancelHandler {
            close(descriptor)
        }
        self.source = source
        source.resume()
        onChange?()
    }

    func stop() {
        debounce?.cancel()
        debounce = nil
        source?.cancel()
        source = nil
        descriptor = -1
    }

    private func scheduleChange() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.debounce = nil
            self.onChange?()
        }
        debounce = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + debounceInterval,
            execute: work
        )
    }

    deinit {
        source?.cancel()
        if source == nil, descriptor >= 0 {
            close(descriptor)
        }
    }
}
