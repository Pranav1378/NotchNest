import AppKit
import SwiftUI

enum NotchTab: String, CaseIterable { case nook, tray, tasks }

enum TrayMode { case files, clipboard }

enum LiveActivity: Equatable {
    case charging, headphones, music, event, timer, timerDone, privacy, download, claudeAsk, claudeDone
}

struct DownloadNotice: Equatable {
    let url: URL
    var inTray: Bool
}

struct TimerAlert: Equatable {
    let title: String
    let detail: String
}

struct HeadphonesInfo: Equatable {
    let name: String
    let symbol: String
    var battery: Int?
}

/// Which screen the notch lives on when there's more than one.
enum DisplayMode: String, CaseIterable {
    /// The built-in screen with the notch; the main display when there's no notch (lid closed,
    /// an older MacBook, a desktop Mac).
    case notch
    /// The display that has the menu bar in System Settings → Displays.
    case primary
    /// Whichever display the pointer is on; the notch moves over when you go there.
    case pointer

    var title: String {
        switch self {
        case .notch: return "Built-in display (with the notch)"
        case .primary: return "Main display"
        case .pointer: return "The display the pointer is on"
        }
    }

    static var current: DisplayMode {
        DisplayMode(rawValue: UserDefaults.standard.string(forKey: Prefs.displayMode) ?? "") ?? .notch
    }
}

/// Where the notch sits: the real notch, or a notch-sized pill centred in the menu bar of a screen
/// that has none (external displays, M1 Airs, a MacBook with its lid closed).
struct NotchGeometry: Equatable {
    var notchSize: CGSize
    var notchMidX: CGFloat
    var screenTop: CGFloat
    var hasNotch: Bool
    var screenFrame: CGRect

    static func current(mouse: NSPoint = NSEvent.mouseLocation) -> NotchGeometry {
        guard let screen = screen(for: DisplayMode.current, mouse: mouse) else {
            return NotchGeometry(notchSize: CGSize(width: 185, height: 32), notchMidX: 756, screenTop: 982,
                                 hasNotch: false, screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982))
        }
        return make(frame: screen.frame, visibleFrame: screen.visibleFrame, safeTop: screen.safeAreaInsets.top,
                    leftArea: screen.auxiliaryTopLeftArea, rightArea: screen.auxiliaryTopRightArea)
    }

    static func screen(for mode: DisplayMode, mouse: NSPoint) -> NSScreen? {
        let screens = NSScreen.screens
        let notched = screens.first { $0.safeAreaInsets.top > 0 }
        switch mode {
        case .notch: return notched ?? screens.first
        case .primary: return screens.first
        case .pointer: return screens.first { $0.frame.insetBy(dx: 0, dy: -1).contains(mouse) } ?? notched ?? screens.first
        }
    }

    /// The pure maths, so it can be checked for screens this Mac doesn't have.
    static func make(frame: CGRect, visibleFrame: CGRect, safeTop: CGFloat,
                     leftArea: CGRect?, rightArea: CGRect?) -> NotchGeometry {
        if safeTop > 0, let left = leftArea, let right = rightArea {
            let width = frame.width - left.width - right.width
            return NotchGeometry(notchSize: CGSize(width: width, height: safeTop),
                                 notchMidX: frame.minX + left.width + width / 2,
                                 screenTop: frame.maxY, hasNotch: true, screenFrame: frame)
        }
        // No notch: a pill as tall as the menu bar (24pt if it's set to hide).
        let menuBar = frame.maxY - visibleFrame.maxY
        let height = menuBar >= 20 ? min(menuBar, 32) : 24
        return NotchGeometry(notchSize: CGSize(width: 180, height: height),
                             notchMidX: frame.midX, screenTop: frame.maxY, hasNotch: false, screenFrame: frame)
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
    var timerCardShown = false
    var usageCardShown = false
    var downloadNotice: DownloadNotice?
    var timerAlert: TimerAlert?
    var claudeDone: ClaudeFinished?
    /// Mice, keyboards and headphones with batteries, loaded when the status card opens.
    var bluetoothDevices: [BluetoothDevice] = []
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
    private var hiddenTimerRun: UUID?
    private var hiddenPrivacySession: Int?

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
    let timer: FocusTimer
    let claude: ClaudeBridge
    let privacy: PrivacyMonitor
    let keepAwake: KeepAwake
    let planUsage: ClaudePlanUsage
    @ObservationIgnored var openSettings: () -> Void = {}
    /// Whether the pointer is over the notch (set by NotchController); short notices wait for it to leave.
    @ObservationIgnored var pointerInside: () -> Bool = { false }
    @ObservationIgnored private var downloadWork: DispatchWorkItem?
    @ObservationIgnored private var timerAlertWork: DispatchWorkItem?
    @ObservationIgnored private var claudeDoneWork: DispatchWorkItem?
    /// Makes the panel key so a text field can take typing (set by NotchController).
    @ObservationIgnored var requestKeyboard: () -> Void = {}
    @ObservationIgnored private var flashWork: DispatchWorkItem?
    @ObservationIgnored private var headphonesWork: DispatchWorkItem?
    @ObservationIgnored private var toastWork: DispatchWorkItem?
    @ObservationIgnored private var volumeWork: DispatchWorkItem?
    @ObservationIgnored private var closedAt = Date.distantPast

    init(media: MediaController, calendar: CalendarService, battery: BatteryMonitor, tray: TrayStore,
         camera: CameraMirror, tasks: TasksService, clipboard: ClipboardHistory, lyrics: LyricsService,
         weather: WeatherService, stats: SystemStats, timer: FocusTimer, claude: ClaudeBridge,
         privacy: PrivacyMonitor, keepAwake: KeepAwake, planUsage: ClaudePlanUsage) {
        self.planUsage = planUsage
        self.timer = timer
        self.claude = claude
        self.privacy = privacy
        self.keepAwake = keepAwake
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
        timer.onFinish = { [weak self] in self?.timerFinished(title: $0, detail: $1) }
        claude.onFinished = { [weak self] in self?.showClaudeDone($0) }
        claude.onRequest = { [weak self] in self?.haptic(.levelChange) }
        privacy.ignoreCamera = { [weak camera] in camera?.isRunning ?? false }
    }

    // MARK: Live activities

    private var musicPlaying: Bool { media.isPlaying && media.hasTrack && Prefs.bool(Prefs.musicActivity) }
    private var upcomingEvent: CalEvent? { Prefs.bool(Prefs.eventActivity) ? calendar.imminentEvent : nil }

    private var privacyShowing: Bool { Prefs.bool(Prefs.privacyActivity) && privacy.isActive }
    private var timerShowing: Bool { Prefs.bool(Prefs.timerActivity) && timer.isActive }
    var claudeRequest: ClaudeRequest? { claude.pending.first }

    /// What the closed notch shows, most urgent first.
    var liveActivity: LiveActivity? {
        if claudeRequest != nil { return .claudeAsk }
        if chargingFlash { return .charging }
        if timerAlert != nil { return .timerDone }
        if headphones != nil { return .headphones }
        if downloadNotice != nil { return .download }
        if claudeDone != nil { return .claudeDone }
        if privacyShowing && privacy.session != hiddenPrivacySession { return .privacy }
        if musicPlaying && media.playSession != hiddenPlaySession { return .music }
        if let event = upcomingEvent, event.id != hiddenEventID { return .event }
        if timerShowing && timer.runID != hiddenTimerRun { return .timer }
        return nil
    }

    /// A tucked-away activity that's still going, shown small so it can be clicked back.
    var miniActivity: LiveActivity? {
        guard liveActivity == nil else { return nil }
        if privacyShowing { return .privacy }
        if musicPlaying { return .music }
        if upcomingEvent != nil { return .event }
        if timerShowing { return .timer }
        return nil
    }

    /// A song and a timer at once: the countdown takes the waveform's place beside the artwork.
    var timerBesideMusic: Bool { liveActivity == .music && timerShowing }

    var showsLyrics: Bool {
        liveActivity == .music && Prefs.bool(Prefs.lyrics)
            && lyrics.trackKey == media.trackIdentity && !lyrics.lines.isEmpty
    }

    /// The row under the notch: lyrics, Claude's question, a finished download or Claude's reply.
    var detailHeight: CGFloat {
        switch liveActivity {
        case .music: return showsLyrics ? Self.lyricsHeight : 0
        case .claudeAsk: return 36
        case .download, .claudeDone: return 26
        default: return 0
        }
    }

    /// Size of the black shape, including the flared top corners.
    var shapeSize: CGSize {
        if isOpen { return Self.openSize }
        let plain = geometry.notchSize.width + Self.closedFlare * 2
        let height = geometry.notchSize.height
        if liveActivity != nil {
            return CGSize(width: plain + Self.wing * 2, height: height + detailHeight)
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
            case .timer:
                hiddenTimerRun = timer.runID
            case .timerDone:
                timerAlertWork?.cancel()
                timerAlert = nil
            case .privacy:
                hiddenPrivacySession = privacy.session
            case .download:
                downloadWork?.cancel()
                downloadNotice = nil
            case .claudeAsk:
                // Put away = answer in the terminal instead.
                if let request = claudeRequest { claude.answer(request.id, .terminal) }
            case .claudeDone:
                claudeDoneWork?.cancel()
                claudeDone = nil
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
            hiddenTimerRun = nil
            hiddenPrivacySession = nil
        }
        haptic(.alignment)
    }

    // MARK: Short-lived notices

    func downloadFinished(_ url: URL, inTray: Bool) {
        if isOpen { showToast(inTray ? "Downloaded \(url.lastPathComponent) · added to the Tray" : "Downloaded \(url.lastPathComponent)") }
        guard Prefs.bool(Prefs.downloadActivity) else { return }
        withAnimation(.notch) { downloadNotice = DownloadNotice(url: url, inTray: inTray) }
        haptic(.alignment)
        endDownloadNotice(after: 7)
    }

    func addDownloadToTray() {
        guard var notice = downloadNotice else { return }
        tray.add([notice.url])
        notice.inTray = true
        withAnimation(.smooth(duration: 0.2)) { downloadNotice = notice }
        endDownloadNotice(after: 2.5)
    }

    func revealDownload() {
        guard let notice = downloadNotice else { return }
        NSWorkspace.shared.activateFileViewerSelecting([notice.url])
    }

    private func endDownloadNotice(after seconds: Double) {
        downloadWork?.cancel()
        downloadWork = later(seconds) { [weak self] in
            guard let self else { return }
            if self.pointerInside() { self.endDownloadNotice(after: 1.5) } else { withAnimation(.notch) { self.downloadNotice = nil } }
        }
    }

    private func timerFinished(title: String, detail: String) {
        if Prefs.bool(Prefs.timerSound) { NSSound(named: "Glass")?.play() }
        haptic(.levelChange)
        if isOpen { showToast("\(title) · \(detail)") }
        withAnimation(.notch) { timerAlert = TimerAlert(title: title, detail: detail) }
        timerAlertWork?.cancel()
        timerAlertWork = later(6) { [weak self] in withAnimation(.notch) { self?.timerAlert = nil } }
    }

    private func showClaudeDone(_ done: ClaudeFinished) {
        if isOpen { showToast("Claude finished · \(done.project)") }
        withAnimation(.notch) { claudeDone = done }
        endClaudeDone(after: 6)
    }

    private func endClaudeDone(after seconds: Double) {
        claudeDoneWork?.cancel()
        claudeDoneWork = later(seconds) { [weak self] in
            guard let self else { return }
            if self.pointerInside() { self.endClaudeDone(after: 1.5) } else { withAnimation(.notch) { self.claudeDone = nil } }
        }
    }

    /// Brings forward the app Claude Code runs in (Terminal, iTerm, VS Code…).
    func openClaudeHost(_ bundleID: String?) {
        if let bundleID, let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            app.activate()
        }
        withAnimation(.notch) { claudeDone = nil }
    }

    func joinImminentEvent() {
        guard let link = calendar.imminentEvent?.meetLink else { return }
        ActivityLog.note("joining \(calendar.imminentEvent?.title ?? "meeting")")
        NSWorkspace.shared.open(link)
    }

    private func later(_ seconds: Double, _ body: @escaping @MainActor () -> Void) -> DispatchWorkItem {
        let work = DispatchWorkItem { MainActor.assumeIsolated { body() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
        return work
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
            timerCardShown = false
            usageCardShown = false
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
        withAnimation(.smooth(duration: 0.2)) {
            statusCardShown.toggle()
            if statusCardShown {
                timerCardShown = false
                usageCardShown = false
            }
        }
        stats.setActive(statusCardShown)
        if statusCardShown {
            Task { bluetoothDevices = await HeadphoneBattery.connectedDevices() }
        }
    }

    func toggleTimerCard() {
        withAnimation(.smooth(duration: 0.2)) {
            timerCardShown.toggle()
            if timerCardShown {
                statusCardShown = false
                usageCardShown = false
            }
        }
        if timerCardShown { stats.setActive(false) }
    }

    func toggleUsageCard() {
        planUsage.reload()
        withAnimation(.smooth(duration: 0.2)) {
            usageCardShown.toggle()
            if usageCardShown {
                statusCardShown = false
                timerCardShown = false
            }
        }
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
