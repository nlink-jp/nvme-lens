# ADR-0001: SMART Access Goes Directly Through IOKit, Not smartctl

| Field | Value |
|-------|-------|
| Status | **Accepted** |
| Date | 2026-08-17 |
| Binds | nvme-lens |
| Decision makers | nlink-jp maintainers |
| Triggered by | RFP §3 — choosing between an external dependency on smartmontools and calling IOKit directly for NVMe SMART access |

## Context

nvme-lens is a resident application that **samples the NVMe SMART / Health
Information log (0x02) every 60 seconds, continuously**. Two access paths exist
on macOS.

**Path A: spawn `smartctl` as a child process and parse its output.** This is
the smallest implementation and requires reading no NVMe specification. But it
obliges the operator to `brew install smartmontools`. This organization holds
that adoption is decided not by features but by **what the operator can
actually set up**, and requiring a prerequisite binary conflicts with that
principle head-on. smartmontools is also GPL, which complicates bundling into a
`.app`. And its output formatting can change between releases, so the parser
carries drift risk permanently.

There is a further consideration specific to this tool: **a one-shot CLI and a
resident process sampling every 60 seconds fail in qualitatively different
ways.** Drive-count × 1440 process spawns per day would run continuously, every
one of them dependent on the state of `PATH`, on Homebrew updates, and on the
signing state of a binary the tool does not own. That places the availability of
a monitoring tool in the hands of its environment.

**Path B: call IOKit's `IONVMeSMARTInterface` directly**, using
`GetIdentifyData` and `GetLogPage`. This is the very path smartctl's own Darwin
backend uses — not a new or unproven mechanism.

Two things were verified on real hardware during research:

- **Root is not required.** Running `smartctl -a` without sudo returned the
  complete field set for both an internal NVMe drive and Thunderbolt-attached
  external NVMe drives. No privileged helper tool and no root daemon need to
  enter the design
- Darwin has no SCSI/ATA pass-through path to USB Mass Storage; `-d sat` and
  friends are rejected without a single byte being sent. This constraint is
  identical under either path and therefore does not bear on the choice

## Decision

**Call IOKit's `IONVMeSMARTInterface` directly (Path B). Depend on no external
binary.**

Concretely:

1. Fetch Identify Controller via `GetIdentifyData` and use the **Serial Number
   as the device identity**. Neither the BSD name nor the IOService path
   survives a reconnect, so neither may serve as a persistent key
2. Fetch the SMART / Health Information log via `GetLogPage(0x02)` and parse the
   structure directly, per the NVMe specification
3. Read **Temperature Sensor 1..8 individually and judge on the maximum**, not
   on Composite (per RFP §7, Composite understates the hotspot by 17–21 °C)
4. Cover the parser with unit tests over known byte sequences, so that the tests
   require no physical device
5. **Use `smartctl` solely as a test oracle; never call it from product code.**
   State the boundary in the negative as well:
   - The shipped binary does not spawn `smartctl`, does not assume it exists,
     and does not search `PATH` for it
   - smartmontools is a **development-environment tool** — not a runtime
     dependency and not part of what is distributed. Operators are never asked
     to install it
   - Cross-checks that need `smartctl` live in a **separate suite that runs on
     development machines only**, kept apart from the ordinary unit test suite.
     Every unit test passes on a machine with no smartmontools installed

## Consequences

**What this buys:**

- Zero external dependencies; nothing for the operator to install, and the
  `.app` is self-contained
- No GPL entanglement, keeping distribution simple
- No output-format drift; what gets read is a spec-fixed binary structure
- No child-process spawn per sample
- No root (verified), hence no privileged helper and no daemon

**What this costs:**

- **Parsing the log page becomes our responsibility.** A misreading of the
  specification is our bug. Unit tests over known byte sequences mitigate this,
  but the expected values in those tests could themselves be wrong, so those
  expected values get validated against `smartctl` output (Decision 5).
  **This concerns the tests only; it creates no runtime dependency**
- `IONVMeSMARTInterface` exposes only `GetIdentifyData` and `GetLogPage`.
  Self-tests and arbitrary admin commands are unavailable. This does not
  conflict with the read-only stance in RFP §3, but it **forecloses ever adding
  self-test execution**
- Non-NVMe devices are unreachable — already out of scope
- Should Apple change or withdraw `IONVMeSMARTInterface`, there is no
  alternative. **Path A holds no advantage here**: smartctl uses the same
  interface and would break simultaneously. The expectation that "smartctl could
  serve as a fallback" does not hold

## Alternatives considered

**1. Spawn `smartctl` and parse its output.** Shortest implementation.
Rejected for the reasons in Context: the installation requirement conflicts with
the adoption principle, GPL bundling is awkward, output formatting drifts, and
resident sampling turns process spawning into a standing cost with a standing
dependency on the environment.

**2. IOKit primary with `smartctl` fallback.** Appears to improve coverage, but
in practice it demands two implementations and two verification efforts,
inflating Phase 1 — and as noted above both use the same interface, so **almost
no failure mode exists in which the fallback would actually help**. It purchases
complexity with no real redundancy behind it.

**3. Bundle the smartmontools binary.** Removes the operator's setup burden, but
takes on GPL distribution obligations, an additional signing and notarization
target, and a standing duty to track upstream. What it delivers is the same
"no external dependency" as Path B, at strictly higher cost.

## References

- [RFP: nvme-lens](../nvme-lens-rfp.md) — §3 Design Decisions / §7 External Platform Constraints
- smartmontools `os_darwin.cpp` — the Darwin backend handles only
  `IOATASMARTInterface` and `IONVMeSMARTInterface`, leaving SCSI unsupported
- NVM Express Base Specification — structure of the SMART / Health Information
  Log (Log Identifier 02h)
