# AGENTS.md — nvme-lens

## What this is

A macOS menu-bar application that continuously monitors NVMe SSD temperature and
endurance, records them, and notifies on threshold breaches. Single binary: no
arguments launches the menu-bar app, anything else is a CLI subcommand.

**Current state: v0.1.0, feature-complete for the RFP's three phases.** A
menu-bar status item opens a panel; History and Settings are separate windows.
The CLI subcommands, the SQLite history and the four alert classes all work and
are verified on real hardware, notifications included.

## Build and test

```sh
make build      # swift build -c release  →  .build/release/NvmeLens
make test       # swift test — no device, no smartmontools required
make build-app  # assemble + sign dist/NvmeLens.app
make package    # notarize + dist/nvme-lens-<version>-darwin-arm64.zip
make fmt        # swift format (absolute paths, never a bare '.')
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
  launches) and a startup check at the top of `main.swift`
  (`singleInstanceDecision`, core-tested) that exits with a stderr note
  (covers direct exec / `open -n`). Side effect: to run a `dist/` build,
  quit the installed instance first — a second copy now refuses to start.
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
