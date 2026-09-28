# Run two tenants from one warm server

This demo bakes an HTTP server into a Nether snapshot, starts two VMs from it,
and checks their independent request counters. Everything runs on your machine.

## Get the code and toolchain

Install Zig **0.16.0**, Python **3.9+**, and Git. Preparing the runtime guest image
also needs Docker. Clone both repositories beside each other:

```sh
git clone https://github.com/justinGrosvenor/nether.git
git clone https://github.com/justinGrosvenor/nether-supervisor.git
```

Use matching current Nether and supervisor sources. The supervisor's idle
handling depends on Nether's `idle_timeout_ms` and connection-aware idle guard.

## Prepare Nether

### Apple Silicon / macOS

Install the Xcode Command Line Tools if needed (`xcode-select --install`), and
start Docker for the runtime image preparation. From the parent directory:

```sh
cd nether
zig build -Dtarget=native -Doptimize=ReleaseSafe
./scripts/fetch-guest-image.sh
if [ ! -d kernels/rootfs ]; then
  mkdir -p kernels/rootfs
  (cd kernels/rootfs && gzip -dc ../initramfs.cpio.gz | cpio -idm)
fi
./tools/build-guest-aarch64-runtimes.sh
cd ..
```

The build signs Nether with the hypervisor entitlement. The runtime image
includes Python, the guest agent, and the TCP/vsock forwarder. The demo uses
`kernels/Image` and `kernels/initramfs.cpio.gz`.

If the linker cannot find the macOS SDK, prefix the build with
`DEVELOPER_DIR=/Library/Developer/CommandLineTools`. See Nether's
[HVF guide](https://github.com/justinGrosvenor/nether/blob/main/docs/running-on-hvf.md)
for image and signing details.

### Linux / x86-64

Use a host with readable and writable `/dev/kvm`. Build a PVH-capable `vmlinux`
with the virtio/vsock options in Nether's
[KVM guide](https://github.com/justinGrosvenor/nether/blob/main/docs/running-on-kvm.md#3-pvh-linux-boot).
Place that kernel at `nether/kernels/vmlinux`. Then, from the parent directory:

```sh
cd nether
zig build -Dtarget=x86_64-linux -Doptimize=ReleaseSafe
./tools/build-guest-x86.sh --runtimes
cp kernels/initramfs-x86.cpio.gz kernels/initramfs
cd ..
```

The supervisor expects `vmlinux` and `initramfs` in the configured kernels
directory. A distro `bzImage` is not the PVH ELF kernel Nether's loader expects.
The live results recorded for this release preparation use HVF; Linux build
and unit-test results are separate from running a real KVM guest.

## Run the demo

```sh
cd nether-supervisor
zig build -Doptimize=ReleaseSafe
python3 scripts/demo.py --nether-dir ../nether
```

The output identifies the run directory, prints the server ID and request count
for each tenant, and checks that:

- `alpha` and `beta` inherited the same running server from the warm base.
- Requests to `alpha` do not advance `beta`'s counter.
- Ensuring `alpha` again reuses its VM and preserves its state.

The reported `ensure` time measures a supervisor request through receipt of a
ready data-socket path. HTTP requests are checked separately. It excludes the
initial base bake.

To keep the two VMs running and try the printed `curl` commands:

```sh
python3 scripts/demo.py --nether-dir ../nether --hold
```

Press Ctrl-C to stop. The runner disables idle expiry for this interactive
demo and only shuts down its own supervisor and VMs. It retains the private
run directory, including configs, logs, and the base snapshot; remove that
printed directory when you no longer need it.

For separate build and artifact locations, every demo/check accepts:

```sh
python3 scripts/demo.py \
  --supervisor ./zig-out/bin/nether-supervisor \
  --nether /absolute/path/to/nether \
  --kernels /absolute/path/to/kernels
```

## Find a failed step

The runner prints its directory before starting. `supervisor.log` records
startup and tenant lifecycle events. Individual guest logs are at
`vms/<id>/nether.log`; the warm base uses `vms/00000000/`.

If the base fails to bake, check the base's log and confirm you prepared the
runtime image: Python alone is not enough; the agent and forwarder must also
be present and started by guest init. If a binary or guest artifact is missing,
the runner reports its path before starting any processes.

For your own guest application, set `guest_service_prestarted=true` and
`app_port` in the supervisor config. See [operations](operations.md) for the
application readiness and protocol behavior.
