import AppKit
import SwiftUI

enum NotchTab: String, CaseIterable { case nook, tray, tasks }

enum TrayMode { case files, clipboard }

enum LiveActivity: Equatable { case charging, headphones, music, event }

struct HeadphonesInfo: Equatable {
    let name: String
    let symbol: String
    var battery: Int?
}

/// Where the notch sits on the screen that has one (or a fake notch on screens without).
struct NotchGeometry {
    var notchSize: CGSize
    var notchMidX: CGFloat
    var screenTop: CGFloat
    var hasNotch: Bool

    static func current() -> NotchGeometry {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.screens.first else {
            return NotchGeometry(notchSize: CGSize(width: 185, height: 32), notchMidX: 756, screenTop: 982, hasNotch: false)
        }
        let frame = screen.frame
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let width = frame.width - left.width - right.width
            return NotchGeometry(notchSize: CGSize(width: width, height: screen.safeAreaInsets.top),
                                 notchMidX: frame.minX + left.width + width / 2,
                                 screenTop: frame.maxY, hasNotch: true)
        }
        let menuBar = max(frame.maxY - screen.visibleFrame.maxY, 24)
        return NotchGeometry(notchSize: CGSize(width: 180, height: menuBar),
                             notchMidX: frame.midX, screenTop: frame.maxY, hasNotch: false)
    }
}

extension Animation {
    static let notch = Animation.spring(response: 0.42, dampingFraction: 0.8)
}

@Observable @MainActor
final class NotchViewModel {
    static let openSize = CGSize(width: 660, height: 232)
    static let closedFlare: CGFloat = 6
    static let openFlare: CGFloat = 14
    /// Extra width on each side of the notch while a live activity is showing.
    static let wing: CGFloat = 76
    /// Side width of a tucked-away ("mini") live activity.
    static let miniWing: CGFloat = 24
    /// The lyric line under the notch.
    static let lyricsHeight: CGFloat = 24

    var isOpen = false
    var tab: NotchTab { didSet { UserDefaults.standard.set(tab.rawValue, forKey: Prefs.lastTab) } }
    var trayMode: TrayMode = .files
    var fileDragActive = false
    var chargingFlash = false
    var headphones: HeadphonesInfo?
    var statusCardShown = false
    var composingEvent = false
    var eventDraft = ""
    var addingEvent = false
    var eventMessage: String?
    var volumeHUD: Float?
    /// A short confirmation at the bottom of the open notch ("Copied 3 items").
    var toast: String?
    var geometry = NotchGeometry.current()
    /// Live activities the user tucked away by clicking or swiping on them.
    private var hiddenPlaySession: Int?
    private var hiddenEventID: String?

    let media: MediaController
    let calendar: CalendarService
    let battery: BatteryMonitor
    let tray: TrayStore
    let camera: CameraMirror
    let tasks: TasksService
    let clipboard: ClipboardHistory
    let lyrics: LyricsService
    let weather: WeatherService
    let stats: SystemStats
    @ObservationIgnored var openSettings: () -> Void = {}
    /// Makes the panel key so a text field can take typing (set by NotchController).
    @ObservationIgnored var requestKeyboard: () -> Void = {}
    @ObservationIgnored private var flashWork: DispatchWorkItem?
    @ObservationIgnored private var headphonesWork: DispatchWorkItem?
    @ObservationIgnored private var toastWork: DispatchWorkItem?
    @ObservationIgnored private var volumeWork: DispatchWorkItem?
    @ObservationIgnored private var closedAt = Date.distantPast

    init(media: MediaController, calendar: CalendarService, battery: BatteryMonitor, tray: TrayStore,
         camera: CameraMirror, tasks: TasksService, clipboard: ClipboardHistory, lyrics: LyricsService,
         weather: WeatherService, stats: SystemStats) {
        self.media = media
        self.calendar = calendar
        self.battery = battery
        self.tray = tray
        self.camera = camera
        self.tasks = tasks
        self.clipboard = clipboard
        self.lyrics = lyrics
        self.weather = weather
        self.stats = stats
        tab = NotchTab(rawValue: UserDefaults.standard.string(forKey: Prefs.lastTab) ?? "") ?? .nook
        battery.onPlugIn = { [weak self] in self?.flashCharging() }
        tray.announce = { [weak self] in self?.showToast($0) }
        clipboard.announce = { [weak self] in self?.showToast($0) }
    }

    // MARK: Live activities

    private var musicPlaying: Bool { media.isPlaying && media.hasTrack && Prefs.bool(Prefs.musicActivity) }
    private var upcomingEvent: CalEvent? { Prefs.bool(Prefs.eventActivity) ? calendar.imminentEvent : nil }

    var liveActivity: LiveActivity? {
        if chargingFlash { return .charging }
        if headphones != nil { return .headphones }
        if musicPlaying && media.playSession != hiddenPlaySession { return .music }
        if let event = upcomingEvent, event.id != hiddenEventID { return .event }
        return nil
    }

    /// A tucked-away activity that's still going, shown small so it can be clicked back.
    var miniActivity: LiveActivity? {
        guard liveActivity == nil else { return nil }
        if musicPlaying { return .music }
        if upcomingEvent != nil { return .event }
        return nil
    }

    var showsLyrics: Bool {
        liveActivity == .music && Prefs.bool(Prefs.lyrics)
            && lyrics.trackKey == media.trackIdentity && !lyrics.lines.isEmpty
    }

    /// Size of the black shape, including the flared top corners.
    var shapeSize: CGSize {
        if isOpen { return Self.openSize }
        let plain = geometry.notchSize.width + Self.closedFlare * 2
        let height = geometry.notchSize.height
        if liveActivity != nil {
            return CGSize(width: plain + Self.wing * 2, height: height + (showsLyrics ? Self.lyricsHeight : 0))
        }
        if miniActivity != nil { return CGSize(width: plain + Self.miniWing * 2, height: height) }
        return CGSize(width: plain, height: height)
    }

    /// Text fields that need the keyboard: the Tasks tab and the quick-add event field.
    var wantsKeyboard: Bool { isOpen && (tab == .tasks || composingEvent) }

    /// Shrinks the activity to its small version until clicked back, or until something new
    /// happens: the next listening session, the next meeting.
    func dismissLiveActivity() {
        guard !isOpen, let activity = liveActivity else { return }
        ActivityLog.note("hid the \(activity) live activity")
        withAnimation(.notch) {
            switch activity {
            case .charging:
                flashWork?.cancel()
                chargingFlash = false
            case .headphones:
                headphonesWork?.cancel()
                headphones = nil
            case .music:
                hiddenPlaySession = media.playSession
            case .event:
                hiddenEventID = calendar.imminentEvent?.id
            }
        }
        haptic(.alignment)
    }

    func restoreLiveActivity() {
        guard !isOpen, miniActivity != nil else { return }
        ActivityLog.note("brought the live activity back")
        withAnimation(.notch) {
            hiddenPlaySession = nil
            hiddenEventID = nil
        }
        haptic(.alignment)
    }

    func headphonesConnected(_ name: String) {
        guard Prefs.bool(Prefs.headphonesActivity) else { return }
        let symbol = HeadphoneBattery.symbol(for: name)
        headphonesWork?.cancel()
        withAnimation(.notch) { headphones = HeadphonesInfo(name: name, symbol: symbol, battery: nil) }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { withAnimation(.notch) { self?.headphones = nil } }
        }
        headphonesWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
        Task {
            // macOS needs a moment after connecting before it reports battery levels.
            try? await Task.sleep(for: .seconds(1.2))
            guard let levels = await HeadphoneBattery.levels(for: name), headphones?.name == name else { return }
            withAnimation(.smooth) { headphones?.battery = levels.headline }
        }
    }

    private func flashCharging() {
        guard Prefs.bool(Prefs.chargingActivity) else { return }
        flashWork?.cancel()
        withAnimation(.notch) { chargingFlash = true }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { withAnimation(.notch) { self?.chargingFlash = false } }
        }
        flashWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    // MARK: Opening and tabs

    func open(tab: NotchTab? = nil) {
        let wasOpen = isOpen
        withAnimation(.notch) {
            if let tab {
                self.tab = tab
            } else if !wasOpen && Date().timeIntervalSince(closedAt) > 10 {
                self.tab = .nook  // after a while away, come back to the home view
                tray.clearSelection()
            }
            isOpen = true
        }
        if self.tab == .tasks { tasks.refreshIfStale() }
        if !wasOpen { ActivityLog.note("notch opened" + (tab.map { " on \($0.rawValue)" } ?? "")) }
        if !wasOpen { haptic(.levelChange) }
    }

    func close() {
        guard isOpen else { return }
        closedAt = Date()
        withAnimation(.notch) {
            isOpen = false
            composingEvent = false
            statusCardShown = false
        }
        eventMessage = nil
        stats.setActive(false)
        camera.stop()
    }

    func select(_ tab: NotchTab) {
        ActivityLog.note("tab \(tab.rawValue)")
        withAnimation(.smooth(duration: 0.25)) { self.tab = tab }
        if tab == .tasks { tasks.refreshIfStale() }
    }

    /// Two-finger swipe on the tab bar: next or previous tab, stopping at the ends.
    func cycleTab(by offset: Int) {
        let all = NotchTab.allCases
        guard let index = all.firstIndex(of: tab) else { return }
        let next = min(max(index + offset, 0), all.count - 1)
        if next != index { select(all[next]) }
    }

    func toggleStatusCard() {
        withAnimation(.smooth(duration: 0.2)) { statusCardShown.toggle() }
        stats.setActive(statusCardShown)
    }

    // MARK: Quick-add event

    func startComposingEvent() {
        withAnimation(.smooth(duration: 0.2)) { composingEvent = true }
        eventMessage = nil
        requestKeyboard()
    }

    func cancelComposingEvent() {
        withAnimation(.smooth(duration: 0.2)) { composingEvent = false }
        eventMessage = nil
    }

    func submitEvent() {
        let text = eventDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !addingEvent else { return }
        addingEvent = true
        eventMessage = nil
        Task {
            defer { addingEvent = false }
            do {
                let event = try await calendar.quickAdd(text)
                eventDraft = ""
                withAnimation(.smooth(duration: 0.2)) { composingEvent = false }
                if let event {
                    let when = event.isAllDay
                        ? event.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
                        : event.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
                    showToast("Added “\(event.title)” · \(when)")
                } else {
                    showToast("Added to your calendar")
                }
            } catch {
                eventMessage = error.localizedDescription
            }
        }
    }

    // MARK: Feedback

    func showToast(_ text: String) {
        toastWork?.cancel()
        withAnimation(.smooth(duration: 0.2)) { toast = text }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { withAnimation(.smooth(duration: 0.3)) { self?.toast = nil } }
        }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    func showVolume(_ level: Float) {
        volumeWork?.cancel()
        volumeHUD = level
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { withAnimation(.smooth(duration: 0.3)) { self?.volumeHUD = nil } }
        }
        volumeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    private func haptic(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        if Prefs.bool(Prefs.haptics) {
            NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
        }
    }
}
