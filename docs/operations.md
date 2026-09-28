# Supervisor operations

## Configuration

The daemon reads `nether-supervisor.conf` in its working directory. Values use
`key = value`; `#` starts a comment. Set `nether_bin` and `kernels_dir` before
launching. Configuration is loaded at startup.

| Key | Default | Meaning |
| --- | --- | --- |
| `control_socket` | `/tmp/nsup/control.sock` | Northbound socket |
| `socket_dir` | `/tmp/nsup` | Per-VM control/data sockets; match Swerver's tenant route |
| `work_root` | `/tmp/nsup/vms` | Per-VM directories and base workspace |
| `kernels_dir` | empty | Shared guest artifact directory |
| `nether_bin` | empty | Absolute path to the Nether executable |
| `base_snap` | empty | Nonempty enables startup baking |
| `launcher_mode` | `real` | Reserved setting; currently parsed but unused |
| `guest_service_prestarted` | `false` | Guest init starts its HTTP service |
| `app_port` | 8080 | Guest service port |
| `cpus` | 1 | Guest vCPUs |
| `ram_mb` | 512 | Written to Nether config; HVF consumes it, KVM currently uses 256 MiB |
| `max_vms` | 16 | Pool limit, clamped to 128 slots |
| `idle_ttl_ms` | 60000 | Idle limit delegated to Nether; zero disables this limit |
| `idle_timeout_s` | 90 | Additional idle limit; smaller enabled limit wins |
| `boot_budget_ms` | 30000 | Ensure waiter deadline |
| `status_addr` | empty | Optional IPv4 HTTP listener, e.g. `127.0.0.1:9190` |
| `status_service_key` | empty | Bearer token for status; empty leaves it unauthenticated |

Socket paths must fit 104 bytes including the NUL. VM sockets are named
`<8-hex-id>.control.sock` and `<8-hex-id>.data.sock`. Each VM's working directory
contains its generated `nether.conf` and `nether.log`.

Cold launches check that the backend's guest artifacts are readable, nonempty
regular files before forking. HVF uses `Image` and `initramfs.cpio.gz`; KVM uses
`vmlinux` and `initramfs`. Relative `kernels_dir` paths are resolved before the
child changes directory. The launcher installs the appropriate links in each
VM's working directory and reports link failures.

Use matching current Nether and supervisor builds for the connection-aware
idle guard and `idle_timeout_ms` setting. Protocol-version acceptance alone
does not identify those capabilities.

## Startup and readiness

`base_snap` enables a fresh startup bake at
`<work_root>/00000000/base.snap`. Its configured value is an enable switch,
not a path to a preexisting snapshot. The base work directory is cleaned before
baking. If baking fails, the supervisor logs the failure and falls back to cold
boots. Console `up` additionally waits for the warm-base log marker.

Cold startup waits for a control handshake and a guest agent command. Unless
`guest_service_prestarted=true`, it starts the built-in Python server on port
8080. A different `app_port` requires a service started by guest init.

The HTTP probe sends `/_ready` through the data socket and accepts any parseable
HTTP status. Applications that need a particular health status should provide
that check separately. Restored forks use the control handshake as their
readiness barrier, preserving the first application request for the caller.

## Protocol and access

The northbound Unix socket supports two commands:

| Command | Reply |
| --- | --- |
| `__info__` | Supervisor handshake with `proto_version=1` |
| `ensure <tenant>` | Ready VM data-socket path, or a framed error |

Replies end with `0x1e<exit>\n`. Southbound connections to Nether accept control
protocol versions 1 and 2.

Protect the supervisor's socket and parent directory with filesystem
permissions: its northbound listener relies on these rather than Nether's
peer-uid gate. The status listener uses `status_service_key` when configured.
Status bind failure is logged while the supervisor continues serving ensures.

`GET /status` returns aggregate pool/counter JSON; `GET /metrics` exposes the
same gauges and counters in Prometheus text format. Per-VM inspection uses
Nether's control sockets; the supervisor API has no VM-list command.

## Pool and idle lifecycle

Concurrent ensures for one tenant share a boot, with up to 16 waiters per slot.
Tenant identifiers have a 128-byte capacity. A full pool returns `pool full`;
retry after a slot is released. An expired waiter leaves the underlying boot
running, so a later request can use the completed VM.

The supervisor writes `idle_timeout_ms` as the smaller nonzero value of
`idle_ttl_ms` and `idle_timeout_s * 1000`. Setting both to zero disables idle
expiry. Nether tracks connections directly, including cached gateway requests
that bypass ensure. A connection holds its idle lease through the final
response flush; the idle period starts again when the last connection closes.
Explicit shutdown and hard runtime/CPU caps remain independent of idle expiry.

After a process exits, the supervisor removes its mapping. Normal exits count
as reclaims and abnormal exits as evictions. The pool is held in memory;
restart does not adopt existing VMs or recover IDs.

## Checks

```sh
zig build test
python3 scripts/gate_idle.py --supervisor /absolute/path/nether-supervisor \
  --nether /absolute/path/nether --kernels /absolute/path/kernels
```

The live gate uses a private temporary directory and retains logs. It checks an
8-second response across a 5-second idle limit, capacity rejection, cached
traffic, and eventual idle reclamation.

The 2026-09-06 runs passed 48 tests on macOS and under Docker linux/amd64, native
and Linux ReleaseSafe builds, and the live idle gate on HVF. Live KVM serving
remains the outstanding backend check.

The older shell gates use fixed paths, stop matching processes, and delete
`/tmp/nsup`. Run them in an isolated environment with no stack using those
resources.
