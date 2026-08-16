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

### Not yet implemented

- The IOKit SMART reader, the SQLite store, background sampling, threshold
  notifications, and the menu-bar UI. `list` / `status` / `history` currently
  exit 69.
- `icon.icns` (Phase 3). `make build-app` assembles the bundle without it and
  says so.
