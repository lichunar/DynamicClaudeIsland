import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, IslandPanelControllerDelegate {
    private let store = SessionStore()
    private let sessionScanner = ClaudeSessionScanner()
    private let runner = ClaudeRunner()
    private let terminalSender = TerminalSessionSender()
    private let notifier = Notifier()
    private let eventMonitor = ClaudeSessionEventMonitor()
    private var panelController: IslandPanelController?
    private var statusItem: NSStatusItem?
    private var currentState: RunnerState = .idle
    private var currentSessionName = ""
    private var isPointerInIsland = false
    private var collapseTask: Task<Void, Never>?
    private var syncTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let discoveredSessions = loadSessions()
        let controller = IslandPanelController(sessions: discoveredSessions.sessions)
        controller.delegate = self
        panelController = controller
        controller.refreshSessions(discoveredSessions.sessions, previews: discoveredSessions.previews)
        eventMonitor.prime(with: discoveredSessions.sessions)

        configureStatusItem()
        startSessionSync()
    }

    func applicationWillTerminate(_ notification: Notification) {
        syncTimer?.invalidate()
        runner.cancel()
    }

    func islandPanel(_ controller: IslandPanelController, didSubmit prompt: String, session: ClaudeSession) {
        currentSessionName = session.name
        currentState = .running(sessionName: session.name)
        controller.setState(currentState)
        controller.appendOutput("\n> \(prompt)\n", for: session)

        if let tty = session.terminalTTY, session.isOpen == true {
            terminalSender.send(prompt, toTTY: tty, processId: session.processId) { [weak self, weak controller] ok, message in
                guard let self else {
                    return
                }
                currentState = .idle
                controller?.setState(currentState)
                if !ok {
                    notifier.send(
                        title: "发送失败",
                        body: "无法发送到原 Claude Code 窗口：\(message)"
                    )
                    runDetachedResume(prompt: prompt, session: session, controller: controller)
                    return
                }
                syncClaudeSessions()
            }
            return
        }

        runDetachedResume(prompt: prompt, session: session, controller: controller)
    }

    private func runDetachedResume(
        prompt: String,
        session: ClaudeSession,
        controller: IslandPanelController?
    ) {
        runner.runPrint(prompt: prompt, in: session) { [weak self, weak controller] result in
            guard let self else {
                return
            }

            if !result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                controller?.appendOutput("\n\(result.output)\n", for: session)
            }

            if result.exitCode == 0 {
                currentState = .idle
                notifier.send(
                    title: "Claude Code 已完成",
                    body: "\(session.name) 已成功完成。"
                )
            } else {
                let message = "Exit code \(result.exitCode)"
                currentState = .failed(message: message)
                notifier.send(
                    title: "Claude Code 运行失败",
                    body: "\(session.name): \(message)"
                )
            }

            controller?.setState(currentState)
            syncClaudeSessions()
        }
    }

    func islandPanel(_ controller: IslandPanelController, didReply reply: String) {
        controller.appendOutput("\n> \(reply)\n")
        if runner.sendReply(reply) {
            let sessionName = currentSessionName.isEmpty ? "Claude Code" : currentSessionName
            currentState = .running(sessionName: sessionName)
            controller.setState(currentState)
        } else {
            currentState = .failed(message: "没有正在运行的 Claude Code 进程")
            controller.setState(currentState)
            notifier.send(
                title: "回复没有发出",
                body: "当前没有正在运行的 Claude Code 进程。"
            )
        }
    }

    func islandPanelDidCancel(_ controller: IslandPanelController) {
        runner.cancel()
        currentSessionName = ""
        currentState = .idle
        controller.setState(currentState)
        controller.appendOutput("\n[已停止]\n")
    }

    func islandPanelDidRequestQuit(_ controller: IslandPanelController) {
        runner.cancel()
        NSApp.terminate(nil)
    }

    func islandPanelMouseDidEnter(_ controller: IslandPanelController) {
        isPointerInIsland = true
        collapseTask?.cancel()
        let discoveredSessions = loadSessions()
        controller.refreshSessions(discoveredSessions.sessions, previews: discoveredSessions.previews)
        controller.expand()
    }

    func islandPanelMouseDidExit(_ controller: IslandPanelController) {
        isPointerInIsland = false
        scheduleCollapseIfNeeded()
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "Claude"
        item.button?.target = self
        item.button?.action = #selector(togglePanel)

        let menu = NSMenu()
        let showItem = NSMenuItem(title: "显示灵动岛", action: #selector(togglePanel), keyEquivalent: " ")
        showItem.target = self
        menu.addItem(showItem)
        menu.addItem(NSMenuItem.separator())
        let configItem = NSMenuItem(title: "查看会话配置", action: #selector(openConfig), keyEquivalent: ",")
        configItem.target = self
        menu.addItem(configItem)
        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        item.menu = menu
        statusItem = item
    }

    @objc private func togglePanel() {
        panelController?.toggle()
    }

    @objc private func openConfig() {
        let alert = NSAlert()
        alert.messageText = "会话配置"
        alert.informativeText = store.configurationPath
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func scheduleCollapseIfNeeded() {
        collapseTask?.cancel()
        collapseTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            await MainActor.run {
                guard
                    let self,
                    !self.isPointerInIsland,
                    let panelController = self.panelController,
                    panelController.isExpanded,
                    !panelController.isBusy
                else {
                    return
                }
                panelController.collapse()
            }
        }
    }

    private func startSessionSync() {
        syncTimer?.invalidate()
        syncTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.syncClaudeSessions()
            }
        }
        syncTimer?.tolerance = 0.5
    }

    private func syncClaudeSessions() {
        guard let panelController else {
            return
        }
        let discoveredSessions = loadSessions()
        let events = eventMonitor.events(from: discoveredSessions.sessions)
        panelController.refreshSessions(discoveredSessions.sessions, previews: discoveredSessions.previews)
        handleSessionEvents(events)
        panelController.keepVisible()
    }

    private func handleSessionEvents(_ events: [ClaudeSessionEvent]) {
        guard let panelController else {
            return
        }

        for event in events {
            notifier.send(title: event.title, body: event.body)
        }

        guard let latest = events.last else {
            return
        }

        switch latest.kind {
        case .needsAttention:
            panelController.showAttentionHint(
                "Claude Code · 需要确认：\(latest.session.name)",
                style: .needsAttention
            )
        case .assistantReply:
            panelController.showAttentionHint(
                "Claude Code · 有新回复：\(latest.session.name)",
                style: .reply
            )
        case .finished:
            panelController.showAttentionHint(
                "Claude Code · 已完成：\(latest.session.name)",
                style: .completed
            )
        case .error:
            currentState = .failed(message: "Claude Code 出错")
            panelController.setState(currentState)
            panelController.showAttentionHint(
                "Claude Code · 出错：\(latest.session.name)",
                style: .error
            )
        }
    }

    private func loadSessions() -> (sessions: [ClaudeSession], previews: [UUID: String]) {
        let discovered = sessionScanner.scan()
        let sessions = discovered.isEmpty ? store.load() : discovered
        let previews = Dictionary(uniqueKeysWithValues: sessions.map { session in
            (session.id, sessionScanner.transcriptPreview(for: session))
        })
        return (sessions, previews)
    }
}

@main
struct DynamicClaudeIslandApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
