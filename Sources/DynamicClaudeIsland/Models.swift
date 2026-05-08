import Foundation

struct ClaudeSession: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var workingDirectory: String
    var resumeId: String
    var commandPath: String
    var transcriptPath: String?
    var updatedAt: Date?
    var isOpen: Bool?
    var processId: Int?
    var terminalTTY: String?
    var status: String?

    static func defaultSession() -> ClaudeSession {
        ClaudeSession(
            id: UUID(),
            name: "默认会话",
            workingDirectory: FileManager.default.currentDirectoryPath,
            resumeId: "",
            commandPath: "/usr/bin/env claude",
            transcriptPath: nil,
            updatedAt: nil,
            isOpen: false,
            processId: nil,
            terminalTTY: nil,
            status: nil
        )
    }
}

enum RunnerState: Equatable {
    case idle
    case running(sessionName: String)
    case needsAttention(sessionName: String)
    case failed(message: String)

    var label: String {
        switch self {
        case .idle:
            "就绪"
        case .running(let sessionName):
            "运行中：\(sessionName)"
        case .needsAttention(let sessionName):
            "等待你确认：\(sessionName)"
        case .failed(let message):
            "失败：\(message)"
        }
    }
}

struct CommandResult {
    var output: String
    var exitCode: Int32
    var needsAttention: Bool
}
