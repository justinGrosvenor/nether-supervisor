# nether-supervisor

**A pool of Linux microVMs behind one tenant API.** The supervisor is a Zig daemon
that launches [Nether](https://github.com/justinGrosvenor/nether) VMs, prepares
warm snapshot bases, and returns the data socket for each tenant's service.

Concurrent requests for the same tenant share a single boot. Subsequent requests
reuse the ready VM. With a warm base, new tenants start from a snapshot of an
already running application.

```text
Your app -- ensure <tenant> --> supervisor -- launch/restore --> Nether VM
         <-- VM data socket --
Your app --------------------- HTTP over data socket -------> guest service
```

Nether tracks connection activity and handles idle shutdown. At capacity, the
supervisor returns `pool full`, preserving VMs that are serving requests. Exited
VMs release their slots for new tenants.

## Try the warm-fork demo

The demo prepares a running HTTP server, forks it into `alpha` and `beta`, and
checks that both inherited the same server with independent request counters.
Requesting `alpha` again reuses its VM and state.

With Zig **0.16.0**, Python **3.9+**, and a built Nether checkout with a runtime
guest image:

```sh
zig build -Doptimize=ReleaseSafe
python3 scripts/demo.py --nether-dir ../nether
```

For a fresh machine, follow the [setup guide](docs/quickstart.md), which includes
guest image preparation for Apple Silicon and Linux/x86-64. The demo uses a
private temporary directory, stops its own processes on exit, and retains its
run files. Add `--hold` to leave it running and get `curl` commands to try yourself.

The demo runs directly against the supervisor; it needs no gateway, console,
account, or hosted service.

## Use it from your application

Send `ensure <tenant>\n` to the supervisor's Unix control socket. A successful
reply contains the VM's Unix data-socket path, followed by byte `0x1e` and `0\n`.
Send HTTP over that data socket to reach the guest's service. Read the complete
reply trailer and check its exit code before using the returned path.

The demo's Python client is in [scripts/live.py](scripts/live.py). Applications can
connect directly, or use [Swerver](https://github.com/justinGrosvenor/swerver)
to route tenant traffic. See the [protocol](docs/operations.md#protocol-and-access)
for framing and the [operations guide](docs/operations.md) for configuration.

## Build and configure

Requires **Zig 0.16.0**, a Nether binary built for your host, and matching guest
artifacts. Use the current Nether and supervisor sources together for
connection-aware idle handling.

```sh
zig build
zig build test
```

For your own deployment, edit [nether-supervisor.conf](nether-supervisor.conf). Set
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

The daemon reads its config from the working directory. If you use Swerver,
configure its tenant routes with the supervisor's `control_socket` and the same
`socket_dir`.

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
`/metrics`. Inspect individual VMs through their Nether control sockets.

The [live checks](docs/operations.md#checks) cover warm forks, cold serving,
concurrent requests, crash recovery, status endpoints, and connection-aware idle
reclamation. CI builds and runs unit tests on macOS and Linux.

The pool state machine lives in [`src/pool.zig`](src/pool.zig); process launch and
readiness live in [`src/supervisor.zig`](src/supervisor.zig) and
[`src/boot.zig`](src/boot.zig).

## Contribute

Tell us what you're building and where you get stuck. Reports about setup,
workload behavior, and integrations help decide what to build next. See
[CONTRIBUTING.md](CONTRIBUTING.md) for reproducing issues and submitting changes.

[Apache-2.0](LICENSE).
