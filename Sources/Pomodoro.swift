import AppKit
import SwiftUI

@MainActor
final class PomodoroTimer: ObservableObject {
    enum Phase: String, CaseIterable {
        case focus = "Focus"
        case rest = "Break"

        var next: Self { self == .focus ? .rest : .focus }
    }

    static let minuteRange = 1...180

    @Published private(set) var phase: Phase = .focus
    @Published private(set) var seconds = 25 * 60
    @Published private(set) var running = false
    @Published private(set) var started = false
    @Published private(set) var completedPhase: Phase?
    @Published private(set) var focusMinutes = 25
    @Published private(set) var breakMinutes = 5

    private let preferences: UserDefaults
    private let completion: () -> Void
    private var deadline: Date?
    private var timeLeft: TimeInterval = 25 * 60
    private var ticker: Timer?

    init(preferences: UserDefaults = .standard, completion: @escaping () -> Void = { NSSound.beep() }) {
        self.preferences = preferences
        self.completion = completion
        focusMinutes = preferences.object(forKey: "pomodoroFocusMinutes") as? Int ?? 25
        breakMinutes = preferences.object(forKey: "pomodoroBreakMinutes") as? Int ?? 5
        focusMinutes = clamp(focusMinutes)
        breakMinutes = clamp(breakMinutes)
        reset()
    }

    var timeLabel: String { String(format: "%02d:%02d", seconds / 60, seconds % 60) }

    func setMinutes(_ minutes: Int, for phase: Phase) {
        let clamped = clamp(minutes)
        switch phase {
        case .focus:
            focusMinutes = clamped
            preferences.set(clamped, forKey: "pomodoroFocusMinutes")
        case .rest:
            breakMinutes = clamped
            preferences.set(clamped, forKey: "pomodoroBreakMinutes")
        }
        if !started && phase == self.phase { reset() }
    }

    func select(_ phase: Phase) {
        guard !started, phase != self.phase else { return }
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
        seconds = (phase == .focus ? focusMinutes : breakMinutes) * 60
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

    private func clamp(_ minutes: Int) -> Int {
        min(Self.minuteRange.upperBound, max(Self.minuteRange.lowerBound, minutes))
    }
}

struct PomodoroPanel: View {
    @ObservedObject var timer: PomodoroTimer
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Label("Pomodoro", systemImage: "timer")
                    .font(.system(size: 13, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .padding(5)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Close Pomodoro")
            }
            HStack(spacing: 6) {
                ForEach(PomodoroTimer.Phase.allCases, id: \.self) { phase in
                    Button(phase.rawValue) { timer.select(phase) }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(.white.opacity(timer.phase == phase ? 0.18 : 0.06), in: Capsule())
                        .accessibilityAddTraits(timer.phase == phase ? .isSelected : [])
                        .disabled(timer.started)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(timer.timeLabel)
                    .font(.system(size: 62, weight: .light))
                    .monospacedDigit()
                    .accessibilityLabel("\(timer.seconds / 60) minutes, \(timer.seconds % 60) seconds")
                if let phase = timer.completedPhase {
                    Text(phase == .focus ? "Focus complete" : "Break complete")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Button(timer.running ? "Pause" : timer.started ? "Resume" : "Start") {
                    if timer.running { timer.pause() } else { timer.start() }
                }
                .buttonStyle(.borderedProminent)
                Button("Reset") { timer.reset() }
                    .buttonStyle(.bordered)
                    .help("Reset to the chosen duration")
            }
            Divider()
            duration("Focus minutes", phase: .focus)
            duration("Break minutes", phase: .rest)
            if timer.started {
                Text("New lengths apply on reset or next session.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(.white)
        .background(Color(white: 0.10).opacity(0.96), in: RoundedRectangle(cornerRadius: 23))
        .overlay {
            RoundedRectangle(cornerRadius: 23)
                .strokeBorder(.white.opacity(0.18), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .environment(\.colorScheme, .dark)
    }

    private func duration(_ label: String, phase: PomodoroTimer.Phase) -> some View {
        let value = Binding(get: { phase == .focus ? timer.focusMinutes : timer.breakMinutes },
                            set: { timer.setMinutes($0, for: phase) })
        return HStack {
            Text(label).font(.system(size: 12))
            Spacer()
            TextField(label, value: value, format: .number.grouping(.never))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .font(.system(size: 12, design: .monospaced))
                .frame(width: 45)
            Stepper(label, value: value, in: PomodoroTimer.minuteRange)
                .labelsHidden()
        }
    }
}

struct PomodoroButton: View {
    @ObservedObject var timer: PomodoroTimer
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(timer.started ? timer.timeLabel : "Pomodoro", systemImage: "timer")
                .monospacedDigit()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open Pomodoro timer")
        .accessibilityValue(timer.started ? timer.timeLabel : "")
        .help(timer.started ? "\(timer.phase.rawValue) · \(timer.timeLabel)" : "Open Pomodoro timer")
    }
}
