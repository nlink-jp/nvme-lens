# RFP: nvme-lens

> Generated: 2026-08-17
> Status: Draft

## 1. Problem Statement

macOS offers no practical way to monitor NVMe SSD temperature and endurance
**continuously**. `diskutil` reports SMART status only as a binary
Verified / Not Supported. `smartctl` produces a point-in-time snapshot per
invocation and keeps no history. Worse, the Composite Temperature an NVMe drive
reports understates its hotspot by 17–21 °C, so relying on the drive's own
warning threshold (WCTEMP, 84 °C) misses a real sensor reading of 82 °C. On the
endurance side, Percentage Used / Available Spare / Media and Data Integrity
Errors move only on a scale of months, so a single observation cannot locate
where degradation began. **nvme-lens is a macOS menu-bar application that
continuously monitors internal and Thunderbolt/USB4-attached NVMe drives,
records per-sensor temperature and endurance indicators over time, and notifies
on threshold breaches.** The target user is a developer who relies on external
NVMe storage day to day and cares about both performance degradation and data
safety.

Temperature bears directly on performance (thermal throttling); endurance
indicators bear directly on data safety. Both come from the same source (the
NVMe SMART / Health Information log, 0x02), yet neither is continuously visible
through stock macOS tooling.

## 2. Functional Specification

### Commands / API Surface

A single binary hosts both the GUI and the CLI (organization convention).

| Command | Purpose |
|---|---|
| `nvme-lens` (no arguments) | Launch the menu-bar application |
| `nvme-lens list` | List detected drives — **including unmonitorable ones, with the reason** |
| `nvme-lens status [--device <serial>]` | Current-value snapshot |
| `nvme-lens history --device <serial> --since <period> [--metric temp\|wear]` | Retrieve history |
| `nvme-lens --version` | Print version (required — `brew test` invokes it) |

### Input / Output

- No input; values are read directly from the device
- **JSON by default**, shaped to feed `json-to-table` / `data-analyzer` directly
- `--format table` for human-readable output

Temperature is stored as **individual Temperature Sensor 1..8 values with the
maximum exposed as a separate field**. Composite is reported alongside but never
used for threshold decisions.

### Configuration

- Sectioned TOML at `~/.config/nvme-lens/config.toml`
- Keys: thresholds (temperature + dwell time, endurance indicators), sampling
  intervals, retention, notification toggles

Defaults:

| Item | Default | Rationale |
|---|---|---|
| Temperature sampling | 60 s | Measured: +9 °C within 20 s of load onset. Fine enough not to miss peaks |
| Endurance sampling | 1 h | These indicators move only over months |
| Temperature retention | 90 days (downsampled to 10-min averages beyond 30 days) | |
| Endurance retention | Unlimited | Small volume, and long-term trend is the whole value of the metric |

### Storage

SQLite. Temperature is per-minute and endurance is per-day, so granularities are
mixed, and the central questions ("peak over the last week", "delta against the
10th of last month") are aggregate queries. SQLite avoids hand-rolling both
aggregation and downsampling.

Tables: `devices` / `samples` (temperature) / `wear_snapshots` (endurance)

### Device Identity

**Serial Number is the key.** Both the BSD name (`/dev/diskN`) and the IOService
path change across reconnects. Furthermore, auto-enumeration such as
`smartctl --scan` gives no guarantee of returning the intended device — during
the research behind this RFP it listed neither of the two attached target drives
and returned an unrelated empty caddy instead. Always reconcile enumeration
results by Serial Number before using them.

### Alerting

Four notification classes:

1. **Temperature threshold breach** — when the per-sensor maximum exceeds the
   threshold **for a sustained interval**. Momentary peaks do not fire
2. **Endurance degradation** — Percentage Used increasing, or Available Spare
   falling below Available Spare Threshold
3. **Media error occurrence** — any increment in Media and Data Integrity
   Errors. The increment itself is the event; no threshold needed
4. **Abnormal growth in Power Cycles / Unsafe Shutdowns** — exposes enclosure
   and power-management problems

Temperature alerting uses a **fixed threshold plus a dwell-time condition**.
Baseline learning is deliberately not used; see §3.

### External Dependencies

None. IOKit only — no external binaries, no external services.

**During development only**, `smartctl` serves as a reference implementation
(test oracle) for validating the parser, but **product code never calls it**.
Operators are never asked to install smartmontools, and every unit test passes on
a machine without it ([ADR-0001](adr/0001-iokit-direct-smart-access.md),
Decision 5).

## 3. Design Decisions

### Language / framework: Swift / AppKit menu bar

Same construction as `sensor-lens-gui` / `active-lens-gui` /
`claude-usage-lens-gui`. Swift is the shortest path to IOKit, and the existing
menu-bar knowledge (calling `makeKey()` on an `NSPopover`, trigger-based
notifications, `MenuBarExtra` limitations) transfers directly. Go + Wails offers
cross-platform reach, but this tool depends entirely on macOS IOKit, so that
advantage does not apply — it only adds CGO complexity.

### SMART access: IOKit `IONVMeSMARTInterface` directly (ADR candidate)

Call `GetLogPage(0x02)` (SMART / Health Information) and `GetIdentifyData`
directly. This is the same proven path smartmontools' Darwin backend uses.

Shelling out to `smartctl` and parsing its output is rejected:

- It requires the user to install `smartmontools`, which conflicts with the
  principle that adoption is decided by what the operator can set up
- smartmontools is GPL, making bundling awkward
- Output formatting can change between releases, so the parser carries drift risk

Going straight to IOKit keeps external dependencies at zero, makes the `.app`
self-contained, and keeps signing and notarization simple.

→ [ADR-0001: SMART Access Goes Directly Through IOKit, Not smartctl](adr/0001-iokit-direct-smart-access.md)

### Strictly read-only

No self-test execution, no firmware operations, nothing that changes drive
state. This structurally removes any path by which the monitoring tool could
damage what it monitors.

### No baseline learning for temperature alerts

Measurement showed Sensor 1 already at 69 °C at idle (Composite 52 °C). A naive
fixed threshold would fire constantly, hence the dwell-time condition — but
baseline-learning alerts are still rejected: they make "why did this fire?"
unanswerable and are heavier to build and to verify. Thresholds are exposed so
the operator can tune them against real measurements.

### Complements existing tools

- `sensor-lens` — source pattern for background collection plus menu-bar display
- `json-to-table` / `data-analyzer` — consumers of the JSON output
- `claude-usage-lens-gui` — menu-bar UI patterns

### Out of Scope

- **USB-attached drives** — impossible in principle (see §7)
- SATA SSDs / HDDs
- Windows / Linux
- Free-space and disk-usage monitoring (a separate problem, already well served)
- Any operation that mutates drive state

## 4. Development Plan

### Phase 1: Core

- NVMe enumeration through IOKit, keyed by Serial Number
- Parsing of `GetLogPage(0x02)` (per-sensor temperature, full endurance set)
- Detection and classification of unmonitorable devices (USB-attached,
  unsupported bus, …)
- CLI: `list` / `status` / `--version`
- Tests: unit tests over known byte sequences → expected values, plus on-device
  E2E

**Complete and valuable on its own.** It proves the values previously obtained
via `smartctl` can be read natively, which validates the premise of every later
phase on real hardware. Independently reviewable.

### Phase 2: Features

- SQLite store and background collection
- The four threshold checks and their notifications
- CLI: `history`
- Downsampling and retention
- Menu-bar GUI (drive list, temperature and endurance display, **reason shown
  for unmonitorable devices**)

The GUI sits here because for a `-lens` tool the menu bar *is* the product, and
Phase 3 would be too late. Phase 2 is heavy as a result; leave room to split it
into "collection + notification" and "GUI" when work begins.

### Phase 3: Release

- README.md / README.ja.md
- CHANGELOG.md
- Signing and notarization
- Homebrew tap registration
- Pre-release real-data E2E and on-device simulation

## 5. Required API Scopes / Permissions

No external service dependency, so API scopes, OAuth, and IAM roles: **None**.

macOS permissions:

- **Notification authorization only** (`UNUserNotificationCenter`)

**Root is not required.** Verified on real hardware during research: `smartctl -a`
run without sudo returned the complete field set for both the internal drive and
the Thunderbolt-attached external drives. No privileged helper tool and no
background daemon are needed.

## 6. Series Placement

Series: **util-series**

Reason: it belongs to the same family as `sensor-lens` / `active-lens` /
`claude-usage-lens` — macOS resident tools that collect and visualize local
state — and its naming (`-lens`), construction, and distribution form match that
group. There is no external-service integration, so cli-series does not fit; it
is neither a security tool nor an experiment.

## 7. External Platform Constraints

### USB-attached drives cannot be monitored, in principle

Darwin provides no SCSI/ATA pass-through path to USB Mass Storage devices
(smartmontools' own Darwin implementation leaves SCSI unsupported, with the
relevant accessor returning zero). On top of that, SMART over NVMe-over-USB has
no standard specification at all and depends on per-bridge vendor commands.

Coverage is therefore limited to **internal NVMe** and **NVMe attached over
Thunderbolt/USB4 via PCIe**. Because most external SSDs ship in USB enclosures,
this constraint governs adoption. The UI lists unmonitorable devices anyway, with
the reason and the remedy (a Thunderbolt enclosure makes them readable). Silently
omitting them reads as "broken" or "not detected".

### Composite Temperature understates the hotspot

Measured (WD_BLACK SN770 1TB in a USB4/TB enclosure):

| State | Composite | Sensor 1 | Sensor 2 |
|---|---|---|---|
| Idle steady state | 52 °C | 69 °C | 52 °C |
| 4 min into sustained read (peak) | 61 °C | **82 °C** | 61 °C |

A consistent 17–21 °C gap. Any implementation that monitors only Composite hides
the real thermal state.

### The drive's own warning is not trustworthy

WCTEMP (84 °C) and CCTEMP (88 °C) are thresholds **on Composite**. In the
measurement above, the hotspot reached 82 °C while Composite stayed at 61 °C and
`Warning Comp. Temperature Time` never left 0 minutes. A state where **the drive
reports itself healthy while actually running hot** is entirely normal. This is
precisely why the tool must carry its own thresholds.

### What IOKit exposes

`IONVMeSMARTInterface` provides only `GetIdentifyData` and `GetLogPage`.
Self-tests and arbitrary admin commands are not available — which does not
conflict with the strictly-read-only stance in §3.

### Other

- Killing the process while the notification authorization prompt is unanswered
  pins the permission to denied, recoverable only through System Settings. This
  shapes smoke-test design
- One report on the Apple Developer Forums describes external NVMe drives
  auto-disconnecting on macOS 26 (Tahoe); cause unidentified, repro conditions
  unknown. Worth watching, but not currently grounds to change this design

---

## Discussion Log

**Origin** — this arose while investigating how to read SMART data from a
USB-attached external SSD, which turned out to be impossible on macOS in
principle. Swapping to a Thunderbolt/USB4 PCIe enclosure solved it, and the
measurements taken along the way supply nearly every premise in this RFP.

**Tool name** — `nvme-lens` chosen. `disk-lens` and `ssd-lens` were considered,
but since USB and SATA are out of reach by construction, a name that narrows the
scope sets correct expectations. The naming itself carries part of the
constraint's explanation.

**Monitoring model** — "resident + history + threshold alerts" chosen. Peaks are
invisible without sampling (82 °C appeared only during the load run), and
Percentage Used moves only over months, so snapshot-only operation would serve
neither the temperature nor the endurance goal.

**Handling unmonitorable devices** — list them with the reason. Hiding them was
rejected: the operator would learn neither that their drive is out of scope nor
that a remedy exists. It also matches the existing stance that a deliberately
inactive state must announce itself in the UI.

**History store** — SQLite chosen. CSV (the idempotent-import pattern from
`sensor-lens`) and JSONL were considered, but mixed granularity (per-minute
temperature, per-day endurance) with period aggregation as the central question
favored not hand-rolling aggregation and downsampling.

**Temperature alert method** — fixed threshold plus dwell time. A plain fixed
threshold would fire constantly given the measured 69 °C idle, but
baseline-learning was set aside for costing explainability and adding
implementation and verification weight.

**SMART access** — IOKit direct. Shelling out to `smartctl` is the shortest
implementation but requires the operator to install smartmontools, conflicting
with the principle that adoption is decided by what the operator can set up. The
hybrid option was set aside because it doubles both implementation and
verification and inflates Phase 1. **This decision is an ADR candidate.**

**Language** — Swift / AppKit. Go + Wails buys cross-platform reach that a
fully IOKit-dependent tool cannot use, at the cost of CGO complexity.

**Device identity** — keyed by Serial Number, grounded in actually hitting a case
where auto-enumeration listed neither attached target and returned an unrelated
empty caddy. Enumeration results get reconciled by an independent identifier.

**Open item on phasing** — the GUI sits in Phase 2, which makes Phase 2 heavy.
Room is left to split it into "collection + notification" and "GUI" at kickoff.
