# nether-supervisor

A Zig daemon that owns a pool of Nether VM processes and answers Swerver tenant
cold-start requests. This README describes the source inspected on 2026-09-06,
including the local Linux guest-layout and prestarted-service changes.

## Request and process flow

```text
Swerver -- ensure <tenant> --> supervisor -- launch/restore --> Nether process
        <-- VM data socket --                              --> guest HTTP service
Swerver --------------------- raw HTTP to VM data socket --->
```

The supervisor owns VM launch, base baking, pooling, and reclaim. The separate
`swerver-console` bridge uses `RemoteSupervisor` to request VMs and read
aggregate status; it does not implement this pool in TypeScript.

The northbound Unix socket supports:

| Command | Reply |
| --- | --- |
| `__info__` | Supervisor handshake, `proto_version=1` |
| `ensure <tenant>` | A ready VM's data-socket path, or a framed error |

Replies use the `0x1e<exit>\n` trailer. Southbound Nether connections accept
protocol versions 1 and 2. The gateway tenant route's `socket_dir` must match
the supervisor's directory.

Northbound access relies on the socket and parent-directory filesystem permissions;
this listener does not implement Nether's peer-uid gate or a token handshake.

## Build and run

Requires **Zig 0.16.0**.

```sh
zig build
zig build test
```

Build Nether for the intended host first. On Apple Silicon, its installed binary
needs the hypervisor entitlement; Nether's native build signs by default.
Prepare its kernel/initramfs with the appropriate Nether runbook.

Edit [nether-supervisor.conf](nether-supervisor.conf), setting at least
`nether_bin` and `kernels_dir` for a real guest. Then run from the directory
holding that config:

```sh
./zig-out/bin/nether-supervisor
```

The daemon reads **only `nether-supervisor.conf` in its working directory**.
There are no implemented CLI config-path or `NSUP_*` environment overrides.

The launcher supports macOS and Linux source paths. It links `kernels/` for
HVF and stages top-level `vmlinux` / `initramfs` links for KVM.
Those two KVM files must exist under `kernels_dir`.
The latter requires matching Linux artifacts and a Linux Nether binary; an ARM
guest directory is not interchangeable with an x86 one. The current Linux
end-to-end guest-serving path was not exercised in this documentation audit.

## Startup and readiness

A nonempty `base_snap` **enables baking**. The daemon creates a fresh base at
`<work_root>/00000000/base.snap`; it does not load an existing snapshot from
the configured value. The base work directory is cleaned before baking.

Cold startup waits for a control connection, a supported handshake, and a guest
agent command. Unless `guest_service_prestarted=true`, it starts the built-in
Python demonstration service. It then probes HTTP `/_ready` through the data
socket before snapshotting the base.

The probe accepts a parseable HTTP status, including a non-success status; it is
not an application-specific health assertion. The built-in service listens on
8080. A different `app_port` requires a prestarted service listening there.

Restored forks use the control handshake as their readiness barrier. They skip
the guest command and HTTP probe, preserving the first application request for
the caller. This is not an independent HTTP readiness check on each fork.

If baking fails, the daemon logs the failure and serves in cold-boot mode.
A listening control socket alone therefore does not prove warm-fork availability.
The console `up` flow additionally waits for the warm-base log marker.

## Configuration

All values are `key = value`; `#` starts a comment. Paths below are defaults,
not automatically valid deployment settings.

| Key | Default | Meaning |
| --- | --- | --- |
| `control_socket` | `/tmp/nsup/control.sock` | Northbound socket |
| `socket_dir` | `/tmp/nsup` | Per-VM control/data sockets |
| `work_root` | `/tmp/nsup/vms` | Per-VM directories and base workspace |
| `kernels_dir` | empty | Shared guest artifact directory |
| `nether_bin` | empty | Nether executable path |
| `base_snap` | empty | Nonempty enables startup baking, as described above |
| `launcher_mode` | `real` | Parsed but unused; no fake launcher is selected |
| `guest_service_prestarted` | `false` | Guest init already starts its HTTP service |
| `app_port` | 8080 | Guest service port |
| `cpus` | 1 | Guest vCPUs |
| `ram_mb` | 512 | Written to Nether config; HVF consumes it, current KVM boot uses a fixed 256 MiB |
| `max_vms` | 16 | Pool limit, clamped to the 128-slot capacity |
| `idle_ttl_ms` | 60000 | Supervisor reclaim age |
| `idle_timeout_s` | 90 | Nether inactivity timeout written into VM config |
| `boot_budget_ms` | 30000 | Ensure waiter deadline |
| `status_addr` | empty | Optional IPv4 HTTP listener, e.g. `127.0.0.1:9190` |
| `status_service_key` | empty | Bearer token; an empty key leaves status unauthenticated |

Generated socket paths must fit the 104-byte limit, including the NUL.
Per-VM names are `<8-hex-id>.control.sock` and `<8-hex-id>.data.sock`.
Each VM's working directory contains `nether.conf` and `nether.log`.

## Pool and reclaim limits

Concurrent ensures for one tenant share a boot, with at most 16 waiters per slot.
Tenant identifiers have a 128-byte capacity. A full pool can evict the least
recently used ready VM. Expiring an ensure waiter does not necessarily cancel
the underlying boot.

The pool is in memory. Restart does not adopt existing VMs or recover IDs.
`last_used_ms` is refreshed by ensure/readiness activity, not by every HTTP
request. Gateway registry hits can serve traffic without calling ensure, so an
actively serving VM can still reach the supervisor idle TTL. There is no
per-request lease preventing reclaim or eviction.

The pool state machine is in `src/pool.zig`; process and socket work lives in
`src/supervisor.zig`, `src/boot.zig`, and `src/launcher.zig`.

## Status and checks

When enabled, `GET /status` returns aggregate pool/counter JSON and
`GET /metrics` exposes the same gauges and counters in Prometheus text format.
There is no northbound VM-list API. Status bind failure is logged but is not
fatal to the supervisor.

The 2026-09-06 host test run passed **46 tests**. This validates unit behavior,
not a live VM boot or a Linux tenant request. The shell gates in `scripts/`
are manual integration harnesses: inspect their fixed paths first. Some stop
matching supervisor processes and delete `/tmp/nsup`; run them only in an
isolated environment with no stack using those resources.
