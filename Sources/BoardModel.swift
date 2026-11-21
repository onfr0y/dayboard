import AppKit
import Combine
import ServiceManagement

@MainActor
final class BoardModel: ObservableObject {
    @Published var today: Date
    @Published var selected: Date
    @Published var month: Date
    @Published var snapshot: Snapshot?
    @Published var habitSnapshot: HabitSnapshot?
    @Published var habitProblem: String?
    @Published private(set) var pendingCheckIns: [PendingCheckIn] = []
    @Published private(set) var checkInProblem: String?
    @Published var busy = false
    @Published var connected = false
    @Published var problem: String?
    @Published var loginStatus = SMAppService.mainApp.status
    @Published var loginProblem: String?
    @Published var tokenDraft = ""
    @Published private(set) var notionConfiguration = NotionConfiguration.current

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
        do {
            token = try TokenStore.read()
            connected = token != nil
        } catch {
            problem = error.localizedDescription
        }
    }

    func start() {
        if !UserDefaults.standard.bool(forKey: "didConfigureLogin") {
            setLaunchAtLogin(true)
        }
        Task {
            await refresh()
            var nextRefresh = Date().addingTimeInterval(300)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                let changed = rollDate()
                if changed || Date() >= nextRefresh {
                    await refresh()
                    nextRefresh = Date().addingTimeInterval(300)
                }
            }
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
    }

    func importNotionConfiguration(from url: URL) async {
        guard !busy else { return }
        do {
            try NotionConfiguration.importFile(url)
            notionConfiguration = NotionConfiguration.current
            problem = nil
            await refresh()
        } catch {
            problem = "Dayboard could not read the Notion configuration. Check the IDs and links in the JSON file."
        }
    }

    func connect(_ input: String) async -> Bool {
        guard !busy else { return false }
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
            return true
        } catch {
            problem = error.localizedDescription
            return false
        }
    }

    func disconnect() {
        guard !busy else { return }
        do {
            try TokenStore.remove()
            token = nil
            connected = false
            problem = nil
            habitProblem = nil
        } catch {
            problem = error.localizedDescription
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

    func checkIn(_ habit: GoodHabit) {
        rollDate()
        let entry = PendingCheckIn(habitID: habit.id, clickedAt: Date(), timeZone: calendar.timeZone.identifier)
        guard habitCheckIns?.contains(habit.id) != true,
              !pendingCheckIns.contains(where: { $0.id == entry.id }) else { return }
        let queue = pendingCheckIns + [entry]
        guard writeCache(queue, to: checkInQueueURL) else {
            checkInProblem = "Dayboard couldn’t save the check-in on this Mac."
            return
        }
        pendingCheckIns = queue
        checkInProblem = nil
        Task { await syncCheckIns() }
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
