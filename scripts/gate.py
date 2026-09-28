#!/usr/bin/env python3
"""Live checks for cold serving, concurrency, crash recovery, and status endpoints."""

from concurrent.futures import ThreadPoolExecutor
import http.client
import json
import os
import secrets
import signal
import socket
import subprocess
import time

from live import Supervisor, get, parser, require, run


def cold(args):
    with Supervisor(args) as supervisor:
        path, elapsed = supervisor.ensure("alpha")
        body = get(path)
        require(body.startswith("IID="), f"unexpected response: {body}")
        reused, _ = supervisor.ensure("alpha")
        require(reused == path, "repeat ensure did not reuse the VM")
        print(f"PASS: cold tenant serves HTTP and is reused ({elapsed:.1f}ms ensure).")


def concurrent(args):
    with Supervisor(args) as supervisor, ThreadPoolExecutor(max_workers=4) as workers:
        results = list(workers.map(supervisor.ensure, ["alpha"] * 4))
        require(len({path for path, _ in results}) == 1, "same-tenant boots were not deduplicated")
        require(supervisor.logs().count("ensure alpha: cold boot vm=") == 1,
                "concurrent alpha requests launched more than one VM")
        get(results[0][0])
        started = time.monotonic()
        results = list(workers.map(supervisor.ensure, ("p", "q", "r")))
        elapsed = (time.monotonic() - started) * 1000
        require(len({path for path, _ in results}) == 3, "distinct tenants shared a VM")
        for path, _ in results:
            get(path)
        # Actual overlap, rather than a timing ratio that varies with host load:
        # all three boots must start before the first one finishes bring-up.
        logs = supervisor.logs()
        starts = [logs.index(f"ensure {name}: cold boot vm=") for name in ("p", "q", "r")]
        ends = [logs.index(f"ensure {name}: SERVING vm=") for name in ("p", "q", "r")]
        require(max(starts) < min(ends), "distinct tenant bring-ups did not overlap")
        print("PASS: four concurrent requests shared one alpha boot.")
        print(f"PASS: three distinct tenants booted concurrently and served HTTP ({elapsed:.1f}ms).")


def reaper(args):
    with Supervisor(args) as supervisor:
        first, _ = supervisor.ensure("alpha")
        get(first)
        # Inspect only children in this runner's dedicated process group. Never
        # find a VM by executable name: another demo or service may be running.
        rows = subprocess.check_output(["ps", "-axo", "pid=,ppid=,pgid="], text=True)
        children = [int(pid) for pid, parent, group in
                    (line.split() for line in rows.splitlines())
                    if int(parent) == supervisor.process.pid == int(group)]
        require(len(children) == 1, f"expected one owned VM child; found {len(children)}")
        pid = children[0]
        require(os.getpgid(pid) == supervisor.process.pid, "VM left the runner's process group")
        os.kill(pid, signal.SIGKILL)
        deadline = time.monotonic() + 5
        while "exited unexpectedly" not in supervisor.logs():
            require(time.monotonic() < deadline, "crashed VM was not reaped")
            time.sleep(.05)
        second, _ = supervisor.ensure("alpha")
        require(first != second, "crashed tenant returned its old socket")
        get(second)
        print("PASS: a crashed VM was evicted and its tenant served from a new VM.")
        supervisor.process.terminate()
        require(supervisor.process.wait(timeout=5) == 0, "supervisor shutdown failed")
        require("teardown: SIGTERM sent" in supervisor.logs(), "VM teardown was not requested")
        deadline = time.monotonic() + 5
        while supervisor.group_alive():
            require(time.monotonic() < deadline, "VM survived supervisor shutdown")
            time.sleep(.05)
        print("PASS: supervisor SIGTERM shut down its VM and exited.")


def status(args):
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        port = reservation.getsockname()[1]
    key = secrets.token_hex(16)
    with Supervisor(args, status_addr=f"127.0.0.1:{port}",
                    status_service_key=key) as supervisor:
        path, _ = supervisor.ensure("alpha")
        get(path)
        require("status surface listening" in supervisor.logs(), "status endpoint did not bind")

        def fetch(target, token=None):
            connection = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
            try:
                headers = {"Authorization": f"Bearer {token}"} if token else {}
                connection.request("GET", target, headers=headers)
                with connection.getresponse() as response:
                    return response.status, response.read().decode()
            finally:
                connection.close()

        for target in ("/metrics", "/status"):
            require(fetch(target)[0] == 401, f"{target} accepted a missing key")
            require(fetch(target, "wrong")[0] == 401, f"{target} accepted a wrong key")
        code, body = fetch("/metrics", key)
        require(code == 200 and "nsup_ensures_total 1\n" in body,
                "authenticated metrics did not report the tenant request")
        code, body = fetch("/status", key)
        require(code == 200 and json.loads(body)["vms_warm"] == 1,
                "authenticated status did not report the ready VM")
        print("PASS: status and metrics require the key and report the live tenant.")


def main():
    cli = parser(__doc__)
    cli.add_argument("check", choices=("cold", "concurrent", "reaper", "status"))
    args = cli.parse_args()
    {"cold": cold, "concurrent": concurrent, "reaper": reaper, "status": status}[args.check](args)


if __name__ == "__main__":
    run(main)
