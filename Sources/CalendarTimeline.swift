import AppKit
import SwiftUI

private let timelineLocale = Locale(identifier: "en_GB")

struct TimelineBlock: Identifiable {
    let event: ScheduleEvent
    let offset: TimeInterval
    let length: TimeInterval
    let lane: Int
    let laneCount: Int
    var id: String { event.id }

    static func layout(_ events: [ScheduleEvent], in day: DateInterval) -> [Self] {
        let timed = events.compactMap { event -> (event: ScheduleEvent, start: Date, end: Date)? in
            guard !event.allDay, let start = event.startTime, let end = event.endTime,
                  start < day.end, (end > day.start || start == end && start >= day.start) else { return nil }
            let first = max(day.start, start)
            let last = min(day.end, max(first.addingTimeInterval(1_560), end))
            return (event, first, last)
        }.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.end > $1.end
        }

        var blocks: [Self] = []
        var group: [(event: ScheduleEvent, start: Date, end: Date, lane: Int)] = []
        var laneEnds: [Date] = []
        var groupEnd = day.start

        func finishGroup() {
            blocks += group.map {
                Self(event: $0.event, offset: $0.start.timeIntervalSince(day.start),
                     length: $0.end.timeIntervalSince($0.start), lane: $0.lane, laneCount: laneEnds.count)
            }
            group.removeAll()
            laneEnds.removeAll()
        }

        for slot in timed {
            if slot.start >= groupEnd { finishGroup() }
            let lane = laneEnds.firstIndex(where: { $0 <= slot.start }) ?? laneEnds.count
            if lane == laneEnds.count {
                laneEnds.append(slot.end)
            } else {
                laneEnds[lane] = slot.end
            }
            group.append((slot.event, slot.start, slot.end, lane))
            groupEnd = max(groupEnd, slot.end)
        }
        finishGroup()
        return blocks
    }
}

@MainActor
final class TimelineDragState: ObservableObject {
    enum Mode { case move, resizeTop, resizeBottom }

    struct Active {
        let event: ScheduleEvent
        let original: CalendarEventFields
        let mode: Mode
        let isFirstColumn: Bool
        var minuteDelta: Int = 0
        var dayDelta: Int = 0
        var translationX: CGFloat = 0
    }

    @Published var active: Active?
    @Published var savingEventID: String?
    @Published var problem: String?
    @Published var offerMacCalendarConnect = false

    func showReadOnlyHint(isGoogleSnapshot: Bool) {
        offerMacCalendarConnect = isGoogleSnapshot
        problem = isGoogleSnapshot
            ? "Connect Google in Mac Calendar to move and sync these time blocks."
            : "This calendar is read-only in Dayboard."
    }

    func dismissProblem() {
        problem = nil
        offerMacCalendarConnect = false
    }

    func begin(event: ScheduleEvent, original: CalendarEventFields, mode: Mode, isFirstColumn: Bool) {
        guard active == nil, savingEventID == nil else { return }
        dismissProblem()
        active = Active(event: event, original: original, mode: mode, isFirstColumn: isFirstColumn)
    }

    func update(translation: CGSize, hourHeight: CGFloat, calendar: Calendar) {
        guard var current = active else { return }
        let rawMinutes = Double(translation.height / hourHeight) * 60.0
        var snapped = Int((rawMinutes / 15.0).rounded()) * 15
        let newDayDelta: Int
        let baseDay = calendar.startOfDay(for: current.original.start)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: baseDay) ?? current.original.end

        switch current.mode {
        case .move:
            if current.isFirstColumn && translation.width > 120 {
                newDayDelta = 1
            } else if !current.isFirstColumn && translation.width < -120 {
                newDayDelta = -1
            } else {
                newDayDelta = 0
            }
            let startOffset = current.original.start.timeIntervalSince(baseDay)
            let duration = max(900, current.original.end.timeIntervalSince(current.original.start))
            let maxStart = max(0, 86_400 - duration)
            let proposed = startOffset + Double(snapped) * 60.0
            let clamped = min(maxStart, max(0, proposed))
            snapped = Int(((clamped - startOffset) / 60.0 / 15.0).rounded()) * 15
        case .resizeTop:
            newDayDelta = 0
            let minDelta = Int(((baseDay.timeIntervalSince(current.original.start)) / 60.0 / 15.0).rounded(.up)) * 15
            let maxStart = current.original.end.addingTimeInterval(-900)
            let maxDelta = Int(((maxStart.timeIntervalSince(current.original.start)) / 60.0 / 15.0).rounded(.down)) * 15
            snapped = min(max(minDelta, maxDelta), max(minDelta, snapped))
        case .resizeBottom:
            newDayDelta = 0
            let duration = current.original.end.timeIntervalSince(current.original.start)
            let minDelta = Int(((900.0 - duration) / 60.0 / 15.0).rounded(.up)) * 15
            let maxDelta = Int(((dayEnd.timeIntervalSince(current.original.end)) / 60.0 / 15.0).rounded(.down)) * 15
            snapped = min(max(minDelta, maxDelta), max(minDelta, snapped))
        }

        if snapped != current.minuteDelta || newDayDelta != current.dayDelta {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        current.minuteDelta = snapped
        current.dayDelta = newDayDelta
        current.translationX = current.mode == .move ? translation.width : 0
        active = current
    }

    func previewFields(for current: Active, calendar: Calendar) -> CalendarEventFields {
        switch current.mode {
        case .move:
            let dayShiftedStart = calendar.date(byAdding: .day, value: current.dayDelta, to: current.original.start)
                ?? current.original.start
            let dayShiftedEnd = calendar.date(byAdding: .day, value: current.dayDelta, to: current.original.end)
                ?? current.original.end
            let newStart = dayShiftedStart.addingTimeInterval(Double(current.minuteDelta) * 60.0)
            let newEnd = dayShiftedEnd.addingTimeInterval(Double(current.minuteDelta) * 60.0)
            return CalendarEventFields(title: current.original.title, allDay: false, start: newStart, end: newEnd)
        case .resizeTop:
            let newStart = min(current.original.end.addingTimeInterval(-900),
                               current.original.start.addingTimeInterval(Double(current.minuteDelta) * 60.0))
            return CalendarEventFields(title: current.original.title, allDay: false,
                                       start: newStart, end: current.original.end)
        case .resizeBottom:
            let newEnd = max(current.original.start.addingTimeInterval(900),
                             current.original.end.addingTimeInterval(Double(current.minuteDelta) * 60.0))
            return CalendarEventFields(title: current.original.title, allDay: false,
                                       start: current.original.start, end: newEnd)
        }
    }

    func finish(calendar: Calendar, commit: @escaping (ScheduleEvent, CalendarEventFields, CalendarEventFields) async throws -> Void) {
        guard let current = active else { return }
        let updated = previewFields(for: current, calendar: calendar)
        active = nil
        guard updated != current.original else { return }
        savingEventID = current.event.id
        dismissProblem()
        Task { @MainActor in
            defer { self.savingEventID = nil }
            do {
                try await commit(current.event, current.original, updated)
            } catch {
                self.problem = error.localizedDescription
            }
        }
    }
}

struct CalendarTimeline: View {
    @ObservedObject var model: BoardModel
    @ObservedObject var schedule: ScheduleModel
    @ObservedObject var drag: TimelineDragState
    let dismiss: () -> Void
    let editEvent: (ScheduleEvent, Date) -> Void
    let addEvent: (Date, Date?) -> Void
    let rescheduleEvent: (ScheduleEvent, CalendarEventFields, CalendarEventFields) async throws -> Void

    var body: some View {
        let calendar = model.calendar
        let nextDay = calendar.date(byAdding: .day, value: 1, to: model.selected) ?? model.selected

        VStack(alignment: .leading, spacing: 15) {
            HStack {
                ZStack(alignment: .leading) {
                    PanelDragRegion()
                        .frame(maxWidth: .infinity, minHeight: 24, maxHeight: 24)
                    Label("Schedule", systemImage: "calendar")
                        .font(.system(size: 12, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                        .allowsHitTesting(false)
                }
                .frame(maxWidth: .infinity, minHeight: 24, maxHeight: 24, alignment: .leading)
                toolbarButton("chevron.left", label: "Previous day") { shift(-1) }
                toolbarButton("chevron.right", label: "Next day") { shift(1) }
                toolbarButton("xmark", label: "Close schedule", action: dismiss)
                    .keyboardShortcut(.cancelAction)
            }
            .frame(height: 24)
            .foregroundStyle(.white.opacity(0.80))

            if let problem = drag.problem {
                HStack(spacing: 8) {
                    Text(problem)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    if drag.offerMacCalendarConnect {
                        Button("Connect") {
                            Task { await schedule.connect(addAccount: true) }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                    Button { drag.dismissProblem() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
            }

            HStack(alignment: .top, spacing: 17) {
                column(day: model.selected, isFirst: true)
                    .id(model.selected)
                Rectangle().fill(.white.opacity(0.14)).frame(width: 1)
                column(day: nextDay, isFirst: false)
                    .id(nextDay)
            }
            .coordinateSpace(name: "timelineBoard")
        }
        .padding(19)
        .background {
            ZStack {
                TimelineGlass()
                Color(white: 0.04).opacity(0.62)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 27, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 27, style: .continuous)
                .strokeBorder(.white.opacity(0.22), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .environment(\.colorScheme, .dark)
    }

    private func isEditable(_ event: ScheduleEvent) -> Bool {
        (event.provider == "notion" && model.connected) || event.nativeIdentifier != nil
    }

    private func column(day: Date, isFirst: Bool) -> some View {
        let items = schedule.events(on: day)
        let allDay = items.filter(\.allDay)

        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(dayLabel(day, isFirst: isFirst))
                        .font(.system(size: 11, weight: .bold))
                        .tracking(0.85)
                        .textCase(.uppercase)
                        .foregroundStyle(.white.opacity(isFirst ? 0.90 : 0.64))
                    Text(day.formatted(.dateTime.day().locale(timelineLocale)))
                        .font(.system(size: 43, weight: .light))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.93))
                }
                Spacer(minLength: 2)
                Text(day.formatted(.dateTime.month(.abbreviated).locale(timelineLocale)))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.65))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(day.formatted(date: .complete, time: .omitted))
            .accessibilityAddTraits(.isHeader)

            if !allDay.isEmpty {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(allDay) { event in
                            eventCard(event, for: day, detail: "All day", showDetail: false)
                                .frame(height: 25)
                        }
                    }
                }
                .frame(height: min(82, CGFloat(allDay.count) * 29 - 4))
            }

            if !schedule.hasCoverage(on: day) && items.isEmpty {
                Text("Calendar data unavailable")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.65))
            }
            hourlyGrid(day: day, events: items, isFirst: isFirst)
        }
        .frame(maxWidth: .infinity)
    }

    private func hourlyGrid(day: Date, events: [ScheduleEvent], isFirst: Bool) -> some View {
        let range = model.calendar.dateInterval(of: .day, for: day) ?? DateInterval(start: day, duration: 86_400)
        let hours = Int(ceil(range.duration / 3_600))
        let height: CGFloat = 52
        let labelWidth: CGFloat = 28
        let blocks = TimelineBlock.layout(events, in: range)

        return ScrollViewReader { scroll in
            ScrollView {
                ZStack(alignment: .topLeading) {
                    VStack(spacing: 0) {
                        ForEach(0...hours, id: \.self) { hour in
                            let slotStart = range.start.addingTimeInterval(Double(hour) * 3_600)
                            HStack(spacing: 0) {
                                Text(slotStart
                                    .formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).locale(timelineLocale)))
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.60))
                                    .frame(width: labelWidth, alignment: .leading)
                                Rectangle().fill(.white.opacity(0.14)).frame(height: 1)
                            }
                            .frame(height: hour == hours ? 16 : height, alignment: .top)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) {
                                if hour < hours { addEvent(day, slotStart) }
                            }
                            .id(hour)
                            .accessibilityHidden(true)
                        }
                    }

                    GeometryReader { geometry in
                        ForEach(blocks) { block in
                            let width = max(1, (geometry.size.width - labelWidth) / CGFloat(block.laneCount))
                            let editable = isEditable(block.event)
                            let active = drag.active?.event.id == block.event.id ? drag.active : nil
                            let preview = active.map { drag.previewFields(for: $0, calendar: model.calendar) }
                            let yDelta: CGFloat = {
                                guard let active else { return 0 }
                                switch active.mode {
                                case .move, .resizeTop: return CGFloat(active.minuteDelta) / 60.0 * height
                                case .resizeBottom: return 0
                                }
                            }()
                            let hDelta: CGFloat = {
                                guard let active else { return 0 }
                                switch active.mode {
                                case .move: return 0
                                case .resizeTop: return -CGFloat(active.minuteDelta) / 60.0 * height
                                case .resizeBottom: return CGFloat(active.minuteDelta) / 60.0 * height
                                }
                            }()
                            let xDelta: CGFloat = active?.mode == .move ? max(-24, min(24, active!.translationX * 0.14)) : 0
                            let baseDuration = CGFloat(block.length / 3_600) * height
                            let duration = max(13, baseDuration + hDelta)
                            let detailText: String = {
                                if let preview, let active {
                                    let base = timeLabel(start: preview.start, end: preview.end)
                                    if active.dayDelta != 0 {
                                        let targetDay = preview.start.formatted(.dateTime.weekday(.abbreviated).locale(timelineLocale))
                                        return "\(targetDay) · \(base)"
                                    }
                                    return base
                                }
                                return timeLabel(block.event)
                            }()
                            timedEventCard(block.event, for: day, detail: detailText,
                                           showDetail: duration > 39 && width > 85 || active != nil,
                                           showLocation: active == nil && duration > 60 && width > 110,
                                           editable: editable, isDragging: active != nil,
                                           isSaving: drag.savingEventID == block.event.id,
                                           isFirstColumn: isFirst, hourHeight: height)
                                .frame(width: max(1, width - 3), height: max(1, duration - 2), alignment: .top)
                                .offset(x: labelWidth + CGFloat(block.lane) * width + xDelta,
                                        y: max(1, CGFloat(block.offset / 3_600) * height + 1 + yDelta))
                                .zIndex(active != nil ? 10 : 0)
                        }
                    }

                    if model.calendar.isDate(day, inSameDayAs: model.today) {
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            if range.contains(context.date) {
                                HStack(spacing: 0) {
                                    Circle().fill(.white).frame(width: 6, height: 6)
                                    Rectangle().fill(.white).frame(height: 1)
                                }
                                .padding(.leading, labelWidth - 4)
                                .offset(y: CGFloat(context.date.timeIntervalSince(range.start) / 3_600) * height)
                            }
                        }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    }
                }
                .frame(height: CGFloat(hours) * height + 16)
            }
            .scrollIndicators(.hidden)
            .onAppear {
                if model.calendar.isDate(day, inSameDayAs: model.today) {
                    let hour = Int(Date().timeIntervalSince(range.start) / 3_600)
                    // Leave recent hours visible and allow the user to scroll back or forward.
                    scroll.scrollTo(max(0, min(hours - 1, hour - 2)), anchor: .top)
                }
            }
        }
    }

    private func timedEventCard(_ event: ScheduleEvent, for day: Date, detail: String, showDetail: Bool,
                                showLocation: Bool, editable: Bool, isDragging: Bool, isSaving: Bool,
                                isFirstColumn: Bool, hourHeight: CGFloat) -> some View {
        let cardBody = ZStack {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(.white.opacity(isDragging ? 1.0 : 0.90))
                    .frame(width: 3)
                    .padding(.vertical, 4)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(event.title)
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                        if isSaving {
                            ProgressView().controlSize(.mini)
                        }
                    }
                    if showDetail {
                        Text(detail)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(isDragging ? 0.95 : 0.74))
                            .lineLimit(1)
                    }
                    if showLocation, let location = event.location, !location.isEmpty {
                        Text(location)
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.66))
                            .lineLimit(1)
                    }
                }
                .padding(.vertical, 2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 5)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.white.opacity(isDragging ? 0.28 : 0.15), in: RoundedRectangle(cornerRadius: 5))
            .overlay {
                if isDragging {
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(.white.opacity(0.75), lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
            .shadow(color: .black.opacity(isDragging ? 0.45 : 0), radius: isDragging ? 8 : 0, y: isDragging ? 3 : 0)

            if editable {
                VStack(spacing: 0) {
                    Color.clear
                        .frame(height: 7)
                        .contentShape(Rectangle())
                        .highPriorityGesture(
                            DragGesture(minimumDistance: 2, coordinateSpace: .named("timelineBoard"))
                                .onChanged { value in
                                    if drag.active == nil, let original = CalendarEventFields(event: event, calendar: model.calendar) {
                                        drag.begin(event: event, original: original, mode: .resizeTop, isFirstColumn: isFirstColumn)
                                    }
                                    drag.update(translation: value.translation, hourHeight: hourHeight, calendar: model.calendar)
                                }
                                .onEnded { _ in
                                    drag.finish(calendar: model.calendar, commit: rescheduleEvent)
                                }
                        )
                    Spacer(minLength: 0)
                    Color.clear
                        .frame(height: 7)
                        .contentShape(Rectangle())
                        .highPriorityGesture(
                            DragGesture(minimumDistance: 2, coordinateSpace: .named("timelineBoard"))
                                .onChanged { value in
                                    if drag.active == nil, let original = CalendarEventFields(event: event, calendar: model.calendar) {
                                        drag.begin(event: event, original: original, mode: .resizeBottom, isFirstColumn: isFirstColumn)
                                    }
                                    drag.update(translation: value.translation, hourHeight: hourHeight, calendar: model.calendar)
                                }
                                .onEnded { _ in
                                    drag.finish(calendar: model.calendar, commit: rescheduleEvent)
                                }
                        )
                }
            }
        }
        .contentShape(Rectangle())
        .clipped()
        .accessibilityLabel(event.title)
        .accessibilityValue(detail)
        .help(editable
              ? "\([event.title, detail, event.location].compactMap { $0 }.joined(separator: " · ")) — Drag to move, drag top or bottom edge to resize, click to edit"
              : [event.title, detail, event.location].compactMap { $0 }.joined(separator: " · "))

        return cardBody
            .onTapGesture {
                editEvent(event, day)
            }
            .gesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .named("timelineBoard"))
                    .onChanged { value in
                        guard editable else {
                            if drag.problem == nil {
                                drag.showReadOnlyHint(isGoogleSnapshot: event.provider == "google")
                            }
                            return
                        }
                        if drag.active == nil, let original = CalendarEventFields(event: event, calendar: model.calendar) {
                            drag.begin(event: event, original: original, mode: .move, isFirstColumn: isFirstColumn)
                        }
                        drag.update(translation: value.translation, hourHeight: hourHeight, calendar: model.calendar)
                    }
                    .onEnded { _ in
                        guard editable else { return }
                        drag.finish(calendar: model.calendar, commit: rescheduleEvent)
                    }
            )
    }

    private func eventCard(_ event: ScheduleEvent, for day: Date, detail: String, showDetail: Bool,
                           showLocation: Bool = false) -> some View {
        Button {
            editEvent(event, day)
        } label: {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(.white.opacity(0.90))
                    .frame(width: 3)
                    .padding(.vertical, 4)
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                    if showDetail {
                        Text(detail)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.74))
                            .lineLimit(1)
                    }
                    if showLocation, let location = event.location, !location.isEmpty {
                        Text(location)
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.66))
                            .lineLimit(1)
                    }
                }
                .padding(.vertical, 2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 5)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clipped()
        .accessibilityLabel(event.title)
        .accessibilityValue(detail)
        .help([event.title, detail, event.location].compactMap { $0 }.joined(separator: " · "))
    }

    private func timeLabel(start: Date, end: Date) -> String {
        let format = Date.FormatStyle.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(timelineLocale)
        return "\(start.formatted(format))–\(end.formatted(format))"
    }

    private func timeLabel(_ event: ScheduleEvent) -> String {
        guard let start = event.startTime, let end = event.endTime else { return "Scheduled event" }
        return timeLabel(start: start, end: end)
    }

    private func dayLabel(_ date: Date, isFirst: Bool) -> String {
        if !isFirst, let tomorrow = model.calendar.date(byAdding: .day, value: 1, to: model.today), date == tomorrow {
            return "Tomorrow"
        }
        return date.formatted(.dateTime.weekday(.wide).locale(timelineLocale))
    }

    private func shift(_ days: Int) {
        guard let date = model.calendar.date(byAdding: .day, value: days, to: model.selected) else { return }
        model.selected = date
        model.month = model.monthStart(date)
        schedule.showMonth(model.month)
    }

    private func toolbarButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 29, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }
}

private struct TimelineGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.appearance = NSAppearance(named: .darkAqua)
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
