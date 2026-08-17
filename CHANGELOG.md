# Changelog

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
- Sectioned TOML config at `~/.config/nvme-lens/config.toml`. Unsupported syntax
  and malformed files are errors, never a silent fallback — a threshold quietly
  dropped is a monitor that quietly stops warning.

### Interface

- `nvme-lens` launches the menu-bar app; the title is the hottest hotspot,
  prefixed `!` / `!!` by severity. `list`, `status`, `sample` and `history` are
  CLI subcommands of the same binary. JSON output by default, `--format table`
  for reading.
- Notifications carry a trigger so they survive the app exiting, and
  authorization is requested on the first real alert rather than at launch:
  killing the process while that prompt is unanswered pins the permission to
  denied, and launch-then-quit is exactly what a smoke test does.
- The version is shown in the menu.

### Verification

Every SMART field was cross-checked against `smartctl` on three drives (one
internal, two Thunderbolt-attached) and agrees exactly — including the internal
drive's unusual 99% available-spare threshold. `smartctl` is a test oracle only;
product code never invokes it and the 87 unit tests pass on a machine with no
smartmontools installed and no NVMe device required.

Three defects were found by running against real hardware while every unit test
passed:

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
on the timer, and terminate cleanly.

### Packaging

- `CFBundleShortVersionString` is normalised: the archive keeps the org's leading
  `v`, the plist does not, and an untagged build becomes `0.0.0` rather than
  putting a commit hash where the app prints its version.
- Developer ID signed with Hardened Runtime and a secure timestamp.
