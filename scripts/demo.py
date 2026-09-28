#!/usr/bin/env python3
"""Bake a running HTTP server once, then serve two independent warm VM forks."""

import re
import shlex
import time

from live import Supervisor, get, parser, require, run


def server_state(path):
    body = get(path)
    match = re.fullmatch(r"IID=(\d+) REQ=(\d+)", body)
    require(match is not None, f"unexpected demo server response: {body!r}")
    return tuple(map(int, match.groups()))


def demonstrate(supervisor):
    alpha, alpha_ms = supervisor.ensure("alpha")
    beta, beta_ms = supervisor.ensure("beta")
    require(alpha != beta, "different tenants received the same VM")
    a_id, a_count = server_state(alpha)
    b_id, b_count = server_state(beta)
    require(a_id == b_id, "the tenants did not inherit the same running server")
    require(a_count == b_count, "the forks started with different request counters")
    print(f"alpha: IID={a_id} REQ={a_count}  ensure={alpha_ms:.1f}ms")
    print(f"beta:  IID={b_id} REQ={b_count}  ensure={beta_ms:.1f}ms")

    # Two alpha requests must not advance beta's private copy of the counter.
    require(server_state(alpha) == (a_id, a_count + 1), "alpha counter did not advance")
    require(server_state(alpha) == (a_id, a_count + 2), "alpha counter did not advance twice")
    require(server_state(beta) == (b_id, b_count + 1), "alpha changed beta's counter")
    reused, hit_ms = supervisor.ensure("alpha")
    require(reused == alpha, "repeat ensure replaced alpha's VM")
    require(server_state(reused) == (a_id, a_count + 3), "repeat ensure reset alpha's state")
    print("PASS: both VMs inherited one warm server and have independent request counters.")
    print(f"PASS: repeat ensure reused alpha's VM and state ({hit_ms:.1f}ms).", flush=True)
    return alpha, beta


def main():
    cli = parser(__doc__)
    cli.add_argument("--hold", action="store_true",
                     help="leave the demo running until Ctrl-C so you can send requests")
    args = cli.parse_args()
    print("Preparing a warm base, then forking alpha and beta...", flush=True)
    with Supervisor(args, warm=True) as supervisor:
        alpha, beta = demonstrate(supervisor)
        if args.hold:
            print("\nSend requests from another terminal:")
            for path in (alpha, beta):
                print(f"  curl --unix-socket {shlex.quote(str(path))} http://localhost/")
            print("\nPress Ctrl-C to stop this supervisor and its VMs.", flush=True)
            while True:
                require(supervisor.process.poll() is None, "supervisor exited")
                time.sleep(.5)
    print("Demo complete. Processes stopped; run files retained.")


if __name__ == "__main__":
    run(main)
