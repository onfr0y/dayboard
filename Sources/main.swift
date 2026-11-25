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
    private let timelineDrag = TimelineDragState()
    private var pomodoroPanel: DesktopPanel?
    private let pomodoro = SessionTimer()
    private var meditationPanel: DesktopPanel?
    private let meditation = SessionTimer(phase: .meditation) { [chime = NSSound(named: "Glass")] in
        if chime?.play() != true { NSSound.beep() }
    }
    private let displayCorners = DisplayCorners()
    private var settings: NSWindow?
    private var eventEditorWindow: NSWindow?
    private var statusItem: NSStatusItem!
    private var visibilityItem: NSMenuItem!
    private var displayCornersItem: NSMenuItem!

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
        schedule.startLiveRefresh()
        let widgetLevel = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
        calendarPanel = desktopPanel(title: "Dayboard Calendar", level: widgetLevel,
                                     content: CalendarWidget(model: model, schedule: schedule) { [weak self] in
            self?.showTimeline()
        })
        agendaPanel = desktopPanel(title: "Dayboard Agenda", level: widgetLevel,
                                   content: AgendaWidget(model: model, schedule: schedule, pomodoro: pomodoro,
                                                         meditation: meditation,
                                                         openPomodoro: { [weak self] in self?.showPomodoro() },
                                                         openMeditation: { [weak self] in self?.showMeditation() },
                                                         openSettings: { [weak self] in self?.showSettings() },
                                                         editEvent: { [weak self] in self?.showEventEditor($0, on: $1) }))
        positionPanel()
        showBoard()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "calendar", accessibilityDescription: "Dayboard")
        statusItem.button?.toolTip = "Dayboard"
        let menu = NSMenu()
        visibilityItem = menu.addItem(withTitle: "Hide Desktop Board", action: #selector(toggleBoard), keyEquivalent: "")
        menu.addItem(withTitle: "Show Calendar Timeline", action: #selector(showTimeline), keyEquivalent: "")
        menu.addItem(withTitle: "New Calendar Event…", action: #selector(newEvent), keyEquivalent: "n")
        menu.addItem(withTitle: "Show Pomodoro Timer", action: #selector(showPomodoro), keyEquivalent: "")
        menu.addItem(withTitle: "Show Meditation Timer", action: #selector(showMeditation), keyEquivalent: "")
        menu.addItem(withTitle: "Refresh Dayboard", action: #selector(refresh), keyEquivalent: "r")
        menu.addItem(withTitle: "Connect Mac Calendar…", action: #selector(connectCalendar), keyEquivalent: "")
        menu.addItem(withTitle: "Switch Text Colour", action: #selector(switchTextColour), keyEquivalent: "")
        displayCornersItem = menu.addItem(withTitle: DisplayCorners.menuTitle,
                                          action: #selector(toggleDisplayCorners), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        menu.addItem(withTitle: "Quit Dayboard", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        statusItem.menu = menu
        updateDisplayCornersMenu()
        displayCorners.refresh()

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
        displayCorners.refresh()
        positionPanel()
        if let timelinePanel, timelinePanel.isVisible {
            timelinePanel.stopReveal()
            timelinePanel.alphaValue = 1
            recoverTimelinePosition(timelinePanel)
        }
        if let pomodoroPanel, pomodoroPanel.isVisible {
            recoverTimerPosition(pomodoroPanel, for: pomodoro)
        }
        if let meditationPanel, meditationPanel.isVisible {
            recoverTimerPosition(meditationPanel, for: meditation)
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
            meditationPanel?.orderOut(nil)
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
        guard let fallback = timelineFrame() else { return }
        schedule.showMonth(model.month)
        if let timelinePanel, timelinePanel.isVisible {
            recoverTimelinePosition(timelinePanel)
            timelinePanel.orderFrontRegardless()
            timelinePanel.makeKey()
            return
        }
        let panel = desktopPanel(title: "Dayboard Calendar Timeline", level: .floating,
                                 content: CalendarTimeline(model: model, schedule: schedule, drag: timelineDrag,
                                                           dismiss: { [weak self] in self?.closeTimeline() },
                                                           editEvent: { [weak self] in self?.showEventEditor($0, on: $1) },
                                                           addEvent: { [weak self] in self?.showNewEventEditor(on: $0, startTime: $1) },
                                                           rescheduleEvent: { [weak self] event, original, changes in
                                                               guard let self else { throw CalendarEditError.unavailable }
                                                               if event.provider == "notion" {
                                                                   try await self.model.updateScheduledTask(event, original: original, changes: changes)
                                                               } else {
                                                                   try self.schedule.updateMacEvent(event, original: original, changes: changes)
                                                               }
                                                           }))
        panel.hasShadow = true
        panel.collectionBehavior = [.moveToActiveSpace, .ignoresCycle, .fullScreenNone]
        panel.onCancel = { [weak self] in self?.closeTimeline() }
        panel.isMovable = true
        panel.setFrame(fallback, display: false)
        let restored = panel.setFrameUsingName("Dayboard Calendar Timeline")
        panel.setFrameAutosaveName("Dayboard Calendar Timeline")
        let target: NSRect
        if restored {
            recoverTimelinePosition(panel)
            target = panel.frame
        } else {
            target = fallback
        }
        timelinePanel = panel
        panel.reveal(at: target)
    }

    private func recoverTimelinePosition(_ panel: DesktopPanel) {
        let dragArea = NSRect(x: panel.frame.minX + 19, y: panel.frame.maxY - 43,
                              width: max(80, panel.frame.width - 140), height: 24)
        let titleVisible = NSScreen.screens.contains { screen in
            let visible = dragArea.intersection(screen.visibleFrame)
            return visible.width >= 44 && visible.height >= 12
        }
        if !titleVisible, let fallback = timelineFrame() {
            panel.setFrame(fallback, display: true)
        }
    }

    private func closeTimeline() {
        guard let panel = timelinePanel else { return }
        timelinePanel = nil
        panel.stopReveal()
        panel.orderOut(nil)
    }

    @objc private func newEvent() {
        showNewEventEditor(on: model.selected)
    }

    private func presentEditorWindow<Content: View>(title: String, rootView: Content) {
        eventEditorWindow?.orderOut(nil)
        let window = NSWindow(contentViewController: NSHostingController(rootView: rootView))
        window.title = title
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.center()
        eventEditorWindow = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func showNewEventEditor(on day: Date, startTime: Date? = nil) {
        var destinations: [CalendarDestination] = []
        if model.connected {
            destinations.append(.notion)
        }
        destinations += schedule.writableCalendars.map { .mac(id: $0.id, title: $0.title) }
        let editor = CalendarEditor(day: day, startTime: startTime, calendar: model.calendar, destinations: destinations)
        let editable = !destinations.isEmpty
        let view = CalendarEditorView(
            editor: editor, sectionTitle: "New Event", editable: editable,
            offeredConnection: !schedule.canReadMacCalendar,
            connect: { [weak self] in
                guard let self else { return }
                Task { await self.schedule.connect(addAccount: true) }
            },
            openOriginal: nil,
            deleteEvent: nil,
            close: { [weak self] in self?.eventEditorWindow?.orderOut(nil) },
            save: { [weak self] changes, destination in
                guard let self, let destination else { throw CalendarEditError.unavailable }
                switch destination {
                case .notion:
                    try await self.model.createScheduledTask(changes)
                case .mac(let id, _):
                    try self.schedule.createMacEvent(calendarID: id, fields: changes)
                }
            })
        presentEditorWindow(title: "New Calendar Event", rootView: view)
    }

    private func showEventEditor(_ event: ScheduleEvent, on day: Date) {
        guard let original = CalendarEventFields(event: event, calendar: model.calendar) else { return }
        let editor = CalendarEditor(original, calendar: model.calendar)
        let editable = (event.provider == "notion" && model.connected) || event.nativeIdentifier != nil
        let deleteAction: (() async throws -> Void)? = editable ? { [weak self] in
            guard let self else { throw CalendarEditError.unavailable }
            if event.provider == "notion" {
                try await self.model.deleteScheduledTask(event)
            } else {
                try self.schedule.deleteMacEvent(event, original: original)
            }
        } : nil
        let view = CalendarEditorView(
            editor: editor, sectionTitle: event.calendar, editable: editable,
            offeredConnection: event.provider == "google",
            connect: { [weak self] in
                guard let self else { return }
                Task { await self.schedule.connect(addAccount: true) }
            },
            openOriginal: { event.open(on: day) },
            deleteEvent: deleteAction,
            close: { [weak self] in self?.eventEditorWindow?.orderOut(nil) },
            save: { [weak self] changes, _ in
                guard let self else { throw CalendarEditError.unavailable }
                if event.provider == "notion" {
                    try await self.model.updateScheduledTask(event, original: original, changes: changes)
                } else {
                    try self.schedule.updateMacEvent(event, original: original, changes: changes)
                }
            })
        presentEditorWindow(title: editable ? "Edit Calendar Event" : "Calendar Event", rootView: view)
    }

    private func timerFrame(for timer: SessionTimer) -> NSRect? {
        guard let screen = agendaPanel?.screen ?? NSScreen.screens.first else { return nil }
        let usable = screen.visibleFrame
        let width = min(340, usable.width - 48)
        let height = min(timer.isMeditation ? 370 : 474, usable.height - 48)
        let right = usable.maxX - width - 24
        let left = max(usable.minX + 24, right - width - 16)
        return NSRect(x: timer.isMeditation ? left : right, y: usable.minY + 24, width: width, height: height)
    }

    @objc private func showPomodoro() {
        if pomodoroPanel == nil { pomodoroPanel = makeTimerPanel(for: pomodoro) }
        showTimerPanel(pomodoroPanel, for: pomodoro)
    }

    @objc private func showMeditation() {
        if meditationPanel == nil { meditationPanel = makeTimerPanel(for: meditation) }
        showTimerPanel(meditationPanel, for: meditation)
    }

    private func makeTimerPanel(for timer: SessionTimer) -> DesktopPanel? {
        guard let frame = timerFrame(for: timer) else { return nil }
        let title = "Dayboard \(timer.title)"
        let dismiss: () -> Void = { [weak self] in
            let panel = timer.isMeditation ? self?.meditationPanel : self?.pomodoroPanel
            panel?.orderOut(nil)
        }
        let panel = desktopPanel(title: title, level: .floating,
                                 content: SessionTimerPanel(timer: timer, dismiss: dismiss))
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
        panel.setFrameAutosaveName(title)
        if panel.setFrameUsingName(title), panel.frame.size != frame.size {
            var restored = NSRect(origin: panel.frame.origin, size: frame.size)
            if let screen = panel.screen {
                let visible = screen.visibleFrame
                restored.origin.y = max(visible.minY, min(restored.minY, visible.maxY - restored.height))
            }
            panel.setFrame(restored, display: true)
        }
        return panel
    }

    private func showTimerPanel(_ panel: DesktopPanel?, for timer: SessionTimer) {
        guard let panel else { return }
        recoverTimerPosition(panel, for: timer)
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    private func recoverTimerPosition(_ panel: DesktopPanel, for timer: SessionTimer) {
        let dragArea = NSRect(x: panel.frame.minX + 22, y: panel.frame.maxY - 47,
                              width: panel.frame.width - 80, height: 25)
        let titleVisible = NSScreen.screens.contains { screen in
            let visible = dragArea.intersection(screen.visibleFrame)
            return visible.width >= 44 && visible.height >= 12
        }
        if !titleVisible, let fallback = timerFrame(for: timer) {
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
        meditation.update()
        model.rollDate()
        schedule.refresh()
        Task { await model.refresh() }
    }

    @objc private func showSettings() {
        if settings == nil {
            let controller = NSHostingController(rootView: BoardSettings(
                model: model, schedule: schedule, displayCorners: displayCorners,
                setRoundedDisplayCorners: { [weak self] in self?.setRoundedDisplayCorners($0) }
            ))
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

    @objc private func toggleDisplayCorners() {
        setRoundedDisplayCorners(!displayCorners.enabled)
    }

    private func setRoundedDisplayCorners(_ enabled: Bool) {
        displayCorners.setEnabled(enabled)
        updateDisplayCornersMenu()
    }

    private func updateDisplayCornersMenu() {
        displayCornersItem.state = displayCorners.enabled ? .on : .off
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
