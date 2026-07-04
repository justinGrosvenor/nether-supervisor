set -u
# Supervision gate:
#   A) CRASH-EVICTION - kill a ready VM's process; the reaper evicts its tenant
#      so the next `ensure` re-cold-starts (a fresh vm id), not a dead socket.
#   B) SIGTERM TEARDOWN - the supervisor drains every VM (SIGTERM) and exits.
NS=~/nether-supervisor/zig-out/bin/nether-supervisor
NETHER_BIN=$HOME/nether/zig-out/bin/nether
WORK=/tmp/nsup
pkill -f "nether-supervisor" 2>/dev/null; pkill -f "$NETHER_BIN" 2>/dev/null; sleep 0.3
rm -rf "$WORK"; mkdir -p "$WORK"
cat > "$WORK/nether-supervisor.conf" <<CONF
control_socket = /tmp/nsup/ctl.sock
socket_dir = /tmp/nsup
work_root = /tmp/nsup/vms
kernels_dir = $HOME/nether/kernels
nether_bin = $NETHER_BIN
ram_mb = 512
cpus = 1
app_port = 8080
boot_budget_ms = 40000
CONF
cat > "$WORK/ensure.py" <<'PY'
import socket,sys
s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM); s.settimeout(45); s.connect("/tmp/nsup/ctl.sock")
s.sendall(b"ensure "+sys.argv[1].encode()+b"\n")
buf=b""
while b"\x1e" not in buf:
    d=s.recv(4096)
    if not d: break
    buf+=d
print(buf.split(b"\x1e")[0].decode())
PY
( cd "$WORK" && exec "$NS" >"$WORK/sup.log" 2>&1 ) & SUP=$!
for i in $(seq 1 50); do [ -S "$WORK/ctl.sock" ] && break; sleep 0.1; done
[ -S "$WORK/ctl.sock" ] || { echo "FAIL: north socket never appeared"; tail -20 "$WORK/sup.log"; kill $SUP 2>/dev/null; exit 1; }

echo "=== A) boot alpha, then kill its VM to simulate a crash ==="
SOCK1=$(python3 "$WORK/ensure.py" alpha)
echo "alpha -> $SOCK1"
VMPID=$(pgrep -f "$NETHER_BIN" | head -1)
echo "killing VM pid $VMPID (SIGKILL)"
kill -9 "$VMPID" 2>/dev/null
# Give the 250ms housekeeping reaper a few ticks to evict.
sleep 1.5
echo "=== re-ensure alpha: should re-cold-start (new vm) ==="
SOCK2=$(python3 "$WORK/ensure.py" alpha)
echo "alpha (after crash) -> $SOCK2"
BOOTS=$(grep -c "cold boot vm=" "$WORK/sup.log")
EVICTED=$(grep -c "exited unexpectedly" "$WORK/sup.log")
echo "cold boots: $BOOTS   evictions logged: $EVICTED"

echo "=== B) SIGTERM the supervisor; expect graceful teardown ==="
kill -TERM "$SUP" 2>/dev/null
for i in $(seq 1 40); do kill -0 "$SUP" 2>/dev/null || break; sleep 0.1; done
if kill -0 "$SUP" 2>/dev/null; then EXITED=0; kill -9 "$SUP" 2>/dev/null; else EXITED=1; fi
TORN=$(grep -c "teardown: SIGTERM sent" "$WORK/sup.log")
echo "supervisor exited on SIGTERM: $EXITED   teardown logged: $TORN"
echo "=== log tail ==="; tail -8 "$WORK/sup.log"
pkill -f "$NETHER_BIN" 2>/dev/null

echo "--- verdict ---"
PASS=1
[ "$EVICTED" -ge 1 ] || { echo "CRASH-EVICTION FAIL: no eviction logged"; PASS=0; }
[ "$BOOTS" -ge 2 ] || { echo "CRASH-EVICTION FAIL: re-ensure did not re-boot (boots=$BOOTS)"; PASS=0; }
[ -n "$SOCK2" ] && [ "$SOCK1" != "$SOCK2" ] || { echo "CRASH-EVICTION FAIL: same/empty socket after crash ($SOCK1 vs $SOCK2)"; PASS=0; }
[ "$EXITED" = "1" ] && [ "$TORN" -ge 1 ] || { echo "TEARDOWN FAIL: exited=$EXITED teardown=$TORN"; PASS=0; }
[ "$PASS" = "1" ] && echo "SUPERVISION GATE: PASS" || echo "SUPERVISION GATE: FAIL"
