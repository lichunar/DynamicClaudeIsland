import Foundation

final class TerminalSessionSender {
    func send(
        _ message: String,
        toTTY tty: String,
        processId: Int?,
        completion: @escaping @MainActor (Bool, String) -> Void
    ) {
        if let processId,
           currentTTY(for: processId) != tty {
            Task { @MainActor in
                completion(false, "session-process-mismatch")
            }
            return
        }

        let process = Process()
        let output = Pipe()
        let errorOutput = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e", Self.script,
            tty,
            message
        ]
        process.standardOutput = output
        process.standardError = errorOutput

        process.terminationHandler = { finishedProcess in
            let stdout = output.fileHandleForReading.readDataToEndOfFile()
            let stderr = errorOutput.fileHandleForReading.readDataToEndOfFile()
            let text = (String(data: stdout + stderr, encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let ok = finishedProcess.terminationStatus == 0 && text == "sent"
            Task { @MainActor in
                completion(ok, text)
            }
        }

        do {
            try process.run()
        } catch {
            Task { @MainActor in
                completion(false, error.localizedDescription)
            }
        }
    }

    private func currentTTY(for processId: Int) -> String? {
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

    private static let script = """
on run argv
  set targetTty to item 1 of argv
  set payload to item 2 of argv
  tell application "Terminal"
    repeat with w in windows
      repeat with t in tabs of w
        if tty of t is targetTty then
          do script payload in t
          return "sent"
        end if
      end repeat
    end repeat
  end tell
  return "not-found"
end run
"""
}
