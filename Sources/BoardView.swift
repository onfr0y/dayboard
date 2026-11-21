import SwiftUI

private let british = Locale(identifier: "en_GB")

private struct WallpaperText {
    let light: Bool
    var ink: Color { light ? .white : Color(white: 0.08) }
    var muted: Color { ink.opacity(0.82) }
    var rule: Color { ink.opacity(0.42) }
    var reverse: Color { light ? .black : .white }
}

private struct SectionLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .tracking(2.0)
            .textCase(.uppercase)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct GlyphButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 25, height: 25)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }
}

struct CalendarWidget: View {
    @ObservedObject var model: BoardModel
    @ObservedObject var schedule: ScheduleModel
    let showTimeline: () -> Void
    private var tone: WallpaperText { WallpaperText(light: schedule.lightText) }

    private var monthDays: [Date?] {
        let calendar = model.calendar
        guard let range = calendar.range(of: .day, in: .month, for: model.month) else { return [] }
        let padding = (calendar.component(.weekday, from: model.month) - calendar.firstWeekday + 7) % 7
        return Array<Date?>(repeating: nil, count: padding) +
            range.map { calendar.date(byAdding: .day, value: $0 - 1, to: model.month) }
    }

    var body: some View {
        GeometryReader { proxy in
            let compact = proxy.size.height < 550
            let heroSize = min(proxy.size.width * 0.57, compact ? 146 : 224,
                               max(90, (proxy.size.height - 185) * 0.60))
            VStack(alignment: .leading, spacing: compact ? 11 : 18) {
                HStack {
                    SectionLabel(title: model.selected.formatted(.dateTime.weekday(.wide).locale(british)))
                    Spacer()
                    SectionLabel(title: model.selected.formatted(.dateTime.year().locale(british)))
                }
                .foregroundStyle(tone.muted)
                Rectangle().fill(tone.rule).frame(height: 1)
                Button(action: showTimeline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(model.calendar.component(.day, from: model.selected))")
                            .font(.system(size: heroSize, weight: .light, design: .default))
                            .monospacedDigit()
                            .tracking(-0.085 * heroSize)
                            .lineLimit(1)
                            .padding(.leading, -6)
                            .padding(.top, -10)
                            .fixedSize(horizontal: true, vertical: false)
                            .accessibilityHidden(true)
                        Text(model.selected.formatted(.dateTime.month(.wide).locale(british)))
                            .font(.system(size: compact ? 28 : 42, weight: .light))
                            .tracking(-1.45)
                            .padding(.bottom, compact ? 6 : 11)
                            .accessibilityLabel(model.selected.formatted(date: .complete, time: .omitted))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show calendar timeline")
                .accessibilityElement(children: .combine)
                monthCalendar(compact: compact)
                Spacer(minLength: 0)
            }
        }
        .foregroundStyle(tone.ink)
        .shadow(color: tone.reverse.opacity(0.77), radius: 2.5, y: 0.8)
        .padding(3)
        .onChange(of: model.month) { _, month in schedule.showMonth(month) }
    }

    private func monthCalendar(compact: Bool) -> some View {
        let ranges = (model.snapshot?.tasks ?? []).compactMap { $0.interval(in: model.calendar) }
        let eventDays = schedule.markedDays(monthDays.compactMap { $0 })
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                SectionLabel(title: model.month.formatted(.dateTime.month(.wide).year().locale(british)))
                Spacer()
                GlyphButton(symbol: "rectangle.split.2x1", label: "Open two-day timeline", action: showTimeline)
                if model.selected != model.today || model.month != model.monthStart(model.today) {
                    Button("Today", action: model.goToToday)
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                }
                GlyphButton(symbol: "chevron.left", label: "Previous month") { model.moveMonth(-1) }
                GlyphButton(symbol: "chevron.right", label: "Next month") { model.moveMonth(1) }
            }
            .foregroundStyle(tone.muted)
            Rectangle().fill(tone.rule).frame(height: 1)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 2) {
                ForEach(Array(["M", "T", "W", "T", "F", "S", "S"].enumerated()), id: \.offset) { _, label in
                    Text(label)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(tone.muted)
                        .frame(height: 19)
                        .accessibilityHidden(true)
                }
                ForEach(Array(monthDays.enumerated()), id: \.offset) { _, date in
                    if let date {
                        let hasTasks = ranges.contains { $0.contains(date) }
                        let hasEvents = eventDays.contains(date)
                        let selected = date == model.selected
                        let today = date == model.today
                        Button {
                            model.selected = date
                            showTimeline()
                        } label: {
                            VStack(spacing: 2) {
                                Text("\(model.calendar.component(.day, from: date))")
                                    .font(.system(size: 12, weight: selected || today ? .semibold : .regular,
                                                  design: .monospaced))
                                HStack(spacing: 3) {
                                    if hasEvents {
                                        Circle().fill(selected ? tone.reverse : tone.ink).frame(width: 3, height: 3)
                                    }
                                    if hasTasks {
                                        Circle().stroke(selected ? tone.reverse : tone.ink, lineWidth: 0.8)
                                            .frame(width: 3, height: 3)
                                    }
                                }
                                .frame(height: 3)
                            }
                            .foregroundStyle(selected ? tone.reverse : tone.ink)
                            .frame(maxWidth: .infinity)
                            .frame(height: compact ? 19 : 24)
                            .background {
                                RoundedRectangle(cornerRadius: 3).fill(selected ? tone.ink : .clear)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(date.formatted(date: .complete, time: .omitted))
                        .accessibilityValue(hasEvents ? (hasTasks ? "Events and tasks" : "Calendar events") :
                                                (hasTasks ? "Scheduled tasks" : ""))
                        .accessibilityAddTraits(selected ? [.isSelected] : [])
                    } else {
                        Color.clear.frame(height: compact ? 19 : 24).accessibilityHidden(true)
                    }
                }
            }
        }
        .frame(maxWidth: 315, alignment: .leading)
    }
}

struct AgendaWidget: View {
    @ObservedObject var model: BoardModel
    @ObservedObject var schedule: ScheduleModel
    let openSettings: () -> Void
    private var tone: WallpaperText { WallpaperText(light: schedule.lightText) }

    private var tasks: [NotionTask] {
        (model.snapshot?.tasks ?? []).filter {
            $0.interval(in: model.calendar)?.contains(model.selected) ?? false
        }.sorted {
            if $0.done != $1.done { return !$0.done }
            if $0.rank != $1.rank { return $0.rank < $1.rank }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    private var habits: [GoodHabit] {
        let checked = model.habitCheckIns ?? []
        return (model.habitSnapshot?.habits ?? []).sorted {
            let left = checked.contains($0.id)
            let right = checked.contains($1.id)
            if left != right { return !left }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            VStack(alignment: .leading, spacing: 16) {
                if width >= 440 {
                    HStack(alignment: .top, spacing: width >= 585 ? 24 : 14) {
                        scheduleAndTasks.frame(maxWidth: .infinity, alignment: .topLeading)
                        Rectangle().fill(tone.rule).frame(width: 1)
                        habitsView.frame(width: width * 0.41, alignment: .topLeading)
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                } else {
                    VStack(alignment: .leading, spacing: 18) {
                        scheduleAndTasks.frame(maxHeight: proxy.size.height * 0.52, alignment: .topLeading)
                        habitsView.frame(maxHeight: .infinity, alignment: .topLeading)
                    }
                }
                footer
            }
        }
        .foregroundStyle(tone.ink)
        .shadow(color: tone.reverse.opacity(0.88), radius: 2.2, y: 0.8)
        .padding(3)
    }

    private var scheduleAndTasks: some View {
        let events = schedule.events(on: model.selected)
        let items = tasks
        return VStack(alignment: .leading, spacing: 10) {
            heading("Schedule", subtitle: model.selected == model.today ? "Today" :
                model.selected.formatted(.dateTime.day().month(.abbreviated).locale(british))) {
                if schedule.nativeCalendarNames.isEmpty {
                    Button("Connect Calendar") { Task { await schedule.connect() } }
                        .buttonStyle(.plain)
                        .help("Connect calendars synced to this Mac for live updates")
                }
            }
            fittingList {
                if events.isEmpty {
                    emptyMessage(schedule.hasCoverage(on: model.selected) ? "No calendar events." : "Calendar data unavailable.")
                } else {
                    ForEach(events) { event in eventRow(event) }
                }
                HStack {
                    SectionLabel(title: "Tasks")
                    Spacer()
                    if model.snapshot != nil {
                        Text("\(items.filter { !$0.done }.count) open")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                    }
                }
                .foregroundStyle(tone.muted)
                .padding(.top, 16)
                Rectangle().fill(tone.rule).frame(height: 1).padding(.bottom, 4)
                if items.isEmpty {
                    emptyMessage(model.snapshot == nil ? "Connect Notion to load tasks." : "No tasks scheduled.")
                } else {
                    ForEach(items) { task in
                        textRow(task.title, placeholder: "Untitled task", url: task.url,
                                checked: task.done, taskTime: scheduledTime(for: task), important: task.rank < 2)
                    }
                }
            }
            .id(model.selected)
        }
    }

    private func eventRow(_ event: ScheduleEvent) -> some View {
        Button {
            event.open(on: model.selected)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(event.allDay ? "all day" : event.startTime.map { clock($0) } ?? "")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(tone.muted)
                    .frame(width: 42, alignment: .leading)
                Text(event.title)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(event.calendar)
    }

    private var habitsView: some View {
        let items = habits
        let checked = model.habitCheckIns ?? []
        let pending = model.pendingToday
        return VStack(alignment: .leading, spacing: 10) {
            heading("Good Habits", subtitle: "Today") {
                if model.habitCheckIns != nil {
                    Text("\(items.filter { checked.contains($0.id) }.count)/\(items.count)")
                }
            }
            fittingList {
                if items.isEmpty {
                    emptyMessage(model.habitSnapshot == nil ? "Connect Notion to load habits." : "No habits in Notion.")
                }
                ForEach(items) { habit in
                    habitRow(habit, checked: checked.contains(habit.id), pending: pending.contains(habit.id))
                }
                if let issue = model.checkInProblem {
                    Button(action: openSettings) {
                        emptyMessage(issue)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens Dayboard settings")
                } else if !model.pendingCheckIns.isEmpty {
                    let count = model.pendingCheckIns.count
                    if model.connected {
                        emptyMessage(model.busy ? "Syncing \(count) check-in\(count == 1 ? "" : "s")…" :
                                        "\(count) check-in\(count == 1 ? "" : "s") waiting to sync.")
                    } else {
                        Button(action: openSettings) {
                            emptyMessage("\(count) queued · Connect Notion to sync")
                        }.buttonStyle(.plain)
                    }
                } else if !items.isEmpty && model.habitCheckIns == nil && model.connected {
                    emptyMessage("Today’s check-ins haven’t synced.")
                }
            }
        }
    }

    private func habitRow(_ habit: GoodHabit, checked: Bool, pending: Bool) -> some View {
        let title = habit.title.isEmpty ? "Untitled habit" : habit.title
        return Button {
            model.checkIn(habit)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(checked ? "✓" : pending ? "…" : "○")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(tone.muted)
                    .frame(width: 14, alignment: .leading)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.system(size: 15))
                    .strikethrough(checked)
                    .foregroundStyle(checked ? tone.muted : tone.ink)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(checked || pending)
        .accessibilityLabel("Check in for \(title)")
        .accessibilityValue(checked ? "Checked in" : pending ? "Waiting to sync" : "Ready")
        .help(checked ? "Checked in today" : pending ? "Waiting to sync" : "Check in for \(title)")
    }

    private func heading<Detail: View>(_ title: String, subtitle: String, @ViewBuilder detail: () -> Detail) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                SectionLabel(title: title)
                Spacer()
                detail().font(.system(size: 11, weight: .medium, design: .monospaced))
            }
            .foregroundStyle(tone.muted)
            Rectangle().fill(tone.rule).frame(height: 1)
            Text(subtitle)
                .font(.system(size: 32, weight: .light))
                .tracking(-1)
        }
    }

    private func fittingList<Rows: View>(@ViewBuilder rows: () -> Rows) -> some View {
        let list = VStack(alignment: .leading, spacing: 2, content: rows)
        return ViewThatFits(in: .vertical) {
            list.fixedSize(horizontal: false, vertical: true)
            ScrollView { list }
        }
    }

    private func emptyMessage(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 13))
            .foregroundStyle(tone.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 3)
    }

    private func scheduledTime(for task: NotionTask) -> String? {
        guard let date = notionTimestamp(task.start), model.calendar.isDate(date, inSameDayAs: model.selected) else { return nil }
        return clock(date)
    }

    private func clock(_ date: Date) -> String {
        date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(british))
    }

    private func textRow(_ title: String, placeholder: String, url: URL, checked: Bool?,
                         taskTime: String? = nil, important: Bool = false) -> some View {
        Link(destination: url) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(checked == true ? "✓" : taskTime ?? (checked == false ? "·" : "–"))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(tone.muted)
                    .frame(minWidth: taskTime == nil ? 12 : 36, alignment: .leading)
                    .accessibilityHidden(true)
                Text(title.isEmpty ? placeholder : title)
                    .font(.system(size: 15, weight: important ? .medium : .regular))
                    .strikethrough(checked == true)
                    .foregroundStyle(checked == true ? tone.muted : tone.ink)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(checked == true ? "Completed" : checked == false ? "Open" : "Status unavailable")
        .help("Open in Notion")
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Rectangle().fill(tone.rule).frame(height: 1)
            HStack(spacing: 10) {
                Button {
                    Task { await model.useJournal(openSettings: openSettings) }
                } label: {
                    Label(model.journalAction, systemImage: "book.closed")
                }
                .buttonStyle(.plain)
                .disabled(model.journalBusy)
                .help(model.journalProblem ?? "Today’s Daily Journal")
                Spacer(minLength: 3)
                if model.busy {
                    ProgressView().controlSize(.small)
                    Text("Syncing")
                } else if let issue = model.problem ?? model.habitProblem {
                    Button("Sync issue", action: openSettings).buttonStyle(.plain).help(issue)
                } else if model.connected, let synced = model.snapshot?.fetchedAt {
                    Text("Synced " + synced.formatted(date: .omitted, time: .shortened))
                } else {
                    Button("Enable live sync", action: openSettings).buttonStyle(.plain)
                }
                if let url = model.notionConfiguration?.tasksURL {
                    Link(destination: url) { Label("Notion", systemImage: "arrow.up.right") }
                        .buttonStyle(.plain)
                }
                if model.connected {
                    GlyphButton(symbol: "arrow.clockwise", label: "Refresh Notion data") { Task { await model.refresh() } }
                        .disabled(model.busy)
                }
                GlyphButton(symbol: "gearshape", label: "Dayboard settings", action: openSettings)
            }
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(tone.muted)
        }
    }
}
