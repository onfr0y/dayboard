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

    var startTime: Date? { notionTimestamp(start) }
    var endTime: Date? { notionTimestamp(end) }

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

    init(seed: URL?, month: Date, calendar: Calendar) {
        self.calendar = calendar
        self.month = month
        let cache = URL.applicationSupportDirectory.appending(path: "Dayboard/calendar.json")
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
    }

    var canReadMacCalendar: Bool { access == .fullAccess }

    var visibleEvents: [ScheduleEvent] {
        let fallback = (snapshot?.events ?? []).filter {
            $0.provider == "notion" || !nativeCalendarNames.contains($0.calendar.lowercased())
        }
        let nativeKeys = Set(nativeEvents.map(eventKey))
        return nativeEvents + fallback.filter { !nativeKeys.contains(eventKey($0)) }
    }

    func events(on day: Date) -> [ScheduleEvent] {
        visibleEvents.filter { $0.appears(on: day, in: calendar) }.sorted {
            if $0.allDay != $1.allDay { return $0.allDay }
            if let left = $0.startTime, let right = $1.startTime, left != right { return left < right }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    func markedDays(_ days: [Date]) -> Set<Date> {
        let spans = visibleEvents.compactMap { $0.interval(in: calendar) }
        return Set(days.filter { day in
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { return false }
            return spans.contains { span in
                span.lowerBound < next &&
                    (span.upperBound > day || (span.lowerBound == span.upperBound && span.lowerBound >= day))
            }
        })
    }

    func hasCoverage(on day: Date) -> Bool {
        if !nativeCalendarNames.isEmpty && calendar.isDate(month, equalTo: day, toGranularity: .month) {
            return true
        }
        guard let snapshot else { return false }
        let key = dayKey(day, in: calendar)
        return key >= snapshot.startDay && key < snapshot.endDay
    }

    func showMonth(_ month: Date) {
        guard self.month != month else { return }
        self.month = month
        refresh()
    }

    func connect() async {
        access = EKEventStore.authorizationStatus(for: .event)
        if access == .denied || access == .restricted {
            if let settings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                NSWorkspace.shared.open(settings)
            }
            return
        }
        if canReadMacCalendar {
            refresh()
            if nativeCalendarNames.isEmpty,
               let accounts = URL(string: "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension") {
                NSWorkspace.shared.open(accounts)
            }
            return
        }
        do {
            _ = try await store.requestFullAccessToEvents()
            error = nil
        } catch {
            self.error = "Calendar access could not be requested. \(error.localizedDescription)"
        }
        refresh()
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
        let predicate = store.predicateForEvents(withStart: range.start, end: range.end, calendars: calendars)
        nativeEvents = store.events(matching: predicate).compactMap { event in
            guard event.status != .canceled, event.attendees?.contains(where: {
                $0.isCurrentUser && $0.participantStatus == .declined
            }) != true, let start = event.startDate, let end = event.endDate else { return nil }
            let first = event.isAllDay ? dayKey(start, in: calendar) : start.ISO8601Format()
            let last = event.isAllDay ? dayKey(end, in: calendar) : end.ISO8601Format()
            return ScheduleEvent(id: "\(event.eventIdentifier ?? event.calendarItemIdentifier)|\(first)",
                                 title: event.title ?? "Untitled event", calendar: event.calendar.title,
                                 provider: "mac", start: first, end: last, allDay: event.isAllDay, url: nil)
        }
    }

    private func eventKey(_ event: ScheduleEvent) -> String {
        let time = event.startTime?.ISO8601Format() ?? event.start
        return "\(event.title.lowercased())|\(time)"
    }
}
