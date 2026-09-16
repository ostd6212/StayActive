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
    private var isActive = true

    private var activityToken: NSObjectProtocol?
    private var displaySleepAssertionID: IOPMAssertionID = 0
    private var hasDisplaySleepAssertion = false

    private let nudgeInterval: TimeInterval = 60.0

    // MARK: - Schedule state

    private var scheduleCheckTimer: Timer?
    private var settingsWindow: NSWindow?
    private var scheduleEnabledCheckbox: NSButton?
    private var startHourPopup: NSPopUpButton?
    private var startMinutePopup: NSPopUpButton?
    private var endHourPopup: NSPopUpButton?
    private var endMinutePopup: NSPopUpButton?

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

        if scheduleEnabled {
            // Start "off" and let the first schedule check decide the real
            // state, so evaluateSchedule() always sees a state change and
            // actually starts the timer/assertion when launch happens
            // inside the scheduled window.
            isActive = false
            statusItem.button?.image = makeStatusIcon(active: false)
            statusItem.menu?.item(at: 0)?.title = toggleTitle()
        } else {
            createDisplaySleepAssertion()
            startTimer()
        }

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

        menu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

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
        return isActive ? "Disable" : "Enable"
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

        let mainColor: NSColor = active
            ? NSColor(calibratedRed: 0.20, green: 0.78, blue: 0.35, alpha: 1.0)
            : NSColor(calibratedWhite: 0.6, alpha: 1.0)

        let dotColor: NSColor = active
            ? NSColor(calibratedRed: 0.0, green: 0.45, blue: 0.10, alpha: 1.0)
            : NSColor(calibratedWhite: 0.35, alpha: 1.0)

        let circleRect = NSRect(x: 1, y: 1, width: 16, height: 16)
        ctx.setFillColor(mainColor.cgColor)
        ctx.fillEllipse(in: circleRect)

        let dotDiameter: CGFloat = 6
        let dotRect = NSRect(
            x: (size.width - dotDiameter) / 2,
            y: (size.height - dotDiameter) / 2,
            width: dotDiameter,
            height: dotDiameter
        )
        ctx.setFillColor(dotColor.cgColor)
        ctx.fillEllipse(in: dotRect)

        image.isTemplate = false
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

    // MARK: - Settings window

    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        if settingsWindow == nil {
            buildSettingsWindow()
        }
        scheduleEnabledCheckbox?.state = scheduleEnabled ? .on : .off
        selectTime(scheduleStartMinutes, hourPopup: startHourPopup, minutePopup: startMinutePopup)
        selectTime(scheduleEndMinutes, hourPopup: endHourPopup, minutePopup: endMinutePopup)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func makeHourPopup(frame: NSRect) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: frame, pullsDown: false)
        popup.addItems(withTitles: (0..<24).map { String(format: "%02d", $0) })
        return popup
    }

    private func makeMinutePopup(frame: NSRect) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: frame, pullsDown: false)
        popup.addItems(withTitles: stride(from: 0, to: 60, by: minuteStep).map { String(format: "%02d", $0) })
        return popup
    }

    private func selectTime(_ minutes: Int, hourPopup: NSPopUpButton?, minutePopup: NSPopUpButton?) {
        let hour = minutes / 60
        let minute = minutes % 60
        let roundedMinuteIndex = Int((Double(minute) / Double(minuteStep)).rounded()) % (60 / minuteStep)
        hourPopup?.selectItem(at: hour)
        minutePopup?.selectItem(at: roundedMinuteIndex)
    }

    private func readTime(hourPopup: NSPopUpButton?, minutePopup: NSPopUpButton?) -> Int {
        let hour = hourPopup?.indexOfSelectedItem ?? 0
        let minuteIndex = minutePopup?.indexOfSelectedItem ?? 0
        return hour * 60 + minuteIndex * minuteStep
    }

    private func buildSettingsWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 170),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "StayActive — Settings"
        window.isReleasedWhenClosed = false
        window.center()

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 170))

        let checkbox = NSButton(
            checkboxWithTitle: "Run on a schedule",
            target: self,
            action: nil
        )
        checkbox.frame = NSRect(x: 20, y: 120, width: 280, height: 24)
        content.addSubview(checkbox)
        scheduleEnabledCheckbox = checkbox

        let startLabel = NSTextField(labelWithString: "Start:")
        startLabel.frame = NSRect(x: 20, y: 78, width: 50, height: 24)
        content.addSubview(startLabel)

        let startHour = makeHourPopup(frame: NSRect(x: 75, y: 74, width: 62, height: 26))
        content.addSubview(startHour)
        startHourPopup = startHour

        let startColon = NSTextField(labelWithString: ":")
        startColon.frame = NSRect(x: 140, y: 78, width: 12, height: 24)
        content.addSubview(startColon)

        let startMinute = makeMinutePopup(frame: NSRect(x: 155, y: 74, width: 62, height: 26))
        content.addSubview(startMinute)
        startMinutePopup = startMinute

        let endLabel = NSTextField(labelWithString: "End:")
        endLabel.frame = NSRect(x: 20, y: 38, width: 50, height: 24)
        content.addSubview(endLabel)

        let endHour = makeHourPopup(frame: NSRect(x: 75, y: 34, width: 62, height: 26))
        content.addSubview(endHour)
        endHourPopup = endHour

        let endColon = NSTextField(labelWithString: ":")
        endColon.frame = NSRect(x: 140, y: 38, width: 12, height: 24)
        content.addSubview(endColon)

        let endMinute = makeMinutePopup(frame: NSRect(x: 155, y: 34, width: 62, height: 26))
        content.addSubview(endMinute)
        endMinutePopup = endMinute

        let saveButton = NSButton(title: "Save", target: self, action: #selector(saveSettings))
        saveButton.frame = NSRect(x: 210, y: 15, width: 90, height: 32)
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        content.addSubview(saveButton)

        window.contentView = content
        settingsWindow = window
    }

    @objc private func saveSettings() {
        scheduleEnabled = (scheduleEnabledCheckbox?.state == .on)
        scheduleStartMinutes = readTime(hourPopup: startHourPopup, minutePopup: startMinutePopup)
        scheduleEndMinutes = readTime(hourPopup: endHourPopup, minutePopup: endMinutePopup)

        log("StayActive: schedule settings saved, enabled=\(scheduleEnabled), start=\(scheduleStartMinutes)min, end=\(scheduleEndMinutes)min")

        settingsWindow?.close()
        evaluateSchedule()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
