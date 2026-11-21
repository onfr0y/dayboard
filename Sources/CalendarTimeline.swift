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

struct CalendarTimeline: View {
    @ObservedObject var model: BoardModel
    @ObservedObject var schedule: ScheduleModel
    let dismiss: () -> Void

    var body: some View {
        let calendar = model.calendar
        let nextDay = calendar.date(byAdding: .day, value: 1, to: model.selected) ?? model.selected

        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Label("Schedule", systemImage: "calendar")
                    .font(.system(size: 12, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                toolbarButton("chevron.left", label: "Previous day") { shift(-1) }
                toolbarButton("chevron.right", label: "Next day") { shift(1) }
                toolbarButton("xmark", label: "Close schedule", action: dismiss)
                    .keyboardShortcut(.cancelAction)
            }
            .foregroundStyle(.white.opacity(0.80))

            HStack(alignment: .top, spacing: 17) {
                column(day: model.selected, isFirst: true)
                    .id(model.selected)
                Rectangle().fill(.white.opacity(0.14)).frame(width: 1)
                column(day: nextDay, isFirst: false)
                    .id(nextDay)
            }
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
            hourlyGrid(day: day, events: items)
        }
        .frame(maxWidth: .infinity)
    }

    private func hourlyGrid(day: Date, events: [ScheduleEvent]) -> some View {
        let range = model.calendar.dateInterval(of: .day, for: day) ?? DateInterval(start: day, duration: 86_400)
        let hours = Int(ceil(range.duration / 3_600))
        let height: CGFloat = 52
        let labelWidth: CGFloat = 28
        let blocks = TimelineBlock.layout(events, in: range)

        return ScrollViewReader { scroll in
            ScrollView {
                ZStack(alignment: .topLeading) {
                    VStack(spacing: 0) {
                        ForEach(0..<hours, id: \.self) { hour in
                            HStack(spacing: 0) {
                                Text(range.start.addingTimeInterval(Double(hour) * 3_600)
                                    .formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).locale(timelineLocale)))
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.60))
                                    .frame(width: labelWidth, alignment: .leading)
                                Rectangle().fill(.white.opacity(0.14)).frame(height: 1)
                            }
                            .frame(height: height, alignment: .top)
                            .id(hour)
                            .accessibilityHidden(true)
                        }
                    }

                    GeometryReader { geometry in
                        ForEach(blocks) { block in
                            let width = max(1, (geometry.size.width - labelWidth) / CGFloat(block.laneCount))
                            let duration = CGFloat(block.length / 3_600) * height
                            eventCard(block.event, for: day, detail: timeLabel(block.event),
                                      showDetail: duration > 39 && width > 85)
                                .frame(width: max(1, width - 3), height: max(1, duration - 2), alignment: .top)
                                .offset(x: labelWidth + CGFloat(block.lane) * width,
                                        y: CGFloat(block.offset / 3_600) * height + 1)
                        }
                    }

                    if model.calendar.isDate(day, inSameDayAs: model.today) {
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            if range.contains(context.date) {
                                HStack(spacing: 0) {
                                    Circle().fill(.white).frame(width: 6, height: 6)
                                    Rectangle().fill(.white).frame(height: 1)
                                }
                                .offset(x: labelWidth - 4, y: CGFloat(context.date.timeIntervalSince(range.start) / 3_600) * height)
                            }
                        }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    }
                }
                .frame(height: CGFloat(hours) * height)
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

    private func eventCard(_ event: ScheduleEvent, for day: Date, detail: String, showDetail: Bool) -> some View {
        Button {
            event.open(on: day)
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
        .help("\(event.title) · \(detail)")
    }

    private func timeLabel(_ event: ScheduleEvent) -> String {
        guard let start = event.startTime, let end = event.endTime else { return "Scheduled event" }
        let format = Date.FormatStyle.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(timelineLocale)
        return "\(start.formatted(format))–\(end.formatted(format))"
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
