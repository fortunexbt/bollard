# Discovery performance

## 2026-10-23 — kernel tables (2.0.0)

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

## 2026-10-04 — native discovery pass (1.1.x)

Paired batches of 15 scans alternated before and after replacing `lsof` and `launchctl` subprocesses with libproc calls: 183.86 ms median before, 17.41 ms after. Distributions in `scan-comparison.json`; a 60-second closed-menu CPU sample is in `idle-sample.json`.
