import AppKit
import Combine
import EventKit

struct ScheduleEvent: Codable, Identifiable {
    let id: String
    let title: String
    let calendar: String
    let provider: String
    let start: String
    let end: String
    let allDay: Bool
    let url: URL?
    var location: String? = nil
    var nativeIdentifier: String? = nil

    var startTime: Date? { notionTimestamp(start) }
    var endTime: Date? { notionTimestamp(end) }

    static func notionEntry(_ task: NotionTask, calendar: Calendar) -> Self? {
        let allDay = task.start.count == 10
        let end: String
        if allDay {
            guard let start = notionDay(task.start, in: calendar),
                  let exclusiveEnd = calendar.date(byAdding: .day, value: 1,
                      to: max(start, task.end.flatMap { notionDay($0, in: calendar) } ?? start)) else { return nil }
            // Notion date ranges include their final day; the schedule uses exclusive end dates.
            end = dayKey(exclusiveEnd, in: calendar)
        } else {
            guard let start = notionTimestamp(task.start) else { return nil }
            end = task.end.flatMap(notionTimestamp).map { max(start, $0) }?.ISO8601Format() ?? task.start
        }
        return Self(id: "notion|\(task.id)", title: task.title.isEmpty ? "Untitled task" : task.title,
                    calendar: "Notion Calendar", provider: "notion", start: task.start, end: end,
                    allDay: allDay, url: task.url)
    }

    func appears(on date: Date, in math: Calendar) -> Bool {
        guard let dayEnd = math.date(byAdding: .day, value: 1, to: date),
              let span = interval(in: math) else { return false }
        return span.lowerBound < dayEnd &&
            (span.upperBound > date || (span.lowerBound == span.upperBound && span.lowerBound >= date))
    }

    func interval(in math: Calendar) -> ClosedRange<Date>? {
        let first = allDay ? notionDay(start, in: math) : startTime
        let last = allDay ? notionDay(end, in: math) : endTime
        guard let first, let last else { return nil }
        return first...max(first, last)
    }

    func open(on date: Date) {
        guard let destination = url ?? URL(string: "calshow:\(Int(date.timeIntervalSinceReferenceDate))") else { return }
        NSWorkspace.shared.open(destination)
    }
}

struct ScheduleSnapshot: Codable {
    let startDay: String
    let endDay: String
    let events: [ScheduleEvent]
}

@MainActor
final class ScheduleModel: ObservableObject {
    @Published private(set) var snapshot: ScheduleSnapshot?
    @Published private(set) var nativeEvents: [ScheduleEvent] = []
    @Published private(set) var notionEvents: [ScheduleEvent]?
    @Published private(set) var access = EKEventStore.authorizationStatus(for: .event)
    @Published private(set) var nativeCalendarNames = Set<String>()
    @Published private(set) var error: String?
    @Published var lightText: Bool = !UserDefaults.standard.bool(forKey: "darkWallpaperText") {
        didSet { UserDefaults.standard.set(!lightText, forKey: "darkWallpaperText") }
    }

    private let store = EKEventStore()
    private let calendar: Calendar
    private var month: Date
    private var observer: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    private var notionObservation: AnyCancellable?
    private var refreshTask: Task<Void, Never>?

    init(seed: URL?, month: Date, calendar: Calendar,
         cache: URL = URL.applicationSupportDirectory.appending(path: "Dayboard/calendar.json")) {
        self.calendar = calendar
        self.month = month
        if let data = try? Data(contentsOf: cache) {
            snapshot = try? JSONDecoder().decode(ScheduleSnapshot.self, from: data)
        }
        if let seed, let data = try? Data(contentsOf: seed),
           let imported = try? JSONDecoder().decode(ScheduleSnapshot.self, from: data) {
            snapshot = imported
            do {
                try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                try data.write(to: cache, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cache.path)
            } catch {
                self.error = "The fetched schedule could not be saved on this Mac."
            }
        }
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) {
            [weak self] _ in Task { @MainActor in self?.refresh() }
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.refresh() } }
        refresh()
        NSLog("Dayboard calendar access: %d; live calendars: %d", access.rawValue, nativeCalendarNames.count)
    }

    var canReadMacCalendar: Bool { access == .fullAccess }

    var calendarConnectionTitle: String {
        switch access {
        case .denied, .restricted: "Open Calendar Privacy"
        case .fullAccess: "Add Calendar Account"
        default: "Allow Calendar Access"
        }
    }

    func observeNotionTasks(_ board: BoardModel) {
        notionObservation = board.$snapshot.sink { [weak self] snapshot in
            guard let self else { return }
            self.notionEvents = snapshot?.tasks.compactMap { ScheduleEvent.notionEntry($0, calendar: self.calendar) }
        }
    }

    var visibleEvents: [ScheduleEvent] {
        let fallback = (snapshot?.events ?? []).filter { event in
            if event.provider == "notion" { return notionEvents == nil }
            return !nativeCalendarNames.contains(event.calendar.lowercased())
        }
        let nativeKeys = Set(nativeEvents.map(eventKey))
        return nativeEvents + fallback.filter { !nativeKeys.contains(eventKey($0)) } + (notionEvents ?? [])
    }

    func events(on day: Date) -> [ScheduleEvent] {
        visibleEvents.filter { $0.appears(on: day, in: calendar) }.sorted {
            if $0.allDay != $1.allDay { return $0.allDay }
            if let left = $0.startTime, let right = $1.startTime, left != right { return left < right }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    func markedDays(_ days: [Date]) -> Set<Date> {
        let spans = visibleEvents.filter { notionEvents == nil || $0.provider != "notion" }
            .compactMap { $0.interval(in: calendar) }
        return Set(days.filter { day in
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { return false }
            return spans.contains { span in
                span.lowerBound < next &&
                    (span.upperBound > day || (span.lowerBound == span.upperBound && span.lowerBound >= day))
            }
        })
    }

    func hasCoverage(on day: Date) -> Bool {
        if notionEvents != nil { return true }
        if !nativeCalendarNames.isEmpty, let range = calendar.dateInterval(of: .month, for: month),
           day >= range.start && day <= range.end {
            return true
        }
        guard let snapshot else { return false }
        let key = dayKey(day, in: calendar)
        return key >= snapshot.startDay && key < snapshot.endDay
    }

    func refreshFromSources() {
        if EKEventStore.authorizationStatus(for: .event) == .fullAccess {
            store.refreshSourcesIfNecessary()
        }
        refresh()
    }

    func startLiveRefresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled, let self else { return }
                self.refreshFromSources()
            }
        }
    }

    func showMonth(_ month: Date) {
        guard self.month != month else { return }
        self.month = month
        refresh()
    }

    func connect(addAccount: Bool = false) async {
        access = EKEventStore.authorizationStatus(for: .event)
        if access == .denied || access == .restricted {
            if let settings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                NSWorkspace.shared.open(settings)
            }
            return
        }
        if !canReadMacCalendar {
            do {
                _ = try await store.requestFullAccessToEvents()
                error = nil
            } catch {
                self.error = "Calendar access could not be requested. \(error.localizedDescription)"
            }
        }
        refresh()
        if canReadMacCalendar && (addAccount || nativeCalendarNames.isEmpty),
           let accounts = URL(string: "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension") {
            NSWorkspace.shared.open(accounts)
        }
    }

    func refresh() {
        access = EKEventStore.authorizationStatus(for: .event)
        guard canReadMacCalendar, let range = calendar.dateInterval(of: .month, for: month) else {
            nativeCalendarNames = []
            nativeEvents = []
            return
        }
        let calendars = store.calendars(for: .event)
        nativeCalendarNames = Set(calendars.map { $0.title.lowercased() })
        guard !calendars.isEmpty else {
            nativeEvents = []
            return
        }
        let end = calendar.date(byAdding: .day, value: 1, to: range.end) ?? range.end
        let predicate = store.predicateForEvents(withStart: range.start, end: end, calendars: calendars)
        nativeEvents = store.events(matching: predicate).compactMap(nativeEntry)
    }

    struct WritableCalendar: Identifiable, Hashable {
        let id: String
        let title: String
    }

    var writableCalendars: [WritableCalendar] {
        guard canReadMacCalendar else { return [] }
        return store.calendars(for: .event)
            .filter(\.allowsContentModifications)
            .map { WritableCalendar(id: $0.calendarIdentifier, title: $0.title) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func createMacEvent(calendarID: String, fields: CalendarEventFields) throws {
        guard canReadMacCalendar,
              let targetCalendar = store.calendars(for: .event).first(where: {
                  $0.calendarIdentifier == calendarID && $0.allowsContentModifications
              }) else { throw CalendarEditError.unavailable }
        let title = fields.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, fields.start <= fields.end else { throw CalendarEditError.invalidDates }
        let event = EKEvent(eventStore: store)
        event.calendar = targetCalendar
        event.title = title
        event.isAllDay = fields.allDay
        event.startDate = fields.start
        // EventKit expects an inclusive end date for all-day events.
        event.endDate = fields.end
        try store.save(event, span: .thisEvent)
        refresh()
    }

    func updateMacEvent(_ entry: ScheduleEvent, original: CalendarEventFields,
                        changes: CalendarEventFields) throws {
        guard canReadMacCalendar, let identifier = entry.nativeIdentifier,
              changes.start <= changes.end, !changes.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let day = calendar.dateInterval(of: .day, for: original.start) else { throw CalendarEditError.unavailable }
        let predicate = store.predicateForEvents(withStart: day.start, end: day.end, calendars: nil)
        guard let event = store.events(matching: predicate).first(where: { candidate in
            guard candidate.eventIdentifier == identifier, let start = candidate.startDate else { return false }
            return (candidate.isAllDay ? calendar.startOfDay(for: start) : start) == original.start
        }), let latest = nativeEntry(event), latest.nativeIdentifier != nil,
           let fields = CalendarEventFields(event: latest, calendar: calendar) else { throw CalendarEditError.conflict }
        if changes.title != original.title {
            guard fields.title == original.title else { throw CalendarEditError.conflict }
        }
        let datesChanged = changes.allDay != original.allDay || changes.start != original.start || changes.end != original.end
        if datesChanged {
            guard fields.allDay == original.allDay, fields.start == original.start,
                  fields.end == original.end else { throw CalendarEditError.conflict }
        }
        if changes.title != original.title { event.title = changes.title.trimmingCharacters(in: .whitespacesAndNewlines) }
        if datesChanged {
            event.isAllDay = changes.allDay
            event.startDate = changes.start
            // EventKit expects an inclusive end date for all-day events.
            event.endDate = changes.end
        }
        try store.save(event, span: .thisEvent)
        refresh()
    }

    func deleteMacEvent(_ entry: ScheduleEvent, original: CalendarEventFields) throws {
        guard canReadMacCalendar, let identifier = entry.nativeIdentifier,
              let day = calendar.dateInterval(of: .day, for: original.start) else { throw CalendarEditError.unavailable }
        let predicate = store.predicateForEvents(withStart: day.start, end: day.end, calendars: nil)
        guard let event = store.events(matching: predicate).first(where: { candidate in
            guard candidate.eventIdentifier == identifier, let start = candidate.startDate else { return false }
            return (candidate.isAllDay ? calendar.startOfDay(for: start) : start) == original.start
        }) else { throw CalendarEditError.conflict }
        try store.remove(event, span: .thisEvent)
        refresh()
    }

    private func nativeEntry(_ event: EKEvent) -> ScheduleEvent? {
        guard event.status != .canceled, event.attendees?.contains(where: {
            $0.isCurrentUser && $0.participantStatus == .declined
        }) != true, let start = event.startDate, let end = event.endDate else { return nil }
        let first = event.isAllDay ? dayKey(start, in: calendar) : start.ISO8601Format()
        let last: String
        if event.isAllDay {
            let exclusiveEnd = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end)) ?? end
            last = dayKey(exclusiveEnd, in: calendar)
        } else {
            last = end.ISO8601Format()
        }
        let editable = event.calendar.allowsContentModifications && (!event.hasAttendees || event.organizer?.isCurrentUser == true)
        return ScheduleEvent(id: "\(event.eventIdentifier ?? event.calendarItemIdentifier)|\(first)",
                             title: event.title ?? "Untitled event", calendar: event.calendar.title,
                             provider: "mac", start: first, end: last, allDay: event.isAllDay, url: nil,
                             location: event.location, nativeIdentifier: editable ? event.eventIdentifier : nil)
    }

    private func eventKey(_ event: ScheduleEvent) -> String {
        let time = event.startTime?.ISO8601Format() ?? event.start
        return "\(event.title.lowercased())|\(time)"
    }
}
