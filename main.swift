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

final class AppDelegate: NSObject, NSApplicationDelegate, NSTextFieldDelegate {

    private var statusItem: NSStatusItem!
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
        statusItem.button?.image = makeStatusIcon(active: isActive)
        statusItem.button?.imagePosition = .imageOnly

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

        statusItem.button?.image = makeStatusIcon(active: isActive)
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

    @objc private func quit() {
        log("StayActive: quit requested")
        NSApp.terminate(nil)
    }

    // MARK: - Icon drawing (programmatic, no SF Symbol)

    private func makeStatusIcon(active: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)

        image.lockFocus()
        defer { image.unlockFocus() }

        guard let ctx = NSGraphicsContext.current?.cgContext else { return image }

        // Off state is drawn as a template image, so macOS tints it exactly
        // like every other menu bar icon (black/white, adapts automatically
        // to light/dark mode and menu bar highlighting). The active state
        // needs an explicit green, so it can't be a template image.
        let ringColor: NSColor = active
            ? NSColor(calibratedRed: 0.20, green: 0.78, blue: 0.35, alpha: 1.0)
            : NSColor.black

        let lineWidth: CGFloat = 1.6
        let inset = lineWidth / 2 + 1
        let circleRect = NSRect(
            x: inset,
            y: inset,
            width: size.width - inset * 2,
            height: size.height - inset * 2
        )

        ctx.setStrokeColor(ringColor.cgColor)
        ctx.setLineWidth(lineWidth)
        ctx.strokeEllipse(in: circleRect)

        let dotDiameter: CGFloat = 7
        let dotRect = NSRect(
            x: (size.width - dotDiameter) / 2,
            y: (size.height - dotDiameter) / 2,
            width: dotDiameter,
            height: dotDiameter
        )
        ctx.setFillColor(ringColor.cgColor)
        ctx.fillEllipse(in: dotRect)

        image.isTemplate = !active
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

        let title = NSTextField(labelWithString: "Schedule")
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.frame = NSRect(x: 14, y: 20, width: rowWidth - 14 - 55, height: 18)
        container.addSubview(title)

        // Time range on its own line below "Schedule" -- squeezing both
        // onto one line next to the switch made long ranges get truncated.
        // Kept narrow and clear of the switch's x-range (a non-interactive
        // label still captures clicks over any area its frame covers).
        let subtitle = NSTextField(labelWithString: scheduleSubtitleText())
        subtitle.font = .systemFont(ofSize: 11, weight: .regular)
        subtitle.textColor = .secondaryLabelColor
        subtitle.frame = NSRect(x: 14, y: 4, width: 90, height: 14)
        container.addSubview(subtitle)
        scheduleLabelField = subtitle

        // Disclosure to reveal the Start/End/Save editing rows on demand --
        // they used to always show whenever the schedule was on, and the
        // first editable field would silently grab keyboard focus (and
        // highlight its text) the instant the menu opened, before the user
        // touched anything. Collapsed by default sidesteps both: nothing
        // focusable is visible until the user asks for it.
        let disclosure = NSButton(
            title: isScheduleExpanded ? "▾" : "▸",
            target: self,
            action: #selector(toggleScheduleExpanded)
        )
        disclosure.isBordered = false
        disclosure.font = .systemFont(ofSize: 11, weight: .regular)
        disclosure.contentTintColor = .secondaryLabelColor
        disclosure.frame = NSRect(x: 108, y: 2, width: 18, height: 18)
        container.addSubview(disclosure)
        disclosureButton = disclosure

        let toggle = NSSwitch()
        toggle.controlSize = .small
        toggle.state = scheduleEnabled ? .on : .off
        toggle.target = self
        toggle.action = #selector(scheduleSwitchToggled(_:))
        // sizeToFit before positioning: a frame that doesn't exactly match
        // NSSwitch's real intrinsic size leaves a dead margin around the
        // visible pill that doesn't respond to clicks. Positioning from the
        // fitted size guarantees the visible switch and its clickable area
        // are the same rect. Added last so it's topmost and nothing else
        // in this view can shadow its clicks.
        toggle.sizeToFit()
        toggle.setFrameOrigin(NSPoint(
            x: rowWidth - 14 - toggle.frame.width,
            y: (container.frame.height / 2 - toggle.frame.height / 2).rounded()
        ))
        container.addSubview(toggle)

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
        disclosureButton?.title = isScheduleExpanded ? "▾" : "▸"
        log("StayActive: schedule editing rows \(isScheduleExpanded ? "expanded" : "collapsed")")
        updateScheduleRowsVisibility()
    }

    @objc private func scheduleSwitchToggled(_ sender: NSSwitch) {
        scheduleEnabled = (sender.state == .on)
        scheduleLabelField?.stringValue = scheduleSubtitleText()
        log("StayActive: schedule toggled, enabled=\(scheduleEnabled)")

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
        evaluateSchedule()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
