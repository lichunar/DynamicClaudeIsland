import Foundation

struct ClaudeSessionEvent {
    enum Kind {
        case assistantReply
        case needsAttention
        case finished
        case error
    }

    var kind: Kind
    var session: ClaudeSession
    var title: String
    var body: String
}

final class ClaudeSessionEventMonitor {
    private var transcriptOffsets: [String: UInt64] = [:]
    private var sessionStatuses: [String: String] = [:]

    func prime(with sessions: [ClaudeSession]) {
        for session in sessions {
            if let path = session.transcriptPath {
                transcriptOffsets[path] = fileSize(at: path)
            }
            if let status = session.status {
                sessionStatuses[session.resumeId] = status
            }
        }
    }

    func events(from sessions: [ClaudeSession]) -> [ClaudeSessionEvent] {
        var events: [ClaudeSessionEvent] = []
        for session in sessions {
            events.append(contentsOf: transcriptEvents(for: session))
            if let statusEvent = statusEvent(for: session) {
                events.append(statusEvent)
            }
        }
        return events
    }

    private func transcriptEvents(for session: ClaudeSession) -> [ClaudeSessionEvent] {
        guard let path = session.transcriptPath else {
            return []
        }

        let size = fileSize(at: path)
        let previousOffset = transcriptOffsets[path] ?? size
        if previousOffset == size {
            transcriptOffsets[path] = size
            return []
        }

        let startOffset = previousOffset > size ? 0 : previousOffset
        transcriptOffsets[path] = size
        guard let raw = readFile(path: path, from: startOffset) else {
            return []
        }

        return raw
            .split(separator: "\n")
            .compactMap { event(fromTranscriptLine: String($0), session: session) }
    }

    private func statusEvent(for session: ClaudeSession) -> ClaudeSessionEvent? {
        guard let status = session.status else {
            return nil
        }

        let previousStatus = sessionStatuses[session.resumeId]
        sessionStatuses[session.resumeId] = status
        guard previousStatus != nil, previousStatus != status else {
            return nil
        }

        let normalized = status.lowercased()
        if needsAttentionStatus(normalized) {
            return ClaudeSessionEvent(
                kind: .needsAttention,
                session: session,
                title: "Claude Code 需要确认",
                body: "\(session.name) 正在等待你处理。"
            )
        }

        if normalized == "idle", let previousStatus, previousStatus.lowercased() != "idle" {
            return ClaudeSessionEvent(
                kind: .finished,
                session: session,
                title: "Claude Code 已完成",
                body: "\(session.name) 已回到空闲状态。"
            )
        }

        return nil
    }

    private func event(fromTranscriptLine line: String, session: ClaudeSession) -> ClaudeSessionEvent? {
        guard let object = jsonObject(from: line) else {
            return nil
        }

        let type = object["type"] as? String
        if type == "assistant",
           let message = object["message"] as? [String: Any],
           let content = plainText(from: message["content"]) {
            let snippet = clipped(content)
            return ClaudeSessionEvent(
                kind: .assistantReply,
                session: session,
                title: "Claude 有新回复",
                body: "\(session.name)：\(snippet)"
            )
        }

        if type == "system", object["subtype"] as? String == "api_error" {
            return ClaudeSessionEvent(
                kind: .error,
                session: session,
                title: "Claude Code 出错",
                body: "\(session.name)：\(errorMessage(from: object))"
            )
        }

        if needsAttentionLine(line, object: object) {
            return ClaudeSessionEvent(
                kind: .needsAttention,
                session: session,
                title: "Claude Code 需要确认",
                body: "\(session.name) 正在等待你确认或授权。"
            )
        }

        return nil
    }

    private func needsAttentionStatus(_ status: String) -> Bool {
        let tokens = ["confirm", "permission", "approval", "waiting", "input", "prompt"]
        return tokens.contains { status.contains($0) }
    }

    private func needsAttentionLine(_ line: String, object: [String: Any]) -> Bool {
        if object["type"] as? String == "permission-mode" {
            return false
        }

        let lowercased = line.lowercased()
        let tokens = [
            "needs approval",
            "requires approval",
            "permission prompt",
            "waiting for approval",
            "waiting for confirmation",
            "do you want to proceed",
            "需要确认",
            "等待确认",
            "请求权限",
            "需要授权",
            "等待授权"
        ]
        return tokens.contains { lowercased.contains($0) }
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

    private func errorMessage(from object: [String: Any]) -> String {
        if let error = object["error"] as? [String: Any],
           let nested = error["error"] as? [String: Any],
           let innermost = nested["error"] as? [String: Any],
           let message = innermost["message"] as? String {
            return clipped(normalize(message))
        }

        return "运行时出现错误。"
    }

    private func jsonObject(from line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else {
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func readFile(path: String, from offset: UInt64) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return nil
        }
        defer {
            try? handle.close()
        }

        do {
            try handle.seek(toOffset: offset)
            let data = handle.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    private func fileSize(at path: String) -> UInt64 {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: path),
            let size = attributes[.size] as? NSNumber
        else {
            return 0
        }
        return size.uint64Value
    }

    private func normalize(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func clipped(_ text: String, limit: Int = 120) -> String {
        guard text.count > limit else {
            return text
        }
        return "\(text.prefix(limit))..."
    }
}
