//
//  AboutWindow.swift
//  AnyScroll
//

import Cocoa

@MainActor
final class AboutWindowController: NSObject {
    private var window: NSWindow?

    /// Shows the About window; the steps describe the current activation button
    /// and whether horizontal scrolling is on.
    func show(activationMethod: ActivationMethod, shortcut: String?, horizontalScrolling: Bool, trackpadKeys: String?,
              releaseStopsHold: Bool) {
        window?.close()

        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .centerX
        content.spacing = 6
        content.edgeInsets = NSEdgeInsets(top: 24, left: 28, bottom: 22, right: 28)

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 96).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 96).isActive = true
        content.addArrangedSubview(icon)

        let name = NSTextField(labelWithString: "AnyScroll")
        name.font = .systemFont(ofSize: 22, weight: .bold)
        content.addArrangedSubview(name)

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let versionLabel = NSTextField(labelWithString: "Version \(version)")
        versionLabel.font = .systemFont(ofSize: 11)
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.isHidden = version.isEmpty
        content.addArrangedSubview(versionLabel)
        content.setCustomSpacing(14, after: versionLabel)

        let tagline = NSTextField(labelWithString: "Windows-style auto-scroll in any direction.")
        tagline.font = .systemFont(ofSize: 13)
        content.addArrangedSubview(tagline)
        content.setCustomSpacing(16, after: tagline)

        let directions = horizontalScrolling ? "in any direction" : "up or down"
        var alternatives: [String] = []
        if let shortcut { alternatives.append("\(shortcut) on the keyboard") }
        if let trackpadKeys { alternatives.append("hold \(trackpadKeys) and start a two-finger scroll") }
        let ways = ([activationMethod.rawValue] + alternatives).joined(separator: ", or ")
        let start = "Press \(ways)\(alternatives.isEmpty ? "" : ",") where you want to scroll. An anchor appears."
        let move = "Move the pointer \(directions) from the anchor\(trackpadKeys != nil ? " (on a trackpad, with one finger)" : ""). The further you go, the faster it scrolls."
        let steps = NSStackView(views: [
            stepRow(1, start),
            stepRow(2, move),
            stepRow(3, releaseStopsHold
                ? "Click any button or press Esc to stop. If you held the button down while moving, just let go."
                : "Click any button or press Esc to stop."),
        ])
        steps.orientation = .vertical
        steps.alignment = .leading
        steps.spacing = 10
        content.addArrangedSubview(steps)
        content.setCustomSpacing(20, after: steps)

        let credit = NSTextField(wrappingLabelWithString: "Made by Andrea79 with Claude Code, 2026.\nBased on Scrollapp by fromis-9, with changes.\nFree software under the GNU GPL v3.")
        credit.font = .systemFont(ofSize: 11)
        credit.alignment = .center
        credit.textColor = .secondaryLabelColor
        content.addArrangedSubview(credit)

        let links = NSStackView(views: [
            linkButton("github.com/Andrea79/AnyScroll", action: #selector(openSource)),
            linkButton("Original Scrollapp", action: #selector(openOriginal)),
        ])
        links.spacing = 16
        content.addArrangedSubview(links)

        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentView = content
        content.widthAnchor.constraint(equalToConstant: 360).isActive = true
        window.layoutIfNeeded()
        window.setContentSize(content.fittingSize)
        window.center()
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func stepRow(_ number: Int, _ text: String) -> NSView {
        let badge = StepBadge(number: number)
        badge.widthAnchor.constraint(equalToConstant: 20).isActive = true
        badge.heightAnchor.constraint(equalToConstant: 20).isActive = true

        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.preferredMaxLayoutWidth = 268

        let row = NSStackView(views: [badge, label])
        row.alignment = .top
        row.spacing = 10
        return row
    }

    private func linkButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.isBordered = false
        button.contentTintColor = .linkColor
        button.font = .systemFont(ofSize: 11)
        return button
    }

    @objc private func openSource() {
        if let url = URL(string: "https://github.com/Andrea79/AnyScroll") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openOriginal() {
        if let url = URL(string: "https://github.com/fromis-9/scrollapp") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// A blue circle with a step number.
private final class StepBadge: NSView {
    private let number: Int

    init(number: Int) {
        self.number = number
        super.init(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemBlue.setFill()
        NSBezierPath(ovalIn: bounds).fill()
        let text = NSAttributedString(string: "\(number)", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .bold),
            .foregroundColor: NSColor.white,
        ])
        let size = text.size()
        text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }
}
