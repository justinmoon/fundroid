# Cuttlefish Custom Builds

Quick links to cuttlefish documentation:

## For Building Custom AOSP

👉 **[AOSP_BUILD.md](./AOSP_BUILD.md)** - Complete guide to building custom cuttlefish binaries from AOSP sources

**What's in it:**
- How to build patched cuttlefish binaries (run_cvd, kernel_log_monitor, etc.)
- The Bluetooth headless patch (skip Bluetooth dependency failures)
- Build workflow with Nix FHS environment
- Packaging and deployment

**When to use:** You want to modify cuttlefish host tools (run_cvd, kernel_log_monitor) or test AOSP patches.

## For Multi-Track Deployment

👉 **[MULTI_TRACK_CUTTLEFISH.md](./MULTI_TRACK_CUTTLEFISH.md)** - Architecture and plan for running multiple cuttlefish variants

**What's in it:**
- Multi-track architecture design
- How to run stock + custom builds simultaneously
- No conflicts between developers testing different patches
- Complete implementation guide

**Status:** ✅ Implemented, dormant until activated

## Quick Start

### Current State (Stock Google Package)
```bash
# Everything uses stable Google package
cuttlefish-fhs run_cvd --help
cfctl instance create-start --purpose ci
```

### To Enable Multi-Track (Optional)

1. **Review the example**:
   ```bash
   cat hetzner/cuttlefish-tracks-example.nix
   ```

2. **Activate in configuration.nix**:
   ```nix
   # Uncomment or add:
   services.cuttlefish = {
     enable = true;
     defaultTrack = "stock";
     tracks.stock = { bundle = <Google package>; };
     # Add custom tracks here
   };
   ```

3. **Deploy**:
   ```bash
   just hetzner
   ```

4. **Use**:
   ```bash
   cfenv run_cvd --help                    # Uses default (stock)
   CF_TRACK=my-track cfenv run_cvd --help  # Uses custom track
   ```

### To Add Custom Track

1. **Build AOSP** (see AOSP_BUILD.md)
2. **Add track definition** (see cuttlefish-tracks-example.nix)
3. **Deploy**: `just hetzner`
4. **Test**: `CF_TRACK=my-track cfenv ...`

## Safety Guarantees

✅ **No disruption**: Multi-track infrastructure is dormant until explicitly enabled  
✅ **Backward compatible**: Legacy configs continue working  
✅ **Safe defaults**: Stock track is default, custom tracks require `CF_TRACK` override  
✅ **Easy rollback**: Just use `CF_TRACK=stock` or disable tracks

## Files

- `AOSP_BUILD.md` - Building custom binaries
- `MULTI_TRACK_CUTTLEFISH.md` - Multi-track architecture  
- `cuttlefish-tracks-example.nix` - Ready-to-use config template
- `aosp-cuttlefish.nix` - FHS build environment for AOSP
- `build-aosp-host.nix` - Standalone AOSP builder

## Current Status

**Deployed**: Stock Google package (stable)  
**Available**: Multi-track infrastructure (ready to activate)  
**Ready to use**: Custom AOSP builds (in Nix store)

Other agents are unaffected - system behaves identically to before.
