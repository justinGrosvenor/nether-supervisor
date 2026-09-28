"""Shared runner for the demo and live checks (Python standard library only)."""

import argparse
import http.client
import os
from pathlib import Path
import platform
import signal
import socket
import subprocess
import tempfile
import time


ROOT = Path(__file__).resolve().parent.parent


def parser(description):
    result = argparse.ArgumentParser(description=description)
    result.add_argument("--nether-dir", type=Path, default=ROOT.parent / "nether",
                        help="Nether checkout (default: sibling nether directory)")
    result.add_argument("--supervisor", type=Path,
                        default=ROOT / "zig-out/bin/nether-supervisor")
    result.add_argument("--nether", type=Path, help="override the Nether executable")
    result.add_argument("--kernels", type=Path, help="override the guest artifacts directory")
    return result


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def connect(path, timeout=60):
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(timeout)
    try:
        sock.connect(str(path))
        return sock
    except BaseException:
        sock.close()
        raise


def command(path, line, timeout=60):
    """Read both the body and complete RS/exit-code/newline control trailer."""
    require("\n" not in line and "\r" not in line, "command must be one line")
    with connect(path, timeout) as sock:
        sock.sendall(line.encode() + b"\n")
        reply = bytearray()
        while True:
            chunk = sock.recv(4096)
            require(chunk, f"control closed before a complete reply to {line!r}")
            reply.extend(chunk)
            require(len(reply) <= 1024 * 1024, "control reply exceeded 1 MiB")
            body, marker, trailer = reply.partition(b"\x1e")
            if marker and b"\n" in trailer:
                return body.decode(), int(trailer.split(b"\n", 1)[0])


def request(path, target="/", timeout=15):
    """Return a socket and response; the caller owns and closes both."""
    sock = connect(path, timeout)
    try:
        sock.sendall(f"GET {target} HTTP/1.0\r\nHost: localhost\r\n\r\n".encode())
        response = http.client.HTTPResponse(sock)
        response.begin()
        return sock, response
    except BaseException:
        sock.close()
        raise


def get(path):
    sock, response = request(path)
    with sock, response:
        body = response.read(1024 * 1024).decode()
        require(response.status == 200, f"HTTP {response.status}: {body}")
        return body.strip()


class Supervisor:
    """An isolated supervisor and its own process group, with retained run files."""

    def __init__(self, args, *, warm=False, **settings):
        self.binary = args.supervisor.expanduser().resolve()
        nether_dir = args.nether_dir.expanduser().resolve()
        nether = (args.nether or nether_dir / "zig-out/bin/nether").expanduser().resolve()
        kernels = (args.kernels or nether_dir / "kernels").expanduser().resolve()
        for binary in (self.binary, nether):
            require(binary.is_file() and os.access(binary, os.X_OK),
                    f"executable missing: {binary}; build both repositories first")
        host = (platform.system(), platform.machine())
        if host == ("Darwin", "arm64"):
            artifacts = ("Image", "initramfs.cpio.gz")
        elif host == ("Linux", "x86_64"):
            artifacts = ("vmlinux", "initramfs")
            require(os.access("/dev/kvm", os.R_OK | os.W_OK),
                    "the Linux live checks need read/write access to /dev/kvm")
        else:
            raise RuntimeError("live VMs need Apple Silicon/macOS or Linux/x86-64 with KVM")
        for name in artifacts:
            path = kernels / name
            require(path.is_file() and path.stat().st_size > 0 and os.access(path, os.R_OK),
                    f"guest artifact missing or unreadable: {path}; see docs/quickstart.md")
        for path in (nether, kernels):
            require(not any(c in str(path) for c in "\n\r#"),
                    f"path cannot be represented in the supervisor config: {path}")

        # A short path also fits macOS's 104-byte Unix socket address limit.
        self.work = Path(tempfile.mkdtemp(prefix="nsup-", dir="/tmp"))
        self.north = self.work / "ctl.sock"
        self.log_path = self.work / "supervisor.log"
        self.warm = warm
        self.process = None
        self.log = None
        config = dict(control_socket=self.north, socket_dir=self.work,
                      work_root=self.work / "vms", nether_bin=nether,
                      kernels_dir=kernels, ram_mb=512, cpus=1, app_port=8080,
                      boot_budget_ms=40000, max_vms=16,
                      idle_ttl_ms=0, idle_timeout_s=0)
        if warm:
            config["base_snap"] = self.work / "base.snap"
        config.update(settings)
        (self.work / "nether-supervisor.conf").write_text(
            "".join(f"{key}={value}\n" for key, value in config.items()))

    def __enter__(self):
        print(f"Run files: {self.work}", flush=True)
        self.log = self.log_path.open("w")
        try:
            self.process = subprocess.Popen(
                [str(self.binary)], cwd=self.work, stdin=subprocess.DEVNULL,
                stdout=self.log, stderr=subprocess.STDOUT, start_new_session=True)
            deadline = time.monotonic() + 100
            while not self.north.exists():
                require(self.process.poll() is None, "supervisor exited during startup")
                require(time.monotonic() < deadline, "supervisor startup timed out")
                time.sleep(.05)
            _, code = command(self.north, "__info__", timeout=5)
            require(code == 0, "supervisor handshake failed")
            if self.warm:
                require("warm-fork base ready" in self.logs(),
                        "warm base failed to bake; the guest needs Python 3, the agent, "
                        "and the loopback forwarder (see docs/quickstart.md)")
            return self
        except BaseException:
            self.close()
            print(self.logs()[-6000:], flush=True)
            raise

    def logs(self):
        return self.log_path.read_text(errors="replace") if self.log_path.exists() else ""

    def ensure(self, tenant):
        require(tenant and not any(c.isspace() for c in tenant),
                "tenant must be a nonempty name without whitespace")
        started = time.monotonic()
        body, code = command(self.north, f"ensure {tenant}")
        require(code == 0, f"ensure {tenant}: {body.strip()}")
        path = Path(body.strip())
        require(path.is_socket(), f"ensure {tenant} returned no data socket: {path}")
        return path, (time.monotonic() - started) * 1000

    def group_alive(self):
        if self.process is None:
            return False
        try:
            os.killpg(self.process.pid, 0)
            return True
        except ProcessLookupError:
            return False

    def close(self):
        if self.process is not None:
            if self.process.poll() is None:
                self.process.terminate()
            deadline = time.monotonic() + 5
            while self.group_alive() and time.monotonic() < deadline:
                self.process.poll()  # reap the supervisor if it has exited
                time.sleep(.05)
            # Also covers interruption during the initial base bake, before the
            # supervisor's housekeeping thread starts. Never match global names.
            for sig in (signal.SIGTERM, signal.SIGKILL):
                if self.group_alive():
                    try:
                        os.killpg(self.process.pid, sig)
                    except ProcessLookupError:
                        pass
                    try:
                        self.process.wait(timeout=2)
                    except subprocess.TimeoutExpired:
                        pass
                    time.sleep(.1)
            self.process.wait(timeout=5)
        if self.log is not None:
            self.log.close()

    def __exit__(self, kind, value, traceback):
        self.close()
        if kind is not None and kind is not KeyboardInterrupt:
            print(self.logs()[-6000:], flush=True)


def run(main):
    try:
        main()
    except KeyboardInterrupt:
        print("\nStopped; demo processes have been shut down.")
        raise SystemExit(130)
    except (OSError, ValueError, RuntimeError, http.client.HTTPException,
            subprocess.SubprocessError) as error:
        raise SystemExit(f"FAIL: {error}") from None
