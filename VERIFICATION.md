# Verification — 2026-10-04

- Built native Apple Silicon release with the installed Swift command-line tools.
- Standalone checks: 12 policy cases covering sibling/shell boundaries, hidden infrastructure and game clients, Minecraft/Jupyter/Ollama identification, watchers, protected descendants, detached ownership, PID reuse, changed parent generation, new descendants, and panel bounds across display sizes/origins.
- Earlier live fixture run: two real Node HTTP servers; stale identity refused; selected fixture terminated; sibling listener and parent shell remained alive. Only task-owned temporary processes were controlled.
- After the user requested no running ports be stopped, remaining tests were policy-only and all existing workloads remained read-only.
- Live discovery observed both PrismLauncher Minecraft servers and Foreman services, while excluding Minecraft client listeners and Gradle/agent infrastructure. Counts change as other tasks start and stop their own processes.
- Startup registration reports enabled. Actual login/reboot was not exercised.
- Native interface inspected through accessibility and screenshots, including expanded Minecraft actions. Removed the temporary preview window after feedback. Final compact 480-point panel uses an explicitly bounded native NSPanel and the app remains an accessory with no Dock icon.
- Swift formatting lint passes.
- Initial review: the scope helper could not resolve an unborn repository against an empty-tree base; independent native safety review was used. Findings on parent generations, suspended processes, bundled Ollama, rewritten restart commands, protected app supervisors, and node-backed package-manager wrappers were addressed. Process-tree operations cannot serialize arbitrary simultaneous external signals/debugger actions.

No production server shutdown, Minecraft world-save/backup cycle, or reboot was performed as a test.

## Measured efficiency follow-up

- Swift 6 strict concurrency build, 16 pure policy checks, and 10 non-vacuous read-only native/lsof comparisons pass.
- Paired scan medians: 183.86 ms before, 17.41 ms after (90.5% lower); see docs/performance/README.md for protocol and limits.
- Menu sorting and persistence verified in the native UI, then restored to Name.
- Login registration remains enabled. Existing workloads were not controlled.

- Final review: seven independent lenses completed against the performance changes with no outstanding actionable findings. Receipt: `/tmp/compound-engineering-501/ce-code-review/20261004-013544-5f9d5ca7`.
- Final installed 1.1.0 UI inspected visually: compact panel, correct ellipsis, two real services, current metrics. Signing verification passes.
- Remaining coverage limits: no deterministic AppKit exit-observer/coalescing lifecycle test; native socket race/error branches lack targeted fault injection; benchmark measures total scan cost rather than isolating native socket cost. No long-duration energy/leak soak was performed.

## Quiet-state follow-up — 1.1.1

- Installed and visually verified a 320 × 106 point quiet panel on the actual empty workload scan. Accessibility tree contains no scroll area, search, zero counters, empty Background section, or diagnostics footer.
- Quiet hidden discovery now runs every 120 seconds with 20 seconds timer tolerance (previously 30 seconds); opening the menu always requests an immediate scan. Quiet visible polling is 5 seconds; active workloads retain 3 seconds visible / 30 seconds hidden. Interval changes replace the timer only when necessary. New workloads may take up to the quiet polling interval plus timer tolerance to appear in the closed-menu badge.
- Native release build and all 16 policy checks pass. App signing verifies and login registration reports enabled. No workload was signalled.

## 2.0.0 — every process stoppable, kernel-table discovery — 2026-10-23

Measured on Fortune's Mac while other agent work kept the load average between 160 and 190. The build shell runs at nice 5, so wall-clock figures from it are pessimistic; the kernel-call costs below are what the app itself pays.

- The 1.1.1 build listed 14 workloads and refused to stop all 14 (reasons: parent shell, detached launcher, unreadable child metadata, supervisor). Those rules are gone. Only launchd, DevPorts itself, other users' processes, macOS system paths, terminals, editors, coding agents, session processes, interactive shells and game clients stay protected, and they are excluded from kill sets rather than blocking them.
- Discovery now uses `KERN_PROC_ALL` and `net.inet.tcp.pcblist_n` (one call each). On this Mac the socket table returned every listener with its owning PID, and the first-sight descriptor check confirmed all of them. Release bench, 15 steady scans over 501 processes and 14 listeners: process table 0.32 ms, socket table 0.22 ms, policy 7.5 ms, full steady scan 9.7 ms median (p95 15.5 ms); first scan 113 ms including `launchctl list`. Full distribution in `docs/performance/scan-2026-10-23.json`. The installed CLI's first `--list` over 470 processes took 162 ms of scan time.
- Policy pass before the final string-search change was 1.0 s median on the same machine; libc `memmem` over the cached lowercased command line brought it to 7.5 ms.
- 17 pure policy checks pass: sibling boundary, protected roots (agent, terminal, shell, editor), tools read-only, application helper merging, framework-embedded Python (system `/usr/bin/python3` resolves into Xcode.app and must not be treated as Xcode), browser helpers, system and foreign listeners, detached servers stoppable, launchd and Homebrew cautions, supervisor caution, npm/sh/tsx promotion, kill-set exclusion of protected descendants, Minecraft, background and AI kinds, validate() tracking live trees (new children joined, exited skipped, PID reuse and changed commands rejected), launch ownership cache transitions, text helpers, panel bounds.
- Live checks pass (run three times): two Node servers and a Python server that ignores SIGTERM under one disposable `zsh -c`; stale identity rejected; SIGTERM stops a Node server while its sibling and shell survive; the SIGTERM-ignoring server is reported as still running after 4 s, then SIGKILL ends it; stopping an exited workload fails cleanly. Earlier crashed runs leaked fixtures because `defer` does not run on a precondition failure; the checks now clean up before every failure, and the leaked fixtures were removed with `devports --kill <name>`.
- Socket parity: 12 read-only snapshots, 158 listener comparisons against lsof, every DevPorts listener matched an lsof PID in an adjacent snapshot and no twice-seen lsof port was missed.
- Installed 2.0.0 to `/Applications/DevPorts.app`, ad-hoc signature verifies after stripping Finder metadata from the copy. `~/.local/bin/devports` symlinks the binary. Screenshot of the live panel: Servers with port chips, bound-address badge, memory highlight, hover Stop button; Background lane; footer scan time 13.6 ms.
- Keyboard path verified on the installed app through System Events: ⌘F, type the disposable server's project name, ↓ selects the only row, ⌘⌫ stops it, and the server exited (`uikeys.sh`, fixture `python3 -m http.server 18422`). This found and fixed a real bug: arrow keys carry the function and numeric-pad modifier flags, so the exact empty-flag match never selected a row.
- Accessibility: rows, stop buttons, port chips, search and section headers carry `accessibilityLabel`s. System Events reports the search field's label but no names for SwiftUI buttons inside this NSHostingView panel (the `More` menu button is the exception), so a click-by-name automation of Stop was not possible; VoiceOver was not tested.
- Not exercised: Restart in Terminal, Unload via `launchctl bootout`, `brew services stop`, Quit of a GUI application, Stop all. These call the same validated paths or standard macOS APIs, but no existing workload was used to test them. Docker containers are not a data source (the daemon is not running here).
