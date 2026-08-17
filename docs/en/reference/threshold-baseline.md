# Measured baseline behind the default thresholds

> Measured 2026-08-17 08:46 – 2026-08-18 08:22 (23.6 hours, one-minute interval,
> no gaps) on a Mac Studio (M2 Max) running macOS 26 and nvme-lens v0.1.2.

This records where the defaults came from, so "why 78 °C?" has an answer later —
and it doubles as a **baseline to compare against**. If the same drive sits
higher than this on a future reading, something changed: the environment, the
enclosure, or the drive.

## Collection completeness

All three drives: **1443 samples over 23.6 hours, no gaps** — exactly what a
one-minute interval predicts.

That is also evidence the App Nap opt-out (`ProcessInfo.beginActivity`) works.
Without it a background-only app's timer freezes overnight and the history breaks.
A gap can only be read as "the app was not running", and nothing can fill it in
afterwards.

## Temperature

| Drive | Attachment | min | max | mean | above 78 °C | above 83 °C |
|---|---|---|---|---|---|---|
| APPLE SSD AP1024Z | Apple Fabric (internal) | 35 | 44 | 37.9 | 0 min | 0 min |
| CT1000P1SSD8 | PCI-Express (TB4 external) | 51 | 54 | 52.4 | 0 min | 0 min |
| WD_BLACK SN770 1TB | PCI-Express (TB4 external) | 67 | 71 | 68.7 | 0 min | 0 min |

Percentiles for the hottest drive (SN770): **p50 = 69 °C, p90 = 70 °C,
p99 = 71 °C**.

### Why 78 °C warning / 83 °C critical stay as they are

- **Idle steady state is 69 °C and the 24-hour maximum is 71 °C — seven degrees
  of headroom** to the threshold.
- A separate load test (about five minutes of sustained reading via `dd`)
  measured **82 °C**. So 78 °C sits where it catches heat that actually happens.
- Lower, and it fires during ordinary use. On a drive that idles at 69 °C a
  threshold near 70 would **fire constantly, and then nobody keeps it enabled**.
- Higher, and it misses real 82 °C excursions.

Seven degrees between p99 (71 °C) and the warning, four between the warning and
the measured peak (82 °C). That split is the reason for this position.

### On the five-minute dwell

Temperature is not judged instantaneously. Firing on a transient peak during a
file copy only produces notifications nobody can act on. In the load test it took
about four minutes to reach 82 °C, so a five-minute condition separates
"genuinely sustained heat" from "a spike" exactly where the measurement puts the
line.

## Power-cycle rate

| | Previous USB enclosure (RTL9210B-CG) | Current TB4 enclosure (ASM2464PD) |
|---|---|---|
| Power-cycle rate | **7.3 per hour** | **0 per hour** (23 h powered, delta 0) |
| Unsafe shutdowns | 72 cumulative | delta 0 |

The old enclosure power-cycled the drive on every `pmset disksleep` (10 minutes
by default). This machine runs with `pmset sleep 0` (prevented by sharingd and
powerd), so those cycles were confirmed to come from idle suspend rather than
system sleep.

Against the default of **2.0 per hour**, the measurement is 0 — no false
positives. And the old enclosure's 7.3 per hour clears it decisively, so the same
problem would be caught. **This is the one threshold with evidence on both
sides.**

## What is *not* verified

**Endurance indicators do not move at all over 24 hours.**

| Indicator | Change over 24 hours |
|---|---|
| Percentage Used | 3 → 3 / 3 → 3 / 0 → 0 (no change) |
| Available Spare | 100 → 100 on every drive |
| Media Errors | delta 0 on every drive |

So for these three thresholds, **the absence of false positives is confirmed and
the ability to detect is not**:

- warn when Percentage Used reaches 80%
- warn when Available Spare approaches the drive's own threshold (once depletion
  has begun)
- alert on any increase in media errors

This is not a gap in the implementation — it cannot be confirmed until
degradation begins. The unit tests exercise the decision logic against synthesised
values, but no real data stands behind it. Do not read this section as "verified".

## Incidental findings

- The internal SSD accrued only **+3 powered hours** across 23.6 real hours; it
  spends much of its time in a low-power state. The two external drives accrued
  +23, matching wall-clock.
- The internal drive wrote about **80 GB** in 24 hours; the external pair wrote
  nothing (idle for this window).

## Reproducing this

```sh
sqlite3 ~/Library/Application\\ Support/nvme-lens/history.sqlite "
SELECT d.model, COUNT(*), MIN(t.hotspot_c), MAX(t.hotspot_c), ROUND(AVG(t.hotspot_c),1)
FROM temperature_samples t JOIN drives d ON d.serial=t.serial GROUP BY t.serial;"
```

The History window shows the same thing (range 24 hours, switching metric).
