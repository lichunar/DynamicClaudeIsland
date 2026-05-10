import AppKit

final class FloatingIslandPanel: NSPanel {
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
    }
}

final class DraggableIslandView: NSView {
    override var mouseDownCanMoveWindow: Bool {
        true
    }
}

@MainActor
protocol IslandPanelControllerDelegate: AnyObject {
    func islandPanel(_ controller: IslandPanelController, didSubmit prompt: String, session: ClaudeSession)
    func islandPanel(_ controller: IslandPanelController, didReply reply: String)
    func islandPanelDidCancel(_ controller: IslandPanelController)
    func islandPanelDidRequestQuit(_ controller: IslandPanelController)
    func islandPanelMouseDidEnter(_ controller: IslandPanelController)
    func islandPanelMouseDidExit(_ controller: IslandPanelController)
}

final class IslandPanelController: NSWindowController, NSTextFieldDelegate {
    weak var delegate: IslandPanelControllerDelegate?

    private enum DisplayMode {
        case compact
        case expanded
    }

    enum AttentionStyle {
        case reply
        case needsAttention
        case completed
        case error
    }

    private var sessions: [ClaudeSession]
    private var selectedSessionIndex = 0
    private var outputs: [UUID: String] = [:]
    private var isRunning = false
    private var trackingArea: NSTrackingArea?
    private var displayMode: DisplayMode = .compact
    private var attentionHint: String?

    private let compactSize = NSSize(width: 300, height: 36)
    private let expandedSize = NSSize(width: 760, height: 188)

    private let rootView = DraggableIslandView()
    private let compactLabel = NSTextField(labelWithString: "Claude Code · 就绪")
    private let statusLabel = NSTextField(labelWithString: "就绪")
    private let sessionPopup = NSPopUpButton()
    private let promptField = NSTextField()
    private let sendButton = NSButton(title: "发送", target: nil, action: nil)
    private let cancelButton = NSButton(title: "停止", target: nil, action: nil)
    private let closeButton = NSButton(title: "关闭", target: nil, action: nil)
    private let outputView = NSTextView()
    private let scrollView = NSScrollView()

    private let defaultBackgroundColor = NSColor(calibratedRed: 0.97, green: 0.96, blue: 0.93, alpha: 0.96)
    private let defaultBorderColor = NSColor(calibratedRed: 0.64, green: 0.58, blue: 0.50, alpha: 0.28)

    init(sessions: [ClaudeSession]) {
        self.sessions = sessions

        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let frame = Self.frame(size: compactSize, in: screenFrame)
        let panel = FloatingIslandPanel(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true

        super.init(window: panel)
        panel.contentView = rootView
        configureUI()
        reloadSessions()
        applyDisplayMode(.compact, animated: false)
        updateTrackingArea()
        panel.orderFrontRegardless()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func toggle() {
        switch displayMode {
        case .compact:
            expand()
        case .expanded:
            collapse()
        }
    }

    func show() {
        expand()
    }

    func expand() {
        applyDisplayMode(.expanded, animated: true)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(promptField)
    }

    func collapse() {
        applyDisplayMode(.compact, animated: true)
        window?.orderFrontRegardless()
    }

    var isExpanded: Bool {
        displayMode == .expanded
    }

    var isBusy: Bool {
        isRunning
    }

    var isEditingPrompt: Bool {
        window?.firstResponder === promptField.currentEditor()
    }

    func setState(_ state: RunnerState) {
        statusLabel.stringValue = state.label
        compactLabel.stringValue = "Claude Code · \(state.label)"
        if state == .idle {
            attentionHint = nil
            applyAttentionStyle(nil)
        }
        switch state {
        case .idle:
            isRunning = false
            promptField.placeholderString = "给 Claude Code 发送指令..."
            sendButton.title = "发送"
            sendButton.isEnabled = true
            cancelButton.isEnabled = false
            sessionPopup.isEnabled = true
        case .running, .needsAttention:
            isRunning = true
            promptField.placeholderString = "回复正在运行的 Claude Code..."
            sendButton.title = "回复"
            sendButton.isEnabled = true
            cancelButton.isEnabled = true
            sessionPopup.isEnabled = false
        case .failed:
            isRunning = false
            promptField.placeholderString = "给 Claude Code 发送指令..."
            sendButton.title = "发送"
            sendButton.isEnabled = true
            cancelButton.isEnabled = false
            sessionPopup.isEnabled = true
        }
    }

    func showAttentionHint(_ text: String, style: AttentionStyle = .reply) {
        attentionHint = text
        compactLabel.stringValue = text
        statusLabel.stringValue = text
        applyAttentionStyle(style)
    }

    func beginMessage(_ text: String, for session: ClaudeSession) {
        outputs[session.id] = text
        if selectedSession()?.id == session.id {
            outputView.string = text
        }
    }

    func refreshSessions(_ updatedSessions: [ClaudeSession], previews: [UUID: String] = [:]) {
        let shouldKeepFocus = isEditingPrompt
        let selectedResumeId = selectedSession()?.resumeId
        let oldResumeIds = sessions.map(\.resumeId)
        let newResumeIds = updatedSessions.map(\.resumeId)
        sessions = updatedSessions
        for (sessionId, preview) in previews where !preview.isEmpty {
            if !isRunning || outputs[sessionId, default: ""].isEmpty {
                outputs[sessionId] = preview
            }
        }
        if let selectedResumeId,
           let index = sessions.firstIndex(where: { $0.resumeId == selectedResumeId }) {
            selectedSessionIndex = index
        } else {
            selectedSessionIndex = 0
        }
        if oldResumeIds != newResumeIds {
            reloadSessions()
        } else if let selected = selectedSession() {
            outputView.string = outputs[selected.id, default: ""]
            outputView.scrollToEndOfDocument(nil)
        }
        compactLabel.stringValue = compactTitle()
        if let attentionHint {
            statusLabel.stringValue = attentionHint
        }
        if shouldKeepFocus {
            window?.makeFirstResponder(promptField)
        }
    }

    func appendOutput(_ text: String, for session: ClaudeSession? = nil) {
        let target = session ?? selectedSession()
        guard let target else {
            return
        }
        outputs[target.id, default: ""] += text
        if selectedSession()?.id == target.id {
            outputView.string = outputs[target.id, default: ""]
            outputView.scrollToEndOfDocument(nil)
        }
    }

    private func configureUI() {
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = defaultBackgroundColor.cgColor
        rootView.layer?.cornerRadius = 18
        rootView.layer?.borderColor = defaultBorderColor.cgColor
        rootView.layer?.borderWidth = 1

        [compactLabel, statusLabel, sessionPopup, promptField, sendButton, cancelButton, closeButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            rootView.addSubview($0)
        }

        compactLabel.alignment = .center
        compactLabel.lineBreakMode = .byTruncatingTail
        compactLabel.textColor = NSColor(calibratedRed: 0.20, green: 0.17, blue: 0.14, alpha: 1)
        compactLabel.font = .systemFont(ofSize: 13, weight: .semibold)

        statusLabel.textColor = NSColor(calibratedRed: 0.24, green: 0.21, blue: 0.18, alpha: 1)
        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)

        sessionPopup.target = self
        sessionPopup.action = #selector(selectSession)
        sessionPopup.contentTintColor = NSColor(calibratedRed: 0.20, green: 0.18, blue: 0.16, alpha: 1)

        promptField.placeholderString = "给 Claude Code 发送指令..."
        promptField.delegate = self
        promptField.target = self
        promptField.action = #selector(sendPrompt)
        promptField.font = .systemFont(ofSize: 15)
        promptField.focusRingType = .none
        promptField.textColor = NSColor(calibratedRed: 0.12, green: 0.11, blue: 0.10, alpha: 1)

        [sendButton, cancelButton, closeButton].forEach { button in
            button.bezelStyle = .rounded
            button.contentTintColor = NSColor(calibratedRed: 0.12, green: 0.10, blue: 0.08, alpha: 1)
        }
        sendButton.target = self
        sendButton.action = #selector(sendPrompt)

        cancelButton.target = self
        cancelButton.action = #selector(cancelRun)
        cancelButton.isEnabled = false

        closeButton.target = self
        closeButton.action = #selector(closeIsland)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        outputView.isEditable = false
        outputView.isSelectable = true
        outputView.drawsBackground = false
        outputView.textColor = NSColor(calibratedRed: 0.18, green: 0.16, blue: 0.14, alpha: 1)
        outputView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        scrollView.documentView = outputView
        rootView.addSubview(scrollView)

        NSLayoutConstraint.activate([
            compactLabel.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 18),
            compactLabel.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -18),
            compactLabel.centerYAnchor.constraint(equalTo: rootView.centerYAnchor),

            statusLabel.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 24),
            statusLabel.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 14),

            sessionPopup.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -8),
            sessionPopup.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            sessionPopup.widthAnchor.constraint(equalToConstant: 220),

            closeButton.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -24),
            closeButton.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 72),

            promptField.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 24),
            promptField.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 12),
            promptField.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -10),
            promptField.heightAnchor.constraint(equalToConstant: 32),

            sendButton.trailingAnchor.constraint(equalTo: cancelButton.leadingAnchor, constant: -8),
            sendButton.centerYAnchor.constraint(equalTo: promptField.centerYAnchor),
            sendButton.widthAnchor.constraint(equalToConstant: 72),

            cancelButton.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -24),
            cancelButton.centerYAnchor.constraint(equalTo: promptField.centerYAnchor),
            cancelButton.widthAnchor.constraint(equalToConstant: 72),

            scrollView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 24),
            scrollView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -24),
            scrollView.topAnchor.constraint(equalTo: promptField.bottomAnchor, constant: 8),
            scrollView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -12)
        ])
    }

    private func reloadSessions() {
        sessionPopup.removeAllItems()
        sessionPopup.addItems(withTitles: sessions.map(\.name))
        selectedSessionIndex = min(selectedSessionIndex, max(0, sessions.count - 1))
        sessionPopup.selectItem(at: selectedSessionIndex)
        if let session = selectedSession() {
            outputView.string = outputs[session.id, default: ""]
        }
    }

    private func selectedSession() -> ClaudeSession? {
        guard sessions.indices.contains(selectedSessionIndex) else {
            return nil
        }
        return sessions[selectedSessionIndex]
    }

    @objc private func selectSession() {
        selectedSessionIndex = sessionPopup.indexOfSelectedItem
        if let session = selectedSession() {
            outputView.string = outputs[session.id, default: ""]
            compactLabel.stringValue = compactTitle()
        }
    }

    @objc private func sendPrompt() {
        let prompt = promptField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, let session = selectedSession() else {
            return
        }
        promptField.stringValue = ""

        if isRunning {
            delegate?.islandPanel(self, didReply: prompt)
            return
        }

        delegate?.islandPanel(self, didSubmit: prompt, session: session)
    }

    @objc private func cancelRun() {
        delegate?.islandPanelDidCancel(self)
    }

    @objc private func closeIsland() {
        delegate?.islandPanelDidRequestQuit(self)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard
            let event = NSApp.currentEvent,
            event.type == .keyDown,
            event.keyCode == 36
        else {
            return
        }
        sendPrompt()
    }

    override func mouseEntered(with event: NSEvent) {
        delegate?.islandPanelMouseDidEnter(self)
    }

    override func mouseExited(with event: NSEvent) {
        delegate?.islandPanelMouseDidExit(self)
    }

    override func windowDidLoad() {
        super.windowDidLoad()
        updateTrackingArea()
    }

    private func applyDisplayMode(_ mode: DisplayMode, animated: Bool) {
        displayMode = mode
        let expanded = mode == .expanded
        compactLabel.isHidden = expanded
        [statusLabel, sessionPopup, promptField, sendButton, cancelButton, closeButton, scrollView].forEach {
            $0.isHidden = !expanded
        }

        rootView.layer?.cornerRadius = expanded ? 28 : 18
        guard let window else {
            return
        }
        let screenFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let frame = Self.frame(
            size: expanded ? expandedSize : compactSize,
            in: screenFrame,
            anchoredTo: window.frame
        )
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window.animator().setFrame(frame, display: true)
            }
        } else {
            window.setFrame(frame, display: true)
        }
        window.orderFrontRegardless()
    }

    func keepVisible() {
        window?.orderFrontRegardless()
    }

    private func updateTrackingArea() {
        if let trackingArea {
            rootView.removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: rootView.bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        rootView.addTrackingArea(area)
        trackingArea = area
    }

    private static func frame(size: NSSize, in screenFrame: NSRect, anchoredTo currentFrame: NSRect? = nil) -> NSRect {
        let margin: CGFloat = 8
        let proposedX: CGFloat
        let proposedY: CGFloat

        if let currentFrame {
            proposedX = currentFrame.midX - size.width / 2
            proposedY = currentFrame.maxY - size.height
        } else {
            proposedX = screenFrame.midX - size.width / 2
            proposedY = screenFrame.maxY - size.height - margin
        }

        let minX = screenFrame.minX + margin
        let maxX = screenFrame.maxX - size.width - margin
        let minY = screenFrame.minY + margin
        let maxY = screenFrame.maxY - size.height - margin
        let x = maxX >= minX ? min(max(proposedX, minX), maxX) : screenFrame.midX - size.width / 2
        let y = maxY >= minY ? min(max(proposedY, minY), maxY) : screenFrame.midY - size.height / 2

        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func compactTitle() -> String {
        if let attentionHint {
            return attentionHint
        }
        guard let selected = selectedSession() else {
            return "Claude Code · 就绪"
        }
        return "Claude Code · \(selected.name)"
    }

    private func applyAttentionStyle(_ style: AttentionStyle?) {
        switch style {
        case nil:
            rootView.layer?.backgroundColor = defaultBackgroundColor.cgColor
            rootView.layer?.borderColor = defaultBorderColor.cgColor
            rootView.layer?.borderWidth = 1
        case .reply:
            rootView.layer?.backgroundColor = NSColor(calibratedRed: 0.98, green: 0.93, blue: 0.84, alpha: 0.97).cgColor
            rootView.layer?.borderColor = NSColor(calibratedRed: 0.92, green: 0.55, blue: 0.12, alpha: 0.58).cgColor
            rootView.layer?.borderWidth = 1.5
        case .needsAttention:
            rootView.layer?.backgroundColor = NSColor(calibratedRed: 1.00, green: 0.89, blue: 0.78, alpha: 0.98).cgColor
            rootView.layer?.borderColor = NSColor(calibratedRed: 0.95, green: 0.35, blue: 0.12, alpha: 0.72).cgColor
            rootView.layer?.borderWidth = 2
        case .completed:
            rootView.layer?.backgroundColor = NSColor(calibratedRed: 0.82, green: 0.98, blue: 0.72, alpha: 0.98).cgColor
            rootView.layer?.borderColor = NSColor(calibratedRed: 0.20, green: 0.70, blue: 0.20, alpha: 0.85).cgColor
            rootView.layer?.borderWidth = 2.5
        case .error:
            rootView.layer?.backgroundColor = NSColor(calibratedRed: 1.00, green: 0.84, blue: 0.84, alpha: 0.98).cgColor
            rootView.layer?.borderColor = NSColor(calibratedRed: 0.84, green: 0.12, blue: 0.14, alpha: 0.80).cgColor
            rootView.layer?.borderWidth = 2
        }
    }
}
