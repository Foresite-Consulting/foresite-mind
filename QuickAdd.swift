// The quick-add box: a small floating bar that sends one line to the Action List queue through the Mind page.

import AppKit

final class QuickAddPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

final class QuickAdd: NSObject {
    private var panel: QuickAddPanel!
    private var field: NSTextField!
    private var note: NSTextField!
    private var busy = false
    /// Sends the text; calls back with nil on success or a plain-English error.
    var send: ((String, @escaping (String?) -> Void) -> Void)?

    override init() {
        super.init()
        build()
    }

    private func build() {
        panel = QuickAddPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 96),
                              styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = ink
        panel.isReleasedWhenClosed = false
        panel.onCancel = { [weak self] in self?.hide() }

        let content = NSView()
        panel.contentView = content

        let eyebrow = NSTextField(labelWithString: "ADD TO ACTION LIST")
        eyebrow.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        eyebrow.textColor = jade

        field = NSTextField()
        field.placeholderAttributedString = NSAttributedString(
            string: "What needs doing — who asked, by when",
            attributes: [.foregroundColor: NSColor(white: 1, alpha: 0.35), .font: NSFont.systemFont(ofSize: 18)])
        field.font = .systemFont(ofSize: 18)
        field.textColor = .white
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.target = self
        field.action = #selector(submit)

        note = NSTextField(labelWithString: "Enter to send · Esc to close · lands in Inbox — needs triage at the next 8am run")
        note.font = .systemFont(ofSize: 11)
        note.textColor = NSColor(white: 1, alpha: 0.45)

        for v in [eyebrow, field!, note!] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            eyebrow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            eyebrow.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            field.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            field.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            field.topAnchor.constraint(equalTo: eyebrow.bottomAnchor, constant: 6),
            note.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            note.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            note.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 8),
        ])
    }

    func show() {
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.midX - panel.frame.width / 2, y: f.minY + f.height * 0.68))
        }
        resetNote()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    func hide() { panel.orderOut(nil) }

    private func resetNote() {
        note.textColor = NSColor(white: 1, alpha: 0.45)
        note.stringValue = "Enter to send · Esc to close · lands in Inbox — needs triage at the next 8am run"
    }

    @objc private func submit() {
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy, let send = send else { return }
        busy = true
        field.isEditable = false
        note.textColor = NSColor(white: 1, alpha: 0.6)
        note.stringValue = "Sending…"
        send(text) { [weak self] error in
            guard let self = self else { return }
            self.busy = false
            self.field.isEditable = true
            if let error = error {
                self.note.textColor = coral
                self.note.stringValue = "Not sent. " + error
                self.panel.makeFirstResponder(self.field)
            } else {
                self.field.stringValue = ""
                self.note.textColor = jade
                self.note.stringValue = "Queued ✓  It moves into your Action List at the next 8am run."
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { self.hide() }
            }
        }
    }
}
