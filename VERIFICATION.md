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
