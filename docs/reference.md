# Bollard reference

The details behind the [README](../README.md), for 3.0.0.

## Lanes

Bollard lists every long-lived process tree that belongs to you, unless it is part of macOS, part of an application, or a terminal session you are sitting in. Recognising a program only improves its label.

- **Servers** are anything with a TCP or UDP port. Each row shows the project (its repository's name), what it runs (`next dev`, `worker.py`, `-m http.server`), port chips, the branch, who started it (Claude Code, Codex, Cursor, Terminal, launchd and others), memory, and CPU while it is busy.
- **Background** is the same without a port. Scripts, workers, watchers, tunnels, launch agents and whatever an agent is running through its shell right now. Unix-domain sockets are shown in the detail. Orphans are marked.
- **Agents** are coding-agent sessions, with the helpers each started directly (its MCP servers) counted and summed into its memory.
- **Apps** are applications that listen on a port, with their own icons. Helpers merge into their application, and Quit goes through the app.
- **System & tools** are macOS services that listen. They are shown and never signalled.
- **Recent** holds servers that went away, with Launch to run them again in Terminal with the same command and directory.

A quiet command has to live three seconds before it is listed, so one-shot commands do not flicker through. An orange port and antenna mean the port is bound to all interfaces and reachable from your network, and the count in the menu bar turns orange too.

Pills under the search box filter by launcher. With a filter active, Stop All stops only that launcher's servers. A server that outlives the shell or agent that started it still says where it came from.

## Actions

Hover a row for Stop and click twice to confirm (hold ⌥ for Force Quit). Right-click for everything else. Expand a row for the command, directory, listeners, cautions, the process tree with per-process actions, and the buttons.

| Action | What it does |
|---|---|
| Stop | SIGTERM to the kill set, then waits 4 s. Survivors are reported and Force Quit is offered. |
| Force Quit | SIGKILL, then waits 1.5 s. |
| Interrupt | SIGINT, like Ctrl-C. |
| Restart | Stops the workload, then reruns the recorded command in a new Terminal window. |
| Unload | Removes a user launch agent with `launchctl bootout`. Homebrew services use `brew services stop`. |
| Stop all, Force quit all | In the ⋯ menu, scoped by the launcher filter. |

| Key | Action |
|---|---|
| ⌃⌥B | Open the panel from anywhere, search field focused |
| ↑ ↓ | Select |
| ⏎ | Open in the browser |
| ⌘⌫ | Stop |
| ⌘⇧⌫ | Force quit |
| ⌘O | Open |
| ⌘P | Pin |
| ⌘R | Refresh |
| Esc | Close |

## Kill set and safety

The kill set is the root's tree minus protected processes and their subtrees. Protected processes are launchd, Bollard itself and whatever it is running under, other users' processes, macOS system paths, terminals and editors, login and session processes, interactive shells and the full-screen programs in them, and game clients.

Rows carry cautions instead of refusals. Examples are a launchd label that may restart the process, protected descendants that will be left running, and a suspended process that is resumed first.

Ending an agent session ends the agent and its helpers. Servers it launched through its shell are their own rows and keep running. `bollard --stop <name>` never matches an agent session (use its PID), and the MCP server never ends one.

Every signal goes through `proc_signal_with_audittoken` after re-reading start time, unique id and generation, so a reused PID is never signalled. The live tree is re-derived before signalling. New descendants are included, exited ones skipped, and a changed command or owner aborts the stop.

## Command line

```sh
bollard                        # the app
bollard --list [query]         # every lane, optionally filtered
bollard 3000                   # who owns port 3000
bollard --json [query]         # the same as JSON
bollard --stop <port|pid|name> # SIGTERM, wait 4 s, exit 2 if still running
bollard --interrupt <target>   # SIGINT
bollard --kill <target>        # SIGKILL
bollard --free-port [start]    # first free port from start (default 3000), exit 3 if none
bollard --wait-port <port> [s] # wait until the port accepts connections, exit 2 on timeout
bollard --wait-free <port> [s] # wait until the port can be bound again, exit 2 on timeout
bollard --mcp                  # MCP server on stdio
bollard --login-status         # launch-at-login state
```

Exit codes are 0 for success, 1 for bad usage, 2 for still running or timed out, and 3 for nothing matched.

`bollard --json` is the stable shape. Each row includes `name`, `runs`, `kind`, `section`, `pid`, `ports`, `listeners` (with `transport`), `sockets`, `provenance`, `origin`, `branch`, `directory`, `command`, `cautions`, `blocked`, `launchd` and `url`. `url` is `http://localhost:<port>` for web servers and `null` otherwise.

## MCP server

`bollard --mcp` speaks the Model Context Protocol over stdio with five tools.

- `list_servers`, `port_owner` and `stop_server` find and stop things.
- `free_port` returns an unused port.
- `wait_for_port` blocks until a server is ready or gone, for at most 120 s.

Every tool carries MCP annotations (read-only, destructive, idempotent). The server speaks protocol 2025-06-18 and falls back to older versions a client asks for. `free_port` and `wait_for_port` probe sockets directly rather than the process list, so they see listeners on loopback and wildcard addresses, not one bound only to a LAN address.

In the panel, the ⋯ menu copies the JSON command. "Copy for agent" on any row puts a Markdown summary (URL, PID, directory, branch, command, how to stop it) on the clipboard. "Claude Code here" and "Codex here" open a terminal in the project with the agent running.

## Controller scripts

Some services should be stopped by a script of their own, such as a game server that saves and backs up or a database with a flush step. Declare it in `~/Library/Application Support/Bollard/controllers.json`.

```json
{"controllers": [{"directory": "~/servers/world", "script": "control.py", "sha256": "…", "label": "Saves and backs up", "timeout": 60}]}
```

A process running `python control.py run` in that directory becomes the workload's root, and Stop signals the script and waits for it to finish. The script's SHA-256 must match, so an edited script loses the integration until you update the fingerprint.

## Discovery

Each scan makes two reads. `KERN_PROC_ALL` gives the process table. A walk over the descriptors of every process Bollard may inspect gives the sockets (TCP in LISTEN, bound UDP and listening Unix-domain sockets), each with the process that actually holds it. macOS 27 no longer hands the kernel's socket table to apps, so descriptors are the one source that works everywhere. Bollard never runs lsof, and like lsof it sees your own processes' sockets, not root's or other users'.

Executable path, arguments and identity are read once per process generation and reread when a process execs. Each process gets a role from where its executable lives and what it is attached to. Its command line is parsed into the program it runs, looking through interpreters, package runners and rewritten process titles, so labels match whole names and never substrings. Who started a detached process comes from macOS's responsible-process record. Only displayed workloads are sampled for memory and CPU. Branches come from `.git/HEAD` without running git.

The panel scans every 2 s while open and every 30 s while closed, slowing to 4 s and 120 s when nothing is running. A steady-state scan takes about 9 ms with 790 processes. Timings are in [performance](performance/README.md).

Source for the process identity interface is Apple's [Darwin process identity ABI](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/proc_info_private.h).

## Building and checks

```sh
./scripts/build.sh      # Apple silicon, hardened runtime, build/Bollard.app
./scripts/install.sh    # into /Applications, relaunch, link ~/.local/bin/bollard
./scripts/dmg.sh        # build/Bollard-<version>.dmg
```

Builds are ad-hoc signed by default. Set `SIGN_IDENTITY` to a Developer ID certificate and `NOTARY_PROFILE` to a notarytool keychain profile to sign and notarise for distribution.

```sh
swift build
.build/debug/BollardChecks --policy-only     # pure policy, git and controller checks
.build/debug/BollardChecks                   # adds live checks, see below
.build/release/BollardBench                  # scan timings as JSON
swift format lint -r Sources Tests Package.swift
```

The full run adds the socket walk against `lsof` parity (lsof is only the test oracle), disposable servers, a launch agent, an app bundle and stop all. The live checks create their own fixtures and remove them, including on failure, and never touch existing workloads. CI runs the build, the policy checks and the format lint. What was checked by hand for each release is in [VERIFICATION.md](../VERIFICATION.md).
