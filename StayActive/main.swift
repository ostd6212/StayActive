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

    func applicationDidFinishLaunching(_ notification: Notification) {
        log("StayActive: applicationDidFinishLaunching - starting up")

        setupStatusItem()
        checkAccessibilityTrust()
        beginBackgroundActivity()
        createDisplaySleepAssertion()
        startTimer()

        log("StayActive: startup complete, nudge interval = \(nudgeInterval)s")
    }

    func applicationWillTerminate(_ notification: Notification) {
        log("StayActive: applicationWillTerminate - cleaning up")
        timer?.invalidate()
        endBackgroundActivity()
        releaseDisplaySleepAssertion()
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
        isActive.toggle()
        log("StayActive: toggled, isActive = \(isActive)")

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
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
