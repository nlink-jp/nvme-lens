# nvme-lens

A macOS menu-bar application that continuously monitors NVMe SSD **temperature**
and **endurance**, records them over time, and notifies on threshold breaches.

Temperature governs performance (thermal throttling). Endurance governs data
safety. Both come from the same NVMe SMART / Health Information log, and neither
is continuously visible through stock macOS tooling: `diskutil` reports only a
binary Verified / Not Supported, and `smartctl` gives a snapshot with no history.

> **Status: v0.1.0.** All of the above works. See
> [the RFP](docs/en/nvme-lens-rfp.md) for the design and
> [the changelog](CHANGELOG.md) for what was verified and how.

## Before you install: which drives can be monitored

| Attachment | Monitored | Why |
|---|---|---|
| Internal NVMe | ✅ | |
| NVMe over Thunderbolt / USB4 (PCIe) | ✅ | The drive enumerates as native NVMe |
| **NVMe or SATA in a USB enclosure** | ❌ | **Impossible on macOS** — see below |
| SATA SSD / HDD | ❌ | Out of scope |

**USB-attached drives cannot be monitored, and no software can change that.**
Darwin provides no SCSI/ATA pass-through path to USB Mass Storage devices, so
SMART commands cannot reach the drive at all — this is not a missing feature of
this tool. Moving the drive into a Thunderbolt/USB4 enclosure that tunnels PCIe
makes it fully readable.

nvme-lens still lists unmonitorable drives, with the reason, rather than hiding
them.

## Why not just read `Temperature:`

The Composite Temperature an NVMe drive reports understates its hotspot.
Measured on a WD_BLACK SN770 in a USB4 enclosure:

| State | Composite | Sensor 1 |
|---|---|---|
| Idle | 52 °C | 69 °C |
| 4 min into a sustained read | 61 °C | **82 °C** |

The drive's own warning threshold (WCTEMP, 84 °C) applies to Composite, so
`Warning Comp. Temperature Time` stayed at 0 minutes while the hotspot sat 2 °C
below the limit. A drive can report itself healthy while running hot. nvme-lens
reads Temperature Sensor 1..8 individually and judges on the maximum.

## Usage

```
nvme-lens                                   Launch the menu-bar application
nvme-lens list [--format json|table]        List drives, monitorable or not
nvme-lens status [--device <serial>]        Current-value snapshot
nvme-lens sample [--format json|table]      Record one sample, report alerts
nvme-lens history --device <serial> --since <period> [--metric temp|wear]
                                            period: 30m, 12h, 7d, 4w
nvme-lens --version                         Print the version
nvme-lens --help                            Print this message
```

Output is JSON by default, shaped to pipe into `json-to-table` or
`data-analyzer`.

Drives are addressed by **serial number**, not by `/dev/diskN` — BSD names and
IOService paths change across reconnects.

## What it notifies on

1. **Temperature** — the per-sensor maximum staying above a threshold for a
   sustained interval (momentary peaks do not fire)
2. **Endurance** — Percentage Used rising, or Available Spare falling below
   Available Spare Threshold
3. **Media errors** — any increment in Media and Data Integrity Errors
4. **Power Cycles / Unsafe Shutdowns** — abnormal growth, which exposes
   enclosure and power-management problems

## Configuration

Sectioned TOML at `~/.config/nvme-lens/config.toml`: thresholds, sampling
intervals, retention, and notification toggles.

## Requirements

- macOS 14 or later, Apple Silicon
- **No root.** No privileged helper, no daemon
- **No external dependencies.** SMART is read through IOKit directly
  ([ADR-0001](docs/en/adr/0001-iokit-direct-smart-access.md))

## Build

```sh
make build      # swift build -c release
make test       # unit tests; needs no device and no smartmontools
make build-app  # assemble and sign dist/NvmeLens.app
make package    # notarize and produce the release zip
```

> macOS releases are **Developer ID signed and Apple-notarized** (stapled). They
> launch without Gatekeeper prompts and work offline.

## Documentation

- [RFP](docs/en/nvme-lens-rfp.md) — problem statement, specification, plan
- [ADR-0001](docs/en/adr/0001-iokit-direct-smart-access.md) — why SMART is read
  through IOKit rather than by shelling out to `smartctl`

日本語版は [README.ja.md](README.ja.md) を参照してください。

## License

MIT
