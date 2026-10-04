# DevPorts

A personal, native macOS menu bar control panel for Fortune's servers and useful background workloads. SwiftUI + AppKit, a small libproc bridge, no runtime dependencies, no telemetry, no network discovery requests, no privileged helper.

The installed application lives at `/Applications/DevPorts.app`. It has no Dock icon or standalone window. Click its menu bar symbol to open the panel. Launch at login is available in the three-dot menu. Discovery refreshes every 3 seconds while open and every 30 seconds while closed; opening the panel refreshes immediately.

## Build and verification

Requires the installed Apple command-line Swift toolchain. Full Xcode is unnecessary.

```sh
./scripts/build.sh
swift run --build-system native DevPortsChecks --policy-only
swift format lint -r Sources Tests Package.swift
```

The native SwiftPM backend avoids the incomplete XCTest / macro-plugin installation on this particular Mac. Checks are a standalone Swift executable. Run `swift run --build-system native DevPortsChecks` only when you want it to create two temporary local HTTP servers, stop one, prove its sibling and parent shell survive, and clean up its own fixtures. It never intentionally controls existing workloads. No existing workloads were stopped during delivery.

Read-only CLI:

```sh
/Applications/DevPorts.app/Contents/MacOS/DevPorts --list
/Applications/DevPorts.app/Contents/MacOS/DevPorts --login-status
```

The optimized native engine is documented in [the measured performance report](docs/performance/README.md). The More menu sorts by name, memory, CPU, or uptime.

## What the numbers mean

Memory is resident memory summed across the displayed workload's process tree, not unique physical memory or GPU allocations. CPU is sampled process CPU time across that same tree; 100% means one core. The first scan has no CPU interval yet. Uptime belongs to the workload root. A transient scan failure retains the previous display but disables actions. TCP listeners and process metadata come from native Darwin APIs. The system lsof is a compatibility fallback only. Launcher labels are cached by process generation. Kernel exit notifications refresh ended workloads without waiting for the polling interval.

Minecraft clients, Gradle daemons, application helpers, coding agents, MCP servers, language servers, and notebook kernels are excluded. Background discovery is intentionally conservative. A detached PID is not automatically called an orphan: that label requires observing its original parent exit. Already-detached workloads with unknown ownership remain visible but read-only.

## Stop and restart

Stop always uses a reviewed workload boundary, never a process-group kill. Interactive shells, applications, agents and system processes are protected. Simple, noninteractive, single-command shell wrappers may belong to the workload; the interactive launching shell does not. An ambiguous supervisor, protected descendant, missing metadata, changed tree, changed executable, changed parent generation, or stale start time causes refusal.

Signals use Darwin's `proc_signal_with_audittoken`, with kernel-checked PID generation. There is no PID-only fallback. Before ordinary termination, the complete tree is revalidated and briefly quiesced parent-first; pending suspension is refused, and any quiescence created by the operation is unwound. The app sends SIGTERM, never SIGKILL, and reports when shutdown remains incomplete. This is a conservative local process tool, not an atomic kernel transaction over an entire tree; concurrent external debugger/signal activity is not something it can fully serialize.

The two existing PrismLauncher Minecraft controllers have a narrow, machine-specific integration. Their exact path, arguments, and SHA-256 fingerprint must match the locally inspected code. Stop signals only the controller, whose handler sends Minecraft's console `stop`, waits for saving, performs its backup, and cleans up its own helpers. Changes to those scripts revoke this integration until reviewed. These actual servers were inspected only; their shutdown path was not exercised during delivery because they support other running tasks.

Restart is available only when the executable/arguments/directory are recoverable. It stops successfully first, then opens the command in Terminal. The confirmation explicitly says the environment is fresh: inherited secrets, variables, and stdin are not reconstructed. Rewritten process titles and unknown detached launchers have no Restart action. Login registration is verified separately from an actual reboot.

## Sources and inspiration

- [Original DevPorts changelog](https://devports.xyz/changelog): compact workload rows, protected agents, Jupyter distinctions, provenance, background processes.
- [Apple Darwin process identity ABI](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/proc_info_private.h).
- [Apple generation-checked process lookup](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/kern_proc.c).

This build is signed locally for personal use, not notarized for public distribution.
