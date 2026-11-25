import AppKit
import SwiftUI

@MainActor
final class SessionTimer: ObservableObject {
    enum Phase: String, CaseIterable {
        case focus = "Focus"
        case rest = "Break"
        case meditation = "Meditation"

        var next: Self {
            switch self {
            case .focus: .rest
            case .rest: .focus
            case .meditation: .meditation
            }
        }

        var durationKey: String {
            switch self {
            case .focus: "pomodoroFocusMinutes"
            case .rest: "pomodoroBreakMinutes"
            case .meditation: "meditationMinutes"
            }
        }

        var defaultMinutes: Int {
            switch self {
            case .focus: 25
            case .rest: 5
            case .meditation: 10
            }
        }

        var completionLabel: String { "\(rawValue) complete" }
    }

    static let minuteRange = 1...180

    @Published private(set) var phase: Phase
    @Published private(set) var seconds = 25 * 60
    @Published private(set) var running = false
    @Published private(set) var started = false
    @Published private(set) var completedPhase: Phase?
    @Published private var durations: [Phase: Int]
    private(set) var sessionSeconds = 25 * 60

    private let preferences: UserDefaults
    private let completion: () -> Void
    private var deadline: Date?
    private var timeLeft: TimeInterval = 25 * 60
    private var ticker: Timer?

    init(phase: Phase = .focus, preferences: UserDefaults = .standard,
         completion: @escaping () -> Void = { NSSound.beep() }) {
        self.phase = phase
        self.preferences = preferences
        self.completion = completion
        durations = Dictionary(uniqueKeysWithValues: Phase.allCases.map { phase in
            let saved = preferences.object(forKey: phase.durationKey) as? Int
            return (phase, Self.clamp(saved ?? phase.defaultMinutes))
        })
        reset()
    }

    var isMeditation: Bool { phase == .meditation }
    var title: String { isMeditation ? "Meditation" : "Pomodoro" }
    var symbol: String { isMeditation ? "leaf" : "timer" }
    var timeLabel: String { String(format: "%02d:%02d", seconds / 60, seconds % 60) }

    func minutes(for phase: Phase) -> Int {
        durations[phase] ?? phase.defaultMinutes
    }

    func setMinutes(_ minutes: Int, for phase: Phase) {
        let clamped = Self.clamp(minutes)
        durations[phase] = clamped
        preferences.set(clamped, forKey: phase.durationKey)
        if !started && phase == self.phase { reset() }
    }

    func select(_ phase: Phase) {
        guard !started, !isMeditation, phase != .meditation, phase != self.phase else { return }
        self.phase = phase
        reset()
    }

    func start(now: Date = .now) {
        guard !running else { return }
        deadline = now.addingTimeInterval(timeLeft)
        completedPhase = nil
        started = true
        running = true
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else {
                    timer.invalidate()
                    return
                }
                self.update()
            }
        }
        ticker = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func pause(now: Date = .now) {
        guard running else { return }
        update(now: now)
        stop()
    }

    func reset() {
        stop()
        started = false
        completedPhase = nil
        sessionSeconds = minutes(for: phase) * 60
        seconds = sessionSeconds
        timeLeft = TimeInterval(seconds)
    }

    func update(now: Date = .now) {
        guard let deadline else { return }
        timeLeft = max(0, deadline.timeIntervalSince(now))
        let remaining = Int(ceil(timeLeft))
        if seconds != remaining { seconds = remaining }
        if remaining == 0 {
            let finished = phase
            phase = phase.next
            reset()
            completedPhase = finished
            completion()
        }
    }

    private func stop() {
        ticker?.invalidate()
        ticker = nil
        deadline = nil
        running = false
    }

    private static func clamp(_ minutes: Int) -> Int {
        min(Self.minuteRange.upperBound, max(Self.minuteRange.lowerBound, minutes))
    }
}

struct SessionTimerPanel: View {
    @ObservedObject var timer: SessionTimer
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let dismiss: () -> Void

    var body: some View {
        if #available(macOS 26, *) {
            content
        } else {
            content
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28))
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text(timer.title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                    .frame(maxWidth: .infinity, minHeight: 25, alignment: .leading)
                    .overlay {
                        PanelDragRegion()
                            .accessibilityHidden(true)
                    }
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .modifier(SessionTimerGlassChrome(height: 25))
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Close \(timer.title)")
            }
            if !timer.isMeditation {
                Picker("Session type", selection: Binding(get: { timer.phase }, set: { timer.select($0) })) {
                    ForEach([SessionTimer.Phase.focus, .rest], id: \.self) { phase in
                        Text(phase.rawValue).tag(phase)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(timer.started)
            }

            VStack(spacing: 4) {
                Text(timer.timeLabel)
                    .font(.system(size: 64, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .contentTransition(.numericText(countsDown: true))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: timer.seconds)
                    .accessibilityLabel("\(timer.seconds / 60) minutes, \(timer.seconds % 60) seconds")
                if let phase = timer.completedPhase {
                    Text(phase.completionLabel)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: Double(timer.seconds), total: Double(timer.sessionSeconds))
                    .labelsHidden()
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity)
            controls
                .frame(maxWidth: .infinity)
            Divider()
            if timer.isMeditation {
                duration("Duration in minutes", phase: .meditation)
                    .disabled(timer.started)
            } else {
                duration("Focus minutes", phase: .focus)
                duration("Break minutes", phase: .rest)
            }
            if timer.started && !timer.isMeditation {
                Text("New lengths apply on reset or next session.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private var controls: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: 8) {
                transportButtons
            }
        } else {
            transportButtons
        }
    }

    private var transportButtons: some View {
        HStack(spacing: 10) {
            transport.modifier(SessionTimerGlassChrome(tint: (timer.isMeditation ? Color.green : .blue).opacity(0.40), height: 34))
            reset.modifier(SessionTimerGlassChrome(height: 34))
        }
    }

    private var transport: some View {
        Button {
            if timer.running { timer.pause() } else { timer.start() }
        } label: {
            Label(timer.running ? "Pause" : timer.started ? "Resume" : "Start",
                  systemImage: timer.running ? "pause.fill" : "play.fill")
                .frame(minWidth: 92)
                .foregroundStyle(.white)
        }
    }

    private var reset: some View {
        Button { timer.reset() } label: {
            Label("Reset", systemImage: "arrow.counterclockwise")
                .foregroundStyle(.white)
        }
        .help("Reset to the chosen duration")
    }

    private func duration(_ label: String, phase: SessionTimer.Phase) -> some View {
        let value = Binding(get: { timer.minutes(for: phase) },
                            set: { timer.setMinutes($0, for: phase) })
        return HStack {
            Text(label).font(.system(size: 12))
            Spacer()
            TextField(label, value: value, format: .number.grouping(.never))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .font(.system(size: 12, design: .monospaced))
                .frame(width: 45)
            Stepper(label, value: value, in: SessionTimer.minuteRange)
                .labelsHidden()
        }
    }
}

struct SessionTimerButton: View {
    @ObservedObject var timer: SessionTimer
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if timer.isMeditation && !timer.started {
                Image(systemName: timer.symbol)
            } else {
                Label(timer.started ? timer.timeLabel : timer.title, systemImage: timer.symbol)
                    .monospacedDigit()
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open \(timer.title) timer")
        .accessibilityValue(timer.started ? timer.timeLabel : "")
        .help(timer.started ? "\(timer.phase.rawValue) · \(timer.timeLabel)" : "Open \(timer.title) timer")
    }
}

struct PanelDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {}

    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }

        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}

private struct SessionTimerGlassChrome: ViewModifier {
    var tint: Color? = nil
    var height: CGFloat

    func body(content: Content) -> some View {
        let capsule = Capsule()
        let control = content
            .controlSize(height > 25 ? .large : .small)
            .frame(minHeight: height)
            .background(tint ?? .white.opacity(0.10), in: capsule)
            .overlay {
                capsule.strokeBorder(.white.opacity(0.24), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        if #available(macOS 26, *) {
            control.buttonStyle(.glass)
        } else {
            control.buttonStyle(.bordered)
        }
    }
}
