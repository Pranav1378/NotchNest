import AVFoundation
import SwiftUI

struct NookView: View {
    let vm: NotchViewModel

    var body: some View {
        HStack(spacing: 14) {
            MediaWidget(media: vm.media)
                .frame(width: 232)
                .overlay(alignment: .top) {
                    if let level = vm.volumeHUD { VolumeHUD(level: level).transition(.opacity) }
                }
            CalendarWidget(vm: vm)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            MirrorWidget(camera: vm.camera)
        }
    }
}

/// Shown over the player while a two-finger swipe changes the volume.
struct VolumeHUD: View {
    let level: Float

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: level == 0 ? "speaker.slash.fill" : (level < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.3.fill"))
                .font(.system(size: 10))
                .frame(width: 14)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.2))
                    Capsule().fill(Color.white).frame(width: geo.size.width * CGFloat(level))
                }
            }
            .frame(width: 90, height: 4)
            Text("\(Int((level * 100).rounded()))%")
                .font(.system(size: 9, weight: .semibold).monospacedDigit())
                .frame(width: 28, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color(white: 0.18)))
    }
}

// MARK: - Media

struct MediaWidget: View {
    let media: MediaController

    var body: some View {
        if media.hasTrack {
            HStack(spacing: 12) {
                ArtworkView(media: media, size: 80, corner: 15)
                    .overlay(alignment: .bottomTrailing) {
                        if media.artwork != nil, let icon = media.appIcon {
                            Image(nsImage: icon).resizable().frame(width: 24, height: 24).offset(x: 5, y: 5)
                        }
                    }
                    .shadow(color: media.accent.opacity(0.35), radius: 12)
                    .onTapGesture { media.openPlayerApp() }
                    .help("Open \(media.appName)")
                VStack(alignment: .leading, spacing: 3) {
                    Text(media.displayTitle).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(media.subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                    ProgressRow(media: media)
                    HStack(spacing: 18) {
                        ControlButton(symbol: "backward.fill", size: 14) { media.previous() }
                        ControlButton(symbol: media.isPlaying ? "pause.fill" : "play.fill", size: 22) { media.togglePlayPause() }
                        ControlButton(symbol: "forward.fill", size: 14) { media.next() }
                    }
                    .frame(maxWidth: .infinity)
                }
                .frame(height: 104)
            }
            .frame(maxHeight: .infinity)
        } else {
            VStack(spacing: 6) {
                Image(systemName: "music.note").font(.system(size: 26)).foregroundStyle(.tertiary)
                Text("Nothing playing").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct ProgressRow: View {
    let media: MediaController

    var body: some View {
        if media.duration > 0 {
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                let elapsed = media.elapsed(at: context.date)
                let fraction = min(1, elapsed / media.duration)
                VStack(spacing: 2) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.18))
                            Capsule().fill(media.accent).frame(width: max(4, geo.size.width * fraction))
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { location in
                            media.seek(to: Double(location.x / geo.size.width) * media.duration)
                        }
                    }
                    .frame(height: 4)
                    HStack {
                        Text(Self.format(elapsed))
                        Spacer()
                        Text("-" + Self.format(media.duration - elapsed))
                    }
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    static func format(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct ControlButton: View {
    let symbol: String
    let size: CGFloat
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: size + 16, height: size + 12)
                .background(Circle().fill(Color.white.opacity(hovering ? 0.12 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Calendar

struct CalendarWidget: View {
    let vm: NotchViewModel
    @State private var selected = Calendar.current.startOfDay(for: .now)
    private var calendar: CalendarService { vm.calendar }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(vm.composingEvent ? "New event" : selected.formatted(.dateTime.month(.wide)))
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if calendar.isLoading { ProgressView().controlSize(.mini) }
                if calendar.hasAccess {
                    Button {
                        if vm.composingEvent { vm.cancelComposingEvent() } else { vm.startComposingEvent() }
                    } label: {
                        Image(systemName: vm.composingEvent ? "xmark" : "plus")
                            .font(.system(size: 9, weight: .bold))
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(Color.white.opacity(0.12)))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(vm.composingEvent ? "Cancel" : "Add an event")
                }
            }
            if vm.composingEvent {
                EventComposer(vm: vm)
            } else {
                HStack(spacing: 0) {
                    ForEach(calendar.days, id: \.self) { day in
                        DayCell(day: day,
                                selected: Calendar.current.isDate(day, inSameDayAs: selected),
                                hasEvents: calendar.hasEvents(on: day))
                            .onTapGesture { withAnimation(.smooth(duration: 0.2)) { selected = day } }
                    }
                }
                eventList
            }
        }
        .onChange(of: calendar.focusDay) { _, day in
            if let day { selected = day }
        }
    }

    @ViewBuilder private var eventList: some View {
        if !calendar.hasAccess {
            Button(action: vm.openSettings) {
                Label("Connect Google Calendar", systemImage: "link")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let items = calendar.events(on: selected)
            if items.isEmpty {
                Text(calendar.lastError ?? (calendar.lastUpdated == nil ? "Loading…" : "No events"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 4) {
                        ForEach(items) { EventRow(event: $0) }
                    }
                }
            }
        }
    }
}

/// Quick-add: type an event in plain English and Google works out the date and time.
struct EventComposer: View {
    @Bindable var vm: NotchViewModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !vm.calendar.canAddEvents {
                Text("Adding events needs one more Google sign-in.").font(.system(size: 11, weight: .semibold))
                Text("Google will ask you to let NotchNest create events.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Button { Task { await vm.calendar.auth.signIn() } } label: {
                    Text(vm.calendar.auth.isSigningIn ? "Waiting for your browser…" : "Sign in again")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.white.opacity(0.12)))
                }
                .buttonStyle(.plain)
            } else {
                TextField("Study group Thu 7pm", text: $vm.eventDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.1)))
                    .focused($focused)
                    .onSubmit { vm.submitEvent() }
                    .onExitCommand { vm.cancelComposingEvent() }
                    .disabled(vm.addingEvent)
                Text(vm.eventMessage ?? (vm.addingEvent ? "Adding…"
                    : "Type it like you'd say it: “Lunch with Atul Fri 1pm”, “CS 425 exam Oct 3”. Return adds it, Esc cancels."))
                    .font(.system(size: 9))
                    .foregroundStyle(vm.eventMessage == nil ? Color.white.opacity(0.5) : Color.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { DispatchQueue.main.async { focused = true } }
    }
}

struct DayCell: View {
    let day: Date
    let selected: Bool
    let hasEvents: Bool

    var body: some View {
        let today = Calendar.current.isDateInToday(day)
        VStack(spacing: 2) {
            Text(day, format: .dateTime.weekday(.narrow))
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(day, format: .dateTime.day())
                .font(.system(size: 11, weight: selected || today ? .bold : .regular))
                .foregroundStyle(selected ? Color.black : (today ? Color.red : Color.white))
                .frame(width: 21, height: 21)
                .background(Circle().fill(selected ? Color.white : Color.clear))
            Circle().fill(hasEvents ? Color.white.opacity(0.55) : Color.clear).frame(width: 3, height: 3)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

struct EventRow: View {
    let event: CalEvent

    var body: some View {
        HStack(spacing: 6) {
            Capsule().fill(event.color).frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                Text(event.timeText).font(.system(size: 9)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let link = event.meetLink {
                Button { NSWorkspace.shared.open(link) } label: {
                    Image(systemName: "video.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .padding(5)
                        .background(Circle().fill(Color.green.opacity(0.85)))
                }
                .buttonStyle(.plain)
                .help("Join video call")
            }
        }
        .frame(height: 26)
        .opacity(event.end < .now ? 0.45 : 1)
        .contentShape(Rectangle())
        .onTapGesture { event.openInCalendar() }
    }
}

// MARK: - Mirror

struct MirrorWidget: View {
    let camera: CameraMirror

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        ZStack {
            shape.fill(Color.white.opacity(0.08))
            if camera.isRunning {
                CameraPreview(preview: camera.previewLayer).clipShape(shape)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: camera.denied ? "video.slash.fill" : "camera.fill").font(.system(size: 20))
                    Text(camera.denied ? "No camera access" : "Mirror")
                        .font(.system(size: 10, weight: .medium))
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.secondary)
            }
        }
        .frame(width: 130, height: 130)
        .contentShape(shape)
        .onTapGesture { camera.toggle() }
        .help(camera.isRunning ? "Turn camera off" : "Preview your camera")
    }
}

/// Hosts `CameraMirror.previewLayer`. The layer is shared and never recreated (see CameraMirror), so
/// this view only borrows it: adding it here moves it out of any older view.
struct CameraPreview: NSViewRepresentable {
    let preview: AVCaptureVideoPreviewLayer

    func makeNSView(context: Context) -> PreviewView { PreviewView(preview: preview) }
    func updateNSView(_ nsView: PreviewView, context: Context) {}
    static func dismantleNSView(_ nsView: PreviewView, coordinator: ()) { nsView.release() }

    final class PreviewView: NSView {
        private let preview: AVCaptureVideoPreviewLayer

        init(preview: AVCaptureVideoPreviewLayer) {
            self.preview = preview
            super.init(frame: .zero)
            wantsLayer = true
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.addSublayer(preview)
            CATransaction.commit()
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            preview.frame = bounds
            CATransaction.commit()
        }

        /// Give the layer up only if a newer preview hasn't already taken it.
        func release() {
            if preview.superlayer === layer { preview.removeFromSuperlayer() }
        }
    }
}
