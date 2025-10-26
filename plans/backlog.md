# Backlog - Follow-up Items

## cfctl / Cuttlefish Instance Boot

### TAP Device Permission Issue
**Status:** Blocked - requires investigation  
**Context:** Experiment #2 fixed the primary "Failed to set group" issue, but revealed a secondary problem.

**Problem:**
```
qemu-system-x86_64: -netdev tap,id=hostnet0,ifname=cvd-mtap-01,script=no,downscript=no: 
could not configure /dev/net/tun (cvd-mtap-01): Operation not permitted
```

**Current State:**
- ✅ `CAP_NET_ADMIN` is being set via `setpriv --ambient-caps +net_admin`
- ✅ Command chain: `sudo -u justin -g cvdnetwork -- setpriv --ambient-caps +net_admin -- fhs-wrapper`
- ❌ QEMU still can't configure TAP devices

**Possible Causes:**
1. Ambient capabilities don't survive bubblewrap's namespace creation (`--unshare-user`)
2. `/dev/net/tun` permissions insufficient (needs group/ACL adjustments)
3. QEMU binary needs file capabilities set (`setcap cap_net_admin+ep /path/to/qemu`)
4. Bubblewrap needs additional flags to preserve capabilities

**Next Steps:**
- Test if capability survives: `sudo -u justin -- setpriv --ambient-caps +net_admin -- /path/to/fhs -- sh -c 'capsh --print'`
- Check if setting file caps on qemu binary helps: `setcap cap_net_admin+ep /var/lib/cuttlefish/bin/.../qemu-system-x86_64`
- Investigate bubblewrap capability propagation (may need `--cap-add` or similar)
- Consider pre-creating TAP devices with proper ownership as alternative

**Impact:** Medium - instances boot and stay running, but networking doesn't initialize. This blocks full Android boot.

---

## Experiment #1 - Heartbeat PID1
**Status:** Not started  
**Goal:** Prove standalone PID 1 prints `[cf-heartbeat]` when launched via cfctl.

See `plans/prompt.md` for full details.

---

## Multi-track Cuttlefish Improvements
**Status:** Ideas for future work

**Potential Enhancements:**
- Make `guest_user`, `guest_primary_group`, `guest_capabilities` track-specific (currently global)
- Allow different security policies per track
- Add capability validation at startup (fail fast if caps unavailable)
