# Native discovery and efficiency pass — 2026-10-04

Measurements are from Fortune's running Mac. Other tasks remained active. No existing server was stopped or restarted for these tests.

## Confirmed result

| Measurement | Before | Optimized |
|---|---:|---:|
| Full scan latency, median of paired batch medians | 183.86 ms | 17.41 ms |
| Routine discovery subprocesses | lsof + launchctl each scan | none when process ownership is unchanged |
| Idle refresh interval | 30 seconds | 30 seconds, plus kernel exit notifications |

The paired comparison alternated before/after twice, with 15 scans per batch (30 per version). Both versions reported two meaningful workloads in all four batches. The retained implementation reduces measured scan latency by **90.5%**. Executable hashes and full distributions are in `scan-comparison.json`. Changing background load and process lifetimes mean this is evidence for this Mac, not a universal benchmark. First scans/new detached identities still resolve launchd metadata and can take roughly 100 ms.

The optimized application's 60-second closed-menu sample used **16.6 ms of CPU** (0.028% of one core), with a **28.3 MB physical memory footprint**, 14 idle wakeups, and 72 interrupt wakeups. The sample's 98 MB RSS includes clean/shared resident pages and is not the same metric as memory footprint. Values are recorded in `idle-sample.json`. This short sample is not a long-duration energy or leak qualification, nor proof of an absolute minimum. CPU moved from subprocesses into the app, so the app-only CPU counters do not establish total CPU savings.

## Retained changes

- Native libproc TCP descriptor discovery for recognizable workloads and their descendants, without connecting to services.
- Launchd metadata cached by complete process identity and resolved after shell/npm wrapper promotion. No TTL-based stale PID reuse.
- Read-only lsof fallback on socket inspection errors; if both paths fail, the app reports failure and disables control actions.
- Strict Swift 6 concurrency; an actor owns scanning state, while control actions run independently and always rescan live identities.
- Kernel workload-root exit notifications plus coalesced refreshes, with no busy loop or extra polling timer. Short-lived helper exits do not trigger scan storms.
- Panel geometry and menu title update only when changed; hidden-menu polling remains slow. Outside-click monitoring exists only while the panel is visible, so ordinary desktop clicks do not wake it or reset the discovery timer.
- Resource sorting, persistent action outcomes, pinned confirmation snapshots, and a normal-quit guard during active shutdown.
- Safety scans include other owners so a foreign-owned descendant cannot disappear from the action boundary.

A broader FD sweep was rejected: it produced no demonstrated benefit and measured worse while live workloads were changing. Small string-path simplification was retained for clarity; no separate speedup is attributed to it.

## Checks and reproduction

The release builds without Swift compiler warnings (SwiftPM itself emits a deprecation notice for its native build backend). Formatting lint passes. Sixteen policy checks cover boundaries, stale identities, protected descendants, supervisor ownership, promoted-root provenance, ownership-cache failure/retry/PID reuse, and screen bounds. Ten read-only socket comparisons matched lsof and required nonempty meaningful listeners; no vacuous pass is accepted.

```sh
swift build --build-system native -c release
.build/release/DevPortsBench
.build/release/DevPortsChecks --socket-parity
swift format lint -r Sources Tests Package.swift
clang scripts/measure-usage.c -o /tmp/devports-usage
# Close the menu, then supply DevPorts' current PID:
/tmp/devports-usage PID 60
```

`--socket-parity` never signals or starts servers. It needs at least one existing recognized listener; absence is reported as unverified. Do not run the checks with no arguments if you want read-only testing: that mode creates and controls its own disposable fixtures.
