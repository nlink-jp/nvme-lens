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
- 19 unit tests covering routing, version resolution, and error-message
  distinctness. They require neither an NVMe device nor smartmontools.
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
- 41 unit tests; all parsing and classification is covered without a device.

Every field was cross-checked against `smartctl` on three drives (internal Apple
Fabric, two Thunderbolt-attached NVMe) and agrees exactly, including the internal
drive's unusual 99% available-spare threshold.

### Not yet implemented

- The SQLite store, background sampling, threshold notifications, and the
  menu-bar UI. `history` and the no-argument launch currently exit 69.
- `icon.icns` (Phase 3). `make build-app` assembles the bundle without it and
  says so.
