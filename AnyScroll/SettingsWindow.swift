//
//  SettingsWindow.swift
//  AnyScroll
//
//  Same layout as Simple SIP Phone's settings: a grouped Form where menus,
//  sliders and switches take one row, with the title and an optional grey
//  note on the left and the control on the right.
//

import Cocoa
import SwiftUI

/// The settings the Settings window edits. Setting a property applies and saves it.
@MainActor
protocol SettingsHost: AnyObject {
    var activationMethod: ActivationMethod { get set }
    var releaseStopsHold: Bool { get set }
    var optionScrollStartsAutoScroll: Bool { get set }
    var scrollSensitivity: Double { get set }
    var horizontalScrolling: Bool { get set }
    var isDirectionInverted: Bool { get set }
    var launchAtLogin: Bool { get set }
}

@MainActor
final class SettingsWindowController: NSObject {
    private let store: SettingsStore
    private var window: NSWindow?

    init(host: SettingsHost) {
        store = SettingsStore(host: host)
        super.init()
    }

    func show() {
        if window == nil {
            let controller = NSHostingController(rootView: SettingsView(store: store))
            controller.sizingOptions = .preferredContentSize
            let window = NSWindow(contentViewController: controller)
            window.title = "AnyScroll Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Re-reads every setting, e.g. after it was changed from the menu.
    func refresh() {
        store.objectWillChange.send()
    }
}

/// Lets SwiftUI bind straight to the app's settings.
@MainActor
final class SettingsStore: ObservableObject {
    private weak var host: SettingsHost?

    init(host: SettingsHost) {
        self.host = host
    }

    func binding<Value>(_ keyPath: ReferenceWritableKeyPath<any SettingsHost, Value>, default value: Value) -> Binding<Value> {
        Binding(
            get: { [weak self] in self?.host?[keyPath: keyPath] ?? value },
            set: { [weak self] newValue in
                self?.objectWillChange.send()
                self?.host?[keyPath: keyPath] = newValue
            }
        )
    }
}

struct SettingsView: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        let speed = store.binding(\.scrollSensitivity, default: 1.0)

        Form {
            Section {
                Row("Start auto-scroll with", note: "Clicking any button stops it again.") {
                    Picker("Start auto-scroll with", selection: store.binding(\.activationMethod, default: .middleClick)) {
                        ForEach(ActivationMethod.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .fixedSize()
                }
                Row("Release to stop after holding", note: "Hold the button while you move, then let go to stop.") {
                    Toggle("Release to stop after holding", isOn: store.binding(\.releaseStopsHold, default: true))
                        .toggleStyle(.switch)
                }
                Row("Option + trackpad scroll", note: "Hold Option and start a two-finger scroll to drop the anchor.") {
                    Toggle("Option + trackpad scroll", isOn: store.binding(\.optionScrollStartsAutoScroll, default: false))
                        .toggleStyle(.switch)
                }
            } header: {
                Text("Activation")
            } footer: {
                FooterText("Press the button once where you want to scroll: an anchor appears. "
                           + "Move the pointer away from it to scroll (on a trackpad, with one finger); "
                           + "the further you go, the faster it scrolls. Click any button to stop, "
                           + "or hold the button down while you move and let go to stop.")
            }

            Section {
                Row("Speed", note: "Below 1.0x it gets much slower, for fine control.") {
                    HStack(spacing: 8) {
                        Slider(value: speed, in: 0.2...3.0)
                            .frame(width: 140)
                        Text(String(format: "%.1fx", speed.wrappedValue))
                            .monospacedDigit()
                            .frame(width: 34, alignment: .trailing)
                    }
                }
                Row("Horizontal scrolling", note: "Also scroll left, right and diagonally.") {
                    Toggle("Horizontal scrolling", isOn: store.binding(\.horizontalScrolling, default: false))
                        .toggleStyle(.switch)
                }
                Row("Invert direction", note: "Moving the pointer up scrolls down.") {
                    Toggle("Invert direction", isOn: store.binding(\.isDirectionInverted, default: false))
                        .toggleStyle(.switch)
                }
            } header: {
                Text("Scrolling")
            } footer: {
                FooterText("Near a screen edge the speed builds up sooner, so full speed is still reachable.")
            }

            Section {
                Toggle("Open at login", isOn: store.binding(\.launchAtLogin, default: false))
                    .toggleStyle(.switch)
            } header: {
                Text("Startup")
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: 460, height: 660)
    }
}

/// A one-row setting: title (and an optional note under it) on the left, the control on the right.
private struct Row<Content: View>: View {
    let title: String
    let note: String?
    @ViewBuilder let content: Content

    init(_ title: String, note: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.note = note
        self.content = content()
    }

    var body: some View {
        LabeledContent {
            content.labelsHidden()
        } label: {
            Text(title)
            if let note { Text(note) }
        }
    }
}

/// Section footer text, justified (SwiftUI's Text only aligns left, centre or right),
/// using AppKit's text field, which supports justified alignment.
private struct FooterText: NSViewRepresentable {
    let text: String

    init(_ text: String) { self.text = text }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.alignment = .justified
        field.textColor = .secondaryLabelColor
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.isSelectable = false
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        field.stringValue = text
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView field: NSTextField, context: Context) -> CGSize? {
        let width = proposal.width ?? 400
        field.preferredMaxLayoutWidth = width
        let height = field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width,
                                                            height: .greatestFiniteMagnitude)).height ?? 0
        return CGSize(width: width, height: ceil(height))
    }
}
