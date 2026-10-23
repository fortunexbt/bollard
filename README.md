# DevPorts

A native macOS menu bar control panel for the servers and background workloads on this Mac. SwiftUI + AppKit, a small C bridge over Darwin's kernel tables, no runtime dependencies, no telemetry, no network requests, no privileged helper.

The installed application lives at `/Applications/DevPorts.app`. It has no Dock icon or standalone window; click its menu bar symbol to open the panel. The symbol's count is the number of dev servers, and it turns orange when one of them is reachable from the network. `devports` on the PATH is the same binary.

## What you see

Every TCP listener on the machine is accounted for, grouped into four lanes:

- **Servers**: dev workloads with a listening port, named by project directory. Framework (Next.js, Vite, Uvicorn, Wrangler, llama.cpp and so on), ports as clickable chips, bound address, memory and CPU summed over the process tree, a CPU sparkline, uptime.
- **Background**: watchers, workers, tunnels and plain scripts with no port. Orphans (whose launching parent was seen exiting) are marked.
- **Apps**: GUI applications that listen, such as browsers or password managers. Helpers are merged into their application, and Quit goes through the application itself.
- **System & tools**: root-owned or macOS daemons, plus helpers that belong to a coding agent, editor or notebook (MCP servers, language servers, kernels). Visible, never signalled from here.

A listener bound to `0.0.0.0` or `::` shows an antenna badge: it is reachable from other devices on your network.

## Stopping things

Hover a row for its Stop button; click it twice to confirm (⌥ for Force Quit). Right-click for every action. Expand a row for the command, directory, listeners, cautions, the process tree with per-process actions, and the buttons.

- **Stop** sends SIGTERM to the workload's kill set and waits up to 4 s. If something survives, the row says so and offers Force Quit prominently.
- **Force Quit** sends SIGKILL and waits 1.5 s.
- **Interrupt** sends SIGINT, the same as Ctrl-C in a terminal.
- **Restart** stops the workload and reruns the recorded command in a fresh Terminal window. It is unavailable when the command was rewritten, launchd owns the service, or the row is an application.
- **Unload** removes a user launch agent with `launchctl bootout`; Homebrew services use `brew services stop` instead.
- **Stop all servers** and **Force quit all servers** live in the ⋯ menu.

Keyboard: ↑/↓ select, ⌘⌫ stop, ⌘⇧⌫ force quit, ⌘O open the first port, ⌘F search, ⌘R refresh, Esc close.

The kill set is the root's process tree minus protected processes and their subtrees. Protected means launchd, DevPorts itself, another user's process, macOS system paths, terminals and editors, coding agents (Claude Code, Codex, Aider, Hermes, Gemini, OpenCode), login and session processes, interactive shells, and game clients. Nothing else is refused. Instead a row carries cautions: a launchd label that may restart it, a parent that may respawn it, protected descendants that will be left running, a suspended process that will be resumed first, or a Minecraft server whose save is skipped by Force Quit.

Every signal goes through `proc_signal_with_audittoken` after re-reading the process's start time, unique id and generation, so a reused PID is never signalled. Before signalling, the live tree is re-derived: descendants spawned since the last scan are included, exited ones are skipped, and a changed command or owner aborts.

The two PrismLauncher Minecraft controllers keep their audited integration: Stop signals the controller, which issues the console `stop`, waits for the world save and runs its backup. Force Quit bypasses it.

## How discovery works

Two kernel calls per scan: `KERN_PROC_ALL` for the whole process table and `net.inet.tcp.pcblist_n` for every TCP socket with its state, bound address and last owning PID. Executable path, arguments and process identity are read once per process generation and cached; only displayed workloads are sampled for memory and CPU. Socket ownership is confirmed through the owner's descriptors the first time a socket is seen, which repairs sockets inherited across a fork. Launchd labels are cached by process identity. Kernel exit notifications refresh ended workloads without waiting for the poll.

The panel polls every 2 s while open and every 30 s while closed (slower on a quiet Mac). Memory is resident memory summed across the kill set; CPU is 100% per core.

## Command line

```sh
devports --list                   # table of every lane
devports --json                   # the same as JSON, for scripts and agents
devports --stop <port|pid|name>   # SIGTERM, wait 4 s, exit 2 if still running
devports --interrupt <target>     # SIGINT
devports --kill <target>          # SIGKILL
devports --login-status
```

## Build and verification

Requires the Apple command-line Swift toolchain; Xcode is not needed.

```sh
./scripts/build.sh                                 # release build, signed app bundle in build/
swift build --build-system native                  # debug targets
.build/debug/DevPortsChecks --policy-only          # pure policy checks, touches nothing
.build/debug/DevPortsChecks --socket-parity        # read-only comparison with lsof
.build/debug/DevPortsChecks                        # creates three disposable servers and stops them
.build/release/DevPortsBench                       # scan timings as JSON
swift format lint -r Sources Tests Package.swift
```

The live checks start two Node HTTP servers and one Python server that ignores SIGTERM under a disposable shell, stop one, prove its sibling and the shell survive, show the stubborn one reported as still running, then force quit it. They never touch existing workloads. Measurements and the verification log are in `VERIFICATION.md` and `docs/performance/`.

## Sources and inspiration

- [Original DevPorts changelog](https://devports.xyz/changelog): compact rows, protected agents, Jupyter distinctions, provenance, background processes.
- [Apple XNU `in_pcb.h`, `socketvar.h`, `tcp_var.h`](https://github.com/apple-oss-distributions/xnu/tree/main/bsd): the `pcblist_n` socket table layout, also used by netstat.
- [Apple Darwin process identity ABI](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/proc_info_private.h).

This build is signed locally for personal use, not notarized for public distribution.
