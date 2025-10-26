# Parallel Experiment Prompt – Heartbeat PID1 & cfctl follow-up

We’re now rebased on master with the new `cfctl` features:
* `cfctl logs --stdout --follow` streams the console when available.
* Held instances keep their artifacts until `cfctl instance destroy`.
* `scripts/test-heartbeat.sh` prefers the follow mode and falls back to a legacy tail.

Let’s split up and explore several threads in parallel. Below are five experiment ideas—pick one (or improvise) and document findings in `notes/` or `docs/`. Keep commits tight and reference logs/evidence.

---

### Experiment 1 – “Heartbeat happy path”
**Goal:** Prove our standalone PID 1 prints `[cf-heartbeat]` when launched via cfctl.
1. Ensure the remote host is running the latest `cfctl` with `logs --follow`. If not, redeploy (`~/configs`, `just hetzner`) or push binaries to the host.
2. Run `scripts/test-heartbeat.sh` (set `REMOTE_CFCTL=/home/justin/cfctl-dev/cfctl` if testing local binaries). The script should stream the console and detect three heartbeats.
3. Capture the console session and stash it (e.g., `logs/heartbeat-YYYYmmdd-HHMM.log`).

**Acceptance criteria:** Script exits success and we have proof (`VIRTUAL_DEVICE_BOOT_COMPLETED` + 3 `[cf-heartbeat]` lines). Document where the log lives.

---

### Experiment 2 – “Why does the guest exit?”
**Goal:** Understand why instances flip to `failed` even when held.
1. Manually drive the lifecycle: create, deploy, hold, start (`--skip-adb-wait`).
2. While running, copy `/var/lib/cfctl/instances/<id>/cfctl-run.log` and any console log. Inspect host journal if needed.
3. Identify the first fatal message (graphics probe? kernel panic?) and summarize.

**Acceptance criteria:** Notes outlining the failure cause with log snippets. Bonus if you suggest or test a mitigation (e.g., forcing `--gpu_mode=guest_swiftshader`).

---

### Experiment 3 – “Minimal init instrumentation” ✅ COMPLETE
**Goal:** Confirm our PID 1 executes before the guest dies.
1. Add a small breadcrumb to `heartbeat_init.c` (e.g., create `/tmp/heartbeat-was-here` or write to `/dev/kmsg`).
2. Repack/deploy/hold an instance, then check the preserved filesystem/logs.

**Acceptance criteria:** Evidence one way or another that the binary ran (or crashed). Include the indicator you used and how you verified it.


**Result:** PID1 never executes. Instance fails during host-side graphics initialization (Vulkan checks terminated by signal 6) before guest VM boots. Added reliable breadcrumb instrumentation (`/tmp/heartbeat-was-here` + kmsg markers with errno preservation and fsync verification) for future testing. See `notes/experiment-3-findings.md`.

---

### Experiment 4 – "cfctl polish / automation" ✅ COMPLETE
**Goal:** Make cfctl and our scripts easier to use.
Ideas:
* Add `--track` support to `cfctl instance start` and teach the daemon to pass the track into `cfenv`.
* Improve `cfctl logs` error handling if the stream disconnects.
* Wrap the heartbeat test in a `just heartbeat` recipe that sets `REMOTE_CFCTL`, captures logs, etc.

**Acceptance criteria:** Usability improvement merged with README/docs updates and passing `cargo check`.


**Result:** Added --track to cfctl instance start, improved error messages, created just heartbeat recipe with REMOTE_CFCTL support. Tested on Hetzner. Merged to master.
---

### Experiment 5 – “Host tool instrumentation”
**Goal:** Better diagnostics for future runs.
Ideas:
* Include a truncated copy of `cfctl-run.log` in `cfctl instance status` or add a `cfctl instance describe` command.
* Have the daemon snapshot console output when an instance transitions to `failed`.

**Acceptance criteria:** New command/flag or logging behavior with tests/docs updated.

---

### Tips / reminders
* Repo root: `~/code/boom/worktrees/android-init-examples-codex`.
* Remote host: `ssh hetzner`, daemon socket `/run/cfctl.sock`.
* `cfctl` sources live in `cuttlefish/cfctl`; `cargo build --release` there builds local binaries.
* Hold instances before they fail: `cfctl instance hold <id>`; clean up with `cfctl instance destroy`.
* Multi-track layout: logs under `/var/lib/cfctl/instances/<id>/`, console symlinks under `/var/lib/cuttlefish/instances/<id>. <id>/`.
* For large logs, drop files in `logs/` instead of overloading commit messages.

Grab an experiment, iterate quickly, and leave breadcrumbs for the next agent. Good luck!
