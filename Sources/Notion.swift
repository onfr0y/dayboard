import Foundation
import Security

func notionDay(_ value: String, in calendar: Calendar) -> Date? {
    if value.count == 10 {
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
    return notionTimestamp(value).map { calendar.startOfDay(for: $0) }
}

func notionTimestamp(_ value: String) -> Date? {
    guard value.count > 10 else { return nil }
    let timestamp = value.replacingOccurrences(of: " ", with: "T")
    return (try? Date(timestamp, strategy: .iso8601)) ??
        (try? Date(timestamp, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
}

struct NotionTask: Codable, Identifiable {
    var id: String { url.absoluteString }
    let url: URL
    let title: String
    let status: String?
    let priority: String?
    let start: String
    let end: String?

    var done: Bool { status == "Completed" }
    var rank: Int {
        ["Urgent", "High Priority", "Medium Priority", "Low Priority"]
            .firstIndex(of: priority ?? "") ?? 4
    }

    func interval(in calendar: Calendar) -> ClosedRange<Date>? {
        guard let first = notionDay(start, in: calendar) else { return nil }
        let last = end.flatMap { notionDay($0, in: calendar) } ?? first
        return first...max(first, last)
    }
}

struct Snapshot: Codable {
    let fetchedAt: Date
    let tasks: [NotionTask]
}

struct GoodHabit: Codable, Identifiable {
    let id: String
    let url: URL
    let title: String

    static func normaliseID(_ value: String) -> String {
        value.replacingOccurrences(of: "-", with: "").lowercased()
    }
}

struct HabitSnapshot: Codable {
    let fetchedAt: Date
    let habits: [GoodHabit]
    let logDay: String?
    let checkedIn: Set<String>
}

struct PendingCheckIn: Codable, Identifiable {
    let habitID: String
    let clickedAt: Date
    let timeZone: String

    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone) ?? .gmt
        return calendar
    }

    var day: String { dayKey(clickedAt, in: calendar) }
    var id: String { "\(habitID)|\(day)" }
}

func dayKey(_ date: Date, in calendar: Calendar) -> String {
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
}

enum NotionFailure: LocalizedError {
    case http(Int), format, keychain(OSStatus), missingToken, checkInAccess, missingConfiguration, journalAccess

    var errorDescription: String? {
        switch self {
        case .http(401): "Notion rejected the token. Enter a valid token in Settings."
        case .http(403), .http(404): "The token needs read access to your Tasks database."
        case .http(429): "Notion is busy. The app will retry automatically."
        case .http(let code): "Notion returned HTTP \(code)."
        case .format: "Notion returned an unexpected response."
        case .keychain(let code): "macOS Keychain returned error \(code)."
        case .missingToken: "Enter your Notion token to connect."
        case .missingConfiguration: "Import your Notion configuration in Dayboard Settings."
        case .checkInAccess: "Give the Notion connection read access to Good Habits, Activity Log and Character, and permission to insert into Activity Log."
        case .journalAccess: "Give the Notion connection access to the Daily Journal data source and permission to create pages."
        }
    }
}

enum NotionAPI {
    struct Batch: Decodable {
        let results: [Page]
        let has_more: Bool
        let next_cursor: String?
    }

    struct Page: Decodable {
        struct Property: Decodable {
            struct Text: Decodable { let plain_text: String }
            struct Choice: Decodable { let name: String }
            struct DateValue: Decodable { let start: String; let end: String? }
            struct Relation: Decodable { let id: String }
            let title: [Text]?
            let status: Choice?
            let select: Choice?
            let date: DateValue?
            let relation: [Relation]?
        }

        let id: String?
        let url: URL
        let properties: [String: Property]
        let in_trash: Bool?

        var task: NotionTask? {
            guard in_trash != true, let date = properties["Action Date"]?.date else { return nil }
            let name = properties["Tasks/Event"]?.title?.map(\.plain_text).joined() ?? ""
            return NotionTask(url: url, title: name, status: properties["Status"]?.status?.name,
                              priority: properties["Priority"]?.select?.name, start: date.start, end: date.end)
        }

        var habit: GoodHabit? {
            guard in_trash != true, let id, let title = properties["Good Habit"]?.title else { return nil }
            return GoodHabit(id: GoodHabit.normaliseID(id), url: url, title: title.map(\.plain_text).joined())
        }
    }

    static func fetch(token: String) async throws -> Snapshot {
        let config = try NotionConfiguration.require()
        let pages = try await query(source: config.taskSourceID.uuidString, token: token,
                                    filter: ["property": "Action Date", "date": ["is_not_empty": true]])
        return Snapshot(fetchedAt: Date(), tasks: pages.compactMap(\.task))
    }

    static func dailyJournal(
        on date: Date, calendar: Calendar, sourceID: UUID, templateID: UUID?,
        token: String, createIfMissing: Bool, session: URLSession = .shared
    ) async throws -> URL? {
        let first = calendar.startOfDay(for: date)
        let last = calendar.date(byAdding: .day, value: 1, to: first)!
        let today = dayKey(first, in: calendar)
        let source = sourceID.uuidString.lowercased()
        // Fetch the local date and nearby timed entries, then check each in the same timezone.
        let previous = dayKey(calendar.date(byAdding: .day, value: -1, to: first)!, in: calendar)
        let following = dayKey(last, in: calendar)
        do {
            let pages = try await query(source: source, token: token, filter: ["and": [
                ["property": "Date", "date": ["on_or_after": previous]],
                ["property": "Date", "date": ["on_or_before": following]]
            ]], session: session)
            let matches = pages.filter {
                guard $0.in_trash != true, let start = $0.properties["Date"]?.date?.start else { return false }
                return notionDay(start, in: calendar) == first
            }
            if let existing = matches.min(by: { $0.url.absoluteString < $1.url.absoluteString }) {
                return existing.url
            }
            guard createIfMissing else { return nil }

            let body: [String: Any] = [
                "parent": ["type": "data_source_id", "data_source_id": source],
                "properties": ["Date": ["date": ["start": today]]],
                "template": templateID.map { ["type": "template_id", "template_id": $0.uuidString.lowercased()] }
                    ?? ["type": "default"]
            ]
            var create = request(path: "pages", token: token, method: "POST")
            create.httpBody = try JSONSerialization.data(withJSONObject: body)
            let response = try await send(create, session: session, rateLimitRetry: false)
            struct CreatedJournal: Decodable { let url: URL }
            return try JSONDecoder().decode(CreatedJournal.self, from: response).url
        } catch NotionFailure.http(403) {
            throw NotionFailure.journalAccess
        } catch NotionFailure.http(404) {
            throw NotionFailure.journalAccess
        }
    }

    static func fetchHabits(token: String, day: Date, calendar: Calendar) async throws -> (HabitSnapshot, String?) {
        let config = try NotionConfiguration.require()
        let pages = try await query(source: config.habitSourceID.uuidString, token: token)
        let habits = pages.compactMap(\.habit)
        let now = Date()
        let key = dayKey(day, in: calendar)
        guard !habits.isEmpty else {
            return (HabitSnapshot(fetchedAt: now, habits: [], logDay: key, checkedIn: []), nil)
        }
        do {
            let ids = try await checkedInIDs(on: day, calendar: calendar, token: token, logID: config.activitySourceID.uuidString)
            return (HabitSnapshot(fetchedAt: now, habits: habits, logDay: key, checkedIn: ids), nil)
        } catch {
            let message: String
            switch error {
            case NotionFailure.http(403), NotionFailure.http(404):
                message = "The token needs read access to Activity Log to show check-ins."
            default:
                message = "Check-ins could not be refreshed. \(error.localizedDescription)"
            }
            return (HabitSnapshot(fetchedAt: now, habits: habits, logDay: nil, checkedIn: []), message)
        }
    }

    static func checkIn(_ entry: PendingCheckIn, token: String, session: URLSession = .shared,
                        configuration: NotionConfiguration? = nil) async throws {
        let config = try configuration ?? NotionConfiguration.require()
        let calendar = entry.calendar
        let day = calendar.startOfDay(for: entry.clickedAt)
        let id = GoodHabit.normaliseID(entry.habitID)
        guard id.count == 32 else { throw NotionFailure.format }
        let ranges = [id.prefix(8), id.dropFirst(8).prefix(4), id.dropFirst(12).prefix(4),
                      id.dropFirst(16).prefix(4), id.suffix(12)]
        let habitID = ranges.joined(separator: "-")
        guard UUID(uuidString: habitID) != nil else { throw NotionFailure.format }
        let logID = config.activitySourceID.uuidString

        do {
            let existing = try await checkedInIDs(on: day, calendar: calendar, token: token, logID: logID, session: session)
            guard !existing.contains(id) else { return }
            let character = try await send(request(path: "data_sources/\(config.characterSourceID.uuidString)", token: token),
                                           session: session)
            guard !character.isEmpty else { throw NotionFailure.format }
            let response = try await send(request(path: "pages/\(habitID)", token: token), session: session)
            let habit = try JSONDecoder().decode(Page.self, from: response)
            guard habit.in_trash != true, habit.habit?.id == id else { throw NotionFailure.format }
            var create = request(path: "pages", token: token, method: "POST")
            create.httpBody = try JSONSerialization.data(withJSONObject: [
                "parent": ["type": "data_source_id", "data_source_id": logID],
                "properties": [
                    "Activity": ["title": []],
                    "Date": ["date": ["start": entry.clickedAt.ISO8601Format()]],
                    "Good Habit": ["relation": [["id": habitID]]],
                    "Character": ["relation": [["id": config.characterPageID.uuidString]]],
                    "History": ["checkbox": false],
                    "Type": ["rich_text": [["type": "text", "text": ["content": "GOOD"]]]]
                ]
            ])
            _ = try await send(create, session: session, rateLimitRetry: false)
        } catch NotionFailure.http(403) {
            throw NotionFailure.checkInAccess
        } catch NotionFailure.http(404) {
            throw NotionFailure.checkInAccess
        }
    }

    private static func checkedInIDs(on day: Date, calendar: Calendar, token: String, logID: String,
                                     session: URLSession = .shared) async throws -> Set<String> {
        let before = dayKey(calendar.date(byAdding: .day, value: -1, to: day)!, in: calendar)
        let after = dayKey(calendar.date(byAdding: .day, value: 1, to: day)!, in: calendar)
        let logs = try await query(source: logID, token: token, filter: ["and": [
            ["property": "Date", "date": ["on_or_after": before]],
            ["property": "Date", "date": ["on_or_before": after]],
            ["property": "Good Habit", "relation": ["is_not_empty": true]]
        ]], session: session)
        return Set(logs.flatMap { page -> [String] in
            guard page.in_trash != true, let date = page.properties["Date"]?.date?.start,
                  notionDay(date, in: calendar) == day else { return [] }
            return page.properties["Good Habit"]?.relation?.map { GoodHabit.normaliseID($0.id) } ?? []
        })
    }

    private static func query(source: String, token: String, filter: [String: Any]? = nil,
                              session: URLSession = .shared) async throws -> [Page] {
        var request = self.request(path: "data_sources/\(source)/query", token: token, method: "POST")

        var cursor: String?
        var visited = Set<String>()
        var pages: [URL: Page] = [:]
        repeat {
            var query: [String: Any] = ["page_size": 100]
            query["filter"] = filter
            query["start_cursor"] = cursor
            request.httpBody = try JSONSerialization.data(withJSONObject: query)
            let data = try await send(request, session: session)
            let batch = try JSONDecoder().decode(Batch.self, from: data)
            for page in batch.results { pages[page.url] = page }
            if batch.has_more {
                guard let next = batch.next_cursor, visited.insert(next).inserted else { throw NotionFailure.format }
                cursor = next
            } else {
                cursor = nil
            }
        } while cursor != nil
        return Array(pages.values)
    }

    private static func request(path: String, token: String, method: String = "GET") -> URLRequest {
        let url = URL(string: "https://api.notion.com/v1/\(path)")!
        var request = URLRequest(url: url, timeoutInterval: 25)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2026-03-11", forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private static func send(_ request: URLRequest, session: URLSession,
                             rateLimitRetry: Bool = true) async throws -> Data {
        let (data, raw) = try await session.data(for: request)
        guard let response = raw as? HTTPURLResponse else { throw NotionFailure.format }
        if response.statusCode == 429 && rateLimitRetry {
            let retry = response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 1
            try await Task.sleep(for: .seconds(min(8, max(1, retry))))
            return try await send(request, session: session, rateLimitRetry: false)
        }
        guard (200...299).contains(response.statusCode) else { throw NotionFailure.http(response.statusCode) }
        return data
    }
}

enum TokenStore {
    static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.fr0y.dayboard.notion",
        kSecAttrAccount as String: "notion-tasks"
    ]

    static func read() throws -> String? {
        var search = query
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(search as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else { throw NotionFailure.keychain(status) }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ token: String) throws {
        let data = Data(token.utf8)
        let attributes = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw NotionFailure.keychain(status) }
    }

    static func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw NotionFailure.keychain(status) }
    }
}
