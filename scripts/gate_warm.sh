set -u
# Warm-fork gate: the supervisor bakes a base snapshot at startup, then each
# `ensure <tenant>` FORKS from it (restore=1) instead of cold-booting. Proof of
# a real fork (not a fresh boot): every tenant inherits the base's RUNNING server
# over CoW, so all of them serve the SAME server IID with independent REQ
# counters. We also time the ensures: a fork is ~sub-second vs a multi-second
# cold boot.
NS=~/nether-supervisor/zig-out/bin/nether-supervisor
WORK=/tmp/nsup
pkill -f "nether-supervisor" 2>/dev/null; pkill -f "/tmp/nsup/vms" 2>/dev/null; sleep 0.3
rm -rf "$WORK"; mkdir -p "$WORK"
cat > "$WORK/nether-supervisor.conf" <<CONF
control_socket = /tmp/nsup/ctl.sock
socket_dir = /tmp/nsup
work_root = /tmp/nsup/vms
kernels_dir = $HOME/nether/kernels
nether_bin = $HOME/nether/zig-out/bin/nether
base_snap = /tmp/nsup/base.snap
ram_mb = 512
cpus = 1
app_port = 8080
boot_budget_ms = 40000
CONF

ensure() { # $1=tenant -> prints "<ms> <datasock>"
  python3 - "$1" <<'PY'
import socket,sys,time
t=sys.argv[1].encode()
s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM); s.settimeout(45); s.connect("/tmp/nsup/ctl.sock")
t0=time.time(); s.sendall(b"ensure "+t+b"\n")
buf=b""
while b"\x1e" not in buf:
    d=s.recv(4096)
    if not d: break
    buf+=d
ms=int((time.time()-t0)*1000)
print("%d %s"%(ms, buf.split(b"\x1e")[0].decode()))
PY
}
serve() { # $1=datasock -> prints IID line body
  curl -s --max-time 10 --unix-socket "$1" http://localhost/
}

echo "=== booting supervisor; it bakes the base at startup (cwd=$WORK) ==="
( cd "$WORK" && exec "$NS" >"$WORK/sup.log" 2>&1 ) &
SUP=$!
# Wait for the north socket. The base bake happens BEFORE the socket binds, so
# by the time it appears the base is ready to fork.
for i in $(seq 1 600); do [ -S "$WORK/ctl.sock" ] && break; sleep 0.1; done
[ -S "$WORK/ctl.sock" ] || { echo "FAIL: north socket never appeared"; tail -30 "$WORK/sup.log"; kill $SUP 2>/dev/null; exit 1; }
grep -q "warm-fork base ready" "$WORK/sup.log" || { echo "FAIL: base never baked"; tail -30 "$WORK/sup.log"; kill $SUP 2>/dev/null; exit 1; }
echo "=== base baked; forking two tenants ==="

read A_MS A_SOCK < <(ensure alpha)
echo "ensure alpha: ${A_MS}ms -> $A_SOCK"
read B_MS B_SOCK < <(ensure beta)
echo "ensure beta:  ${B_MS}ms -> $B_SOCK"

A_BODY=$(serve "$A_SOCK"); echo "alpha serves: '$A_BODY'"
B_BODY=$(serve "$B_SOCK"); echo "beta  serves: '$B_BODY'"

A_IID=$(echo "$A_BODY" | sed -n 's/.*IID=\([0-9]*\).*/\1/p')
B_IID=$(echo "$B_BODY" | sed -n 's/.*IID=\([0-9]*\).*/\1/p')
echo "=== supervisor log tail ==="; tail -10 "$WORK/sup.log"
kill $SUP 2>/dev/null; pkill -f "/tmp/nsup/vms" 2>/dev/null

echo "--- verdict ---"
echo "alpha IID=$A_IID  beta IID=$B_IID"
if [ -n "$A_IID" ] && [ "$A_IID" = "$B_IID" ]; then
  echo "WARM-FORK GATE: PASS (both tenants inherited the same base server $A_IID; alpha ${A_MS}ms, beta ${B_MS}ms)"
else
  echo "WARM-FORK GATE: FAIL (IIDs differ or missing -> not forks of one base)"
fi
