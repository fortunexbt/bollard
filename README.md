# Bollard

Everything you left running on your Mac, in the menu bar, with a Stop button that works.

![Bollard panel](docs/screenshot.png)

## Install

```sh
brew trust --cask fortunexbt/tap/bollard
brew install --cask fortunexbt/tap/bollard
```

Homebrew 7 only loads formulae, casks and commands from official taps or taps
you trust, so the first command is needed once per machine.

Or download `Bollard-<version>.dmg` from [Releases](https://github.com/fortunexbt/bollard/releases) and drag Bollard to Applications. Releases are signed with a Developer ID and notarized.

Then click the bollard in your menu bar, or press ⌃⌥B. Needs macOS 26 or later on Apple silicon.

To build from source: `./scripts/build.sh && ./scripts/install.sh` with the Xcode command-line tools.

Bollard is a native macOS menu bar app for people who run a lot of local work, much of it started by coding agents they are not watching. It shows every server, script, background job and agent session of yours, names each one by project and git branch, says what it runs and who started it, and stops it with one click, a shortcut, a command, or a tool call from the agent itself. SwiftUI on Liquid Glass, a small C bridge over Darwin's process interfaces, no runtime dependencies, no telemetry, no network requests, no privileged helper.

## What you see

Bollard does not keep a list of programs it knows. Every long-lived process tree that belongs to you is listed, unless it is part of macOS, part of an application, or a terminal session you are sitting in. A compiled binary, a `python -c` one-liner or a shell loop shows up the same way a Next.js server does; recognising the program only improves the label.

- **Servers**: anything with a TCP or UDP port. The project (its repository's name), what it runs (`next dev`, `worker.py`, `-m http.server`), port chips, the branch, who started it (Claude Code, Codex, Cursor, Terminal, launchd…), memory, and CPU while it is busy.
- **Background**: the same, without a port: scripts, workers, watchers, tunnels, launch agents, whatever an agent is running through its shell right now. Unix-domain sockets are shown in the detail. Orphans are marked.
- **Agents**: each coding-agent session, with the helpers it started directly (its MCP servers) counted and summed into its memory.
- **Apps**: applications that listen on a port, with their own icons. Helpers merge into their application; Quit goes through the app.
- **System & tools**: macOS services that listen. Visible, never signalled.
- **Recent**: servers that went away, with Launch to run them again in Terminal with the same command and directory.

A quiet command has to live three seconds before it is listed, so one-shot commands do not flicker through. An orange port and antenna mean the port is bound to all interfaces and reachable from your network; the count in the menu bar turns orange too.

Pills under the search box filter by launcher. With a filter active, "Stop All" stops only that launcher's servers, so "everything Claude Code left running" is one menu item. A server that outlives the shell or agent that started it still says where it came from.

## Stopping things

Hover a row for Stop, click twice to confirm (⌥ for Force Quit). Right-click for everything. Expand a row for the command, directory, listeners, cautions, the process tree with per-process actions, and the buttons.

- **Stop** sends SIGTERM to the kill set and waits 4 s. Survivors are reported and Force Quit is offered.
- **Force Quit** sends SIGKILL and waits 1.5 s.
- **Interrupt** sends SIGINT, like Ctrl-C.
- **Restart** stops the workload, then reruns the recorded command in a fresh Terminal window.
- **Unload** removes a user launch agent with `launchctl bootout`; Homebrew services use `brew services stop`.
- **Stop all** and **Force quit all** in the ⋯ menu, scoped by the filter.

Keyboard: ⌃⌥B opens the panel from anywhere with the search field focused, ↑/↓ select, ⏎ open in the browser, ⌘⌫ stop, ⌘⇧⌫ force quit, ⌘O open, ⌘P pin, ⌘R refresh, Esc close.

The kill set is the root's tree minus protected processes and their subtrees. Protected: launchd, Bollard itself and whatever it is running under, other users' processes, macOS system paths, terminals and editors, login and session processes, interactive shells and the full-screen programs in them, game clients. Rows carry cautions instead of refusals (a launchd label that may restart it, protected descendants left running, a suspended process resumed first).

Ending an agent session ends the agent and its helpers. Servers it launched through its shell are their own rows and keep running. `bollard --stop <name>` never matches an agent session (use its PID), and the MCP server never ends one.

Every signal goes through `proc_signal_with_audittoken` after re-reading start time, unique id and generation, so a reused PID is never signalled. The live tree is re-derived before signalling: new descendants are included, exited ones skipped, a changed command or owner aborts.

## For agents

`bollard --mcp` is a Model Context Protocol server over stdio with five tools. `list_servers`, `port_owner` and `stop_server` find and stop things. `free_port` returns an unused port and `wait_for_port` blocks until a server is ready or gone, so an agent never sleeps and guesses. Register it once and your agent can check what is on port 3000 and stop it without guessing at `lsof` and `kill`:

```sh
claude mcp add -s user bollard -- ~/.local/bin/bollard --mcp
```

Every tool carries MCP annotations (read-only, destructive, idempotent), and the server speaks protocol 2025-06-18 and falls back to older versions a client asks for. `free_port` and `wait_for_port` probe sockets directly rather than the process list. They see listeners on loopback and wildcard addresses, not one bound only to a LAN address. `wait_for_port` waits at most 120 s.

`bollard --json` is the stable shape. Each row includes `name`, `runs`, `kind`, `section`, `pid`, `ports`, `listeners` (with `transport`), `sockets`, `provenance`, `origin`, `branch`, `directory`, `command`, `cautions`, `blocked`, `launchd` and `url`. `url` is `http://localhost:<port>` for web servers and `null` otherwise.

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
bollard --free-port [start]    # first free port from start (default 3000), exit 3 if none
bollard --wait-port <port> [s] # wait until the port accepts connections, exit 2 on timeout
bollard --wait-free <port> [s] # wait until the port can be bound again, exit 2 on timeout
bollard --mcp                  # MCP server on stdio
```

Exit codes are 0 for success, 1 for bad usage, 2 for still running or timed out, and 3 for nothing matched.

## Controller scripts

Some services should be stopped by a script of their own (a game server that saves and backs up, a database with a flush step). Declare it in `~/Library/Application Support/Bollard/controllers.json`:

```json
{"controllers": [{"directory": "~/servers/world", "script": "control.py", "sha256": "…", "label": "Saves and backs up", "timeout": 60}]}
```

A process running `python control.py run` in that directory becomes the workload's root; Stop signals the script and waits for it to finish. The script's SHA-256 must match, so an edited script loses the integration until you update the fingerprint.

## How discovery works

Two reads per scan. `KERN_PROC_ALL` gives the process table. A walk over the descriptors of every process Bollard may inspect gives the sockets: TCP in LISTEN, bound UDP and listening Unix-domain sockets, each with the process that actually holds it. macOS 27 no longer hands the kernel's socket table to apps, so descriptors are the one source that works everywhere. Bollard never runs lsof, and like lsof it sees your own processes' sockets, not root's or other users'.

Executable path, arguments and identity are read once per process generation, and reread when a process execs. Each process gets a role from where its executable lives and what it is attached to, and its command line is parsed into the program it runs (looking through interpreters, package runners and rewritten process titles) so labels match whole names, never substrings. Who started a detached process comes from macOS's responsible-process record. Only displayed workloads are sampled for memory and CPU. Branches come from `.git/HEAD`, no git binary.

The panel scans every 2 s while open and every 30 s while closed, slowing to 4 s and 120 s when nothing is running. A steady-state scan takes about 9 ms with 790 processes; see `docs/performance/`.

## Build from source

```sh
./scripts/build.sh      # Apple silicon, hardened runtime, build/Bollard.app
./scripts/install.sh    # into /Applications, relaunch, ~/.local/bin/bollard
./scripts/dmg.sh        # build/Bollard-<version>.dmg
```

Ad-hoc signed by default. Set `SIGN_IDENTITY` to a Developer ID certificate and `NOTARY_PROFILE` to a notarytool keychain profile to sign and notarize for distribution. `./scripts/dmg.sh` packages the app.

Checks:

```sh
swift build
.build/debug/BollardChecks --policy-only     # pure policy, git and controller checks
.build/debug/BollardChecks                   # socket walk and lsof parity (lsof is only the test oracle), disposable servers, a launch agent, an app bundle, stop all
.build/release/BollardBench                  # scan timings as JSON
swift format lint -r Sources Tests Package.swift
```

The live checks create their own fixtures and remove them, including on failure. They never touch existing workloads.

## Sources

- [Apple Darwin process identity ABI](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/proc_info_private.h).
