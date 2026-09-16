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

    private let nudgeInterval: TimeInterval = 20.0

    // MARK: - Schedule state

    private var scheduleCheckTimer: Timer?
    private var settingsWindow: NSWindow?
    private var scheduleEnabledCheckbox: NSButton?
    private var startTimePicker: NSDatePicker?
    private var endTimePicker: NSDatePicker?

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
            title: "Налаштування…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(
            title: "Вийти",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu

        log("StayActive: status item ready")
    }

    private func toggleTitle() -> String {
        return isActive ? "Вимкнути" : "Увімкнути"
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

    private func startTimer() {
        timer?.invalidate()
        log("StayActive: starting nudge timer, interval = \(nudgeInterval)s")
        timer = Timer.scheduledTimer(withTimeInterval: nudgeInterval, repeats: true) { [weak self] _ in
            self?.nudge()
        }
        // Fire once immediately so status is refreshed right away.
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

    private func dateFromMinutes(_ minutes: Int) -> Date {
        var comps = DateComponents()
        comps.hour = minutes / 60
        comps.minute = minutes % 60
        return Calendar.current.date(from: comps) ?? Date()
    }

    private func minutesFromDate(_ date: Date) -> Int {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
    }

    // MARK: - Settings window

    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        if settingsWindow == nil {
            buildSettingsWindow()
        }
        scheduleEnabledCheckbox?.state = scheduleEnabled ? .on : .off
        startTimePicker?.dateValue = dateFromMinutes(scheduleStartMinutes)
        endTimePicker?.dateValue = dateFromMinutes(scheduleEndMinutes)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func buildSettingsWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 170),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "StayActive — Налаштування"
        window.isReleasedWhenClosed = false
        window.center()

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 170))

        let checkbox = NSButton(
            checkboxWithTitle: "Працювати за розкладом",
            target: self,
            action: #selector(scheduleCheckboxChanged)
        )
        checkbox.frame = NSRect(x: 20, y: 120, width: 280, height: 24)
        content.addSubview(checkbox)
        scheduleEnabledCheckbox = checkbox

        let startLabel = NSTextField(labelWithString: "Початок:")
        startLabel.frame = NSRect(x: 20, y: 78, width: 70, height: 24)
        content.addSubview(startLabel)

        let startPicker = NSDatePicker(frame: NSRect(x: 100, y: 74, width: 100, height: 28))
        startPicker.datePickerElements = [.hourMinute]
        startPicker.datePickerStyle = .textFieldAndStepper
        content.addSubview(startPicker)
        startTimePicker = startPicker

        let endLabel = NSTextField(labelWithString: "Кінець:")
        endLabel.frame = NSRect(x: 20, y: 38, width: 70, height: 24)
        content.addSubview(endLabel)

        let endPicker = NSDatePicker(frame: NSRect(x: 100, y: 34, width: 100, height: 28))
        endPicker.datePickerElements = [.hourMinute]
        endPicker.datePickerStyle = .textFieldAndStepper
        content.addSubview(endPicker)
        endTimePicker = endPicker

        let saveButton = NSButton(title: "Зберегти", target: self, action: #selector(saveSettings))
        saveButton.frame = NSRect(x: 210, y: 15, width: 90, height: 32)
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        content.addSubview(saveButton)

        window.contentView = content
        settingsWindow = window
    }

    @objc private func scheduleCheckboxChanged() {
        // Applied on Save, this just reflects immediate UI state.
    }

    @objc private func saveSettings() {
        scheduleEnabled = (scheduleEnabledCheckbox?.state == .on)
        if let start = startTimePicker?.dateValue {
            scheduleStartMinutes = minutesFromDate(start)
        }
        if let end = endTimePicker?.dateValue {
            scheduleEndMinutes = minutesFromDate(end)
        }

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
