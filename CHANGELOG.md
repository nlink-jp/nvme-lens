# Changelog

## [Unreleased]

### Added

- Project scaffold: Swift Package Manager layout with the logic in a
  `NvmeLensCore` library target and a thin `NvmeLens` executable, so the core is
  unit-testable without a device.
- `Makefile` following the org Swift SPM template (`build` / `build-app` /
  `package` / `test` / `fmt` / `clean`), version from `git describe`.
- Signing wiring: `scripts/codesign-darwin-app.sh` and
  `scripts/notarize-darwin-app.sh`, `Info.plist` with `LSUIElement` for
  menu-bar residency.
- CLI argument routing (`list` / `status` / `history` / `--version` / `--help`)
  with readable, per-case error messages and BSD-conventional exit codes
  (64 `EX_USAGE`, 69 `EX_UNAVAILABLE`).
- Version resolution that falls back to a development marker rather than
  reporting an unsubstituted Makefile placeholder.
- [RFP](docs/en/nvme-lens-rfp.md) and
  [ADR-0001](docs/en/adr/0001-iokit-direct-smart-access.md) (SMART is read
  through IOKit, never by shelling out to `smartctl`), both mirrored in
  Japanese.

- **SMART reading through IOKit** (ADR-0001): a `CNvmeSmart` C shim isolates the
  CFPlugIn COM calls to `IONVMeSMARTInterface`, enumerating by the
  `NVMe SMART Capable` property rather than by device class. Runs unprivileged.
- **NVMe log page 0x02 and Identify Controller parsers**, written against the
  NVMe specification. Apple's `NVMeSMARTData` struct could not be used: it
  reserves everything past byte 192, which is where the per-sensor temperatures
  live.
- **Hotspot temperature**: the maximum implemented Temperature Sensor, falling
  back to composite for drives that implement none (Apple's internal SSD), with
  the fallback reported rather than implied.
- **Drive classification** distinguishing monitored drives from USB-attached,
  non-NVMe, virtual, and advertised-but-unresponsive ones, each with a reason
  and, where one exists, a remedy. USB takes priority over "did not answer"
  because it is the fact a user can act on.
- `list` and `status` implemented, JSON and table output. Disk images are
  excluded from `list` by default.

  Every field was cross-checked against `smartctl` on three drives (internal
  Apple Fabric, two Thunderbolt-attached NVMe) and agrees exactly, including the
  internal drive's unusual 99% available-spare threshold.

- **SQLite history store** (`~/Library/Application Support/nvme-lens/history.sqlite`):
  per-sample temperature, per-sample wear snapshots, WAL mode, retention pruning
  for temperature (wear snapshots are kept — they are small and their long-term
  trend is the point).
- **Alert evaluation**, pure and injected with `now`, covering the four classes:
  sustained hotspot temperature, endurance degradation, any increase in media
  errors, and an abnormal power-cycle rate.
- **Minimal TOML reader** for `~/.config/nvme-lens/config.toml`. Unsupported
  syntax is rejected rather than ignored: a threshold silently dropped is a
  monitor that silently stops warning. A malformed file is an error, not a
  fallback to defaults.
- `nvme-lens sample` — one collection pass: read, persist, evaluate. Exits 1 when
  it produced alerts so a scheduled collector can notice without parsing output.
  The menu-bar app will drive the same path on a timer.
- `nvme-lens history --device <serial> --since <30m|12h|7d|4w>` with temperature
  summary and wear delta, including power cycles per powered hour.
- 80 unit tests, still with no device and no smartmontools required.

### Fixed

- Available-spare alerting no longer fires on a healthy drive. Available Spare
  Threshold is a vendor choice — 5%, 10% and **99%** were all observed on one
  machine — so a bare "within N points of the threshold" test warned about
  Apple's internal SSD while its spare was still 100%. Proximity now only counts
  once depletion has actually begun. Found by running against real hardware.

### Added (menu bar)

- **Menu-bar application** (AppKit `NSStatusItem` + `NSMenu`). The title is the
  hottest hotspot across monitored drives, prefixed `!` on a warning and `!!` on
  a critical, so the state is legible without opening the menu. Each drive gets
  a row; unmonitorable drives stay listed with their reason.
- **Timer-driven sampling** on the configured interval, added to the run loop in
  `.common` mode so an open menu does not stall collection. It drives the same
  `Sampler` as the `sample` subcommand, so GUI and CLI histories cannot diverge.
- **macOS notifications** for alerts, carrying a trigger so a notification is not
  dropped when the app exits first. Authorization is requested on the first real
  alert rather than at launch: killing the process while that prompt is
  unanswered pins the permission to denied, and launch-then-quit is exactly what
  a smoke test does.
- The version is shown in the menu.
- A failing store no longer blanks the display — the readings are still valid,
  and the menu says the history is not being written.

### Fixed

- The menu-bar app crashed on launch outside an `.app` bundle.
  `UNUserNotificationCenter.current()` raises
  `bundleProxyForCurrentProcess is nil` when the process has no bundle, which is
  every `swift build` run. UserNotifications is now skipped entirely when
  `Bundle.main.bundleIdentifier` is nil, and the menu says
  `notifications off: running unbundled` rather than staying quiet — silently not
  notifying is indistinguishable from nothing being wrong. Caught by a launch
  smoke test; all 87 unit tests passed throughout.

### Not yet implemented

- `icon.icns` (Phase 3). `make build-app` assembles the bundle without it and
  says so.

### Not yet verified

- The bundled `.app` path, where notifications are actually enabled. The
  unbundled binary is verified to launch, sample and terminate cleanly; running
  `make build-app` and exercising the signed bundle remains to be done.
