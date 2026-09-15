import SwiftUI

extension FocusTimer {
    var tint: Color {
        switch kind {
        case .timer: return .orange
        case .focus: return Color(red: 1, green: 0.42, blue: 0.36)
        case .rest: return .green
        }
    }
}

/// The countdown, ticking once a second.
struct TimerText: View {
    let timer: FocusTimer
    var size: CGFloat = 11

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(FocusTimer.format(timer.remaining(at: context.date)))
                .font(.system(size: size, weight: .semibold).monospacedDigit())
                .foregroundStyle(timer.isPaused ? timer.tint.opacity(0.55) : timer.tint)
                .fixedSize()
        }
    }
}

/// Header button: a timer icon, plus the countdown while one is running. Click for the timer card.
struct TimerButton: View {
    let vm: NotchViewModel

    var body: some View {
        let timer = vm.timer
        Button { vm.toggleTimerCard() } label: {
            HStack(spacing: 4) {
                Image(systemName: timer.isPaused ? "pause.circle" : "timer")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(timer.isActive ? timer.tint : Color.secondary)
                if timer.isActive { TimerText(timer: timer, size: 10) }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.white.opacity(vm.timerCardShown ? 0.14 : 0)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(timer.isActive ? "\(timer.title) timer" : "Timer and Pomodoro")
    }
}

/// Start a timer (presets or your own length) or a Pomodoro; pause, extend or stop one that's running.
struct TimerCard: View {
    let vm: NotchViewModel
    @AppStorage("timerCustomMinutes") private var custom = 20

    var body: some View {
        let timer = vm.timer
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        VStack(alignment: .leading, spacing: 10) {
            if timer.isActive { running(timer) } else { idle(timer) }
        }
        .padding(12)
        .frame(width: 236, alignment: .leading)
        .background(shape.fill(Color(white: 0.11)))
        .overlay(shape.strokeBorder(Color.white.opacity(0.08)))
        .shadow(color: .black.opacity(0.5), radius: 10, y: 4)
    }

    @ViewBuilder private func idle(_ timer: FocusTimer) -> some View {
        Text("Timer").font(.system(size: 11, weight: .semibold))
        HStack(spacing: 5) {
            ForEach([1, 5, 10, 15, 30], id: \.self) { minutes in
                chip("\(minutes)m") { start { timer.start(minutes: Double(minutes)) } }
            }
        }
        HStack(spacing: 6) {
            round("minus") { custom = max(1, custom - (custom > 10 ? 5 : 1)) }
            Text("\(custom) min")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .frame(minWidth: 44)
            round("plus") { custom = min(180, custom + (custom >= 10 ? 5 : 1)) }
            Spacer(minLength: 0)
            chip("Start", prominent: true) { start { timer.start(minutes: Double(custom)) } }
        }
        Divider().overlay(Color.white.opacity(0.08))
        Button { start { timer.startPomodoro() } } label: {
            HStack(spacing: 8) {
                Image(systemName: "brain.head.profile").font(.system(size: 12))
                    .foregroundStyle(Color(red: 1, green: 0.42, blue: 0.36))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Pomodoro").font(.system(size: 11, weight: .semibold))
                    Text("\(FocusTimer.focusMinutes) min focus, \(FocusTimer.breakMinutes) min break"
                         + (timer.focusSessionsToday > 0 ? " · \(timer.focusSessionsToday) done today" : ""))
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "play.fill").font(.system(size: 10))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func running(_ timer: FocusTimer) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(timer.title + (timer.isPaused ? " · paused" : ""))
                .font(.system(size: 11, weight: .semibold))
            Spacer()
            if timer.isPomodoro {
                Text("\(timer.focusSessionsToday) done today").font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
        TimerText(timer: timer, size: 28)
        HStack(spacing: 6) {
            chip(timer.isPaused ? "Resume" : "Pause", prominent: true) {
                if timer.isPaused { timer.resume() } else { timer.pause() }
            }
            chip("+1 min") { timer.addMinute() }
            if timer.isPomodoro { chip("Skip") { timer.skip() } }
            Spacer(minLength: 0)
            chip("Stop") { timer.stop() }
        }
    }

    /// Starting a countdown closes the card, so the notch gets out of the way.
    private func start(_ action: () -> Void) {
        action()
        withAnimation(.smooth(duration: 0.2)) { vm.timerCardShown = false }
    }

    private func chip(_ title: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .foregroundStyle(prominent ? Color.black : Color.white)
                .background(Capsule().fill(prominent ? Color.orange : Color.white.opacity(0.12)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func round(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.white.opacity(0.12)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}
