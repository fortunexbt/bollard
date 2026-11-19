# Changelog

## 3.0.1 — 2026-11-19

The panel stuttered, badly on a busy Mac. Scans cost about a tenth of the CPU they did.

- The panel asked macOS whether Bollard launches at login every time it redrew, a blocking call on the main thread. It is read when the panel opens.
- What a process runs, and what its path says about it, is worked out once when the process is first seen. 3.0.0 re-parsed every command line on every scan.
- A process's sockets are read again only when its open files change, with a periodic reread.
- An exited process is no longer mistaken for one that had exec'd, which made a busy Mac scan twice.
- While the panel is closed, scans skip memory, CPU and working directories.
- Scans wait while the list is being scrolled, so a refresh never lands mid-scroll.
- The editor and agent lists in each row's menu and the application icons are looked up once.

## 3.0.0 — 2026-11-18

Discovery, the panel and the platform floor are new. Needs macOS 26 or later.

- Every long-lived process tree of yours is a workload. 2.x listed a process without a port only when it matched a list of known programs, so `python -c`, `node -e`, shell loops and compiled binaries never appeared. Roles (macOS, application, agent, terminal session, yours) now come from structure, and recognising the program only improves the label.
- Programs are named from parsed command lines: interpreters, package runners and rewritten process titles are looked through, and nothing matches on a substring. A project in `~/invite-app` is no longer Vite.
- Rows are named by repository, with what they run beside the name, so six workloads in one project are six different rows.
- Agents lane: each coding-agent session with the helpers it started, such as MCP servers. Ending one leaves the servers it launched running.
- UDP ports and Unix-domain sockets.
- A server that outlives its shell or agent still says who started it, from macOS's responsible-process record.
- Sockets come from a descriptor walk only. macOS 27 withholds the kernel socket table from apps, so the table parser is gone.
- The scanner notices exec, so a process that replaces itself is relabelled and can still be stopped.
- New panel on Liquid Glass: search first, launcher filters, application icons, family colours, one expanded row at a time with the command, folder, listeners, process tree and actions.
- New icon and menu bar glyph, a layered icon for the dark, clear and tinted looks, and a drag-to-install disk image.
- `bollard --free-port`, `--wait-port` and `--wait-free`, with matching `free_port` and `wait_for_port` MCP tools. MCP tools carry read-only and destructive annotations.
- JSON rows add `runs`, `sockets`, a `transport` per listener and a `url` for web servers.
- Apple silicon only.

## 2.1.0 — 2026-10-23

Renamed from DevPorts to Bollard. Universal binary, hardened runtime, app icon, DMG and install scripts.

- Origin filter: pills for Claude Code, Codex, Cursor, Terminal, launchd and the rest; "Stop all" follows the filter.
- Git branch and worktree name on every row, read from the checkout's HEAD without running git.
- Recent lane: servers that went away, relaunched in Terminal with their original command and directory.
- Pin to top and rename, per project.
- Notifications when a dev server starts or stops unexpectedly (toggle in the menu).
- Global shortcut ⌃⌥B opens the panel (toggle in the menu).
- "Copy for agent", "Claude Code here", "Codex here" and other installed agents and editors in the project menu.
- MCP server (`bollard --mcp`) with list_servers, port_owner and stop_server tools.
- CLI: `bollard 3000` shorthand, `--version`, `--help`; `--list`/`--json` accept a query.
- Declared controller scripts (`~/Library/Application Support/Bollard/controllers.json`) replace the hard-coded Minecraft integration.
- lsof fallback when the kernel socket table cannot be parsed; the footer says so.
- Panel sizes itself to its measured content.

## 2.0.0 — 2026-10-23

Every workload stoppable: cautions instead of refusals; Stop, Interrupt, Force Quit, Stop all; launchd unload and brew services; app Quit. Kernel-table discovery (`KERN_PROC_ALL`, `net.inet.tcp.pcblist_n`). Four lanes. Keyboard, context menus, sparklines. CLI `--json`, `--stop`, `--interrupt`, `--kill`.

## 1.1.1 — 2026-10-04

Native libproc discovery, quiet-Mac panel, launch at login.
