# Docs Refresh Summary

## What Changed
1. **README overhaul:** focuses on fundroid’s real scope (PID1, compositor, cfctl) and points to the new plans directory instead of the stale emulator instructions.
2. **`docs/cuttlefish.md` trim:** tightened to just the Hetzner workflow + key commands, dropping references to old scripts and making `just heartbeat` the entry point.
3. **`cuttlefish/README.md` shortcuts:** inlined the quick links (AOSP build guide, flake usage, cfctl build/test loop, Hetzner deploy) so the separate CUTTLEFISH_README.md file could go away.
4. **New `docs/plans/` folder:** added concrete step-by-step plans for (a) Cuttlefish PID1 logging, (b) ramdisk packaging, and (c) Pixel 4a bring-up, each with acceptance tests.
5. **Doc consolidation:** retired the sprawling `docs/qemu-*.md`, `rust-wayland-plan.md`, `wayland.md`, etc., folding their useful bits into `docs/ideas.md` (reference backlog) and `docs/work-log.md` (history of wins).

## Why
- The old README and cuttlefish docs described an emulator demo that no longer reflects the repo. A concise status page keeps new agents oriented without re-reading history.
- Hetzner work is our bottleneck; `docs/cuttlefish.md` now highlights the exact commands and logs we rely on for QA.
- `docs/plans/` turns the “parallel track” ideas into actionable, testable chunks so multiple agents can execute independently without conflicting context.

## Next Steps
- Start with `docs/plans/cf-pid1-logging.md` to unblock console visibility on Cuttlefish.
- Run `docs/plans/cf-ramdisk-packaging.md` in parallel once PID1 markers land, so we can ship the compositor ramdisk.
- Use `docs/plans/pixel4a-bringup.md` as the hardware fast-follow while the Hetzner work iterates.
