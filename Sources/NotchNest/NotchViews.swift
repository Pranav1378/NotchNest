import SwiftUI

struct NotchRootView: View {
    let vm: NotchViewModel
    // Read in body so toggling these in Settings refreshes the closed notch immediately.
    @AppStorage(Prefs.musicActivity) private var musicActivity = true
    @AppStorage(Prefs.eventActivity) private var eventActivity = true
    @AppStorage(Prefs.lyrics) private var lyricsEnabled = true

    var body: some View {
        let _ = (musicActivity, eventActivity, lyricsEnabled)
        let size = vm.shapeSize
        let shape = NotchShape(topRadius: vm.isOpen ? NotchViewModel.openFlare : NotchViewModel.closedFlare,
                               bottomRadius: vm.isOpen ? 28 : (vm.showsLyrics ? 14 : 10))
        ZStack(alignment: .top) {
            shape.fill(Color.black)
                .shadow(color: .black.opacity(vm.isOpen ? 0.6 : 0), radius: 18, y: 8)
            content
                .frame(width: size.width, height: size.height, alignment: .top)
                .clipShape(shape)
        }
        .frame(width: size.width, height: size.height)
        .contentShape(shape)
        .overlay {
            if !vm.isOpen {
                Color.clear.contentShape(Rectangle()).onTapGesture { location in
                    closedTap(at: location, width: size.width)
                }
            }
        }
        .contextMenu {
            if !vm.isOpen && vm.liveActivity != nil {
                Button("Hide Live Activity") { vm.dismissLiveActivity() }
                Divider()
            }
            if !vm.isOpen && vm.miniActivity != nil {
                Button("Show Live Activity") { vm.restoreLiveActivity() }
                Divider()
            }
            Button("Settings…") { vm.openSettings() }
            Divider()
            Button("Quit NotchNest") { NSApp.terminate(nil) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.notch, value: vm.liveActivity)
        .animation(.notch, value: vm.miniActivity)
        .animation(.notch, value: vm.showsLyrics)
        .environment(\.colorScheme, .dark)
    }

    /// On the closed notch: the sides of a live activity shrink it, the sides of a small one
    /// bring it back, and anywhere else opens the notch.
    private func closedTap(at location: CGPoint, width: CGFloat) {
        let flare = NotchViewModel.closedFlare
        let onTopRow = location.y <= vm.geometry.notchSize.height
        if vm.liveActivity != nil, onTopRow,
           location.x < flare + NotchViewModel.wing || location.x > width - flare - NotchViewModel.wing {
            vm.dismissLiveActivity()
        } else if vm.miniActivity != nil,
                  location.x < flare + NotchViewModel.miniWing || location.x > width - flare - NotchViewModel.miniWing {
            vm.restoreLiveActivity()
        } else {
            vm.open()
        }
    }

    @ViewBuilder private var content: some View {
        if vm.isOpen {
            // Fixed size so the spring reveals the layout instead of squashing it.
            OpenNotchView(vm: vm)
                .frame(width: NotchViewModel.openSize.width - 2 * (NotchViewModel.openFlare + 16),
                       height: NotchViewModel.openSize.height)
                .transition(.blurFade)
        } else if let activity = vm.liveActivity {
            LiveActivityView(activity: activity, vm: vm)
                .transition(.blurFade)
        } else if let activity = vm.miniActivity {
            MiniActivityView(activity: activity, vm: vm)
                .transition(.blurFade)
        }
    }
}

struct OpenNotchView: View {
    let vm: NotchViewModel

    var body: some View {
        VStack(spacing: 6) {
            // The menu-bar row stays empty; controls sit just below it.
            Color.clear.frame(height: vm.geometry.notchSize.height - 4)
            header.frame(height: 26)
            Group {
                switch vm.tab {
                case .nook: NookView(vm: vm)
                case .tray: TrayView(vm: vm)
                case .tasks: TasksView(tasks: vm.tasks, openSettings: vm.openSettings)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.bottom, 16)
        }
        .overlay(alignment: .topTrailing) {
            if vm.statusCardShown {
                StatusCard(vm: vm)
                    .padding(.top, vm.geometry.notchSize.height + 26)
                    .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .topTrailing)))
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = vm.toast {
                ToastView(text: toast).padding(.bottom, 2).transition(.opacity)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 4) {
            TabButton(icon: "house.fill", title: "Nook", selected: vm.tab == .nook) { vm.select(.nook) }
            TabButton(icon: "tray.full.fill", title: "Tray", selected: vm.tab == .tray,
                      badge: vm.tray.items.count) { vm.select(.tray) }
            TabButton(icon: "checklist", title: "Tasks", selected: vm.tab == .tasks) { vm.select(.tasks) }
            if vm.tab == .tray {
                TrayModeSwitch(vm: vm).padding(.leading, 8).transition(.opacity)
            }
            Spacer()
            StatusButton(vm: vm)
            Button(action: vm.openSettings) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
    }
}

/// "Files | Clipboard" — only shown in the header while the Tray tab is open.
struct TrayModeSwitch: View {
    let vm: NotchViewModel

    var body: some View {
        HStack(spacing: 0) {
            segment("Files", .files)
            segment("Clipboard", .clipboard)
        }
        .padding(2)
        .background(Capsule().fill(Color.white.opacity(0.08)))
    }

    private func segment(_ title: String, _ mode: TrayMode) -> some View {
        let selected = vm.trayMode == mode
        return Button { withAnimation(.smooth(duration: 0.2)) { vm.trayMode = mode } } label: {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .foregroundStyle(selected ? Color.white : Color.white.opacity(0.5))
                .background(Capsule().fill(Color.white.opacity(selected ? 0.16 : 0)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Weather and battery in the header; click for the status card.
struct StatusButton: View {
    let vm: NotchViewModel
    @AppStorage(Prefs.weather) private var weatherEnabled = true

    var body: some View {
        Button { vm.toggleStatusCard() } label: {
            HStack(spacing: 8) {
                if weatherEnabled, let weather = vm.weather.now {
                    HStack(spacing: 3) {
                        Image(systemName: weather.symbol).symbolRenderingMode(.multicolor).font(.system(size: 11))
                        Text("\(Int(weather.temperature.rounded()))°")
                            .font(.system(size: 10, weight: .medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                BatteryBadge(battery: vm.battery)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.white.opacity(vm.statusCardShown ? 0.14 : 0)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Weather and system info")
    }
}

struct StatusCard: View {
    let vm: NotchViewModel
    @AppStorage(Prefs.weather) private var weatherEnabled = true

    var body: some View {
        let stats = vm.stats
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        VStack(alignment: .leading, spacing: 8) {
            if weatherEnabled {
                if let weather = vm.weather.now {
                    row(weather.symbol, multicolor: true,
                        title: "\(Int(weather.temperature.rounded()))° · \(weather.summary)",
                        detail: (weather.place.isEmpty ? "" : "\(weather.place) · ")
                            + "H \(Int(weather.high.rounded()))°  L \(Int(weather.low.rounded()))°")
                } else if let problem = vm.weather.problem {
                    row("location.slash", title: "Weather", detail: problem)
                }
            }
            row(vm.battery.isCharging ? "battery.100.bolt" : "battery.75",
                title: "Battery \(vm.battery.percent)%" + (vm.battery.isCharging ? " · charging" : ""),
                detail: [stats.batteryHealth.map { "Health \($0)%" }, stats.batteryCondition,
                         stats.cycleCount.map { "\($0) cycles" }].compactMap { $0 }.joined(separator: " · "))
            if let snapshot = stats.snapshot {
                row("cpu", title: "CPU " + (snapshot.cpu.map { "\(Int(($0 * 100).rounded()))%" } ?? "…"),
                    detail: "Memory \(Self.memory(snapshot.memoryUsed)) of \(Self.memory(snapshot.memoryTotal))")
                row("arrow.up.arrow.down", title: "↓ \(SystemSnapshot.rate(snapshot.download))",
                    detail: "↑ \(SystemSnapshot.rate(snapshot.upload))")
            }
        }
        .padding(12)
        .frame(width: 236, alignment: .leading)
        .background(shape.fill(Color(white: 0.11)))
        .overlay(shape.strokeBorder(Color.white.opacity(0.08)))
        .shadow(color: .black.opacity(0.5), radius: 10, y: 4)
    }

    private func row(_ icon: String, multicolor: Bool = false, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .symbolRenderingMode(multicolor ? .multicolor : .monochrome)
                .font(.system(size: 12))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 11, weight: .semibold))
                if !detail.isEmpty {
                    Text(detail).font(.system(size: 9)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private static func memory(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }
}

struct ToastView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color(white: 0.22)))
    }
}

/// Compact content either side of the physical notch while it's closed, plus the lyric line.
struct LiveActivityView: View {
    let activity: LiveActivity
    let vm: NotchViewModel
    @AppStorage(Prefs.lyrics) private var lyricsEnabled = true

    var body: some View {
        let height = vm.geometry.notchSize.height
        let side = NotchViewModel.wing - 8
        let wantsLyrics = activity == .music && lyricsEnabled
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                leading.frame(width: side, height: height, alignment: .leading)
                Spacer(minLength: vm.geometry.notchSize.width)
                trailing.frame(width: side, height: height, alignment: .trailing)
            }
            if vm.showsLyrics {
                LyricLineView(lyrics: vm.lyrics, media: vm.media)
                    .frame(height: NotchViewModel.lyricsHeight - 4)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, NotchViewModel.closedFlare + 8)
        .task(id: "\(vm.media.trackIdentity)|\(wantsLyrics)") {
            if wantsLyrics {
                vm.lyrics.load(title: vm.media.title, artist: vm.media.artist, duration: vm.media.duration)
            }
        }
    }

    @ViewBuilder private var leading: some View {
        switch activity {
        case .music:
            ArtworkView(media: vm.media, size: 22, corner: 6)
        case .charging:
            HStack(spacing: 4) {
                Image(systemName: "bolt.fill").font(.system(size: 11, weight: .bold))
                Text("Charging").font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(.green)
            .fixedSize()
        case .headphones:
            Image(systemName: vm.headphones?.symbol ?? "headphones")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
        case .event:
            Image(systemName: "calendar").font(.system(size: 13, weight: .semibold))
                .foregroundStyle(vm.calendar.imminentEvent?.color ?? .blue)
        }
    }

    @ViewBuilder private var trailing: some View {
        switch activity {
        case .music:
            WaveformView(color: vm.media.accent, playing: vm.media.isPlaying).frame(width: 20, height: 14)
        case .charging:
            HStack(spacing: 4) {
                Text("\(vm.battery.percent)%").font(.system(size: 11, weight: .semibold).monospacedDigit())
                Image(systemName: "battery.100.bolt").font(.system(size: 14))
            }
            .foregroundStyle(.green)
            .fixedSize()
        case .headphones:
            if let battery = vm.headphones?.battery {
                HStack(spacing: 3) {
                    Text("\(battery)%").font(.system(size: 11, weight: .semibold).monospacedDigit())
                    Image(systemName: battery <= 20 ? "battery.25" : "battery.100").font(.system(size: 13))
                }
                .foregroundStyle(battery <= 20 ? Color.red : Color.green)
                .fixedSize()
            } else {
                Text("Connected").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).fixedSize()
            }
        case .event:
            TimelineView(.periodic(from: .now, by: 15)) { context in
                Text(vm.calendar.imminentEvent.map { countdown(to: $0.start, now: context.date) } ?? "")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(vm.calendar.imminentEvent?.color ?? .blue)
            }
        }
    }

    private func countdown(to start: Date, now: Date) -> String {
        let minutes = Int(ceil(start.timeIntervalSince(now) / 60))
        return minutes <= 0 ? "now" : "\(minutes)m"
    }
}

/// The current line of a song's lyrics, sliding up as the song moves on.
struct LyricLineView: View {
    let lyrics: LyricsService
    let media: MediaController

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { context in
            let index = lyrics.index(at: media.elapsed(at: context.date))
            let line = index.map { lyrics.lines[$0].text } ?? ""
            ZStack {
                Text(line.isEmpty ? "♪" : line)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.92))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(maxWidth: .infinity)
                    .id(index ?? -1)
                    .transition(.push(from: .bottom))
            }
            .animation(.smooth(duration: 0.35), value: index)
            .clipped()
        }
    }
}

/// A tucked-away live activity: tiny artwork and waveform (or a dot) hugging the notch.
struct MiniActivityView: View {
    let activity: LiveActivity
    let vm: NotchViewModel

    var body: some View {
        let height = vm.geometry.notchSize.height
        HStack(spacing: 0) {
            leading.frame(width: NotchViewModel.miniWing - 4, height: height)
            Spacer(minLength: vm.geometry.notchSize.width)
            trailing.frame(width: NotchViewModel.miniWing - 4, height: height)
        }
        .padding(.horizontal, NotchViewModel.closedFlare + 2)
        .help("Click or swipe to bring it back")
    }

    @ViewBuilder private var leading: some View {
        if activity == .music {
            ArtworkView(media: vm.media, size: 14, corner: 4)
        } else {
            Circle().fill(vm.calendar.imminentEvent?.color ?? .blue).frame(width: 6, height: 6)
        }
    }

    @ViewBuilder private var trailing: some View {
        if activity == .music {
            WaveformView(color: vm.media.accent, playing: vm.media.isPlaying, barWidth: 2, barHeight: 9)
                .frame(width: 14, height: 10)
        } else {
            Image(systemName: "calendar").font(.system(size: 9, weight: .semibold))
                .foregroundStyle(vm.calendar.imminentEvent?.color ?? .blue)
        }
    }
}

struct TabButton: View {
    let icon: String
    let title: String
    let selected: Bool
    var badge = 0
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                Text(title).font(.system(size: 11, weight: .semibold))
                if badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 4)
                        .background(Capsule().fill(Color.white.opacity(0.2)))
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .foregroundStyle(selected ? Color.white : Color.white.opacity(0.5))
            .background(Capsule().fill(Color.white.opacity(selected ? 0.14 : 0)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct ArtworkView: View {
    let media: MediaController
    let size: CGFloat
    let corner: CGFloat

    var body: some View {
        Group {
            if let art = media.artwork {
                Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
            } else if let icon = media.appIcon {
                Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
            } else {
                ZStack {
                    LinearGradient(colors: [.pink, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "music.note").font(.system(size: size * 0.45, weight: .semibold))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

struct WaveformView: View {
    let color: Color
    let playing: Bool
    var barWidth: CGFloat = 3
    var barHeight: CGFloat = 14

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !playing)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: barWidth * 0.7) {
                ForEach(0..<4, id: \.self) { i in
                    let phase = t * (3.1 + Double(i) * 0.9) + Double(i) * 1.7
                    let level = playing ? 0.3 + 0.7 * abs(sin(phase) * cos(phase * 0.37 + Double(i))) : 0.2
                    Capsule().fill(color).frame(width: barWidth, height: max(barWidth, barHeight * level))
                }
            }
            .frame(maxHeight: .infinity)
        }
    }
}

struct BatteryBadge: View {
    let battery: BatteryMonitor

    var body: some View {
        if battery.hasBattery {
            HStack(spacing: 4) {
                Text("\(battery.percent)%")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                Image(systemName: symbol)
                    .font(.system(size: 13))
                    .foregroundStyle(battery.pluggedIn ? Color.green : (battery.percent <= 20 ? Color.red : Color.white))
            }
        }
    }

    private var symbol: String {
        if battery.isCharging { return "battery.100.bolt" }
        switch battery.percent {
        case 88...: return "battery.100"
        case 63..<88: return "battery.75"
        case 38..<63: return "battery.50"
        case 13..<38: return "battery.25"
        default: return "battery.0"
        }
    }
}

private struct BlurFade: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        content
            .blur(radius: active ? 8 : 0)
            .opacity(active ? 0 : 1)
            .scaleEffect(active ? 0.92 : 1, anchor: .top)
    }
}

extension AnyTransition {
    static var blurFade: AnyTransition {
        .modifier(active: BlurFade(active: true), identity: BlurFade(active: false))
    }
}
