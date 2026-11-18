# Verification

What was checked for 3.0.0 on 2026-11-18, macOS 27.2 (26B123), Xcode 27.2, Apple silicon. Earlier
records are in the git history of this file.

## Automated

`swift build && .build/debug/BollardChecks` passes:

- 16 policy checks on synthetic process tables: discovery of unrecognised programs, the settle
  time, program parsing and kinds, wrappers, agents and helpers, applications and helpers, terminal
  sessions, launchd jobs, socket owners and origins, project names, kill-set validation, launchd
  label caching, git checkouts, controller scripts and panel placement.
- Port and binary checks: `--free-port`, `--wait-port`, MCP initialize, tool listing and calls
  through the built binary.
- 12 rounds of socket-walk against `lsof` parity, about 120 listener comparisons.
- Live fixtures the checks create and remove: three servers, a stale identity refused, SIGTERM
  stop, a SIGTERM-ignoring server reported then force quit, siblings untouched; a user launch
  agent discovered, cautioned and unloaded; a scripted .app listed under Apps and force quit; stop
  all across three servers.

`swift format lint -r Sources Tests Package.swift` is clean.

## By hand

- A lab of 13 processes started from a Claude Code shell: an HTTP server, a UDP listener, a
  Unix-socket listener, an IPv6-only Node server, `python -c`, `node -e`, a bash loop, a compiled
  binary, plain scripts, and two in a folder named `my-mcp-app`. 2.2.0 listed 7 of the 11 that
  stayed up and showed the UDP and Unix-socket servers as portless scripts. 3.0.0 lists all 11,
  each with what it runs, and attributes every one to Claude Code after its shell exited.
- Every lab process was then stopped with `bollard --stop <port|pid>` from the release binary.
- The panel was reviewed in dark and light appearance through the debug renderer
  (`swift run Bollard --render out.png`) and on screen over Liquid Glass.

## Not verified

- VoiceOver, Increase Contrast and Reduce Transparency were not exercised.
- Restart in Terminal, "Claude Code Here" and brew services were not exercised in this pass.
- macOS 26 was not available to test on; the build targets it and uses no API newer than 26.
- Root's and other users' sockets are invisible to the descriptor walk, as they are to `lsof`.
  `port_owner` says so when a port is held by a process Bollard cannot inspect.
- Policy runs once or twice per scan at about 6 ms each. It is not optimised further.
