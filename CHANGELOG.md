# Changelog

## [Unreleased]

### Fixed

- Clicking a notification banner could start a second instance (two menu
  bar items, double polling): notificationd opens the app via
  LaunchServices by bundle identifier, and with more than one registered
  copy of the .app (dev build in `dist/`, `/Applications`) it may launch
  a different copy than the running one. The app is now single-instance
  at two layers: `LSMultipleInstancesProhibited` in Info.plist stops
  LaunchServices launches, and a startup guard exits with a stderr note
  when another instance is already running (covers direct binary exec
  and `open -n`)

## v0.1.2 — 2026-08-17

### Fixed

- **The History window opened too narrow.** Its controls measure ~817 pt and the
  window opened at 720, so the row overflowed until the user widened it by hand.
  Widening the default alone would not have held — a drive's model name is not
  something this tool bounds, and a longer one would overflow whatever width was
  chosen today. The control row now wraps, the default is derived from the
  measured content with headroom, and the floor is deliberately below it so a
  narrow window is usable rather than broken.
- **A label was stranded above its own control.** The wrapping layout treats each
  child separately, and the range picker's label was handed to it apart from the
  segmented buttons — so at the minimum width "Range" sat on one line and its
  buttons on the next. Label and control are now one unit. The other two pickers
  were never affected because they carry their labels internally; this one had
  been separated earlier to stop the label wrapping one character per line, and
  that fix created this one.

  The minimum width is now asserted to exceed the widest label+control unit:
  below that, wrapping cannot help.

## v0.1.1 — 2026-08-17

### Fixed

- **The panel's graph never updated.** `SparklineView` held its data in `let`
  properties assigned at construction, and the SwiftUI wrapper's `updateNSView`
  only marked the view dirty — so once SwiftUI had built the view it redrew the
  same samples for the rest of the process's life. The History window was
  unaffected because it re-reads the store on every render, which is why the data
  looked collected but frozen.

  It never appeared in development: restarting the app to test each change
  rebuilt the view every time. It takes a machine that installs the app once and
  leaves it running. Reported from exactly such an install.

  The view now takes the new values on every update, and three tests assert that
  what it will draw actually changed — verified to fail against the previous
  implementation. A fourth test asserting `needsDisplay` was written and removed:
  a view outside a window does not retain the flag, so it measured AppKit rather
  than this code.

## v0.1.0 — 2026-08-17

First release. Continuous temperature and endurance monitoring for NVMe SSDs on
macOS, as a menu-bar application with a CLI in the same binary.

### Monitoring

- **SMART is read through IOKit directly** — no smartmontools, no external
  binary, no root, no privileged helper, no daemon
  ([ADR-0001](docs/en/adr/0001-iokit-direct-smart-access.md)). Devices are found
  by the `NVMe SMART Capable` property rather than by device class, because the
  providing class differs between internal and external controllers.
- **Per-sensor temperature, not composite.** Composite Temperature understates
  the hotspot — measured at 17–21 °C below Temperature Sensor 1 on a real drive,
  which sat 2 °C under its warning threshold while the drive reported itself
  healthy. nvme-lens reads Temperature Sensor 1..8 and judges on the maximum,
  falling back to composite only for drives that implement no sensors (Apple's
  internal SSD is one) and saying so when it does.
- The NVMe log page 0x02 and Identify Controller parsers are written against the
  specification. Apple's `NVMeSMARTData` struct is unusable here: it reserves
  everything past byte 192, which is exactly where the per-sensor temperatures
  live.
- **Drives are keyed by serial number.** BSD names and IOService paths both
  change across reconnects, and automatic enumeration was observed returning an
  unrelated device instead of the intended one.

### Coverage and its limits

- Internal NVMe and NVMe attached over Thunderbolt/USB4 (PCIe) are monitored.
- **USB-attached drives cannot be monitored on macOS at all** — Darwin has no
  SCSI/ATA pass-through to USB Mass Storage. They are listed anyway, with the
  reason and the remedy (a Thunderbolt/USB4 enclosure that tunnels PCIe), because
  a drive that silently vanishes from the list reads as broken or undetected.
- Non-NVMe devices and drives that advertise SMART capability without answering
  (an empty enclosure does this) are listed with their own reasons. Disk images
  are excluded by default.

### History and alerting

- SQLite store for per-sample temperature and per-sample wear snapshots, with
  retention pruning for temperature. Wear snapshots are kept: they are small and
  their long-term trend is the whole point.
- Four alert classes — sustained hotspot temperature, endurance degradation, any
  increase in media errors, and an abnormal power-cycle rate. The temperature
  rule requires the heat to persist, so a spike during a file copy stays silent.
- The power-cycle rule exposes what no other indicator does: a USB enclosure was
  measured cycling a drive 7.3 times per powered hour through disk sleep, where
  the same drive on Thunderbolt does zero.
- Every setting lives in the application: pinned drives, opening at login,
  notifications, sampling interval, thresholds and retention. There is no
  configuration file. Each of those decides what the *application* does, so a
  file shared with the command line only produced rows the settings window could
  display but not change (an RFP amendment — §2 originally specified TOML).

### Interface

- `nvme-lens` launches the menu-bar app. The status item is a drive symbol plus
  the temperature of whichever drives are pinned; the symbol is a template image
  while everything is healthy, so the menu bar draws it in its own colour, and
  takes orange or red only when something needs attention.
- Clicking opens a **panel** — a verdict line, a six-hour graph per pinned drive,
  the rest one line each. A **History window** reaches the retained data: up to
  ninety days, across temperature, percentage used, available spare, data
  written, power cycles, unsafe shutdowns and media errors. Stretches when the
  tool was not running are drawn as gaps rather than smoothed over, and the
  proportion of the window actually recorded is stated.
- A **Settings window** holds every setting. Nothing in it is read-only.
- `list`, `status`, `sample` and `history` are CLI subcommands of the same
  binary. JSON by default, `--format table` for reading. The command line records
  and reports; deciding what deserves a warning belongs to the application, which
  is the thing that can raise one.
- Notifications carry a trigger so they survive the app exiting. Authorization is
  requested when the user switches them on, and at launch when the preference is
  on but was never actually requested. Deferring it until the first alert means
  the request never happens while everything is healthy — so the application
  never appears in the system's notification list, cannot be configured there,
  and stays silent forever. Delivery is gated on the status the system actually
  reports, and the settings window says so when it is denied.
- The version is shown in Settings.

### Verification

Every SMART field was cross-checked against `smartctl` on three drives (one
internal, two Thunderbolt-attached) and agrees exactly — including the internal
drive's unusual 99% available-spare threshold. `smartctl` is a test oracle only;
product code never invokes it and the 125 unit tests pass on a machine with no
smartmontools installed and no NVMe device required.

Several defects were found by running against real hardware while every unit
test passed:

- Available-spare alerting fired on a healthy drive. Available Spare Threshold is
  a vendor choice — 5%, 10% and 99% were all observed on one machine — so
  proximity to it means nothing until depletion has actually begun.
- Classifying by interconnect string would have excluded the internal drive,
  which reports `Apple Fabric` rather than `PCI-Express`.
- The menu-bar app crashed on launch outside an `.app` bundle:
  `UNUserNotificationCenter.current()` raises `bundleProxyForCurrentProcess is
  nil` with no bundle. UserNotifications is now skipped in that case and the menu
  says so, since silently not notifying is indistinguishable from nothing being
  wrong.

Both the bare binary and the signed `.app` bundle were verified to launch, sample
on the timer, and terminate cleanly. Notification delivery was verified
end to end by lowering the threshold until three real alerts fired.

Using the application turned up several more, none of which the tests could have
caught:

- The first interface was an `NSMenu`. A graph, a value hierarchy and a health
  verdict all had to be forced into a list of commands; each fix — grey text,
  clipped width, an ambiguous degree sign — made the seams more obvious. It was
  replaced with a panel and separate windows.
- `isTemplate` is honoured for a button's image and ignored for an image
  embedded in an attributed string, so the "healthy" symbol kept rendering grey
  in the menu bar until it moved into the image slot.
- `internaldrive.fill.badge.exclamationmark` is not a real SF Symbol. It reads
  perfectly plausibly and silently degrades the menu bar to a bullet; every name
  the renderer can emit is now asserted to resolve.
- Sizes measured against the content of the day broke three times as content was
  added. Fixed heights were replaced with floors and ideals, and the remaining
  constants are the ones a container legitimately owns.

### Packaging

- `CFBundleShortVersionString` is normalised: the archive keeps the org's leading
  `v`, the plist does not, and an untagged build becomes `0.0.0` rather than
  putting a commit hash where the app prints its version.
- Developer ID signed with Hardened Runtime and a secure timestamp.
