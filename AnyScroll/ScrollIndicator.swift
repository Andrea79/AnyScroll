//
//  ScrollIndicator.swift
//  AnyScroll
//
//  A background (LSUIElement) app cannot change the system cursor over other
//  apps' windows, so NSCursor.set() has no visible effect. Instead we draw the
//  Windows-style autoscroll anchor in a transparent, click-through window
//  placed above everything else.
//

import Cocoa

enum VerticalDirection {
    case none, up, down
}

enum HorizontalDirection {
    case none, left, right
}

/// Which ways auto-scroll moves the page: the global setting or a per-app rule.
enum ScrollDirections: String, CaseIterable {
    case vertical, horizontal, both

    var title: String {
        switch self {
        case .vertical: return "Vertical"
        case .horizontal: return "Horizontal"
        case .both: return "Both"
        }
    }

    var allowsVertical: Bool { self != .horizontal }
    var allowsHorizontal: Bool { self != .vertical }
}

@MainActor
final class ScrollIndicator {
    private let anchorSize: CGFloat = 38
    private var window: NSPanel?
    private var anchorView: AnchorView?

    func show(at point: NSPoint, directions: ScrollDirections) {
        let view = AnchorView(frame: NSRect(x: 0, y: 0, width: anchorSize, height: anchorSize))
        view.directions = directions
        let panel = NSPanel(contentRect: frame(centeredAt: point),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.contentView = view
        panel.orderFrontRegardless()

        hide()
        window = panel
        anchorView = view
    }

    func update(vertical: VerticalDirection, horizontal: HorizontalDirection) {
        guard let view = anchorView,
              view.vertical != vertical || view.horizontal != horizontal else { return }
        view.vertical = vertical
        view.horizontal = horizontal
        view.needsDisplay = true
    }

    func hide() {
        window?.orderOut(nil)
        window = nil
        anchorView = nil
    }

    /// Menu bar icon in the anchor's style: a circle with up/down arrows, plus
    /// left/right ones when horizontal scrolling is on. Template, so it follows
    /// the menu bar's light or dark appearance.
    static func statusBarImage(horizontal: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            NSColor.black.set()
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            circle.lineWidth = 1.3
            circle.stroke()
            let mid = NSPoint(x: rect.midX, y: rect.midY)
            NSBezierPath(ovalIn: NSRect(x: mid.x - 1.1, y: mid.y - 1.1, width: 2.2, height: 2.2)).fill()
            // Four arrows need to sit further out and be narrower so they do not touch
            let (tip, base, halfWidth): (CGFloat, CGFloat, CGFloat) = horizontal ? (6.6, 3.5, 2.1) : (6.2, 2.6, 2.6)
            for arrow in ArrowShape.all(around: mid, tip: tip, base: base, halfWidth: halfWidth,
                                        vertical: true, horizontal: horizontal) {
                arrow.path.fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "AnyScroll"
        return image
    }

    private func frame(centeredAt point: NSPoint) -> NSRect {
        NSRect(x: point.x - anchorSize / 2, y: point.y - anchorSize / 2,
               width: anchorSize, height: anchorSize)
    }
}

/// One triangular arrow pointing away from the centre.
private struct ArrowShape {
    let path: NSBezierPath
    let isActive: (VerticalDirection, HorizontalDirection) -> Bool

    /// Up and down arrows and/or left and right ones.
    /// View coordinates are not flipped: larger y is up.
    static func all(around mid: NSPoint, tip: CGFloat, base: CGFloat, halfWidth: CGFloat,
                    vertical: Bool, horizontal: Bool) -> [ArrowShape] {
        func triangle(_ points: [NSPoint]) -> NSBezierPath {
            let path = NSBezierPath()
            path.move(to: points[0])
            points.dropFirst().forEach { path.line(to: $0) }
            path.close()
            return path
        }
        var arrows: [ArrowShape] = []
        if vertical {
            arrows += [
                ArrowShape(path: triangle([NSPoint(x: mid.x, y: mid.y + tip),
                                           NSPoint(x: mid.x - halfWidth, y: mid.y + base),
                                           NSPoint(x: mid.x + halfWidth, y: mid.y + base)]),
                           isActive: { v, _ in v == .up }),
                ArrowShape(path: triangle([NSPoint(x: mid.x, y: mid.y - tip),
                                           NSPoint(x: mid.x - halfWidth, y: mid.y - base),
                                           NSPoint(x: mid.x + halfWidth, y: mid.y - base)]),
                           isActive: { v, _ in v == .down }),
            ]
        }
        if horizontal {
            arrows += [
                ArrowShape(path: triangle([NSPoint(x: mid.x - tip, y: mid.y),
                                           NSPoint(x: mid.x - base, y: mid.y - halfWidth),
                                           NSPoint(x: mid.x - base, y: mid.y + halfWidth)]),
                           isActive: { _, h in h == .left }),
                ArrowShape(path: triangle([NSPoint(x: mid.x + tip, y: mid.y),
                                           NSPoint(x: mid.x + base, y: mid.y - halfWidth),
                                           NSPoint(x: mid.x + base, y: mid.y + halfWidth)]),
                           isActive: { _, h in h == .right }),
            ]
        }
        return arrows
    }
}

private final class AnchorView: NSView {
    var vertical: VerticalDirection = .none
    var horizontal: HorizontalDirection = .none
    var directions: ScrollDirections = .both

    private let inactiveColor = NSColor(white: 0.25, alpha: 1)

    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 1.5, dy: 1.5))
        NSColor.white.withAlphaComponent(0.92).setFill()
        circle.fill()
        inactiveColor.withAlphaComponent(0.9).setStroke()
        circle.lineWidth = 1.5
        circle.stroke()

        let mid = NSPoint(x: bounds.midX, y: bounds.midY)
        let dot = NSBezierPath(ovalIn: NSRect(x: mid.x - 2, y: mid.y - 2, width: 4, height: 4))
        inactiveColor.setFill()
        dot.fill()

        for arrow in ArrowShape.all(around: mid, tip: 13, base: 6, halfWidth: 5,
                                    vertical: directions.allowsVertical, horizontal: directions.allowsHorizontal) {
            (arrow.isActive(vertical, horizontal) ? NSColor.systemBlue : inactiveColor).setFill()
            arrow.path.fill()
        }
    }
}
