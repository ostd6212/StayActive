import Cocoa
import IOKit.pwr_mgt
import ApplicationServices
import os.log

// NSLog messages show up as "<private>" in Console/log stream because the
// unified logging system treats NSLog's fully-composed string as a single
// dynamic %@ argument, which is redacted by default. Route through os_log
// with an explicit %{public}@ so the text stays readable.
private let stayActiveLog = OSLog(subsystem: "com.dmytro.stayactive", category: "general")

func log(_ message: String) {
    os_log("%{public}@", log: stayActiveLog, type: .info, message)
}

// Used for the inactive-state dot, which is a template image like the
// ring, so vibrancy is actually fine for it; kept non-vibrant anyway since
// that was the first (unsuccessful) attempt at the active-dot color shift
// and there's no reason to reintroduce vibrancy-dependent behavior here.
private final class NonVibrantImageView: NSImageView {
    override var allowsVibrancy: Bool { false }
}

// Draws the active-state green dot in a small separate borderless NSWindow
// floated on top of the status item's icon, instead of as content inside
// the status item's own button. Two prior attempts to keep this dot's
// color from shifting to blue on a dimmed non-key-screen menu bar --
// disabling vibrancy on its NSImageView, and drawing it fully opaque in
// explicit sRGB -- both failed to stop the shift (confirmed live both
// times), which means whatever transform causes it is applied to the
// status item's own backing content, not controllable from a subview
// property or a color choice. A completely separate window is composited
// by the window server as an ordinary opaque layer on top, outside that
// per-menu-bar-surface transform entirely.
// An NSWindow's own frame origin is constrained to whole points --
// confirmed live via calibration logging: a computed origin of
// (970.0, 962.5) resulted in an actual window frame of (970.0, 962.0,
// ...). Content drawn *inside* a window isn't under that same
// constraint, though, so the leftover sub-point fraction the window's
// own origin can't represent is absorbed here instead: the view is
// sized a point larger than the dot in each dimension, and the dot is
// drawn at dotOrigin (always in [0, 1) in each axis) rather than at a
// fixed (0, 0) -- the window's rounded whole-point origin plus this
// fractional draw offset reconstructs the exact intended position.
private final class DotOverlayView: NSView {
    var dotOrigin: NSPoint = .zero {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1.0).setFill()
        NSBezierPath(ovalIn: NSRect(origin: dotOrigin, size: NSSize(width: 6, height: 6))).fill()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSTextFieldDelegate {

    private var statusItem: NSStatusItem!
    private var ringView: NSImageView?
    private var dotView: NSImageView?
    private var dotOverlayWindows: [NSWindow] = []
    private var dotOverlayTimer: Timer?
    private var dotOverlayDebounceTimer: Timer?

    // Per-screen offsets (distance from that screen's own right edge, and
    // height above that screen's own visibleFrame.maxY), recorded from real
    // measurements whenever that particular screen is the one owning the
    // real button window. Calibration data confirmed live that a mirrored
    // menu extra's actual distance from the right edge can differ by
    // dozens of points between a Retina and a non-Retina screen (measured:
    // 566pt vs 622pt on this exact hardware) -- other menu extras simply
    // don't render at identical widths in points across differently-scaled
    // mirrored menu bars, so "same order and spacing" doesn't mean "same
    // distance from the edge". Once a screen has been observed as the
    // owner at least once, its own recorded offsets give an exact position
    // from then on instead of inferring one from a different screen.
    private var measuredOffsetsByScreen: [ObjectIdentifier: (insetFromRight: CGFloat, heightAboveVisibleFrame: CGFloat)] = [:]
    private var timer: Timer?
    private var isActive = false

    private var activityToken: NSObjectProtocol?
    private var displaySleepAssertionID: IOPMAssertionID = 0
    private var hasDisplaySleepAssertion = false

    private let nudgeInterval: TimeInterval = 60.0

    // MARK: - Schedule state

    private var scheduleCheckTimer: Timer?

    private var scheduleLabelField: NSTextField?
    private var disclosureButton: NSButton?
    private var isScheduleExpanded = false
    private var topSeparatorItem: NSMenuItem?
    private var scheduleRowItem: NSMenuItem?
    private var startRowItem: NSMenuItem?
    private var endRowItem: NSMenuItem?
    private var saveRowItem: NSMenuItem?
    private var bottomSeparatorItem: NSMenuItem?
    private var startHourField: NSTextField?
    private var startMinuteField: NSTextField?
    private var endHourField: NSTextField?
    private var endMinuteField: NSTextField?

    private let minuteStep = 5

    private let defaults = UserDefaults.standard

    private var scheduleEnabled: Bool {
        get { defaults.bool(forKey: "scheduleEnabled") }
        set { defaults.set(newValue, forKey: "scheduleEnabled") }
    }

    // Minutes since midnight. Defaults to 09:00-18:00 on first run.
    private var scheduleStartMinutes: Int {
        get {
            defaults.object(forKey: "scheduleStartMinutes") != nil
                ? defaults.integer(forKey: "scheduleStartMinutes") : 9 * 60
        }
        set { defaults.set(newValue, forKey: "scheduleStartMinutes") }
    }

    private var scheduleEndMinutes: Int {
        get {
            defaults.object(forKey: "scheduleEndMinutes") != nil
                ? defaults.integer(forKey: "scheduleEndMinutes") : 18 * 60
        }
        set { defaults.set(newValue, forKey: "scheduleEndMinutes") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        log("StayActive: applicationDidFinishLaunching - starting up")

        setupStatusItem()
        checkAccessibilityTrust()
        beginBackgroundActivity()

        // Always start inactive (gray). If a schedule is enabled, the first
        // check below will immediately turn it on when launch happens to
        // fall inside the configured window; otherwise the user starts it
        // manually from the menu.
        startScheduleTimer()

        log("StayActive: startup complete, nudge interval = \(nudgeInterval)s, scheduleEnabled = \(scheduleEnabled)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        log("StayActive: applicationWillTerminate - cleaning up")
        timer?.invalidate()
        scheduleCheckTimer?.invalidate()
        dotOverlayTimer?.invalidate()
        dotOverlayDebounceTimer?.invalidate()
        endBackgroundActivity()
        releaseDisplaySleepAssertion()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    // MARK: - Status item / menu

    private func setupStatusItem() {
        log("StayActive: setting up status item")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        // The ring and the (inactive-only) dot are separate overlay
        // subviews rather than one drawn into the button's own .image, and
        // the dot is centered on the RING's own anchors, not the button's
        // -- centering each independently on the button left them slightly
        // off from one another in practice (likely NSStatusBarButton's own
        // image layout doesn't put its image at exactly the same point as
        // the button's geometric bounds center). Anchoring the dot to the
        // ring directly makes them share the exact same reference point, so
        // they can't drift apart regardless of any such button-level quirk.
        // The active-state green dot is a separate floating window (see
        // DotOverlayView) positioned over this same spot instead of a third
        // state for this image, so it isn't subject to whatever transform
        // the status item's own backing content goes through.
        if let button = statusItem.button {
            let ring = NSImageView()
            ring.translatesAutoresizingMaskIntoConstraints = false
            ring.image = makeRingImage()
            button.addSubview(ring)

            // Always the inactive (template, black) dot now -- the active
            // green state is drawn by a separate floating window (see
            // DotOverlayView) instead of by swapping this view's image, so
            // this view only needs hiding/showing, never redrawing.
            let dot = NonVibrantImageView()
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.image = makeInactiveDotImage()
            button.addSubview(dot)

            NSLayoutConstraint.activate([
                ring.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                ring.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                ring.widthAnchor.constraint(equalToConstant: 18),
                ring.heightAnchor.constraint(equalToConstant: 18),

                dot.centerXAnchor.constraint(equalTo: ring.centerXAnchor),
                dot.centerYAnchor.constraint(equalTo: ring.centerYAnchor),
                dot.widthAnchor.constraint(equalToConstant: 6),
                dot.heightAnchor.constraint(equalToConstant: 6),
            ])
            ringView = ring
            dotView = dot
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(repositionDotOverlay),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        // Other menu extras constantly reflow on their own (the clock
        // ticking over, a battery percentage or Wi-Fi signal icon
        // changing width) and that shifts every icon to their left,
        // including this one, at essentially random moments completely
        // unrelated to any click. The ring (a real subview of the button)
        // moves with its window instantly when that happens; the overlay
        // window does not, since it's a separate window whose position we
        // compute ourselves -- and before this, only the once-a-second
        // timer or an explicit trigger caught up. Confirmed live via a
        // screen recording: the dot visibly jumped in and out of
        // alignment with the ring, with no clicking involved, matching
        // that up-to-1-second lag exactly. Reacting to the button's own
        // window actually moving closes that lag immediately instead of
        // waiting for the next poll.
        if let buttonWindow = statusItem.button?.window {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(buttonWindowGeometryChanged),
                name: NSWindow.didMoveNotification,
                object: buttonWindow
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(buttonWindowGeometryChanged),
                name: NSWindow.didResizeNotification,
                object: buttonWindow
            )
            // macOS orders the button's window out entirely (rather than
            // moving it) when it gets collapsed behind the menu bar's
            // "<<"/">>" overflow chevron, and orders it back in when
            // expanded -- neither of which is a move or a resize. React
            // immediately (not debounced -- there's no rapid-fire burst of
            // these the way a click's highlight animation produces) so the
            // overlay disappears/reappears with the real icon instead of
            // lagging or being left floating with nothing under it.
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(repositionDotOverlay),
                name: NSWindow.didChangeOcclusionStateNotification,
                object: buttonWindow
            )
        }

        let menu = NSMenu()

        let toggleItem = NSMenuItem(
            title: toggleTitle(),
            action: #selector(toggleActive),
            keyEquivalent: ""
        )
        toggleItem.target = self
        menu.addItem(toggleItem)

        let topSeparator = NSMenuItem.separator()
        menu.addItem(topSeparator)
        topSeparatorItem = topSeparator

        menu.addItem(buildScheduleSwitchRow())

        // Built once, up front, and shown/hidden via isHidden from here on --
        // never inserted/removed while the menu might be open. Mutating a
        // live NSMenu's item list mid-tracking left the menu's hit-testing
        // out of sync with what was on screen (confirmed live: the switch
        // only registered every other click after a rebuild).
        let startItem = makeTimeRowItem(label: "Start", minutes: scheduleStartMinutes, isStart: true)
        menu.addItem(startItem)
        startRowItem = startItem

        let endItem = makeTimeRowItem(label: "End", minutes: scheduleEndMinutes, isStart: false)
        menu.addItem(endItem)
        endRowItem = endItem

        let saveItem = buildSaveButtonRow()
        menu.addItem(saveItem)
        saveRowItem = saveItem

        let bottomSeparator = NSMenuItem.separator()
        menu.addItem(bottomSeparator)
        bottomSeparatorItem = bottomSeparator

        updateScheduleRowsVisibility()

        let quitItem = NSMenuItem(
            title: "Quit",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu

        log("StayActive: status item ready")
    }

    private func toggleTitle() -> String {
        return isActive ? "Stop" : "Start"
    }

    private func formatMinutes(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    private func scheduleSubtitleText() -> String {
        guard scheduleEnabled else { return "Off" }
        return "\(formatMinutes(scheduleStartMinutes))–\(formatMinutes(scheduleEndMinutes))"
    }

    @objc private func toggleActive() {
        setActive(!isActive, reason: "manual toggle")
    }

    private func setActive(_ newValue: Bool, reason: String) {
        guard newValue != isActive else { return }
        isActive = newValue
        log("StayActive: setActive(\(newValue)) reason=\(reason)")

        dotView?.isHidden = isActive
        if isActive {
            showDotOverlay()
        } else {
            hideDotOverlay()
        }
        statusItem.menu?.item(at: 0)?.title = toggleTitle()

        if isActive {
            startTimer()
            createDisplaySleepAssertion()
        } else {
            timer?.invalidate()
            timer = nil
            releaseDisplaySleepAssertion()
        }
    }

    // MARK: - Dot overlay windows (active-state green dot)

    private func makeDotOverlayWindow() -> NSWindow {
        // One point larger than the 6x6 dot in each dimension, so
        // DotOverlayView always has room to draw it at a [0, 1)-range
        // fractional offset without clipping -- see DotOverlayView.
        let size = NSSize(width: 7, height: 7)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .statusBar
        // Menu extras stay visible across every space and full-screen app on
        // their screen; this overlay needs the same behavior so it doesn't
        // vanish or lag behind during a space switch.
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.contentView = DotOverlayView(frame: NSRect(origin: .zero, size: size))
        return window
    }

    private func showDotOverlay() {
        updateDotOverlayPosition()

        // didMove/didResize on the button's own window (registered in
        // setupStatusItem) catches most repositioning immediately, but
        // confirmed live, the large jump when the menu bar's own "<<"/">>"
        // overflow collapses or expands doesn't fire either notification
        // -- that move is most likely driven directly by SystemUIServer
        // rather than through the standard AppKit window-moving API this
        // app's own process would use, so there's nothing here to observe
        // for it. It still self-corrects once this periodic recheck's
        // next tick lands, so a short interval keeps that self-correction
        // fast enough to not read as "stuck" (confirmed live: at 1.0s it
        // was noticeable; this is cheap enough to run much more often).
        dotOverlayTimer?.invalidate()
        dotOverlayTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.updateDotOverlayPosition()
        }
    }

    private func hideDotOverlay() {
        dotOverlayTimer?.invalidate()
        dotOverlayTimer = nil
        dotOverlayWindows.forEach { $0.orderOut(nil) }
    }

    // In macOS's "Displays have separate Spaces" setup (the default), a
    // menu extra is mirrored onto every screen's own menu bar, but AppKit
    // only ever hands this process one real NSWindow for it
    // (statusItem.button.window) -- tied to whichever single screen
    // currently owns it. There's no API for where the *mirrored* copies
    // land on the other screens' menu bars (confirmed live: floating a
    // single overlay window only fixed the color on the screen that owns
    // the real button window -- the icon on every other screen lost its
    // dot entirely).
    //
    // Inferring a non-owning screen's position from the CURRENT owner's
    // measurement (several earlier attempts, both horizontal and vertical)
    // was never reliable: calibration logging from the actual hardware
    // showed the icon's real distance from the right edge measured 566pt
    // on one screen and 622pt on the other -- a 56pt difference. Other menu
    // extras evidently don't render at identical widths in points across a
    // Retina and a non-Retina mirrored menu bar, so "same order and
    // spacing" does not mean "same distance from the edge", and no
    // formula based on one screen's numbers can predict another's exactly.
    //
    // What DOES work: every screen eventually becomes the owner on its own
    // (whenever the user's focus is on it), at which point its position is
    // measured exactly. Recording those exact offsets per screen, and
    // reusing a screen's OWN last-recorded offsets whenever a different
    // screen currently owns the window, converges to perfect accuracy
    // everywhere after each screen has been the owner at least once --
    // rather than a formula that can only ever approximate.
    private func updateDotOverlayPosition() {
        guard isActive,
            let ring = ringView,
            let buttonWindow = statusItem.button?.window,
            let ownerScreen = buttonWindow.screen
        else { return }

        // macOS collapses menu extras behind a "<<"/">>" overflow chevron
        // when there isn't room for all of them -- confirmed live via a
        // screen recording: clicking Stop re-collapsed the bar, the ring
        // vanished behind the chevron, and the overlay dot just kept
        // floating at its last known position with nothing under it,
        // "living its own life". buttonWindow.isVisible was tried first,
        // but confirmed live it stayed true throughout -- the button's
        // window apparently isn't ordered out when collapsed, just moved
        // off/behind the visible area, which isVisible doesn't reflect
        // (it only means the window wants to be shown, not that it's
        // currently actually on screen). occlusionState.contains(.visible)
        // reflects whether the window is presently unoccluded and on
        // screen, which is the actual condition we need here.
        //
        // This only tells us about the OWNING screen's window, though --
        // hiding every screen's overlay whenever just that one is occluded
        // (an earlier version of this fix) was confirmed live to make the
        // dot drift on a screen whose own icon was never collapsed at all:
        // each screen's menu bar overflows independently based on its own
        // available width, so one screen's occlusion says nothing about
        // another's. Only the owning screen's overlay gets hidden here;
        // every other screen keeps using its own last-recorded offsets
        // untouched.
        // Calibration logging (round 3) settled this: occlusionState never
        // actually changes across an overflow collapse/expand on this
        // hardware (always reported .visible) -- what changes instead is
        // buttonWindow.frame itself, by hundreds of points (confirmed:
        // x alternated between 880 and 605 on the same screen). So this
        // is an ordinary (if unusually large) window move, already
        // covered by the didMove/didResize handling below and by the
        // once-a-second timer as a backstop -- not a distinct occlusion
        // case. The check stays as a real (if narrower than assumed)
        // safety net for a status item actually being fully hidden.
        let ownerIsOccluded = !buttonWindow.occlusionState.contains(.visible)

        // buttonWindow.frame.mid{X,Y} was tried here first, then the
        // (hidden while active) dotView's own layout -- but confirmed
        // live, clicking Start left the dot shifted down afterward, and it
        // never self-corrected even though the periodic timer kept
        // re-measuring every second, meaning the measurement itself was
        // consistently wrong for as long as the app stayed active, not
        // just transiently wrong once. dotView is hidden for that entire
        // duration, and a hidden view's layout isn't guaranteed to keep
        // updating live -- it can freeze at whatever it was when hiding
        // happened instead of tracking later changes, which fits exactly.
        // The ring is NEVER hidden and the dot is defined to sit exactly
        // centered on it (see the layout constraints above), so measuring
        // the ring instead gives the same target position without ever
        // reading a possibly-stale hidden view's geometry.
        //
        // Skipped entirely while occluded: the button's window frame isn't
        // meaningful while collapsed into the overflow, so measuring it now
        // would just record garbage over the last known good value.
        if !ownerIsOccluded {
            let ringFrameOnScreen = buttonWindow.convertToScreen(ring.convert(ring.bounds, to: nil))
            let dotFrameOnScreen = NSRect(x: ringFrameOnScreen.midX - 3, y: ringFrameOnScreen.midY - 3, width: 6, height: 6)
            let insetFromRight = ownerScreen.frame.maxX - dotFrameOnScreen.midX
            let heightAboveVisibleFrame = dotFrameOnScreen.midY - ownerScreen.visibleFrame.maxY
            measuredOffsetsByScreen[ObjectIdentifier(ownerScreen)] = (insetFromRight, heightAboveVisibleFrame)
        }

        let screens = NSScreen.screens
        while dotOverlayWindows.count < screens.count {
            dotOverlayWindows.append(makeDotOverlayWindow())
        }
        while dotOverlayWindows.count > screens.count {
            dotOverlayWindows.removeLast().orderOut(nil)
        }

        for (window, screen) in zip(dotOverlayWindows, screens) {
            if screen === ownerScreen && ownerIsOccluded {
                window.orderOut(nil)
                continue
            }
            // Every screen (including the owner) reads its own last-
            // recorded offsets here -- for the owner, that's the value
            // just measured and stored above. Falling back to the owning
            // screen's own entry for a screen that's never been the owner
            // itself (tried right before this) was confirmed live to be
            // worse than showing nothing: the MacBook's own icon position
            // swings by hundreds of points depending on how much its menu
            // bar is currently collapsed (confirmed via calibration
            // logging -- buttonWindow.frame.x alternated between 880 and
            // 605 on the same screen from one moment to the next), so
            // borrowing its current reading for a screen with a
            // completely different, unrelated layout produced a visibly
            // detached dot rather than an approximately-right one. No
            // entry yet means there's nothing trustworthy to show it at.
            guard let offsets = measuredOffsetsByScreen[ObjectIdentifier(screen)] else {
                window.orderOut(nil)
                continue
            }
            let idealDotOrigin = NSPoint(
                x: screen.frame.maxX - offsets.insetFromRight - 3,
                y: screen.visibleFrame.maxY + offsets.heightAboveVisibleFrame - 3
            )
            // The window's own origin can only land on a whole point
            // (confirmed live via calibration logging: a computed origin
            // of (970.0, 962.5) resulted in an actual window frame of
            // (970.0, 962.0, ...) -- rounding that away was tried and
            // still left the dot visibly off-center, since the target
            // itself genuinely sits at a half-point value here and any
            // whole-point choice is off by up to 0.5pt from it). Floor the
            // window to a whole point and hand the leftover fraction to
            // DotOverlayView to draw with instead of discarding it, so the
            // reconstructed position (window origin + fractional draw
            // offset) still lands exactly on the true target.
            let windowOrigin = NSPoint(x: idealDotOrigin.x.rounded(.down), y: idealDotOrigin.y.rounded(.down))
            let fraction = NSPoint(x: idealDotOrigin.x - windowOrigin.x, y: idealDotOrigin.y - windowOrigin.y)

            window.setFrameOrigin(windowOrigin)
            (window.contentView as? DotOverlayView)?.dotOrigin = fraction
            window.orderFrontRegardless()
        }
    }

    @objc private func repositionDotOverlay() {
        updateDotOverlayPosition()
    }

    // The button's window goes through several rapid intermediate frame
    // changes of its own during a click's highlight/press-and-release
    // animation (confirmed live: clicking Start visibly left the dot
    // shifted down afterward on one screen -- reacting to every one of
    // those intermediate frames could latch onto a not-yet-settled one
    // instead of the final, correct position). Debounce briefly so a burst
    // of move/resize notifications from one interaction only measures once
    // things have settled.
    @objc private func buttonWindowGeometryChanged() {
        dotOverlayDebounceTimer?.invalidate()
        dotOverlayDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
            self?.updateDotOverlayPosition()
        }
    }

    @objc private func quit() {
        log("StayActive: quit requested")
        NSApp.terminate(nil)
    }

    // MARK: - Icon drawing (programmatic, no SF Symbol)

    // Plain ring, always a template image so macOS tints it exactly like
    // every other menu bar icon (same color, same vibrancy blend against
    // the bar) in every appearance -- drawn once and never redrawn, since
    // its look never depends on app state. The active/inactive indicator
    // lives entirely in the separate dot views (see makeInactiveDotImage
    // and DotOverlayView) rather than here, because isTemplate re-tints an
    // entire image uniformly from its alpha mask: a single image can't have
    // a native-matching ring and an explicitly-colored dot at the same time.
    private func makeRingImage() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)

        image.lockFocus()
        defer { image.unlockFocus() }

        guard let ctx = NSGraphicsContext.current?.cgContext else { return image }

        // Whole-number inset so the circle's bounds land on exact pixel
        // boundaries in the 18x18 canvas -- a fractional inset (the
        // previous 1.8) still resolves mathematically centered, but the
        // resulting sub-pixel anti-aliasing at such a tiny size can read as
        // visually off-center. Line width is independent of this and can
        // be any thickness without affecting centering, since the stroke
        // is applied symmetrically around the (already-centered) path.
        let lineWidth: CGFloat = 1.2
        let inset: CGFloat = 2
        let circleRect = NSRect(
            x: inset,
            y: inset,
            width: size.width - inset * 2,
            height: size.height - inset * 2
        )

        ctx.setStrokeColor(NSColor.black.cgColor)
        ctx.setLineWidth(lineWidth)
        ctx.strokeEllipse(in: circleRect)

        image.isTemplate = true
        return image
    }

    // Small overlay image centered on top of the ring, shown only while
    // inactive. Always a template image so it's tinted identically to the
    // ring and reads as part of the same native-colored icon. The active
    // state's green dot is a separate floating window instead (see
    // DotOverlayView) -- two attempts to keep an explicit color drawn into
    // this same view from shifting hue on a dimmed non-key-screen menu bar
    // (disabling vibrancy, then full opacity + explicit sRGB) both failed,
    // pointing at a transform applied to the status item's own backing
    // content rather than anything fixable via this view's image.
    private func makeInactiveDotImage() -> NSImage {
        // Even-numbered size: centering a 6pt view in an 18pt one lands on
        // a whole number (6pt margin each side); an odd 7 landed on a
        // fractional 5.5pt margin.
        let size = NSSize(width: 6, height: 6)
        let image = NSImage(size: size)

        image.lockFocus()
        defer { image.unlockFocus() }

        guard let ctx = NSGraphicsContext.current?.cgContext else { return image }
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fillEllipse(in: NSRect(origin: .zero, size: size))

        image.isTemplate = true
        return image
    }

    // MARK: - Accessibility check

    private func checkAccessibilityTrust() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options: CFDictionary = [promptKey: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        log("StayActive: AXIsProcessTrustedWithOptions -> trusted = \(trusted)")
    }

    // MARK: - App Nap / idle sleep prevention

    private func beginBackgroundActivity() {
        log("StayActive: beginning ProcessInfo activity (disables App Nap)")
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Keep app responsive and prevent idle system sleep while active"
        )
    }

    private func endBackgroundActivity() {
        if let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
            activityToken = nil
            log("StayActive: ended ProcessInfo activity")
        }
    }

    // MARK: - Display sleep / screensaver prevention (IOKit)

    private func createDisplaySleepAssertion() {
        guard !hasDisplaySleepAssertion else { return }

        let reason = "StayActive prevents display sleep and screensaver" as CFString
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &displaySleepAssertionID
        )

        if result == kIOReturnSuccess {
            hasDisplaySleepAssertion = true
            log("StayActive: IOPMAssertion created (id=\(displaySleepAssertionID)) - display sleep blocked")
        } else {
            log("StayActive: IOPMAssertionCreateWithName failed, IOReturn = \(result)")
        }
    }

    private func releaseDisplaySleepAssertion() {
        guard hasDisplaySleepAssertion else { return }
        let result = IOPMAssertionRelease(displaySleepAssertionID)
        hasDisplaySleepAssertion = false
        log("StayActive: IOPMAssertionRelease -> IOReturn = \(result)")
    }

    // MARK: - Periodic activity nudge

    // If there was genuine (hardware) mouse/keyboard input more recently than
    // this, skip the synthetic nudge — it's not needed (the real input
    // already reset every app's idle timer) and skipping makes a collision
    // between our synthetic event and real input impossible by construction.
    private let collisionAvoidWindow: TimeInterval = 5.0

    private func startTimer() {
        timer?.invalidate()
        log("StayActive: starting nudge timer, interval = \(nudgeInterval)s")
        timer = Timer.scheduledTimer(withTimeInterval: nudgeInterval, repeats: true) { [weak self] _ in
            self?.nudgeIfNeeded()
        }
        // Fire once immediately so status is refreshed right away.
        nudgeIfNeeded()
    }

    private func secondsSinceLastRealInput() -> TimeInterval {
        // .hidSystemState reflects only genuine hardware-generated events,
        // so our own synthetic nudges (posted via .cghidEventTap) never
        // count here — this is real physical activity only.
        return CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
    }

    private func nudgeIfNeeded() {
        let idle = secondsSinceLastRealInput()
        if idle < collisionAvoidWindow {
            log("StayActive: skipping nudge, real input was \(String(format: "%.1f", idle))s ago")
            return
        }
        nudge()
    }

    private func nudge() {
        log("StayActive: nudge() called")

        guard let currentLocation = CGEvent(source: nil)?.location else {
            log("StayActive: nudge() could not read current mouse location")
            return
        }

        let shiftedLocation = CGPoint(x: currentLocation.x + 1, y: currentLocation.y)

        if let moveOut = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                  mouseCursorPosition: shiftedLocation, mouseButton: .left) {
            moveOut.post(tap: .cghidEventTap)
        } else {
            log("StayActive: nudge() failed to create mouse-move-out event")
        }

        if let moveBack = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                   mouseCursorPosition: currentLocation, mouseButton: .left) {
            moveBack.post(tap: .cghidEventTap)
        } else {
            log("StayActive: nudge() failed to create mouse-move-back event")
        }

        // keyCode 56 = Shift, no modifier flags, down+up. Invisible, no text is typed.
        if let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 56, keyDown: true) {
            keyDown.flags = []
            keyDown.post(tap: .cghidEventTap)
        } else {
            log("StayActive: nudge() failed to create key-down event")
        }

        if let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 56, keyDown: false) {
            keyUp.flags = []
            keyUp.post(tap: .cghidEventTap)
        } else {
            log("StayActive: nudge() failed to create key-up event")
        }

        log("StayActive: nudge() completed (mouse jiggle + shift key sent)")
    }

    // MARK: - Schedule (auto on/off by time of day)

    private func startScheduleTimer() {
        scheduleCheckTimer?.invalidate()
        scheduleCheckTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.evaluateSchedule()
        }
        evaluateSchedule()
    }

    private func evaluateSchedule() {
        guard scheduleEnabled else { return }

        let now = Date()
        let comps = Calendar.current.dateComponents([.hour, .minute], from: now)
        let nowMinutes = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)

        let start = scheduleStartMinutes
        let end = scheduleEndMinutes

        let withinSchedule: Bool
        if start == end {
            withinSchedule = true
        } else if start < end {
            withinSchedule = nowMinutes >= start && nowMinutes < end
        } else {
            // Overnight range, e.g. 22:00 -> 06:00
            withinSchedule = nowMinutes >= start || nowMinutes < end
        }

        if withinSchedule != isActive {
            setActive(withinSchedule, reason: "schedule (\(nowMinutes) min, window \(start)-\(end))")
        }
    }

    // MARK: - Inline schedule menu rows

    // All schedule rows are built once, up front, and shown/hidden via
    // isHidden from then on -- never inserted into or removed from the
    // menu's item list after that. Mutating a live NSMenu's items while it
    // might be open left the menu's hit-testing out of sync with what was
    // drawn (confirmed live: the switch only registered every other click
    // right after a rebuild). isHidden is a supported, safe toggle instead.
    private let rowWidth: CGFloat = 200

    private let hourFieldTag = 1
    private let minuteFieldTag = 2

    private func buildScheduleSwitchRow() -> NSMenuItem {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: rowWidth, height: 40))

        // Two rows, each with its own trailing control flush to the same
        // right margin: "Schedule" + switch on top, the time range +
        // disclosure chevron below it. Putting the chevron on its own
        // centered line, or crowded next to the time, both looked off --
        // mirroring the title/switch row keeps it visually consistent.
        let title = NSTextField(labelWithString: "Schedule")
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.frame = NSRect(x: 14, y: 20, width: rowWidth - 14 - 55, height: 18)
        container.addSubview(title)

        let subtitle = NSTextField(labelWithString: scheduleSubtitleText())
        subtitle.font = .systemFont(ofSize: 11, weight: .regular)
        subtitle.textColor = .secondaryLabelColor
        subtitle.frame = NSRect(x: 14, y: 4, width: rowWidth - 14 - 48, height: 14)
        container.addSubview(subtitle)
        scheduleLabelField = subtitle

        let toggle = NSSwitch()
        toggle.controlSize = .small
        toggle.state = scheduleEnabled ? .on : .off
        toggle.target = self
        toggle.action = #selector(scheduleSwitchToggled(_:))
        // sizeToFit before positioning: a frame that doesn't exactly match
        // NSSwitch's real intrinsic size leaves a dead margin around the
        // visible pill that doesn't respond to clicks. Positioning from the
        // fitted size guarantees the visible switch and its clickable area
        // are the same rect. Aligned to the title line's vertical center,
        // not the whole row.
        toggle.sizeToFit()
        // NSSwitch has no smaller controlSize than .small, so shrink the
        // frame itself a bit further (uniformly, to keep its aspect ratio
        // intact) rather than via a layer transform -- a transform leaves
        // the original, larger frame as the actual clickable area, which
        // is exactly the kind of click/visual mismatch already fixed once.
        let shrink: CGFloat = 0.82
        toggle.setFrameSize(NSSize(width: toggle.frame.width * shrink, height: toggle.frame.height * shrink))
        toggle.setFrameOrigin(NSPoint(
            x: rowWidth - 14 - toggle.frame.width,
            y: (title.frame.midY - toggle.frame.height / 2).rounded()
        ))
        container.addSubview(toggle)

        // Disclosure to reveal the Start/End/Save editing rows on demand --
        // they used to always show whenever the schedule was on, and the
        // first editable field would silently grab keyboard focus (and
        // highlight its text) the instant the menu opened, before the user
        // touched anything. Collapsed by default sidesteps both: nothing
        // focusable is visible until the user asks for it. Horizontally
        // centered under the switch (not flush to the same right margin,
        // which left it looking shifted right of the switch's visual
        // center since the switch is wider) and added last so it's topmost.
        let disclosureWidth: CGFloat = 20
        let disclosure = NSButton(frame: NSRect(
            x: (toggle.frame.midX - disclosureWidth / 2).rounded(),
            y: 1,
            width: disclosureWidth,
            height: 20
        ))
        disclosure.bezelStyle = .inline
        disclosure.isBordered = false
        disclosure.imagePosition = .imageOnly
        disclosure.image = NSImage(
            systemSymbolName: isScheduleExpanded ? "chevron.down" : "chevron.right",
            accessibilityDescription: nil
        )
        disclosure.contentTintColor = .secondaryLabelColor
        disclosure.target = self
        disclosure.action = #selector(toggleScheduleExpanded)
        // Nothing to expand while the schedule is off, so there's no point
        // showing it at all -- appears once the switch is turned on.
        disclosure.isHidden = !scheduleEnabled
        container.addSubview(disclosure)
        disclosureButton = disclosure

        let item = NSMenuItem()
        item.view = container
        scheduleRowItem = item
        return item
    }

    // Editable, so hour/minute can be typed directly (no steppers anymore --
    // once typing works there's no need for click-to-increment arrows too).
    private func makeValueField(_ text: String, tag: Int) -> NSTextField {
        let field = NSTextField(string: text)
        field.alignment = .center
        field.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        field.bezelStyle = .roundedBezel
        field.controlSize = .small
        field.delegate = self
        field.tag = tag
        return field
    }

    private func clampedTimeComponent(_ text: String, isMinute: Bool) -> Int {
        let maxValue = isMinute ? 59 : 23
        let value = Int(text.trimmingCharacters(in: .whitespaces)) ?? 0
        let clamped = min(max(value, 0), maxValue)
        guard isMinute else { return clamped }
        // Only minuteStep increments are meaningful (matches the schedule
        // check's granularity), so round typed input to the nearest one.
        return min(Int((Double(clamped) / Double(minuteStep)).rounded()) * minuteStep, 55)
    }

    // Rejects any edit that would grow the field past 2 characters or that
    // contains a non-digit, so neither a 3rd digit nor a letter is even
    // insertable, instead of only being cleaned up after the fact when the
    // field loses focus.
    func control(
        _ control: NSControl,
        textView: NSTextView,
        shouldChangeTextIn affectedCharRange: NSRange,
        replacementString: String?
    ) -> Bool {
        guard let replacementString else { return true }
        guard replacementString.allSatisfy({ $0.isNumber }) else { return false }
        let resultLength = (textView.string as NSString)
            .replacingCharacters(in: affectedCharRange, with: replacementString)
            .count
        return resultLength <= 2
    }

    // Backstop for the above: shouldChangeTextIn only intercepts normal
    // typing, not every possible way text can end up in the field (paste,
    // dictation, drag-and-drop, IME input). This runs after any of those
    // and forcibly strips non-digits / truncates to 2 chars regardless of
    // how the text got there, so nothing can slip through both.
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        let sanitized = String(field.stringValue.filter { $0.isNumber }.prefix(2))
        guard sanitized != field.stringValue else { return }
        field.stringValue = sanitized
        field.currentEditor()?.string = sanitized
        field.currentEditor()?.selectedRange = NSRange(location: sanitized.count, length: 0)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        let value = clampedTimeComponent(field.stringValue, isMinute: field.tag == minuteFieldTag)
        field.stringValue = String(format: "%02d", value)
    }

    private func makeTimeRowItem(label labelText: String, minutes: Int, isStart: Bool) -> NSMenuItem {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: rowWidth, height: 26))

        // Content block (label + fields) is centered in the row so it lines
        // up with the Save button below, which is also row-centered --
        // left-aligning just this row while Save centers under the full
        // width made the whole block look crooked/off-axis.
        let label = NSTextField(labelWithString: labelText)
        label.font = .systemFont(ofSize: 12, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: 40, y: 5, width: 34, height: 16)
        container.addSubview(label)

        let hour = minutes / 60
        let minute = minutes % 60

        let hourField = makeValueField(String(format: "%02d", hour), tag: hourFieldTag)
        hourField.frame = NSRect(x: 80, y: 3, width: 32, height: 20)
        container.addSubview(hourField)

        let colon = NSTextField(labelWithString: ":")
        colon.font = .systemFont(ofSize: 12, weight: .regular)
        colon.textColor = .secondaryLabelColor
        colon.frame = NSRect(x: 116, y: 5, width: 8, height: 16)
        container.addSubview(colon)

        let minuteField = makeValueField(String(format: "%02d", minute), tag: minuteFieldTag)
        minuteField.frame = NSRect(x: 128, y: 3, width: 32, height: 20)
        container.addSubview(minuteField)

        if isStart {
            startHourField = hourField
            startMinuteField = minuteField
        } else {
            endHourField = hourField
            endMinuteField = minuteField
        }

        let item = NSMenuItem()
        item.view = container
        return item
    }

    private func buildSaveButtonRow() -> NSMenuItem {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: rowWidth, height: 28))

        let button = NSButton(title: "Save", target: self, action: #selector(saveSchedule))
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 12, weight: .regular)
        let fittingWidth = max(button.fittingSize.width, 76)
        button.frame = NSRect(x: (rowWidth - fittingWidth) / 2, y: 2, width: fittingWidth, height: 22)
        container.addSubview(button)

        let item = NSMenuItem()
        item.view = container
        return item
    }

    private func setFieldValues(_ hourField: NSTextField?, _ minuteField: NSTextField?, minutes: Int) {
        hourField?.stringValue = String(format: "%02d", minutes / 60)
        minuteField?.stringValue = String(format: "%02d", minutes % 60)
    }

    private func updateScheduleRowsVisibility() {
        let shouldShow = scheduleEnabled && isScheduleExpanded
        let hidden = !shouldShow
        startRowItem?.isHidden = hidden
        endRowItem?.isHidden = hidden
        saveRowItem?.isHidden = hidden

        if shouldShow {
            // Reset to the persisted values in case fields were left
            // mid-edit (typed but not saved) from a previous time this was
            // shown.
            setFieldValues(startHourField, startMinuteField, minutes: scheduleStartMinutes)
            setFieldValues(endHourField, endMinuteField, minutes: scheduleEndMinutes)
        }
    }

    @objc private func toggleScheduleExpanded() {
        isScheduleExpanded.toggle()
        disclosureButton?.image = NSImage(
            systemSymbolName: isScheduleExpanded ? "chevron.down" : "chevron.right",
            accessibilityDescription: nil
        )
        log("StayActive: schedule editing rows \(isScheduleExpanded ? "expanded" : "collapsed")")
        updateScheduleRowsVisibility()
    }

    @objc private func scheduleSwitchToggled(_ sender: NSSwitch) {
        scheduleEnabled = (sender.state == .on)
        scheduleLabelField?.stringValue = scheduleSubtitleText()
        disclosureButton?.isHidden = !scheduleEnabled
        log("StayActive: schedule toggled, enabled=\(scheduleEnabled)")

        if !scheduleEnabled {
            // Nothing to expand while off; reset so it doesn't reappear
            // pre-expanded the next time the schedule is turned back on.
            isScheduleExpanded = false
            disclosureButton?.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        }

        updateScheduleRowsVisibility()
        evaluateSchedule()
    }

    @objc private func saveSchedule() {
        let startHour = clampedTimeComponent(startHourField?.stringValue ?? "0", isMinute: false)
        let startMinute = clampedTimeComponent(startMinuteField?.stringValue ?? "0", isMinute: true)
        let endHour = clampedTimeComponent(endHourField?.stringValue ?? "0", isMinute: false)
        let endMinute = clampedTimeComponent(endMinuteField?.stringValue ?? "0", isMinute: true)

        scheduleStartMinutes = startHour * 60 + startMinute
        scheduleEndMinutes = endHour * 60 + endMinute

        setFieldValues(startHourField, startMinuteField, minutes: scheduleStartMinutes)
        setFieldValues(endHourField, endMinuteField, minutes: scheduleEndMinutes)

        log("StayActive: schedule saved, start=\(scheduleStartMinutes)min, end=\(scheduleEndMinutes)min")

        scheduleLabelField?.stringValue = scheduleSubtitleText()

        // Collapse back under the disclosure once saved -- editing is done,
        // no reason to keep the fields taking up space in the menu.
        isScheduleExpanded = false
        disclosureButton?.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        updateScheduleRowsVisibility()

        evaluateSchedule()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
