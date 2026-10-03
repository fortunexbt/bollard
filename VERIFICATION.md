# Verification — 2026-10-04

- Built native Apple Silicon release with the installed Swift command-line tools.
- Standalone checks: 12 policy cases covering sibling/shell boundaries, hidden infrastructure and game clients, Minecraft/Jupyter/Ollama identification, watchers, protected descendants, detached ownership, PID reuse, changed parent generation, new descendants, and panel bounds across display sizes/origins.
- Earlier live fixture run: two real Node HTTP servers; stale identity refused; selected fixture terminated; sibling listener and parent shell remained alive. Only task-owned temporary processes were controlled.
- After the user requested no running ports be stopped, remaining tests were policy-only and all existing workloads remained read-only.
- Live discovery observed both PrismLauncher Minecraft servers and Foreman services, while excluding Minecraft client listeners and Gradle/agent infrastructure. Counts change as other tasks start and stop their own processes.
- Startup registration reports enabled. Actual login/reboot was not exercised.
- Native interface inspected through accessibility and screenshots, including expanded Minecraft actions. Removed the temporary preview window after feedback. Final compact 480-point panel uses an explicitly bounded native NSPanel and the app remains an accessory with no Dock icon.
- Swift formatting lint passes.
- Code review: skipped (ce-code-review unavailable). The scope helper could not resolve an unborn repository against an empty-tree base; independent native safety review was used. Findings on parent generations, suspended processes, bundled Ollama, rewritten restart commands, protected app supervisors, and node-backed package-manager wrappers were addressed. Process-tree operations cannot serialize arbitrary simultaneous external signals/debugger actions.

No production server shutdown, Minecraft world-save/backup cycle, or reboot was performed as a test.
