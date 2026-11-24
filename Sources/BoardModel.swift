import AppKit
import Combine
import ServiceManagement

@MainActor
final class BoardModel: ObservableObject {
    enum JournalStatus {
        case unchecked, missing, available(URL)
    }

    @Published var today: Date
    @Published var selected: Date
    @Published var month: Date
    @Published var snapshot: Snapshot?
    @Published var habitSnapshot: HabitSnapshot?
    @Published var scheduleCollapsed = UserDefaults.standard.bool(forKey: "scheduleCollapsed") {
        didSet { UserDefaults.standard.set(scheduleCollapsed, forKey: "scheduleCollapsed") }
    }
    @Published var tasksCollapsed = UserDefaults.standard.bool(forKey: "tasksCollapsed") {
        didSet { UserDefaults.standard.set(tasksCollapsed, forKey: "tasksCollapsed") }
    }
    @Published var habitsCollapsed = UserDefaults.standard.bool(forKey: "habitsCollapsed") {
        didSet { UserDefaults.standard.set(habitsCollapsed, forKey: "habitsCollapsed") }
    }
    @Published var habitProblem: String?
    @Published private(set) var pendingCheckIns: [PendingCheckIn] = []
    @Published private(set) var checkInProblem: String?
    @Published var busy = false
    @Published var connected = false
    @Published private(set) var readingSavedToken = false
    @Published var problem: String?
    @Published var loginStatus = SMAppService.mainApp.status
    @Published var loginProblem: String?
    @Published var tokenDraft = ""
    @Published private(set) var notionConfiguration = NotionConfiguration.current
    @Published private(set) var journalBusy = false
    @Published private(set) var journalProblem: String?
    @Published private var journalStatus = JournalStatus.unchecked
    private var journalDay: String?

    let calendar: Calendar
    private var token: String?
    private let cacheURL: URL
    private let habitCacheURL: URL
    private let checkInQueueURL: URL

    init(seed: URL?, habitSeed: URL?) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_GB")
        calendar.firstWeekday = 2
        calendar.timeZone = .autoupdatingCurrent
        self.calendar = calendar
        let currentDay = calendar.startOfDay(for: Date())
        today = currentDay
        selected = currentDay
        month = calendar.dateInterval(of: .month, for: currentDay)!.start
        cacheURL = URL.applicationSupportDirectory.appending(path: "Dayboard/tasks.json")
        habitCacheURL = URL.applicationSupportDirectory.appending(path: "Dayboard/habits.json")
        checkInQueueURL = URL.applicationSupportDirectory.appending(path: "Dayboard/pending-check-ins.json")
        if let data = try? Data(contentsOf: checkInQueueURL),
           let queued = try? JSONDecoder().decode([PendingCheckIn].self, from: data) {
            pendingCheckIns = queued
        }
        if let data = try? Data(contentsOf: cacheURL) {
            snapshot = try? JSONDecoder().decode(Snapshot.self, from: data)
        }
        if snapshot == nil, let seed, let data = try? Data(contentsOf: seed),
           let imported = try? JSONDecoder().decode(Snapshot.self, from: data) {
            snapshot = imported
            _ = writeCache(imported, to: cacheURL)
        }
        if let data = try? Data(contentsOf: habitCacheURL) {
            habitSnapshot = try? JSONDecoder().decode(HabitSnapshot.self, from: data)
        }
        if habitSnapshot == nil, let habitSeed, let data = try? Data(contentsOf: habitSeed),
           let imported = try? JSONDecoder().decode(HabitSnapshot.self, from: data) {
            habitSnapshot = imported
            _ = writeCache(imported, to: habitCacheURL)
        }
    }

    func start() {
        if !UserDefaults.standard.bool(forKey: "didConfigureLogin") {
            setLaunchAtLogin(true)
        }
        Task {
            await restoreSavedToken()
            await refresh()
            var nextRefresh = Date().addingTimeInterval(60)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                let changed = rollDate()
                if changed || Date() >= nextRefresh {
                    await refresh()
                    nextRefresh = Date().addingTimeInterval(60)
                }
            }
        }
    }

    func restoreSavedToken() async {
        guard !connected, !readingSavedToken, !busy else { return }
        readingSavedToken = true
        defer { readingSavedToken = false }
        do {
            token = try await Task.detached { try TokenStore.read() }.value
            connected = token != nil
            problem = nil
        } catch {
            problem = "Allow Dayboard to use its saved Notion token in macOS Keychain, or enter a token below."
        }
    }

    @discardableResult
    func rollDate() -> Bool {
        let newDay = calendar.startOfDay(for: Date())
        guard newDay != today else { return false }
        let followToday = selected == today && month == monthStart(today)
        today = newDay
        if followToday { goToToday() }
        return true
    }

    func goToToday() {
        selected = today
        month = monthStart(today)
    }

    func monthStart(_ date: Date) -> Date {
        calendar.dateInterval(of: .month, for: date)!.start
    }

    func moveMonth(_ step: Int) {
        guard let date = calendar.date(byAdding: .month, value: step, to: month) else { return }
        month = date
        selected = calendar.isDate(today, equalTo: date, toGranularity: .month) ? today : date
    }

    func refresh() async {
        guard !busy, let token else { return }
        busy = true
        defer { busy = false }
        do {
            let fresh = try await NotionAPI.fetch(token: token)
            snapshot = fresh
            problem = writeCache(fresh, to: cacheURL) ? nil : "The local task cache could not be saved."
        } catch {
            problem = error.localizedDescription
        }
        await refreshHabits(token: token)
        await flushCheckIns(token: token)
        await updateJournal()
    }

    func createScheduledTask(_ fields: CalendarEventFields) async throws {
        guard !busy else { throw CalendarEditError.syncing }
        guard let token else { throw CalendarEditError.unavailable }
        busy = true
        defer { busy = false }
        let created = try await NotionAPI.createScheduledTask(fields: fields, calendar: calendar, token: token)
        let current = snapshot?.tasks ?? []
        let updated = Snapshot(fetchedAt: snapshot?.fetchedAt ?? Date(), tasks: current + [created])
        self.snapshot = updated
        _ = writeCache(updated, to: cacheURL)
    }

    func updateScheduledTask(_ event: ScheduleEvent, original: CalendarEventFields,
                             changes: CalendarEventFields) async throws {
        guard !busy else { throw CalendarEditError.syncing }
        guard let token, let url = event.url, event.provider == "notion" else { throw CalendarEditError.unavailable }
        busy = true
        defer { busy = false }
        let saved = try await NotionAPI.updateScheduledTask(url: url, original: original, changes: changes,
                                                            calendar: calendar, token: token)
        if let snapshot {
            let updated = Snapshot(fetchedAt: snapshot.fetchedAt, tasks: snapshot.tasks.map { $0.url == url ? saved : $0 })
            self.snapshot = updated
            _ = writeCache(updated, to: cacheURL)
        }
    }

    func deleteScheduledTask(_ event: ScheduleEvent) async throws {
        guard !busy else { throw CalendarEditError.syncing }
        guard let token, let url = event.url, event.provider == "notion" else { throw CalendarEditError.unavailable }
        busy = true
        defer { busy = false }
        try await NotionAPI.deleteScheduledTask(url: url, token: token)
        if let snapshot {
            let updated = Snapshot(fetchedAt: snapshot.fetchedAt, tasks: snapshot.tasks.filter { $0.url != url })
            self.snapshot = updated
            _ = writeCache(updated, to: cacheURL)
        }
    }

    func importNotionConfiguration(from url: URL) async {
        guard !busy, !journalBusy else { return }
        do {
            try NotionConfiguration.importFile(url)
            notionConfiguration = NotionConfiguration.current
            problem = nil
            journalStatus = .unchecked
            journalProblem = nil
            await refresh()
        } catch {
            problem = "Dayboard could not read the Notion configuration. Check the IDs and links in the JSON file."
        }
    }

    func connect(_ input: String) async -> Bool {
        guard !busy, !journalBusy, !readingSavedToken else { return false }
        let candidate = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else {
            problem = NotionFailure.missingToken.localizedDescription
            return false
        }
        busy = true
        defer { busy = false }
        do {
            let fresh = try await NotionAPI.fetch(token: candidate)
            try TokenStore.save(candidate)
            token = candidate
            connected = true
            snapshot = fresh
            problem = writeCache(fresh, to: cacheURL) ? nil : "The local task cache could not be saved."
            await refreshHabits(token: candidate)
            await flushCheckIns(token: candidate)
            await updateJournal()
            return true
        } catch {
            problem = error.localizedDescription
            return false
        }
    }

    func disconnect() {
        guard !busy, !journalBusy else { return }
        do {
            try TokenStore.remove()
            token = nil
            connected = false
            problem = nil
            habitProblem = nil
            journalStatus = .unchecked
            journalProblem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    var dailyJournalStatus: JournalStatus {
        journalDay == dayKey(today, in: calendar) ? journalStatus : .unchecked
    }

    var journalAction: String {
        if journalBusy { return "Checking journal…" }
        guard connected, notionConfiguration?.journalSourceID != nil else { return "Connect journal" }
        switch dailyJournalStatus {
        case .unchecked: return "Check journal"
        case .missing: return "Create journal"
        case .available: return "Open journal"
        }
    }

    func useJournal(openSettings: () -> Void) async {
        rollDate()
        guard connected, notionConfiguration?.journalSourceID != nil else {
            openSettings()
            return
        }
        switch dailyJournalStatus {
        case .available(let url):
            NSWorkspace.shared.open(url)
        case .missing:
            if let url = await updateJournal(createIfMissing: true) { NSWorkspace.shared.open(url) }
        case .unchecked:
            await updateJournal()
        }
    }

    @discardableResult
    private func updateJournal(createIfMissing: Bool = false) async -> URL? {
        guard !journalBusy, let token, let config = notionConfiguration,
              let source = config.journalSourceID else { return nil }
        let day = today
        let dateKey = dayKey(day, in: calendar)
        journalBusy = true
        defer { journalBusy = false }
        do {
            let result = try await NotionAPI.dailyJournal(on: day, calendar: calendar, sourceID: source,
                                                          templateID: config.journalTemplateID, token: token,
                                                          createIfMissing: createIfMissing)
            journalDay = dateKey
            journalStatus = result.map(JournalStatus.available) ?? .missing
            journalProblem = nil
            return result
        } catch {
            journalProblem = error.localizedDescription
            // A lost response may still mean Notion created the page. Look it up before offering another create.
            journalStatus = .unchecked
            return nil
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        defer { loginStatus = SMAppService.mainApp.status }
        do {
            if enabled {
                if loginStatus != .enabled && loginStatus != .requiresApproval {
                    try SMAppService.mainApp.register()
                }
            } else if loginStatus == .enabled || loginStatus == .requiresApproval {
                try SMAppService.mainApp.unregister()
            }
            UserDefaults.standard.set(true, forKey: "didConfigureLogin")
            loginProblem = nil
        } catch {
            loginProblem = error.localizedDescription
        }
    }

    var habitCheckIns: Set<String>? {
        guard let habitSnapshot, habitSnapshot.logDay == dayKey(today, in: calendar) else { return nil }
        return habitSnapshot.checkedIn
    }

    var pendingToday: Set<String> {
        let day = dayKey(today, in: calendar)
        return Set(pendingCheckIns.filter { $0.day == day }.map(\.habitID))
    }

    func checkIn(_ habit: GoodHabit) -> Bool {
        rollDate()
        let entry = PendingCheckIn(habitID: habit.id, clickedAt: Date(), timeZone: calendar.timeZone.identifier)
        guard habitCheckIns?.contains(habit.id) != true,
              !pendingCheckIns.contains(where: { $0.id == entry.id }) else { return false }
        let queue = pendingCheckIns + [entry]
        guard writeCache(queue, to: checkInQueueURL) else {
            checkInProblem = "Dayboard couldn’t save the check-in on this Mac."
            return false
        }
        pendingCheckIns = queue
        checkInProblem = nil
        Task { await syncCheckIns() }
        return true
    }

    func syncCheckIns() async {
        guard !busy, let token, !pendingCheckIns.isEmpty else { return }
        busy = true
        defer { busy = false }
        await flushCheckIns(token: token)
    }

    private func flushCheckIns(token: String) async {
        guard !pendingCheckIns.isEmpty else { return }
        var attempted = Set<String>()
        checkInProblem = nil
        while let entry = pendingCheckIns.first(where: { !attempted.contains($0.id) }) {
            attempted.insert(entry.id)
            do {
                try await NotionAPI.checkIn(entry, token: token)
                if entry.day == dayKey(today, in: calendar), let previous = habitSnapshot {
                    let checked = (habitCheckIns ?? []).union([entry.habitID])
                    let updated = HabitSnapshot(fetchedAt: Date(), habits: previous.habits,
                                                logDay: entry.day, checkedIn: checked)
                    habitSnapshot = updated
                    _ = writeCache(updated, to: habitCacheURL)
                }
                let remaining = pendingCheckIns.filter { $0.id != entry.id }
                guard writeCache(remaining, to: checkInQueueURL) else {
                    checkInProblem = "Notion saved the check-in, but Dayboard couldn’t update its local queue."
                    return
                }
                pendingCheckIns = remaining
            } catch NotionFailure.checkInAccess {
                checkInProblem = NotionFailure.checkInAccess.localizedDescription
                return
            } catch {
                checkInProblem = error.localizedDescription
            }
        }
    }

    private func refreshHabits(token: String) async {
        do {
            let (fresh, issue) = try await NotionAPI.fetchHabits(token: token, day: today, calendar: calendar)
            let previous = habitSnapshot
            let retainToday = issue != nil && previous?.logDay == dayKey(today, in: calendar)
            let merged = HabitSnapshot(fetchedAt: fresh.fetchedAt, habits: fresh.habits,
                                       logDay: retainToday ? previous?.logDay : fresh.logDay,
                                       checkedIn: retainToday ? previous?.checkedIn ?? [] : fresh.checkedIn)
            habitSnapshot = merged
            let saved = writeCache(merged, to: habitCacheURL)
            habitProblem = issue ?? (saved ? nil : "The local habit cache could not be saved.")
        } catch NotionFailure.http(404) {
            habitProblem = "The token needs read access to the original Good Habit database."
        } catch {
            habitProblem = "Good Habits could not sync. \(error.localizedDescription)"
        }
    }

    private func writeCache<T: Encodable>(_ snapshot: T, to url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            return false
        }
    }
}
