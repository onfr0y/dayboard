import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var model: BoardModel!
    private var schedule: ScheduleModel!
    private var calendarPanel: DesktopPanel!
    private var agendaPanel: DesktopPanel!
    private var timelinePanel: DesktopPanel?
    private var pomodoroPanel: DesktopPanel?
    private let pomodoro = PomodoroTimer()
    private var settings: NSWindow?
    private var statusItem: NSStatusItem!
    private var visibilityItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = ProcessInfo.processInfo.arguments
        if let flag = args.firstIndex(of: "--notion-config"), args.indices.contains(flag + 1) {
            do {
                try NotionConfiguration.importFile(URL(filePath: args[flag + 1]))
            } catch {
                NSLog("Dayboard could not import the Notion configuration: %@", error.localizedDescription)
            }
        }
        let seed = args.firstIndex(of: "--seed").flatMap { args.indices.contains($0 + 1) ? URL(filePath: args[$0 + 1]) : nil }
        let habitSeed = args.firstIndex(of: "--habit-seed").flatMap { args.indices.contains($0 + 1) ? URL(filePath: args[$0 + 1]) : nil }
        model = BoardModel(seed: seed, habitSeed: habitSeed)
        let calendarSeed = args.firstIndex(of: "--calendar-seed").flatMap { args.indices.contains($0 + 1) ? URL(filePath: args[$0 + 1]) : nil }
        schedule = ScheduleModel(seed: calendarSeed, month: model.month, calendar: model.calendar)
        schedule.observeNotionTasks(model)
        let widgetLevel = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
        calendarPanel = desktopPanel(title: "Dayboard Calendar", level: widgetLevel,
                                     content: CalendarWidget(model: model, schedule: schedule) { [weak self] in
            self?.showTimeline()
        })
        agendaPanel = desktopPanel(title: "Dayboard Agenda", level: widgetLevel,
                                   content: AgendaWidget(model: model, schedule: schedule, pomodoro: pomodoro,
                                                         openPomodoro: { [weak self] in self?.showPomodoro() },
                                                         openSettings: { [weak self] in self?.showSettings() }))
        positionPanel()
        showBoard()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "calendar", accessibilityDescription: "Dayboard")
        statusItem.button?.toolTip = "Dayboard"
        let menu = NSMenu()
        visibilityItem = menu.addItem(withTitle: "Hide Desktop Board", action: #selector(toggleBoard), keyEquivalent: "")
        menu.addItem(withTitle: "Show Calendar Timeline", action: #selector(showTimeline), keyEquivalent: "")
        menu.addItem(withTitle: "Show Pomodoro Timer", action: #selector(showPomodoro), keyEquivalent: "")
        menu.addItem(withTitle: "Refresh Dayboard", action: #selector(refresh), keyEquivalent: "r")
        menu.addItem(withTitle: "Connect Mac Calendar…", action: #selector(connectCalendar), keyEquivalent: "")
        menu.addItem(withTitle: "Switch Text Colour", action: #selector(switchTextColour), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        menu.addItem(withTitle: "Quit Dayboard", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        statusItem.menu = menu

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(woke), name: NSWorkspace.didWakeNotification, object: nil
        )
        model.start()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if calendarPanel != nil && !calendarPanel.isVisible { toggleBoard() }
        return false
    }

    func applicationDidChangeScreenParameters(_ notification: Notification) {
        positionPanel()
        if let timelinePanel, timelinePanel.isVisible, let frame = timelineFrame() {
            timelinePanel.stopReveal()
            timelinePanel.alphaValue = 1
            timelinePanel.setFrame(frame, display: true)
        }
        if let pomodoroPanel, pomodoroPanel.isVisible {
            recoverPomodoroPosition(pomodoroPanel)
        }
    }

    private func positionPanel() {
        guard let screen = NSScreen.screens.first, calendarPanel != nil else { return }
        let usable = screen.visibleFrame
        let height = min(610, usable.height * 0.82)
        let left = usable.minX + min(112, usable.width * 0.075)
        let bottom = usable.minY + (usable.height - height) * 0.54
        let calendarWidth = min(380, usable.width * 0.32)
        let gap = min(76, usable.width * 0.042)
        let agendaWidth = min(760, usable.width * 0.82 - calendarWidth - gap)
        calendarPanel.setFrame(NSRect(x: left, y: bottom, width: calendarWidth, height: height), display: true)
        agendaPanel.setFrame(NSRect(x: left + calendarWidth + gap, y: bottom, width: agendaWidth, height: height), display: true)
    }

    private func desktopPanel<Content: View>(title: String, level: NSWindow.Level, content: Content) -> DesktopPanel {
        let panel = DesktopPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 610),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = title
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = level
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        panel.contentView = NSHostingView(rootView: content)
        return panel
    }

    private func showBoard() {
        calendarPanel.orderFrontRegardless()
        agendaPanel.orderFrontRegardless()
    }

    @objc private func toggleBoard() {
        if calendarPanel.isVisible {
            closeTimeline()
            pomodoroPanel?.orderOut(nil)
            calendarPanel.orderOut(nil)
            agendaPanel.orderOut(nil)
            visibilityItem.title = "Show Desktop Board"
        } else {
            showBoard()
            visibilityItem.title = "Hide Desktop Board"
        }
    }

    private func timelineFrame() -> NSRect? {
        guard let screen = calendarPanel?.screen ?? NSScreen.screens.first else { return nil }
        let usable = screen.visibleFrame
        let margin = min(24, usable.width * 0.025)
        return NSRect(x: usable.minX + margin, y: usable.minY + margin,
                      width: min(500, usable.width - margin * 2),
                      height: min(530, usable.height - margin * 2))
    }

    @objc private func showTimeline() {
        guard let target = timelineFrame() else { return }
        schedule.showMonth(model.month)
        if let timelinePanel, timelinePanel.isVisible {
            timelinePanel.orderFrontRegardless()
            timelinePanel.makeKey()
            return
        }
        let panel = desktopPanel(title: "Dayboard Calendar Timeline", level: .floating,
                                 content: CalendarTimeline(model: model, schedule: schedule) { [weak self] in
            self?.closeTimeline()
        })
        panel.hasShadow = true
        panel.collectionBehavior = [.moveToActiveSpace, .ignoresCycle, .fullScreenNone]
        panel.onCancel = { [weak self] in self?.closeTimeline() }
        timelinePanel = panel
        panel.reveal(at: target)
    }

    private func closeTimeline() {
        guard let panel = timelinePanel else { return }
        timelinePanel = nil
        panel.stopReveal()
        panel.orderOut(nil)
    }

    private func pomodoroFrame() -> NSRect? {
        guard let screen = agendaPanel?.screen ?? NSScreen.screens.first else { return nil }
        let usable = screen.visibleFrame
        let width = min(340, usable.width - 48)
        let height = min(382, usable.height - 48)
        return NSRect(x: usable.maxX - width - 24, y: usable.minY + 24, width: width, height: height)
    }

    @objc private func showPomodoro() {
        if pomodoroPanel == nil {
            guard let frame = pomodoroFrame() else { return }
            let dismiss: () -> Void = { [weak self] in self?.pomodoroPanel?.orderOut(nil) }
            let panel = desktopPanel(title: "Dayboard Pomodoro", level: .floating,
                                     content: PomodoroPanel(timer: pomodoro, dismiss: dismiss))
            if #available(macOS 26, *), let content = panel.contentView {
                let glass = NSGlassEffectView(frame: content.frame)
                glass.cornerRadius = 28
                glass.style = .regular
                glass.appearance = NSAppearance(named: .darkAqua)
                glass.tintColor = NSColor(white: 0.14, alpha: 0.30)
                content.autoresizingMask = [.width, .height]
                panel.contentView = glass
                glass.contentView = content
            }
            panel.hasShadow = true
            panel.collectionBehavior = [.moveToActiveSpace, .ignoresCycle, .fullScreenNone]
            panel.onCancel = dismiss
            panel.setFrame(frame, display: true)
            panel.isMovable = true
            panel.setFrameAutosaveName("Dayboard Pomodoro")
            pomodoroPanel = panel
        }
        guard let panel = pomodoroPanel else { return }
        recoverPomodoroPosition(panel)
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    private func recoverPomodoroPosition(_ panel: DesktopPanel) {
        let dragArea = NSRect(x: panel.frame.minX + 22, y: panel.frame.maxY - 47,
                              width: panel.frame.width - 80, height: 25)
        let titleVisible = NSScreen.screens.contains { screen in
            let visible = dragArea.intersection(screen.visibleFrame)
            return visible.width >= 44 && visible.height >= 12
        }
        if !titleVisible, let fallback = pomodoroFrame() {
            panel.setFrame(fallback, display: true)
        }
    }

    @objc private func refresh() {
        schedule.refreshFromSources()
        if model.connected {
            Task { await model.refresh() }
        } else if !schedule.canReadMacCalendar {
            showSettings()
        }
    }

    @objc private func woke() {
        pomodoro.update()
        model.rollDate()
        schedule.refresh()
        Task { await model.refresh() }
    }

    @objc private func showSettings() {
        if settings == nil {
            let controller = NSHostingController(rootView: BoardSettings(model: model, schedule: schedule))
            let window = NSWindow(contentViewController: controller)
            window.title = "Dayboard Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settings = window
        }
        model.loginStatus = ServiceManagement.SMAppService.mainApp.status
        NSApp.activate()
        settings?.makeKeyAndOrderFront(nil)
    }

    @objc private func connectCalendar() { Task { await schedule.connect() } }
    @objc private func switchTextColour() { schedule.lightText.toggle() }
    @objc private func quit() { NSApp.terminate(nil) }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
