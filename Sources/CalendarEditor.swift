import SwiftUI

enum CalendarEditError: LocalizedError {
    case unavailable, conflict, invalidDates, notionAccess, syncing

    var errorDescription: String? {
        switch self {
        case .unavailable: "This event is unavailable or its calendar is read-only."
        case .conflict: "This event changed elsewhere. Close the editor and reopen it to use the latest details."
        case .invalidDates: "Enter a title and an end date or time on or after the start."
        case .notionAccess: "Give the Dayboard connection permission to update this Notion database."
        case .syncing: "Dayboard is refreshing. Try saving again in a moment."
        }
    }
}

struct CalendarEventFields: Equatable {
    let title: String
    let allDay: Bool
    let start: Date
    // End is the last included day for all-day events, or the end time for timed events.
    let end: Date

    init(title: String, allDay: Bool, start: Date, end: Date) {
        self.title = title
        self.allDay = allDay
        self.start = start
        self.end = end
    }

    init?(event: ScheduleEvent, calendar: Calendar) {
        guard let dates = event.interval(in: calendar) else { return nil }
        title = event.title
        allDay = event.allDay
        start = dates.lowerBound
        if event.allDay && dates.upperBound > start {
            end = calendar.date(byAdding: .day, value: -1, to: dates.upperBound) ?? start
        } else {
            end = dates.upperBound
        }
    }
}

enum CalendarDestination: Identifiable, Hashable {
    case notion
    case mac(id: String, title: String)

    var id: String {
        switch self {
        case .notion: "notion"
        case .mac(let id, _): "mac|\(id)"
        }
    }

    var title: String {
        switch self {
        case .notion: "Notion Calendar"
        case .mac(_, let title): title
        }
    }
}

@MainActor
final class CalendarEditor: ObservableObject {
    let original: CalendarEventFields?
    let calendar: Calendar
    let destinations: [CalendarDestination]
    @Published var destination: CalendarDestination?
    @Published var title: String
    @Published var allDay: Bool
    @Published var start: Date
    @Published var end: Date
    @Published var confirmDelete = false
    @Published private(set) var saving = false
    @Published private(set) var problem: String?

    var isNew: Bool { original == nil }

    init(_ fields: CalendarEventFields, calendar: Calendar) {
        original = fields
        self.calendar = calendar
        destinations = []
        destination = nil
        title = fields.title
        allDay = fields.allDay
        start = fields.start
        end = fields.end
    }

    init(day: Date, startTime: Date? = nil, calendar: Calendar, destinations: [CalendarDestination]) {
        original = nil
        self.calendar = calendar
        self.destinations = destinations
        destination = destinations.first
        title = ""
        allDay = false
        let baseStart: Date
        if let startTime {
            baseStart = startTime
        } else {
            let now = Date()
            if calendar.isDate(day, inSameDayAs: now),
               let hour = calendar.dateComponents([.hour], from: now).hour,
               let nextHour = calendar.date(bySettingHour: min(22, hour + 1), minute: 0, second: 0, of: day) {
                baseStart = nextHour
            } else {
                baseStart = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day
            }
        }
        start = baseStart
        end = calendar.date(byAdding: .hour, value: 1, to: baseStart) ?? baseStart
    }

    var fields: CalendarEventFields {
        CalendarEventFields(title: title, allDay: allDay,
                            start: allDay ? calendar.startOfDay(for: start) : start,
                            end: allDay ? calendar.startOfDay(for: end) : end)
    }

    var canSave: Bool {
        let trimmed = !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard !saving, trimmed, fields.start <= fields.end else { return false }
        if let original { return fields != original }
        return destination != nil
    }

    func handleAllDayToggle(_ isAllDay: Bool) {
        guard !isAllDay else { return }
        let startMidnight = start == calendar.startOfDay(for: start)
        let endMidnight = end == calendar.startOfDay(for: end)
        if startMidnight && endMidnight {
            if let nine = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: start),
               let ten = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: end) {
                start = nine
                end = max(nine, ten)
            }
        }
    }

    func save(_ apply: (CalendarEventFields, CalendarDestination?) async throws -> Void) async -> Bool {
        guard canSave else { return false }
        let changes = fields
        let target = destination
        saving = true
        problem = nil
        defer { saving = false }
        do {
            try await apply(changes, target)
            return true
        } catch {
            problem = error.localizedDescription
            return false
        }
    }

    func remove(_ apply: () async throws -> Void) async -> Bool {
        guard !saving else { return false }
        saving = true
        problem = nil
        defer { saving = false }
        do {
            try await apply()
            return true
        } catch {
            problem = error.localizedDescription
            return false
        }
    }
}

struct CalendarEditorView: View {
    @ObservedObject var editor: CalendarEditor
    let sectionTitle: String
    let editable: Bool
    let offeredConnection: Bool
    let connect: () -> Void
    let openOriginal: (() -> Void)?
    let deleteEvent: (() async throws -> Void)?
    let close: () -> Void
    let save: (CalendarEventFields, CalendarDestination?) async throws -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                Section(sectionTitle) {
                    if editor.isNew && !editor.destinations.isEmpty {
                        Picker("Calendar", selection: Binding(
                            get: { editor.destination ?? editor.destinations[0] },
                            set: { editor.destination = $0 }
                        )) {
                            ForEach(editor.destinations) { dest in
                                Text(dest.title).tag(dest)
                            }
                        }
                    }
                    TextField("Title", text: $editor.title)
                    Toggle("All-day event", isOn: $editor.allDay)
                        .onChange(of: editor.allDay) { _, value in
                            editor.handleAllDayToggle(value)
                        }
                    DatePicker("Starts", selection: $editor.start,
                               displayedComponents: editor.allDay ? [.date] : [.date, .hourAndMinute])
                    DatePicker(editor.allDay ? "Last day" : "Ends", selection: $editor.end,
                               displayedComponents: editor.allDay ? [.date] : [.date, .hourAndMinute])
                }
                .disabled(editor.saving || !editable)
            }
            .formStyle(.grouped)
            .environment(\.calendar, editor.calendar)
            .environment(\.timeZone, editor.calendar.timeZone)

            if !editable {
                Text(offeredConnection ? "Connect this event’s account in Mac Calendar to edit it here." :
                        editor.isNew ? "Connect Notion or Mac Calendar in Settings to create events." :
                        "This calendar is read-only in Dayboard.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if let problem = editor.problem {
                Text(problem).font(.callout).foregroundStyle(.red)
            } else if editor.fields.end < editor.fields.start {
                Text("The end must be on or after the start.").font(.callout).foregroundStyle(.red)
            }

            HStack {
                if let openOriginal {
                    Button("Open original", action: openOriginal)
                }
                if offeredConnection { Button("Connect Mac Calendar", action: connect) }
                if editable, deleteEvent != nil {
                    Button("Delete", role: .destructive) { editor.confirmDelete = true }
                        .disabled(editor.saving)
                }
                Spacer()
                if editor.saving { ProgressView().controlSize(.small) }
                Button(editable ? "Cancel" : "Done", action: close)
                    .keyboardShortcut(.cancelAction)
                    .disabled(editor.saving)
                if editable {
                    Button(editor.isNew ? "Add" : "Save") {
                        Task {
                            if await editor.save(save) { close() }
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!editor.canSave)
                }
            }
        }
        .padding(16)
        .frame(width: 490, height: editor.isNew ? 345 : 305)
        .confirmationDialog("Delete this event?", isPresented: $editor.confirmDelete) {
            Button("Delete", role: .destructive) {
                guard let deleteEvent else { return }
                Task {
                    if await editor.remove(deleteEvent) { close() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the event from \(sectionTitle).")
        }
    }
}
