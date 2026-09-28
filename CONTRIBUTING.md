# Contributing

Issues about real workloads and first-run setup are especially useful. Include
what you're building, what you tried, and what happened. Small reproductions
and documentation improvements are welcome.

## Build and check a change

Use Zig **0.16.0** on macOS or Linux:

```sh
zig fmt --check build.zig build.zig.zon src
zig build -Doptimize=ReleaseSafe
zig build test
zig build test -Doptimize=ReleaseSafe
python3 -m py_compile scripts/*.py
```

Unit tests do not need Nether or a guest image. CI runs the build and unit tests
on macOS/ARM64 and Linux/x86-64 in Debug and ReleaseSafe modes.

For changes to launch, readiness, pooling, or shutdown, run the relevant
[live checks](docs/operations.md#checks) with matching Nether sources. The
[quickstart](docs/quickstart.md) prepares the guest artifacts.

## Reporting a problem

Include the host OS and architecture, `zig version`, the supervisor and Nether
commit IDs, the command you ran, and the relevant log excerpt. If either checkout
has local changes, mention them. The demo prints its run directory; start with
`supervisor.log` and the affected VM's `nether.log`.

For a feature request, describe the workflow you want to support and the part
that is currently difficult. This helps us choose an interface that fits real
applications.

## Pull requests

Explain the behavior changed and how you checked it. Keep changes focused, add
regression coverage for behavior changes, and update the relevant examples or
docs when the public workflow changes. Follow the existing Zig formatting and
module layout. Contributions are under the repository's [Apache-2.0 license](LICENSE).

The source entry point is `src/main.zig`. Pool decisions live in `src/pool.zig`,
process lifecycle in `src/supervisor.zig`, guest bring-up in `src/boot.zig`, and
control framing in `src/proto.zig` and the control client/server modules.
