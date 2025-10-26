# Experiment 5 – Host Tool Instrumentation

**Date:** 2025-10-26  
**Branch:** experiment-5  
**Goal:** Better diagnostics for cfctl instance management

## Summary

Successfully implemented two major diagnostic improvements to cfctl:

1. **New `cfctl instance describe` command** - Provides detailed instance diagnostics including truncated cfctl-run.log
2. **Automatic console snapshot on failure** - Daemon automatically captures console output when instances transition to Failed state

## Changes Made

### 1. Protocol Changes (`src/protocol.rs`)

- Added `Describe` request variant with optional `run_log_lines` parameter
- Enhanced `InstanceActionResponse` with two new optional fields:
  - `run_log_tail`: Contains truncated cfctl-run.log content
  - `console_snapshot_path`: Path to saved console snapshot on failure

### 2. CLI Changes (`src/bin/cfctl.rs`)

- Added `cfctl instance describe <id> [--run-log-lines N]` command
- Default shows last 50 lines of run log (configurable via flag)
- Returns JSON with instance status, run log tail, and console snapshot path if available

### 3. Manager Implementation (`src/daemon/manager.rs`)

#### describe() method
```rust
fn describe(&mut self, id: InstanceId, run_log_lines: Option<usize>) -> Result<InstanceActionResponse>
```
- Retrieves instance metadata
- Reads and returns truncated cfctl-run.log (default 50 lines)
- Checks for console snapshot and includes path if present

#### snapshot_console_on_failure() method
```rust
fn snapshot_console_on_failure(&self, id: InstanceId, paths: &InstancePaths) -> Result<()>
```
- Called automatically when instance transitions to `Failed` state
- Reads full console log from cuttlefish instances directory
- Saves copy to `<instance_dir>/console_snapshot.log`
- Logs success/failure for debugging

#### handle_guest_exit() enhancement
- Now checks if new state is `Failed`
- If failed, automatically snapshots console output before updating metadata
- Non-blocking: logs warning if snapshot fails but continues with state transition

### 4. Daemon Integration (`src/daemon/mod.rs`)

- Added `Describe` case to `describe_request()` helper for logging

## Usage Examples

### Describe an instance
```bash
# Show default diagnostics (50 lines of run log)
cfctl instance describe 1

# Show more run log lines
cfctl instance describe 1 --run-log-lines 100
```

### Example output
```json
{
  "ok": true,
  "action": {
    "summary": {
      "id": 1,
      "adb": {
        "host": "127.0.0.1",
        "port": 6500,
        "serial": "127.0.0.1:6500"
      },
      "state": "failed"
    },
    "run_log_tail": "... last 50 lines of cfctl-run.log ...",
    "console_snapshot_path": "/var/lib/cfctl/instances/1/console_snapshot.log"
  }
}
```

### Automatic console snapshot
When an instance crashes or exits with error:
1. Daemon detects failure in `spawn_exit_watcher` thread
2. Calls `handle_guest_exit()` which sees state is `Failed`
3. Automatically captures full console log to snapshot file
4. Snapshot persisted even after instance cleanup
5. Available via `describe` command for post-mortem analysis

## Testing

- ✅ `cargo check` passes
- ✅ `cargo build --release` succeeds
- Ready for deployment and integration testing on Hetzner

## Acceptance Criteria Met

✅ **New command/flag implemented**: `cfctl instance describe` with `--run-log-lines` option  
✅ **Run log access**: Truncated cfctl-run.log included in describe response  
✅ **Console snapshot on failure**: Automatic capture when transitioning to Failed state  
✅ **Documentation updated**: This file documents implementation  
✅ **Code quality**: Passes cargo check without warnings

## Next Steps

1. Deploy to Hetzner and test with real instances
2. Run heartbeat test and verify describe shows useful diagnostics
3. Intentionally fail an instance and verify console snapshot is captured
4. Consider adding describe output to status command or instance list

## Benefits

- **Faster debugging**: No need to SSH to check logs, use describe command
- **Post-mortem analysis**: Console snapshots preserved even after cleanup
- **Better visibility**: See run log without manually tailing files
- **Automation friendly**: JSON output easily parseable by scripts
