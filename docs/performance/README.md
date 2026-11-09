# Discovery performance

## 2026-11-09 native socket walk (2.2.0)

On macOS 27.2 the kernel returns an empty `pcblist_n` table to callers that are not platform binaries, so 2.2.0 spent about 92 ms of every scan spawning `lsof`. The scanner now reads the table when it has records and otherwise walks `proc_listallpids`, `PROC_PIDLISTFDS` and `PROC_PIDFDSOCKETINFO` in the C bridge, keeping TCP sockets in LISTEN. `lsof` is gone from the product and remains only as the oracle in the parity checks.

`scan-2026-11-09.json` is `BollardBench` (release) on the same Mac, 705 processes, 9 listeners, 6 workloads, 15 samples. The before figures are two runs of the lsof build recorded minutes earlier (173.5 and 169.6 ms first scan, 95.2 and 97.7 ms steady median). The after figures are the median across three runs, which agreed within 2%.

| Stage | Before (lsof) | After (walk) |
|---|---:|---:|
| Socket table | 91.6 to 94.9 ms | 0.57 ms |
| Steady scan, median | 95.2 to 97.7 ms | 2.9 ms |
| Steady scan, p95 | 100.8 to 106.5 ms | 4.2 ms |
| First scan, including `launchctl list` | 170 to 174 ms | 81 ms |
| Process table | 0.16 to 0.20 ms | 0.07 ms |

A bare walk takes 0.6 to 1 ms across 705 pids, of which 424 are inspectable and 281 are denied, with about 4,000 descriptors and 228 sockets. That is cheap enough that no cache was added. A cache would need invalidation on every socket open and close, which costs more than the walk.

Visibility matches `lsof`. Run as the same user, `lsof` shows only listeners owned by that user, and so does the walk. Root and other users' listeners are invisible to both because `proc_pidinfo` is denied for their processes. The parity check compared the two across 12 rounds and found the same nine listeners and owners.

## 2026-10-23 kernel tables (2.0.0)

`scan-2026-10-23.json` is `BollardBench` (release) on the development Mac under a load average near 180 from other work. 501 processes, 14 listeners, 9 workloads, 15 samples.

| Stage | Median | p95 |
|---|---:|---:|
| Process table, `KERN_PROC_ALL` | 0.32 ms | 0.86 ms |
| Socket table, `net.inet.tcp.pcblist_n` | 0.22 ms | 0.31 ms |
| Uncached full snapshot (args, path, cwd, identity for every own process) | 10.4 ms | 28.8 ms |
| Policy (grouping, lanes, cautions) | 7.5 ms | 10.3 ms |
| Steady scan, cached details, sampled members only | 9.7 ms | 15.5 ms |
| First scan, including `launchctl list` | 113 ms | |

What changed from the 2026-10-04 pass: per-process `proc_pidinfo` and descriptor enumeration are replaced by two table reads; executable path, arguments and identity are read once per process generation; socket ownership is confirmed through descriptors only the first time a socket handle is seen; memory and CPU are sampled only for displayed trees; command lines are lowercased once and searched with `memmem` (the generic Swift search cost about 1 s per scan on long Java and browser command lines). The old scanner inspected only recognisable workloads; the new one accounts for every listener on the machine, so the two are not directly comparable, but the steady-state figure is lower while covering more.

## 2026-10-04 native discovery pass (1.1.x)

Paired batches of 15 scans alternated before and after replacing `lsof` and `launchctl` subprocesses with libproc calls: 183.86 ms median before, 17.41 ms after. Distributions in `scan-comparison.json`; a 60-second closed-menu CPU sample is in `idle-sample.json`.
