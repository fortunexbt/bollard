# Bollard

Every server on your Mac, in the menu bar, with a Stop button that works.

Bollard is a native macOS menu bar app for people who run a lot of local servers, often started by coding agents they are not watching. It shows every TCP listener on the machine, names each one by project and git branch, says which agent or tool started it, and stops it with one click, a shortcut, a command, or a tool call from the agent itself. SwiftUI + AppKit, a small C bridge over Darwin's kernel tables, no runtime dependencies, no telemetry, no network requests, no privileged helper.

## What you see

Four lanes, plus a Recent lane of servers you can bring back:

- **Servers**: dev workloads with a listening port, named by project directory. Framework, port chips, git branch or worktree, the launcher (Claude Code, Codex, Cursor, Terminal, launchd…), memory and CPU across the process tree, a CPU sparkline, uptime.
- **Background**: watchers, workers, tunnels and scripts with no port. Orphans are marked.
- **Apps**: GUI applications that listen. Helpers merge into their application; Quit goes through the app.
- **System & tools**: macOS daemons, other users' ports, and helpers owned by an agent, editor or notebook (MCP servers, language servers, kernels). Visible, never signalled.
- **Recent**: servers that went away, with Launch to run them again in Terminal with the same command and directory.

An antenna badge means the port is bound to all interfaces and reachable from your network; the menu bar icon turns orange when a dev server is.

Pills under the search box filter by launcher. With a filter active, "Stop all" stops only that launcher's servers, so "everything Claude Code left running" is one menu item.

## Stopping things

Hover a row for Stop, click twice to confirm (⌥ for Force Quit). Right-click for everything. Expand a row for the command, directory, listeners, cautions, the process tree with per-process actions, and the buttons.

- **Stop** sends SIGTERM to the kill set and waits 4 s. Survivors are reported and Force Quit is offered.
- **Force Quit** sends SIGKILL and waits 1.5 s.
- **Interrupt** sends SIGINT, like Ctrl-C.
- **Restart** stops the workload, then reruns the recorded command in a fresh Terminal window.
- **Unload** removes a user launch agent with `launchctl bootout`; Homebrew services use `brew services stop`.
- **Stop all** and **Force quit all** in the ⋯ menu, scoped by the filter.

Keyboard: ⌃⌥B opens the panel from anywhere, ↑/↓ select, ⌘⌫ stop, ⌘⇧⌫ force quit, ⌘O open the first port, ⌘P pin, ⌘F search, ⌘R refresh, Esc close.

The kill set is the root's tree minus protected processes and their subtrees. Protected: launchd, Bollard itself, other users' processes, macOS system paths, terminals and editors, coding agents, login and session processes, interactive shells, game clients. Nothing else is refused; rows carry cautions instead (a launchd label that may restart it, a parent loop that may respawn it, protected descendants left running, a suspended process resumed first).

Every signal goes through `proc_signal_with_audittoken` after re-reading start time, unique id and generation, so a reused PID is never signalled. The live tree is re-derived before signalling: new descendants are included, exited ones skipped, a changed command or owner aborts.

## For agents

`bollard --mcp` is a Model Context Protocol server over stdio with three tools: `list_servers`, `port_owner` and `stop_server`. Register it once and your agent can check what is on port 3000 and stop it without guessing at `lsof` and `kill`:

```sh
claude mcp add -s user bollard -- ~/.local/bin/bollard --mcp
```

The ⋯ menu copies that command. "Copy for agent" on any row puts a Markdown summary (URL, PID, directory, branch, command, how to stop it) on the clipboard. "Claude Code here" and "Codex here" open a terminal in the project with the agent running.

## Command line

```sh
bollard                        # the app
bollard --list [query]         # every lane, optionally filtered
bollard 3000                   # who owns port 3000
bollard --json [query]         # the same as JSON
bollard --stop <port|pid|name> # SIGTERM, wait 4 s, exit 2 if still running
bollard --interrupt <target>   # SIGINT
bollard --kill <target>        # SIGKILL
bollard --mcp                  # MCP server on stdio
```

## Controller scripts

Some services should be stopped by a script of their own (a game server that saves and backs up, a database with a flush step). Declare it in `~/Library/Application Support/Bollard/controllers.json`:

```json
{"controllers": [{"directory": "~/servers/world", "script": "control.py", "sha256": "…", "label": "Saves and backs up", "timeout": 60}]}
```

A process running `python control.py run` in that directory becomes the workload's root; Stop signals the script and waits for it to finish. The script's SHA-256 must match, so an edited script loses the integration until you update the fingerprint.

## How discovery works

Two kernel calls per scan: `KERN_PROC_ALL` for the process table and `net.inet.tcp.pcblist_n` for every TCP socket with its state, bound address and last owning PID. Executable path, arguments and identity are read once per process generation. Socket ownership is confirmed through the owner's descriptors the first time a socket is seen. Only displayed workloads are sampled for memory and CPU. Branches come from `.git/HEAD`, no git binary. If the socket table cannot be parsed on some future macOS, Bollard falls back to lsof and says so in the footer.

The panel polls every 2 s while open and every 30 s while closed. Steady-state scans take about 10 ms on a loaded machine; see `docs/performance/`.

## Build

```sh
./scripts/build.sh      # universal (arm64 + x86_64), hardened runtime, build/Bollard.app
./scripts/install.sh    # into /Applications, relaunch, ~/.local/bin/bollard
./scripts/dmg.sh        # build/Bollard-<version>.dmg
```

Ad-hoc signed by default. Set `SIGN_IDENTITY` to a Developer ID certificate and `NOTARY_PROFILE` to a notarytool keychain profile to sign and notarize for distribution.

Checks:

```sh
swift build --build-system native
.build/debug/BollardChecks --policy-only     # pure policy, git and controller checks
.build/debug/BollardChecks --socket-parity   # read-only comparison with lsof
.build/debug/BollardChecks                   # disposable servers, a launch agent, an app bundle, stop all
.build/release/BollardBench                  # scan timings as JSON
swift format lint -r Sources Tests Package.swift
```

The live checks create their own fixtures and remove them, including on failure. They never touch existing workloads.

## Sources

- [Apple XNU `in_pcb.h`, `socketvar.h`, `tcp_var.h`](https://github.com/apple-oss-distributions/xnu/tree/main/bsd): the `pcblist_n` socket table, also used by netstat.
- [Apple Darwin process identity ABI](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/proc_info_private.h).
