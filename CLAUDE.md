# CLAUDE.md — nvme-lens

See [`AGENTS.md`](AGENTS.md) for the full picture.

**Organization rules:** https://github.com/nlink-jp/.github/blob/main/CONVENTIONS.md

Rules specific to this project that are easy to get wrong:

- **`smartctl` is a test oracle, never a runtime dependency.** Product code must
  not spawn it, assume it exists, or search `PATH`. Unit tests must pass without
  smartmontools installed (ADR-0001 Decision 5).
- **Composite temperature is not the hotspot.** Judge on the maximum of
  Temperature Sensor 1..8, never on `Temperature:`.
- **USB-attached drives are unmonitorable by OS constraint.** Do not attempt
  workarounds; list them with the reason instead.
- **Serial number is the device key**, not `/dev/diskN` and not the IOService
  path. Reconcile enumeration results by serial before trusting them.
- **Read-only.** Never add anything that changes drive state.
- Keep logic in `NvmeLensCore`; `main.swift` stays a thin entry point.
- `make build`, never `swift build`, for anything that produces an artifact.
- Recursive rewrites take an absolute path (`make fmt` already does).
