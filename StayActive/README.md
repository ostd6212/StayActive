# StayActive

macOS menu bar app that simulates user activity (so Slack/Teams/Discord
don't mark you "away") and blocks display sleep / the screensaver.

All of this must be run **on your own Mac** — it uses `swiftc`, `codesign`,
`security`, `iconutil`, `tccutil` and the `log` command, none of which
exist outside macOS.

## Setup (run once, in order)

```bash
# 0. Put this folder where you want it
mkdir -p ~/Documents/StayActive
# copy main.swift, Info.plist, generate_icon.swift, build.sh, install.sh,
# watch_logs.sh, setup_certificate.sh into ~/Documents/StayActive

cd ~/Documents/StayActive

# 1. Create the app icon (Dock/Finder icon)
swift generate_icon.swift
iconutil -c icns icon.iconset
# -> produces icon.icns in this folder

# 2. Create a stable self-signed code-signing certificate via CLI only
chmod +x setup_certificate.sh
./setup_certificate.sh
security find-identity -v -p codesigning
# You must see "StayActive Dev" in the list before continuing.

# 3. Build and sign the app
chmod +x build.sh
./build.sh
codesign -dv StayActive.app
```

## Install and watch logs

Open a **second terminal window** first, and start log streaming
*before* installing/opening the app so you can see startup logs:

```bash
# Terminal A (start first, leave running)
chmod +x watch_logs.sh
./watch_logs.sh
```

```bash
# Terminal B
chmod +x install.sh
./install.sh
```

`install.sh` removes any previous `/Applications/StayActive.app`, moves
the freshly built one in, resets the app's Accessibility TCC entry, and
opens it.

## What to expect next

Right after `open /Applications/StayActive.app`, macOS will show a
system dialog asking for **Accessibility** permission — this is required
because StayActive posts synthetic mouse/keyboard events via `CGEvent`.

**This is the one step nobody can automate for you.** Apple deliberately
blocks programmatic granting of Accessibility access (including via the
Accessibility API itself) as a security boundary — a script that could
grant Accessibility permission to itself would be a sandbox escape. When
the dialog appears:

1. Click **"Open System Settings"** in the dialog.
2. In *Privacy & Security → Accessibility*, turn the toggle **on** for
   StayActive.

Because `setup_certificate.sh` produces one stable, reusable identity,
rebuilding with `build.sh` again later will keep the same code signature
and this grant should persist across rebuilds (no need to re-approve
every time you recompile) — as long as you don't regenerate the
certificate.

## Using the app

- Menu bar icon: green circle = active (nudging every 20s + blocking
  display sleep), gray = disabled.
- Menu: **Вимкнути** / **Увімкнути** toggles it, **Вийти** quits.
- Every 20 seconds while active it moves the mouse 1px and back, and
  sends a harmless Shift key down/up (keyCode 56, no modifiers) — enough
  to reset each app's own idle timer without typing or clicking anything
  visible.
- `ProcessInfo.beginActivity([.userInitiated, .idleSystemSleepDisabled])`
  disables App Nap for the process.
- An `IOPMAssertionCreateWithName` assertion
  (`kIOPMAssertionTypePreventUserIdleDisplaySleep`) blocks display sleep
  and the screensaver directly, independent of the CGEvent nudges.

## Files

| File                  | Purpose                                             |
|-----------------------|------------------------------------------------------|
| `main.swift`          | The menu bar app                                    |
| `Info.plist`          | Bundle metadata (`LSUIElement`, bundle id, etc.)    |
| `generate_icon.swift` | Draws the `.iconset` PNGs (green circle + dot)      |
| `setup_certificate.sh`| Creates & trusts the "StayActive Dev" cert via CLI  |
| `build.sh`            | Compiles, bundles, and codesigns `StayActive.app`   |
| `install.sh`          | Installs to `/Applications`, resets TCC, launches   |
| `watch_logs.sh`       | Streams `NSLog` output for the running app          |
