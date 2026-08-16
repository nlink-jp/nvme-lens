# AGENTS.md — nvme-lens

## What this is

A macOS menu-bar application that continuously monitors NVMe SSD temperature and
endurance, records them, and notifies on threshold breaches. Single binary: no
arguments launches the menu-bar app, anything else is a CLI subcommand.

**Current state: reading works.** `list` and `status` read real SMART data
through IOKit and render JSON or a table. The SQLite store, background sampling,
notifications, and the menu-bar UI are not written yet.

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
  Report.swift            ← JSON/table rendering
  Version.swift           ← version resolution + fallback
Sources/NvmeLens/
  main.swift              ← thin entry point: parse, dispatch, exit
Tests/NvmeLensCoreTests/  ← 41 tests
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
- `icon.icns` does not exist yet; `make build-app` bundles without it and prints
  a note. Adding it is a Phase 3 task.

## Conventions

Organization rules: https://github.com/nlink-jp/.github/blob/main/CONVENTIONS.md

- Tests ship with the implementation, never after
- `README.md` and `README.ja.md` change in the same commit
- `docs/ja/*.ja.md` for prose; ADRs use the same basename in both
  `docs/en/adr/` and `docs/ja/adr/` (four-digit, per-project numbering)
- Small typed commits: `feat:`, `fix:`, `docs:`, `test:`, `chore:`
