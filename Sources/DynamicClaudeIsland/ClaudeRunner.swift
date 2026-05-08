import Foundation
import Darwin

final class ClaudeRunner: @unchecked Sendable {
    private var process: Process?
    private var terminalHandle: FileHandle?
    private var childHandles: [FileHandle] = []

    func run(
        prompt: String,
        in session: ClaudeSession,
        onOutput: @escaping @MainActor (String) -> Void,
        onNeedsAttention: @escaping @MainActor () -> Void,
        completion: @escaping @MainActor (CommandResult) -> Void
    ) {
        cancel()

        let process = Process()
        let terminal: PseudoTerminal
        do {
            terminal = try PseudoTerminal()
        } catch {
            Task { @MainActor in
                completion(CommandResult(
                    output: error.localizedDescription,
                    exitCode: -1,
                    needsAttention: false
                ))
            }
            return
        }

        let command = commandLine(for: prompt, session: session)

        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = URL(fileURLWithPath: session.workingDirectory)
        process.standardInput = terminal.stdin
        process.standardOutput = terminal.stdout
        process.standardError = terminal.stderr
        self.process = process
        self.terminalHandle = terminal.master
        self.childHandles = [terminal.stdin, terminal.stdout, terminal.stderr]

        let buffer = OutputBuffer()

        let handleData: @Sendable (Data) -> Void = { data in
            guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
                return
            }
            let cleanText = Self.cleanTerminalText(text)
            let needsAttention = Self.looksLikeAttentionPrompt(text)
            let shouldNotify = buffer.append(cleanText, needsAttention: needsAttention)
            Task { @MainActor in
                onOutput(cleanText)
                if shouldNotify {
                    onNeedsAttention()
                }
            }
        }

        terminal.master.readabilityHandler = { handle in
            handleData(handle.availableData)
        }

        process.terminationHandler = { finishedProcess in
            terminal.master.readabilityHandler = nil
            let snapshot = buffer.snapshot()
            let result = CommandResult(
                output: snapshot.output,
                exitCode: finishedProcess.terminationStatus,
                needsAttention: snapshot.needsAttention
            )
            Task { @MainActor in
                self.process = nil
                self.terminalHandle = nil
                self.childHandles = []
                completion(result)
            }
        }

        do {
            try process.run()
        } catch {
            self.process = nil
            Task { @MainActor in
                completion(CommandResult(
                    output: error.localizedDescription,
                    exitCode: -1,
                    needsAttention: false
                ))
            }
        }
    }

    func runPrint(
        prompt: String,
        in session: ClaudeSession,
        completion: @escaping @MainActor (CommandResult) -> Void
    ) {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        let command = printCommandLine(for: prompt, session: session)

        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = URL(fileURLWithPath: session.workingDirectory)
        process.standardOutput = stdout
        process.standardError = stderr
        self.process = process

        process.terminationHandler = { finishedProcess in
            let output = stdout.fileHandleForReading.readDataToEndOfFile()
            let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: output + errorOutput, encoding: .utf8) ?? ""
            Task { @MainActor in
                self.process = nil
                completion(CommandResult(
                    output: Self.cleanTerminalText(text),
                    exitCode: finishedProcess.terminationStatus,
                    needsAttention: Self.looksLikeAttentionPrompt(text)
                ))
            }
        }

        do {
            try process.run()
        } catch {
            Task { @MainActor in
                completion(CommandResult(
                    output: error.localizedDescription,
                    exitCode: -1,
                    needsAttention: false
                ))
            }
        }
    }

    @discardableResult
    func sendReply(_ reply: String) -> Bool {
        guard
            let process,
            process.isRunning,
            let data = "\(reply)\n".data(using: .utf8)
        else {
            return false
        }

        do {
            try terminalHandle?.write(contentsOf: data)
            return true
        } catch {
            NSLog("Failed to write reply: \(error.localizedDescription)")
            return false
        }
    }

    func cancel() {
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        terminalHandle = nil
        childHandles = []
    }

    private func commandLine(for prompt: String, session: ClaudeSession) -> String {
        var parts = [session.commandPath]
        if !session.resumeId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("--resume \(shellQuote(session.resumeId))")
        }
        parts.append(shellQuote(prompt))
        return parts.joined(separator: " ")
    }

    private func printCommandLine(for prompt: String, session: ClaudeSession) -> String {
        var parts = [session.commandPath]
        if !session.resumeId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("--resume \(shellQuote(session.resumeId))")
        }
        parts.append("-p \(shellQuote(prompt))")
        return parts.joined(separator: " ")
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func looksLikeAttentionPrompt(_ text: String) -> Bool {
        let lower = text.lowercased()
        let markers = [
            "do you want to proceed",
            "requires approval",
            "needs approval",
            "permission",
            "confirm",
            "continue?",
            "需要确认",
            "需要人工",
            "权限"
        ]
        return markers.contains { lower.contains($0) }
    }

    private static func cleanTerminalText(_ text: String) -> String {
        var result = text
        let patterns = [
            #"\u{001B}\[[0-?]*[ -/]*[@-~]"#,
            #"\u{001B}\][^\u{0007}]*(\u{0007}|\u{001B}\\)"#,
            #"[\u{0000}-\u{0008}\u{000B}\u{000C}\u{000E}-\u{001F}\u{007F}]"#
        ]
        for pattern in patterns {
            result = result.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return result
    }
}

private struct PseudoTerminal {
    let master: FileHandle
    let stdin: FileHandle
    let stdout: FileHandle
    let stderr: FileHandle

    init() throws {
        var masterFD: Int32 = 0
        var slaveFD: Int32 = 0
        guard openpty(&masterFD, &slaveFD, nil, nil, nil) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        master = FileHandle(fileDescriptor: masterFD, closeOnDealloc: true)
        stdin = FileHandle(fileDescriptor: dup(slaveFD), closeOnDealloc: true)
        stdout = FileHandle(fileDescriptor: dup(slaveFD), closeOnDealloc: true)
        stderr = FileHandle(fileDescriptor: dup(slaveFD), closeOnDealloc: true)
        close(slaveFD)
    }
}

private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var output = ""
    private var attention = false

    func append(_ text: String, needsAttention: Bool) -> Bool {
        lock.lock()
        let shouldNotify = needsAttention && !attention
        output += text
        attention = attention || needsAttention
        lock.unlock()
        return shouldNotify
    }

    func snapshot() -> (output: String, needsAttention: Bool) {
        lock.lock()
        let result = (output, attention)
        lock.unlock()
        return result
    }
}
