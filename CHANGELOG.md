# Changelog

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
