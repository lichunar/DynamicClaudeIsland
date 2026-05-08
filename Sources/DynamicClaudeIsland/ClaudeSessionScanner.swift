import Foundation

final class ClaudeSessionScanner {
    private let claudeDirectory: URL

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        claudeDirectory = homeDirectory.appendingPathComponent(".claude", isDirectory: true)
    }

    func scan() -> [ClaudeSession] {
        let projectSessions = scanProjectTranscripts()
        let openSessions = scanOpenSessions()

        let merged = projectSessions.map { session in
            var copy = session
            if let openSession = openSessions[session.resumeId] {
                copy.workingDirectory = openSession.workingDirectory
                copy.isOpen = true
                copy.processId = openSession.processId
                copy.terminalTTY = openSession.terminalTTY
                copy.status = openSession.status
                copy.updatedAt = maxDate(copy.updatedAt, openSession.updatedAt)
                copy.name = "● \(copy.name)"
            }
            return copy
        }

        return merged.sorted { lhs, rhs in
            let lhsOpen = lhs.isOpen ?? false
            let rhsOpen = rhs.isOpen ?? false
            if lhsOpen != rhsOpen {
                return lhsOpen && !rhsOpen
            }
            return (lhs.updatedAt ?? .distantPast) > (rhs.updatedAt ?? .distantPast)
        }
    }

    func transcriptPreview(for session: ClaudeSession, maxMessages: Int = 12) -> String {
        guard
            let path = session.transcriptPath,
            let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        else {
            return ""
        }
        defer {
            try? handle.close()
        }

        let data = handle.readDataToEndOfFile()
        guard let raw = String(data: data, encoding: .utf8) else {
            return ""
        }

        let messages = raw
            .split(separator: "\n")
            .compactMap { parseTranscriptLine(String($0)) }
            .suffix(maxMessages)

        return messages.joined(separator: "\n\n")
    }

    private func scanProjectTranscripts() -> [ClaudeSession] {
        let projectsDirectory = claudeDirectory.appendingPathComponent("projects", isDirectory: true)
        guard
            let enumerator = FileManager.default.enumerator(
                at: projectsDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return []
        }

        var sessions: [ClaudeSession] = []
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "jsonl" else {
                continue
            }
            if let session = parseTranscript(fileURL) {
                sessions.append(session)
            }
        }
        return sessions
    }

    private func parseTranscript(_ fileURL: URL) -> ClaudeSession? {
        guard let raw = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return nil
        }

        let fallbackSessionId = fileURL.deletingPathExtension().lastPathComponent
        var sessionId = fallbackSessionId
        var cwd = FileManager.default.homeDirectoryForCurrentUser.path
        var firstPrompt = ""
        var updatedAt = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)

        for line in raw.split(separator: "\n") {
            guard let object = jsonObject(from: String(line)) else {
                continue
            }

            if let value = object["sessionId"] as? String {
                sessionId = value
            }
            if let value = object["cwd"] as? String {
                cwd = value
            }
            if let timestamp = parseDate(object["timestamp"] as? String) {
                updatedAt = maxDate(updatedAt, timestamp)
            }
            if firstPrompt.isEmpty,
               object["type"] as? String == "user",
               let message = object["message"] as? [String: Any],
               let content = plainText(from: message["content"]) {
                firstPrompt = content
            }
        }

        let title = firstPrompt.isEmpty ? fileURL.deletingPathExtension().lastPathComponent : firstPrompt
        return ClaudeSession(
            id: stableUUID(from: sessionId),
            name: displayName(title: title, cwd: cwd),
            workingDirectory: cwd,
            resumeId: sessionId,
            commandPath: "/usr/bin/env claude",
            transcriptPath: fileURL.path,
            updatedAt: updatedAt,
            isOpen: false,
            processId: nil,
            terminalTTY: nil,
            status: nil
        )
    }

    private func scanOpenSessions() -> [String: (workingDirectory: String, updatedAt: Date?, processId: Int?, terminalTTY: String?, status: String?)] {
        let sessionsDirectory = claudeDirectory.appendingPathComponent("sessions", isDirectory: true)
        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: sessionsDirectory,
                includingPropertiesForKeys: nil
            )
        else {
            return [:]
        }

        var result: [String: (workingDirectory: String, updatedAt: Date?, processId: Int?, terminalTTY: String?, status: String?)] = [:]
        for file in files where file.pathExtension == "json" {
            guard
                let data = try? Data(contentsOf: file),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let sessionId = object["sessionId"] as? String
            else {
                continue
            }
            let cwd = object["cwd"] as? String ?? FileManager.default.homeDirectoryForCurrentUser.path
            let updatedAt = dateFromMilliseconds(object["updatedAt"])
            let processId = (object["pid"] as? NSNumber)?.intValue
            let tty = processId.flatMap { terminalTTY(for: $0) }
            let status = object["status"] as? String
            result[sessionId] = (cwd, updatedAt, processId, tty, status)
        }
        return result
    }

    private func terminalTTY(for processId: Int) -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "tty=", "-p", "\(processId)"]
        process.standardOutput = output
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        let tty = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let tty, !tty.isEmpty, tty != "??" else {
            return nil
        }
        return tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"
    }

    private func parseTranscriptLine(_ line: String) -> String? {
        guard let object = jsonObject(from: line) else {
            return nil
        }

        let type = object["type"] as? String
        if type == "user",
           let message = object["message"] as? [String: Any],
           let content = plainText(from: message["content"]) {
            return "你：\(content)"
        }

        if type == "assistant",
           let message = object["message"] as? [String: Any],
           let content = plainText(from: message["content"]) {
            return "Claude：\(content)"
        }

        if type == "last-prompt",
           let content = object["lastPrompt"] as? String {
            return "最近输入：\(content)"
        }

        return nil
    }

    private func jsonObject(from line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else {
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func plainText(from value: Any?) -> String? {
        if let string = value as? String {
            return normalize(string)
        }

        if let parts = value as? [[String: Any]] {
            let text = parts.compactMap { part -> String? in
                guard part["type"] as? String == "text" else {
                    return nil
                }
                return part["text"] as? String
            }.joined(separator: "\n")
            return text.isEmpty ? nil : normalize(text)
        }

        return nil
    }

    private func displayName(title: String, cwd: String) -> String {
        let cleanTitle = normalize(title)
        let shortTitle = cleanTitle.count > 28 ? "\(cleanTitle.prefix(28))..." : cleanTitle
        let directory = URL(fileURLWithPath: cwd).lastPathComponent
        if directory.isEmpty {
            return shortTitle
        }
        return "\(directory) · \(shortTitle)"
    }

    private func normalize(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parseDate(_ value: String?) -> Date? {
        guard let value else {
            return nil
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private func dateFromMilliseconds(_ value: Any?) -> Date? {
        if let number = value as? NSNumber {
            return Date(timeIntervalSince1970: number.doubleValue / 1000)
        }
        if let value = value as? Double {
            return Date(timeIntervalSince1970: value / 1000)
        }
        return nil
    }

    private func maxDate(_ lhs: Date?, _ rhs: Date?) -> Date? {
        guard let lhs else {
            return rhs
        }
        guard let rhs else {
            return lhs
        }
        return max(lhs, rhs)
    }

    private func stableUUID(from string: String) -> UUID {
        if let uuid = UUID(uuidString: string) {
            return uuid
        }

        var bytes = Array(string.utf8)
        if bytes.count < 16 {
            bytes += Array(repeating: 0, count: 16 - bytes.count)
        }
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
