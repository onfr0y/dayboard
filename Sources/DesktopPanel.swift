import AppKit

final class DesktopPanel: NSPanel {
    var onCancel: (() -> Void)?
    private var revealTimer: Timer?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        if let onCancel { onCancel() } else { super.cancelOperation(sender) }
    }

    func stopReveal() {
        revealTimer?.invalidate()
        revealTimer = nil
    }

    func reveal(at target: NSRect, reduceMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) {
        stopReveal()
        if reduceMotion {
            setFrame(target, display: true)
            alphaValue = 1
            orderFrontRegardless()
            makeKey()
            return
        }
        let start = target.offsetBy(dx: -36, dy: -min(155, target.height * 0.28))
        setFrame(start, display: true)
        alphaValue = 0
        orderFrontRegardless()
        makeKey()
        let startedAt = ProcessInfo.processInfo.systemUptime
        let duration = 0.48
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, self.isVisible else {
                    timer.invalidate()
                    return
                }
                let progress = min(1, (ProcessInfo.processInfo.systemUptime - startedAt) / duration)
                let remaining = 1 - progress
                let eased = 1 - remaining * remaining * remaining
                self.setFrameOrigin(NSPoint(x: start.minX + (target.minX - start.minX) * eased,
                                            y: start.minY + (target.minY - start.minY) * eased))
                self.alphaValue = min(1, progress * 2.8)
                if progress == 1 {
                    self.setFrame(target, display: true)
                    self.stopReveal()
                }
            }
        }
        revealTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
}
