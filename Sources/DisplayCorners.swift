import AppKit
import Combine

@MainActor
final class DisplayCorners: ObservableObject {
    static let radiusRange: ClosedRange<Double> = 8...40
    static let menuTitle = "Rounded Display Corners"

    @Published private(set) var enabled: Bool
    @Published private(set) var radius: Double

    private let preferences: UserDefaults
    private var overlays: [NSPanel] = []

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        enabled = preferences.bool(forKey: "roundedDisplayCorners")
        radius = preferences.object(forKey: "displayCornerRadius") as? Double ?? 22
        radius = min(max(radius, Self.radiusRange.lowerBound), Self.radiusRange.upperBound)
    }

    func setEnabled(_ enabled: Bool) {
        guard self.enabled != enabled else { return }
        self.enabled = enabled
        preferences.set(enabled, forKey: "roundedDisplayCorners")
        refresh()
    }

    func setRadius(_ radius: Double) {
        let bounded = min(max(radius, Self.radiusRange.lowerBound), Self.radiusRange.upperBound)
        guard self.radius != bounded else { return }
        self.radius = bounded
        preferences.set(bounded, forKey: "displayCornerRadius")
        refresh()
    }

    func refresh() {
        let screens = enabled ? NSScreen.screens : []
        let desiredCount = screens.count * DisplayCorner.allCases.count
        while overlays.count > desiredCount {
            overlays.removeLast().orderOut(nil)
        }

        for (screenIndex, screen) in screens.enumerated() {
            let size = min(radius, screen.frame.width / 2, screen.frame.height / 2)
            for (cornerIndex, corner) in DisplayCorner.allCases.enumerated() {
                let index = screenIndex * DisplayCorner.allCases.count + cornerIndex
                let frame = corner.frame(on: screen.frame, size: size)
                if index == overlays.count {
                    overlays.append(makeOverlay(frame: frame, corner: corner))
                }
                let overlay = overlays[index]
                if overlay.frame != frame {
                    overlay.setFrame(frame, display: false)
                    overlay.contentView?.needsDisplay = true
                }
                if !overlay.isVisible { overlay.orderFrontRegardless() }
            }
        }
    }

    private func makeOverlay(frame: NSRect, corner: DisplayCorner) -> NSPanel {
        let overlay = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        overlay.title = "Dayboard Display Corner"
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.hasShadow = false
        overlay.ignoresMouseEvents = true
        overlay.hidesOnDeactivate = false
        overlay.isExcludedFromWindowsMenu = true
        overlay.animationBehavior = .none
        overlay.level = .statusBar
        overlay.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .canJoinAllApplications]
        overlay.contentView = CornerMask(frame: NSRect(origin: .zero, size: frame.size), corner: corner)
        return overlay
    }
}

private enum DisplayCorner: CaseIterable {
    case bottomLeft, bottomRight, topLeft, topRight

    private var isRight: Bool { self == .bottomRight || self == .topRight }
    private var isTop: Bool { self == .topLeft || self == .topRight }

    func frame(on screen: NSRect, size: CGFloat) -> NSRect {
        NSRect(x: isRight ? screen.maxX - size : screen.minX,
               y: isTop ? screen.maxY - size : screen.minY,
               width: size, height: size)
    }

    func mask(size: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.move(to: .zero)
        path.addLine(to: CGPoint(x: 0, y: size))
        path.addArc(center: CGPoint(x: size, y: size), radius: size,
                    startAngle: .pi, endAngle: 1.5 * .pi, clockwise: false)
        path.closeSubpath()

        var flip = CGAffineTransform(a: isRight ? -1 : 1, b: 0, c: 0, d: isTop ? -1 : 1,
                                     tx: isRight ? size : 0, ty: isTop ? size : 0)
        return path.copy(using: &flip) ?? path
    }
}

private final class CornerMask: NSView {
    private let corner: DisplayCorner

    init(frame: NSRect, corner: DisplayCorner) {
        self.corner = corner
        super.init(frame: frame)
        autoresizingMask = [.width, .height]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.clear(dirtyRect)
        context.setFillColor(NSColor.black.cgColor)
        context.addPath(corner.mask(size: bounds.width))
        context.fillPath()
    }
}
