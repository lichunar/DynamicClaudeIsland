import Foundation

final class SessionStore {
    private let fileURL: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let directory = base.appendingPathComponent("DynamicClaudeIsland", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("sessions.json")
    }

    func load() -> [ClaudeSession] {
        guard let data = try? Data(contentsOf: fileURL) else {
            let fallback = [ClaudeSession.defaultSession()]
            save(fallback)
            return fallback
        }

        do {
            let sessions = try JSONDecoder().decode([ClaudeSession].self, from: data)
            return sessions.isEmpty ? [ClaudeSession.defaultSession()] : sessions
        } catch {
            return [ClaudeSession.defaultSession()]
        }
    }

    func save(_ sessions: [ClaudeSession]) {
        do {
            let data = try JSONEncoder.pretty.encode(sessions)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            NSLog("Failed to save sessions: \(error.localizedDescription)")
        }
    }

    var configurationPath: String {
        fileURL.path
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
