#!/usr/bin/env python3
"""Live regression: capacity pressure and idle expiry preserve an active response.

Requires matching Nether/supervisor builds and a guest image with Python and the
forwarder. Works with HVF or KVM artifacts. Uses a private directory and only
terminates processes it launches. Logs are retained at the printed path.
"""
import http.client
import shlex
import time

from live import Supervisor, command, parser, request, require, run


SERVER = '''
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import time
class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        body = b'finished\\n'
        self.send_response(200)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.flush()
        if self.path == '/slow':
            time.sleep(8)
        self.wfile.write(body)
ThreadingHTTPServer(('127.0.0.1', 8080), Handler).serve_forever()
'''


def main():
    args = parser(__doc__).parse_args()
    with Supervisor(args, max_vms=1, idle_ttl_ms=5000, idle_timeout_s=90) as supervisor:
        data, _ = supervisor.ensure("alpha")
        control = str(data).replace(".data.sock", ".control.sock")
        # Replace only the demo Python process in this check's private guest.
        code_text = "exec(bytes.fromhex(" + repr(SERVER.encode().hex()) + "))"
        _, code = command(control, "killall python3; python3 -c " + shlex.quote(code_text)
                          + " >/tmp/idle-proof.log 2>&1 &")
        require(code == 0, "could not start the slow-response server")
        deadline = time.monotonic() + 3
        while True:
            try:
                sock, response = request(data)
                with sock, response:
                    require(response.read() == b"finished\n", "unexpected response")
                break
            except (OSError, http.client.HTTPException):
                if time.monotonic() >= deadline:
                    raise
                time.sleep(.05)
        started = time.monotonic()
        sock, response = request(data, "/slow")
        with sock, response:
            # Header receipt proves the VM is already serving this request.
            rejected, code = command(supervisor.north, "ensure beta")
            require(code != 0 and "pool full" in rejected, f"unexpected admission: {rejected}")
            require(response.read() == b"finished\n", "response truncated")
        require(time.monotonic() - started >= 8, "slow response did not span the idle limit")
        print("PASS: full pool rejected beta; alpha finished its 8s response across the 5s idle limit.", flush=True)
        # A cached data-plane hit bypasses ensure but must restart idle age.
        time.sleep(3)
        sock, response = request(data)
        with sock, response:
            require(response.read() == b"finished\n", "cached request failed")
        time.sleep(3)
        rejected, code = command(supervisor.north, "ensure beta")
        require(code != 0 and "pool full" in rejected, "cached traffic did not refresh idle age")
        deadline = time.monotonic() + 10
        while True:
            replacement, code = command(supervisor.north, "ensure beta")
            if code == 0:
                require(replacement.strip() != str(data), "replacement reused the old VM")
                break
            require("pool full" in replacement, replacement)
            require(time.monotonic() < deadline, "idle VM never reclaimed")
            time.sleep(.25)
        print("PASS: cached traffic refreshed idle age; after idle exit beta received a new VM.", flush=True)


if __name__ == "__main__":
    run(main)
