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

final class AppDelegate: NSObject, NSApplicationDelegate {

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
    private var topSeparatorItem: NSMenuItem?
    private var scheduleRowItem: NSMenuItem?
    private var startRowItem: NSMenuItem?
    private var endRowItem: NSMenuItem?
    private var saveRowItem: NSMenuItem?
    private var bottomSeparatorItem: NSMenuItem?
    private var startHourStepper: NSStepper?
    private var startMinuteStepper: NSStepper?
    private var endHourStepper: NSStepper?
    private var endMinuteStepper: NSStepper?
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

        let bottomSeparator = NSMenuItem.separator()
        menu.addItem(bottomSeparator)
        bottomSeparatorItem = bottomSeparator

        if scheduleEnabled {
            insertScheduleEditingRows(into: menu)
        }

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

    private func scheduleLabelText() -> String {
        guard scheduleEnabled else { return "Schedule" }
        return "Schedule (\(formatMinutes(scheduleStartMinutes))–\(formatMinutes(scheduleEndMinutes)))"
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

    // NSPopUpButton doesn't work reliably embedded in a menu item's custom
    // view -- it needs to open its own nested menu while the parent NSMenu
    // already owns mouse tracking, which is a well-known AppKit limitation
    // (confirmed live: the dropdowns didn't respond to clicks at all).
    // NSStepper doesn't have this problem since it never presents a menu of
    // its own, so hour/minute are click-to-increment/decrement instead.
    private let rowWidth: CGFloat = 260

    private let hourStepperTag = 1
    private let minuteStepperTag = 2

    private func buildScheduleSwitchRow() -> NSMenuItem {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: rowWidth, height: 26))

        let label = NSTextField(labelWithString: scheduleLabelText())
        label.frame = NSRect(x: 14, y: 4, width: rowWidth - 14 - 46, height: 18)
        label.lineBreakMode = .byTruncatingTail
        container.addSubview(label)
        scheduleLabelField = label

        let toggle = NSSwitch(frame: NSRect(x: rowWidth - 46, y: 1, width: 38, height: 24))
        toggle.state = scheduleEnabled ? .on : .off
        toggle.target = self
        toggle.action = #selector(scheduleSwitchToggled(_:))
        container.addSubview(toggle)

        let item = NSMenuItem()
        item.view = container
        scheduleRowItem = item
        return item
    }

    private func makeValueField(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.alignment = .center
        field.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        return field
    }

    @objc private func stepperChanged(_ sender: NSStepper) {
        let field: NSTextField?
        if sender === startHourStepper {
            field = startHourField
        } else if sender === startMinuteStepper {
            field = startMinuteField
        } else if sender === endHourStepper {
            field = endHourField
        } else if sender === endMinuteStepper {
            field = endMinuteField
        } else {
            field = nil
        }
        field?.stringValue = String(format: "%02d", sender.integerValue)
    }

    private func makeTimeRowItem(label labelText: String, minutes: Int, isStart: Bool) -> NSMenuItem {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: rowWidth, height: 30))

        let label = NSTextField(labelWithString: labelText)
        label.frame = NSRect(x: 14, y: 6, width: 40, height: 18)
        container.addSubview(label)

        let hour = minutes / 60
        let minute = minutes % 60

        let hourField = makeValueField(String(format: "%02d", hour))
        hourField.frame = NSRect(x: 60, y: 6, width: 26, height: 18)
        container.addSubview(hourField)

        let hourStepper = NSStepper(frame: NSRect(x: 88, y: 2, width: 19, height: 27))
        hourStepper.minValue = 0
        hourStepper.maxValue = 23
        hourStepper.increment = 1
        hourStepper.valueWraps = true
        hourStepper.integerValue = hour
        hourStepper.tag = hourStepperTag
        hourStepper.target = self
        hourStepper.action = #selector(stepperChanged(_:))
        container.addSubview(hourStepper)

        let colon = NSTextField(labelWithString: ":")
        colon.frame = NSRect(x: 112, y: 6, width: 10, height: 18)
        container.addSubview(colon)

        let minuteField = makeValueField(String(format: "%02d", minute))
        minuteField.frame = NSRect(x: 124, y: 6, width: 26, height: 18)
        container.addSubview(minuteField)

        let minuteStepper = NSStepper(frame: NSRect(x: 152, y: 2, width: 19, height: 27))
        minuteStepper.minValue = 0
        minuteStepper.maxValue = 55
        minuteStepper.increment = Double(minuteStep)
        minuteStepper.valueWraps = true
        minuteStepper.integerValue = minute
        minuteStepper.tag = minuteStepperTag
        minuteStepper.target = self
        minuteStepper.action = #selector(stepperChanged(_:))
        container.addSubview(minuteStepper)

        if isStart {
            startHourField = hourField
            startMinuteField = minuteField
            startHourStepper = hourStepper
            startMinuteStepper = minuteStepper
        } else {
            endHourField = hourField
            endMinuteField = minuteField
            endHourStepper = hourStepper
            endMinuteStepper = minuteStepper
        }

        let item = NSMenuItem()
        item.view = container
        return item
    }

    private func insertScheduleEditingRows(into menu: NSMenu) {
        guard startRowItem == nil else { return }

        let startIndex: Int
        if let scheduleRowItem, menu.items.contains(scheduleRowItem) {
            startIndex = menu.index(of: scheduleRowItem) + 1
        } else {
            startIndex = menu.items.count
        }

        let startItem = makeTimeRowItem(label: "Start", minutes: scheduleStartMinutes, isStart: true)
        menu.insertItem(startItem, at: startIndex)
        startRowItem = startItem

        let endItem = makeTimeRowItem(label: "End", minutes: scheduleEndMinutes, isStart: false)
        menu.insertItem(endItem, at: startIndex + 1)
        endRowItem = endItem

        let saveItem = NSMenuItem(title: "Save", action: #selector(saveSchedule), keyEquivalent: "")
        saveItem.target = self
        menu.insertItem(saveItem, at: startIndex + 2)
        saveRowItem = saveItem
    }

    private func removeScheduleEditingRows(from menu: NSMenu) {
        for item in [startRowItem, endRowItem, saveRowItem] {
            if let item, menu.items.contains(item) {
                menu.removeItem(item)
            }
        }
        startRowItem = nil
        endRowItem = nil
        saveRowItem = nil
        startHourStepper = nil
        startMinuteStepper = nil
        endHourStepper = nil
        endMinuteStepper = nil
        startHourField = nil
        startMinuteField = nil
        endHourField = nil
        endMinuteField = nil
    }

    @objc private func scheduleSwitchToggled(_ sender: NSSwitch) {
        scheduleEnabled = (sender.state == .on)
        scheduleLabelField?.stringValue = scheduleLabelText()
        log("StayActive: schedule toggled, enabled=\(scheduleEnabled)")

        if let menu = statusItem.menu {
            if scheduleEnabled {
                insertScheduleEditingRows(into: menu)
            } else {
                removeScheduleEditingRows(from: menu)
            }
        }

        evaluateSchedule()
    }

    @objc private func saveSchedule() {
        scheduleStartMinutes = (startHourStepper?.integerValue ?? 0) * 60 + (startMinuteStepper?.integerValue ?? 0)
        scheduleEndMinutes = (endHourStepper?.integerValue ?? 0) * 60 + (endMinuteStepper?.integerValue ?? 0)

        log("StayActive: schedule saved, start=\(scheduleStartMinutes)min, end=\(scheduleEndMinutes)min")

        scheduleLabelField?.stringValue = scheduleLabelText()
        evaluateSchedule()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
