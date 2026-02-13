import Foundation

enum Logger {
    private static let queue = DispatchQueue(label: "com.tabbed.logger", qos: .utility)
    private static let flushInterval: TimeInterval = 0.2
    private static let maxBufferedBytes = 32 * 1024

    private static let logURL: URL = {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Managers/
            .deletingLastPathComponent() // Tabbed/
            .deletingLastPathComponent() // version-a/
            .appendingPathComponent("logs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("Tabbed.log")
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private static var fileHandle: FileHandle?
    private static var flushTimer: DispatchSourceTimer?
    private static var pendingData = Data()
    private static var started = false

    static func log(_ message: String) {
        queue.async {
            startIfNeeded()
            let timestamp = dateFormatter.string(from: Date())
            let line = "[\(timestamp)] \(message)\n"
            if let data = line.data(using: .utf8) {
                pendingData.append(data)
                if pendingData.count >= maxBufferedBytes {
                    flushLocked()
                }
            }
        }
    }

    static func flush() {
        queue.async {
            flushLocked()
        }
    }

    static func flushAndClose() {
        queue.sync {
            flushLocked()
            fileHandle?.closeFile()
            fileHandle = nil
            flushTimer?.cancel()
            flushTimer = nil
            started = false
        }
    }

    private static func startIfNeeded() {
        guard !started else { return }
        started = true
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        fileHandle = try? FileHandle(forWritingTo: logURL)
        fileHandle?.seekToEndOfFile()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + flushInterval, repeating: flushInterval)
        timer.setEventHandler {
            flushLocked()
        }
        timer.resume()
        flushTimer = timer
    }

    private static func flushLocked() {
        guard !pendingData.isEmpty else { return }
        fileHandle?.write(pendingData)
        pendingData.removeAll(keepingCapacity: true)
    }
}
