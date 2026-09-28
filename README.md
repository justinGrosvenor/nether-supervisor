# nether-supervisor

**A pool of Linux microVMs behind one tenant API.** The supervisor is a Zig daemon
that launches Nether VMs for Swerver, prepares warm snapshot bases, and returns
the data socket for each tenant's service.

Concurrent requests for the same tenant share a single boot. Subsequent requests
reuse the ready VM. With a warm base, new tenants start from a snapshot of an
already running application.

```text
Swerver -- ensure <tenant> --> supervisor -- launch/restore --> Nether VM
        <-- VM data socket --
Swerver --------------------- HTTP over data socket -------> guest service
```

Nether tracks connection activity and handles idle shutdown. At capacity, the
supervisor returns `pool full`, preserving VMs that are serving requests. Exited
VMs release their slots for new tenants.

## Build and run

Requires **Zig 0.16.0**, a Nether binary built for your host, and matching guest
artifacts. Use the current Nether and supervisor sources together for
connection-aware idle handling.

```sh
zig build
zig build test
```

Edit [nether-supervisor.conf](nether-supervisor.conf) in this checkout. Set
`nether_bin` to the absolute path of the Nether executable and `kernels_dir` to
your guest artifact directory:

| Host | Files in `kernels_dir` |
| --- | --- |
| Apple Silicon / HVF | `Image`, `initramfs.cpio.gz` |
| Linux x86-64 / KVM | `vmlinux`, `initramfs` |

The built-in demo service uses Python on port 8080. For an x86 image containing
Python and the forwarder, use Nether's `tools/build-guest-x86.sh --runtimes`.
For your own service, set `guest_service_prestarted=true` and point `app_port`
at the service started by guest init.

```sh
./zig-out/bin/nether-supervisor
```

The daemon reads its config from the working directory. Configure Swerver to use
the supervisor's `control_socket` and the same `socket_dir` for tenant routes.

## Warm bases and VM lifecycle

Set `base_snap` to a nonempty value to enable a startup bake. The supervisor boots
a base guest, starts or connects to its service, probes HTTP through the data
socket, and writes `<work_root>/00000000/base.snap`. New tenants restore from
that base. Restored forks complete a control handshake and preserve the first
application request for their caller.

`max_vms` controls pool capacity. `idle_ttl_ms` and `idle_timeout_s` select the
smaller enabled idle limit, enforced by Nether after data/egress connections
close. Per-VM configuration and logs live under `work_root`.

See [operations](docs/operations.md) for the full configuration reference,
readiness behavior, protocol, and lifecycle details.

## Observe and test

Enable `status_addr` for aggregate JSON at `/status` and Prometheus metrics at
`/metrics`. The Swerver console connects through its `RemoteSupervisor` adapter
and attaches to individual Nether control sockets for VM inspection.

[gate_idle.py](scripts/gate_idle.py) exercises capacity pressure, a slow response
across the idle timeout, cached traffic, and eventual idle reclamation. Run it
with the commands in [operations](docs/operations.md#checks).

The pool state machine lives in [`src/pool.zig`](src/pool.zig); process launch and
readiness live in [`src/supervisor.zig`](src/supervisor.zig) and
[`src/boot.zig`](src/boot.zig).
