# nether-supervisor

The 1c VM supervisor for the two-tier microVM platform (swerver Tier-1 gateway +
nether Tier-2 microVMs). It owns a pool of `nether` microVMs and answers
swerver's cold-start requests, closing the automated tenant cold-start loop.

## What it does

A two-sided broker:

- **North** (what swerver's `wasm_control_socket` dials): a Unix control socket
  speaking the nether control protocol (proto_version=1, `0x1e`-framed replies).
  Answers `__info__` and `ensure <tenant>` -> the tenant's warm VM `data_socket`
  path. This is what `~/platform/e2e/scripts/control_stub.py` fakes today.
- **South** (the VM pool): spawns/forks real `nether` processes, drives each
  one's control socket (readiness, snapshot, shutdown), and reclaims idle VMs.
  Each VM exposes a `data_socket` that swerver proxies to as a raw HTTP upstream.

swerver needs no changes: the supervisor is a drop-in for the stub plus real VM
lifecycle.

## Build

Requires Zig 0.16.0 (`~/Library/zig/0.16.0/zig`).

```sh
zig build            # build the daemon
zig build test       # run unit tests
zig build run        # run (reads nether-supervisor.conf from cwd)
```

## Status

Under active construction. See the build order in the plan: scaffold + config
(done), the wire codec, the south driver, a real-nether validation gate, then
the full pool, warm-fork start, hardening, and an e2e lane. The real VM path
requires macOS/HVF; the codec and driver unit tests are host-portable.

## Config

`nether-supervisor.conf` (`key = value`), read from the process cwd like nether's
own `nether.conf`. See the committed sample for every key and its default.
