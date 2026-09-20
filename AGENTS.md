# AGENTS.md — nvme-lens

## What this is

A macOS menu-bar application that continuously monitors NVMe SSD temperature and
endurance, records them, and notifies on threshold breaches. Single binary: no
arguments launches the menu-bar app, anything else is a CLI subcommand.

**Current state: released, and feature-complete for the RFP's three phases.** The
version lives in `git describe --tags` and `CHANGELOG.md`, not here — the number
that used to be written in this sentence went stale with every release. A
menu-bar status item opens a panel; History and Settings are separate windows.
The CLI subcommands, the SQLite history and the four alert classes all work and
are verified on real hardware, notifications included.

## Build and test

```sh
make build      # swift build -c release  →  .build/release/NvmeLens
make test       # swift test — no device, no smartmontools required
make build-app  # assemble + sign dist/NvmeLens.app
make package    # notarize + dist/nvme-lens-<version>-darwin-arm64.zip
make verify-release  # gate: .notarized marker + stapler validate (run before upload)
make clean
```

Never run `swift build` directly for a release artifact — `make build` is what
puts output under `dist/`.

## Structure

```
Sources/CNvmeSmart/       ← C shim: CFPlugIn COM against IONVMeSMARTInterface
  include/CNvmeSmart.h    ← buffers in, IOReturn status out; no parsing here
Sources/NvmeLensCore/     ← all logic; the parsers need no device
  CommandLineRouter.swift ← argv → Command; pure, no I/O
  SmartHealth.swift       ← log page 0x02 parser (NVMe spec offsets)
  ControllerIdentity.swift← Identify Controller parser (serial, model, WCTEMP)
  DriveInventory.swift    ← pure classification: monitored vs why not
  IOKitDeviceReader.swift ← the only type that touches the device
  AlertEvaluator.swift    ← pure alerting; `now` is injected
  HealthStore.swift       ← SQLite history (temperature + wear snapshots)
  Sampler.swift           ← one pass: read → persist → evaluate
  MetricSeries.swift      ← bucketing + gaps + axis domain, for every metric
  TemperatureSeries.swift ← the panel's six-hour window
  MenuBarPresentation.swift ← what to say; never how it looks
  LoginItem.swift         ← status → control state, as a pure mapping
  PanelToggle.swift       ← one click, two handlers (global monitor + button action): who closes, who must not reopen
  Configuration.swift     ← thresholds, as a plain value the app fills in
  Report.swift            ← JSON/table rendering
  Version.swift           ← version resolution + fallback
  SingleInstance.swift    ← singleInstanceDecision(): startup duplicate-instance guard (pure; pids in, decision out)
Sources/NvmeLens/
  main.swift              ← thin entry point: parse, dispatch, exit
  MenuBarApp.swift        ← status item, popover, windows, notifications
  AppModel.swift          ← observable state shared by the views
  Preferences.swift       ← every setting (UserDefaults); no config file exists
  PanelView / HistoryView / SettingsView  ← SwiftUI, hosted in AppKit
  StatusBarRenderer.swift ← symbol + tint for the status item
  SparklineView.swift     ← the panel's chart (AppKit drawing)
Tests/NvmeLensCoreTests/  ← core
Tests/NvmeLensTests/      ← the app target (symbol names must resolve)
docs/{en,ja}/             ← RFP and ADRs (ja mirrors en; ADRs share a basename)
scripts/                  ← codesign / notarize (copied from org templates)
Info.plist                ← ${APP_NAME}/${BUNDLE_ID}/${VERSION} substituted by make
```

The split into a library target plus a thin executable exists so the core can be
tested; executable targets are awkward to import from tests. Keep logic out of
`main.swift`.

## Gotchas

- **The release build pins the linked SDK.** macOS decides which generation of
  window chrome to draw from `LC_BUILD_VERSION`'s sdk field, and the Xcode 27 /
  Swift 6.4 `swift build` stamps it with the deployment target, not the SDK it
  compiled against — an app shipped that way draws with the previous design
  (square window corners). `make build` passes `-platform_version macos
  $(MACOS_MIN) $(MACOS_SDK)` (the minimum read from Package.swift, so it is
  stated once), and `make verify-release` fails if the built bundle's sdk is not
  the current one. Signing, notarization and every test pass either way, so the
  gate is the only thing that can catch it.
- **There is no `fmt` target, on purpose.** The code is 4-space and formatted by
  hand; it was never written under swift-format, and no configuration reproduces
  it. Measured on 2026-09-20 (Swift 6.4 toolchain): with `indentation` set to 4
  the formatter still changes 25 files / 144 lines, and 9 files / 54 lines with
  the line length relaxed as well — its pretty-printer re-lays-out line breaks,
  and that is not configurable. The `fmt` target that used to be here ran with
  no `.swift-format`, applied the tool's 2-space defaults, and rewrote all 39
  files for a change that touched three. Match the surrounding code by hand. A
  formatter can come back only together with its configuration and the one-time
  `style:` commit that brings the tree in line (org CONVENTIONS → Scaffold
  checklist → formatter hooks).
- **`smartctl` is a test oracle only.** Product code must never spawn it, assume
  it exists, or search `PATH` for it. Every unit test must pass on a machine
  with no smartmontools installed (ADR-0001 Decision 5).
- **USB-attached drives cannot be monitored, ever.** Darwin has no SCSI/ATA
  pass-through to USB Mass Storage. This is an OS constraint, not a gap to close.
  List such drives with the reason; never hide them.
- **Never judge temperature on `Temperature:` (Composite).** It understates the
  hotspot by 17–21 °C in measurement. Read Temperature Sensor 1..8 individually
  and use the maximum. The drive's own WCTEMP/CCTEMP thresholds apply to
  Composite, so the drive can call itself healthy while running hot.
- **Identify drives by serial number.** BSD names (`/dev/diskN`) and IOService
  paths change across reconnects, and `smartctl --scan`-style enumeration has
  been observed returning an unrelated device rather than the intended one.
  Reconcile any enumeration result by serial before using it.
- **`IONVMeSMARTInterface` offers only `GetIdentifyData` and `GetLogPage`.** No
  self-tests, no arbitrary admin commands. The tool is read-only by design.
- **Root is not required** — verified on real hardware. If something seems to
  need it, the diagnosis is wrong; do not add a privileged helper.
- **Available Spare Threshold is a vendor choice, not a small number.** 5%, 10%
  and 99% were all observed on one machine, so "spare is within N points of the
  threshold" is meaningless on its own — require that depletion actually began
  (spare < 100%) before proximity counts. This shipped as a false positive on the
  internal SSD and was caught only by running against real hardware.
- **The evaluator must read its baseline before the sampler writes the new row**,
  or every delta is zero forever.
- **UserNotifications needs a real `.app` bundle.** Touching
  `UNUserNotificationCenter.current()` from a bare `swift build` binary raises
  `bundleProxyForCurrentProcess is nil` and kills the process. Guard on
  `Bundle.main.bundleIdentifier != nil` and say in the UI when notifications are
  off — silence looks identical to "nothing is wrong".
- **Notification clicks launch by bundle ID — enforce a single instance.**
  Clicking a banner makes notificationd open the app via LaunchServices,
  which resolves `jp.nlink.nvme-lens` among *all* registered copies
  (`dist/` dev builds, release-verification extractions, `/Applications`)
  and may start a different copy than the running one → two menu bar
  items, double polling. Guarded at two layers:
  `LSMultipleInstancesProhibited` (Info.plist, stops LaunchServices
  launches) and a startup check in `main.swift`'s `.menuBar` branch
  (`singleInstanceDecision`, core-tested) that exits with a stderr note
  (covers direct exec / `open -n`). The guard sits *after* CLI dispatch
  on purpose: `list`/`status`/`sample`/`history` must keep working while
  the menu-bar app runs. Side effect: to run a `dist/` build's GUI,
  quit the installed instance first — a second copy now refuses to start.
- **Outside-click dismissal does not rely on `.transient` alone.** A global
  mouse-down monitor is installed while the panel is shown
  (`syncOutsideClickMonitor`). What that rests on was measured on the real app
  (macOS 27.0, 2026-09-20; 3 clicks per cell unless noted) with synthetic HID
  clicks (`CGEvent` at `.cghidEventTap`), the status item's frame from the AX
  `AXExtrasMenuBar` of the pid, panel visibility from `CGWindowList`, the
  frontmost app from both `NSWorkspace` and `lsappinfo front`, and outside
  clicks aimed only at a probe-owned window/panel or at a point just re-read
  as `AXMenuBar`:
  - **`.transient` alone** (control build, bare release binary, only the
    `addGlobalMonitorForEvents` block removed) closed the panel when the click
    landed in a window that takes activation — another app's normal window 3/3,
    the already-frontmost app's window 3/3 — and missed surfaces that take none:
    another process's non-activating panel 0/3, an empty stretch of the menu bar
    0/3. The same numbers came back in all three states tried: never activated;
    settings window open and nvme-lens made frontmost (through its own
    Settings… path) before every trial; settings opened, then closed (the
    already-frontmost case was not run with settings open). Activation history
    changed nothing. The comment that used to stand on the monitor — "does not
    reliably dismiss … once the app has been activated" — was a causal reading
    (the one status-lens's notes also carried until it was measured there), and
    no measurement supports it.
  - **As shipped** (the installed v0.1.3) all four outside surfaces
    closed 3/3 in the same cells, and a click inside the panel left it open 3/3.
  - **A click into this app's own settings window closes the panel**, on the
    shipped build and on the no-monitor control alike: 3/3 with the panel
    opened from a frontmost nvme-lens, 3/3 with another app frontmost, 3/3
    (shipped build) with nvme-lens already active after a click inside the
    panel. There is no local monitor and these cells found no need for one —
    our own window is a window that takes activation. The History window was
    not measured.
  - **`makeKey()` is what lets `.transient` work at all here, and it is not an
    activation.** With `makeKey()` removed as well, nothing closed: 0/3 on all
    four surfaces (status-lens measured the same; load-spinner did not — control
    results do not carry across apps). Opening the panel never made nvme-lens
    frontmost (18 samples from 0.15 s to 3 s after opening, over 3 openings).
    When nvme-lens *is* frontmost (settings window), clicking the status item
    hands frontmost back to the previous app (12/12) — whose windows may then
    cover the settings window.
  - **Re-clicking the status item closes the panel — through `PanelToggle`,
    not through `isShown`.** Up to v0.1.3 it did not (0/3 never activated, 0/3 after
    settings was opened and closed, 0/3 on a copy that was already running): the
    panel vanished 23–40 ms after mouse-down and was back 68–221 ms after
    it, button still held (mouse-up was posted at 300 ms). Why, from trace builds:
    on macOS 27.0 the menu bar is hosted by another process (MenuBarAgent), so a
    click on our own status item reaches the *global* monitor first — in every
    trace, active app or not — and the button's action 14–49 ms later,
    running under a synthesized `leftMouseUp` whose `eventNumber` is 0 whatever the
    mouse-down carried, so the two cannot be matched by identity. With
    `popover.animates = false` the monitor's close is immediate, and the action
    found `isShown == false` and opened the panel again. Controls: without the
    monitor the re-click closed 3/3 (twice); with the monitor but the default
    close animation `isShown` was still true when the action arrived and it
    closed 6/6 — that margin is all that keeps the installed status-lens and
    load-spinner (3/3 each) from the same defect. When nvme-lens is the active
    app (after a click inside the panel) the action sometimes never comes (3 of
    5 traced re-clicks; the other 2 reopened), which is why such re-clicks
    closed 6/6 in one run and 2/3 in others before the fix.
    - **The fix matches the two by order.** The monitor still closes on every
      global mouse-down and notes when the click was on the status item; the
      next action is that click's and is dropped (`PanelToggle`, tested). If no
      action comes, the note is void at the next mouse-down the monitor sees, so
      the monitor outlives the panel until then. `popoverDidClose` runs the same
      `syncOutsideClickMonitor`, which also removes the monitor after a close
      `.transient` made on its own (it used to linger until the next click).
    - **"On the status item" is the button's *window* frame, read at click
      time, with top-left ownership** (`statusItemOwns`). Measured by which
      points open the panel: the window is the menu bar's full 30 pt while the
      button is 22 pt, and the rows between belong to the item; the screen's
      top row is exactly `frame.maxY` and is owned; `frame.minY` (first row
      under the menu bar) and `frame.maxX` (the neighbour's first column) are
      not. `CGRect.contains` is wrong on both vertical edges. The item is as
      wide as its text, so a frame read earlier is stale within a sampling
      interval. A global monitor's `locationInWindow` is already in screen
      coordinates (`window == nil`).
    - **The note is taken only for clicks on the item**, so where item clicks
      never reach a global monitor it stays a plain toggle.
    - **Do not trade this for the animation's margin, a time window, or
      `isShown` alone** — each is the defect again under a different load.
    - **The monitor is removed in one place, which also drops the reference**
      (`removeOutsideClickMonitor`; a source test counts the call sites).
      `NSEvent.removeMonitor` over-releases a monitor it is handed twice. The
      first version of this fix crashed on the way out — Quit is a button
      *inside* the panel, `applicationWillTerminate` removed the monitor and
      kept the reference, termination closed the panel's window, and the new
      `popoverDidClose` removed it again (SIGSEGV, exit status 139; found by
      the maintainer's hand check, not by the probe, which had only ever
      terminated the app from outside with the panel closed).
    - **Verified on the fixed build** (bare release binary, same method):
      re-click closes without reopening 3/3 never activated and 3/3 after
      settings; 3/3 at each of centre, screen top row, y=1, the button's bottom
      row and the last column; 3/3 by right-click, with the next click opening.
      Active after a click inside: closed 12/12, and the click after that opened
      9/9. The four outside surfaces 3/3 in all three states, inside click stays
      open 3/3, own settings window 3/3 in all three variants. One spot does not
      toggle, before or after: the panel's arrow overlaps the item's last rows
      at its centre, and a click there is a click inside the panel (neither the
      monitor nor the action fires; eight points to the left on the same row it
      closed 3/3). Ways out, each judged by exit status and crash reports: Quit
      from the panel 3/3 clean, Quit from the panel with the History and
      Settings windows open, and an external terminate while the panel is
      open — all exit 0; History… and Settings… close the panel and leave the
      toggle and the outside click working.
  - **Only a real machine can judge any of this.** Re-verify with the method
    above; a check that only clicks another app's window passes `.transient`
    alone, one that never re-clicks the status item passes the re-click
    defect, one that never clicks inside the panel first never meets the
    re-click whose action does not come, and one that never presses the
    panel's own buttons — Quit above all — never runs the panel's close
    during termination. A probe that finds the panel as "a tall window owned
    by the pid" mistakes the History window for it; exclude titled windows.
- **`isTemplate` only works on a button's image.** An image embedded in an
  attributed string ignores it and is drawn in whatever colour it carries, which
  is why the healthy menu-bar symbol rendered grey. Symbols go in
  `statusItem.button.image`.
- **Verify SF Symbol names exist.** A name that does not resolve degrades the
  menu bar to a bullet, silently. `StatusBarRenderer.allSymbolNames` is asserted
  to resolve in the tests.
- **No configuration file.** Every setting is in the app's Settings window and
  stored in UserDefaults. A setting the UI can display but not change is worse
  than one it does not show.
- **Do not size a view against today's content.** Fixed heights broke three
  times as sections were added; declare floors and ideals and let containers
  resize.
- **`CFBundleShortVersionString` is not `$(VERSION)`.** The archive keeps the
  leading `v`, the plist must not have it, and an untagged build must not put a
  commit hash where the app prints its version. `build-app` normalises it.

## Conventions

Organization rules: https://github.com/nlink-jp/.github/blob/main/CONVENTIONS.md

- Tests ship with the implementation, never after
- `README.md` and `README.ja.md` change in the same commit
- `docs/ja/*.ja.md` for prose; ADRs use the same basename in both
  `docs/en/adr/` and `docs/ja/adr/` (four-digit, per-project numbering)
- Small typed commits: `feat:`, `fix:`, `docs:`, `test:`, `chore:`
