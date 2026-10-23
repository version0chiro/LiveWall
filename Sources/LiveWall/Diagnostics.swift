import Darwin
import Foundation

enum LiveWallDiagnostics {
    private static let logger = DiagnosticLogger()

    static var suggestedFilename: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "LiveWall-Diagnostics-\(formatter.string(from: Date())).txt"
    }

    static func log(_ message: String) {
        logger.record(message)
    }

    static func redactedPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home {
            return "~"
        }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    static func makeReport(
        details: [String: String],
        includeLog: Bool = true
    ) -> String {
        let bundle = Bundle.main
        let version = bundle.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "development"
        let build = bundle.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "development"

        var lines = [
            "LiveWall Diagnostics",
            "Generated: \(ISO8601DateFormatter().string(from: Date()))",
            "Version: \(version) (\(build))",
            "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Process architecture: \(processArchitecture)",
            "Hardware: \(hardwareModel)",
            ""
        ]

        for key in details.keys.sorted() {
            let value = details[key] ?? ""
            lines.append("\(key): \(redactingHome(in: value))")
        }

        if includeLog {
            lines.append("")
            lines.append("Recent LiveWall Log")
            lines.append("-------------------")
            let recentLog = logger.readLog()
            lines.append(
                recentLog.isEmpty
                    ? "No log entries are available."
                    : redactingHome(in: recentLog)
            )
        }

        return lines.joined(separator: "\n") + "\n"
    }

    static func writeReport(
        to url: URL,
        details: [String: String]
    ) throws {
        let report = makeReport(details: details)
        try report.write(to: url, atomically: true, encoding: .utf8)
        log("Exported diagnostics to \(redactedPath(url.path))")
    }

    private static var processArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    private static var hardwareModel: String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0,
              size > 0 else {
            return "unknown"
        }
        var value = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &value, &size, nil, 0) == 0 else {
            return "unknown"
        }
        return String(cString: value)
    }

    private static func redactingHome(in value: String) -> String {
        value.replacingOccurrences(
            of: NSHomeDirectory(),
            with: "~"
        )
    }
}

private final class DiagnosticLogger {
    private let lock = NSLock()
    private let fileManager = FileManager.default
    private let logDirectoryURL: URL
    private let logURL: URL
    private let previousLogURL: URL
    private let maximumLogSize = 2 * 1024 * 1024

    init() {
        let library = fileManager.urls(
            for: .libraryDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library", isDirectory: true)
        logDirectoryURL = library
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("LiveWall", isDirectory: true)
        logURL = logDirectoryURL.appendingPathComponent("LiveWall.log")
        previousLogURL = logDirectoryURL.appendingPathComponent(
            "LiveWall.previous.log"
        )
    }

    func record(_ message: String) {
        lock.lock()
        defer { lock.unlock() }

        do {
            try fileManager.createDirectory(
                at: logDirectoryURL,
                withIntermediateDirectories: true
            )
            try rotateIfNeeded()
            if !fileManager.fileExists(atPath: logURL.path) {
                fileManager.createFile(atPath: logURL.path, contents: nil)
            }

            let flattened = message
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let line = Data("[\(timestamp)] \(flattened)\n".utf8)
            let handle = try FileHandle(forWritingTo: logURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            try handle.close()
        } catch {
            fputs(
                "LiveWall diagnostics logging failed: \(error.localizedDescription)\n",
                stderr
            )
        }
    }

    func readLog() -> String {
        lock.lock()
        defer { lock.unlock() }

        let current = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        let previous = (
            try? String(contentsOf: previousLogURL, encoding: .utf8)
        ) ?? ""
        return [previous, current]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private func rotateIfNeeded() throws {
        let attributes = try? fileManager.attributesOfItem(atPath: logURL.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        guard size >= maximumLogSize else { return }

        if fileManager.fileExists(atPath: previousLogURL.path) {
            try fileManager.removeItem(at: previousLogURL)
        }
        try fileManager.moveItem(at: logURL, to: previousLogURL)
    }
}
